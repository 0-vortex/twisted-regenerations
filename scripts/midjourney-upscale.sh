#!/usr/bin/env bash

set -euo pipefail

# Check for required tools
for cmd in tput uname mktemp curl unzip find sort awk; do
  if ! command -v $cmd >/dev/null; then
    echo -e "${cmd} is not installed, but is required."
    exit 1
  fi
done

# Get the number of supported colors
NUM_COLORS="$(tput colors || echo 0)"

# Terminal color constants
RED=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 1 || printf '')
YELLOW=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 3 || printf '')
GREEN=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 2 || printf '')
BLUE=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 4 || printf '')
MAGENTA=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 5 || printf '')
CYAN=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 6 || printf '')
GRAY=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 7 || printf '')
NC=$([ "$NUM_COLORS" -gt 7 ] && tput sgr0 || printf '')

# Helper functions
error() {
  echo -e "${RED}Error: $*${NC}" >&2
  exit 1
}

debug() {
  echo -e "${CYAN}Log: $*${NC}" >&2
}

BIN_SHASUM="sha256sum"

# Identify platform needs to happen before setting default values
UNAME="$(uname -s)"
case "${UNAME}" in
Linux*)
  PLATFORM=linux
  ;;
Darwin*)
  PLATFORM=macos
  BIN_SHASUM="shasum -a 256"
  ;;
CYGWIN* | MINGW32* | MSYS* | MINGW*)
  PLATFORM=windows
  ;;
*)
  PLATFORM="unknown"
  ;;
esac

if [[ ${PLATFORM} == "unknown" ]]; then
  error "Unsupported platform \"$UNAME\""
fi

# Set default values
POSITIONAL_ARGS=()
UPSCALER_FOLDER="${MJU_UPSCALER_FOLDER:-"./scripts/realesrgan-ncnn-vulkan-20220424-$PLATFORM"}"
UPSCALER_COMMAND="${MJU_UPSCALER_COMMAND:-"realesrgan-ncnn-vulkan"}"
UPSCALER_FACTOR="${MJU_UPSCALER_FACTOR:-"4k"}"
UPSCALER_MODEL="${MJU_UPSCALER_MODEL:-"realesrgan-x4plus"}"
PROCESS_LOCK_FILE="$(mktemp /tmp/upscaler.sh.lock.XXXXXX)" && rm -f "$PROCESS_LOCK_FILE"
SUCCESS_LOCK_FILE=$(mktemp /tmp/upscaler.sh.success.XXXXXX)
FAILED_LOCK_FILE=$(mktemp /tmp/upscaler.sh.failed.XXXXXX)
SKIPPED_LOCK_FILE=$(mktemp /tmp/upscaler.sh.skipped.XXXXXX)
export UPSCALER_FOLDER UPSCALER_COMMAND UPSCALER_FACTOR UPSCALER_MODEL PROCESS_LOCK_FILE SUCCESS_LOCK_FILE FAILED_LOCK_FILE SKIPPED_LOCK_FILE
declare -A VALID_CHECKSUMS
VALID_CHECKSUMS["realesrgan-ncnn-vulkan-20220424-macos.zip"]="e0ad05580abfeb25f8d8fb55aaf7bedf552c375b5b4d9bd3c8d59764d2cc333a"
VALID_CHECKSUMS["realesrgan-ncnn-vulkan-20220424-windows.zip"]="abc02804e17982a3be33675e4d471e91ea374e65b70167abc09e31acb412802d"
VALID_CHECKSUMS["realesrgan-ncnn-vulkan-20220424-ubuntu.zip"]="e5aa6eb131234b87c0c51f82b89390f5e3e642b7b70f2b9bbe95b6a285a40c96"

# Define a function to show help
showHelp() {
  echo -e "${YELLOW}Usage: ./scripts/midjourney-upscaler.sh [--help] [-u|--upscaler-path PATH] [-f|--factor 4K|8K] DIRECTORY${NC}"
  echo -e "\nUpscale all images in a directory (and its subdirectories) using a specified upscaler."
  echo -e "\n${CYAN}Options:${NC}"
  echo -e "  ${CYAN}--help${NC}                     ${GRAY}Show this help message and exit${NC}"
  echo -e "  ${CYAN}-u, --upscaler-path PATH${NC}   ${GRAY}Set the path to the upscaler binary (default: \"${UPSCALER_FOLDER}\")${NC}"
  echo -e "  ${CYAN}-f, --factor 4K|8K${NC}         ${GRAY}Set the upscale factor (default: \"${UPSCALER_FACTOR}\")${NC}"
  echo -e "  ${CYAN}-m, --model MODEL${NC}          ${GRAY}Set the upscale model (default: \"${UPSCALER_MODEL}\")${NC}"
  echo -e "\n${CYAN}Environment Variables:${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_FOLDER${NC}        ${GRAY}Path to the upscaler binary (default: \"${UPSCALER_FOLDER}\")${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_COMMAND${NC}       ${GRAY}The upscaler command (default: \"${UPSCALER_COMMAND}\")${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_FACTOR${NC}        ${GRAY}The upscale factor (default: \"${UPSCALER_FACTOR}\")${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_MODEL${NC}         ${GRAY}The upscale model (default: \"${UPSCALER_MODEL}\")${NC}"

  exit 0
}

# Show help if no arguments are passed
if [ $# -eq 0 ]; then
  showHelp
fi

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
  -u | --upscaler-path)
    UPSCALER_FOLDER="$2"
    shift 2
    ;;
  -f | --factor)
    UPSCALER_FACTOR=$(echo "$2" | tr '[:upper:]' '[:lower:]')
    shift 2
    ;;
  -m | --model)
    UPSCALER_MODEL="$2"
    shift 2
    ;;
  --* | -*)
    error "Unknown option $1"
    ;;
  *)
    POSITIONAL_ARGS+=("$1") # save positional arg
    shift                   # past argument
    ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Validate command-line arguments
if [[ "$UPSCALER_FACTOR" != "4k" && "$UPSCALER_FACTOR" != "8k" ]]; then
  error "Invalid factor $UPSCALER_FACTOR. Must be 4k or 8k."
fi
if [[ ! -v "POSITIONAL_ARGS[0]" ]]; then
  error "Invalid PATH provided."
fi
if [[ ! -d "$UPSCALER_FOLDER" ]]; then
  temp_installer="$(mktemp /tmp/upscaler.bin.XXXXXX)"
  temp_sha="$(mktemp /tmp/upscaler.sha.XXXXXX)"
  release="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-$PLATFORM.zip"

  debug "Upscaler folder not found. Attempting to download..."
  curl -L "$release" --output "$temp_installer"

  # Extract the filename from the URL
  file_name=$(basename "$release")

  # Get the expected checksum from the associative array
  expected_checksum=${VALID_CHECKSUMS["$file_name"]}

  # If the expected checksum is not empty, verify the checksum
  if [[ -n "$expected_checksum" ]]; then
    verify_checksum "$temp_installer" "$expected_checksum"
  fi

  mkdir -p "$UPSCALER_FOLDER"
  unzip "$temp_installer" -d "$UPSCALER_FOLDER"
  chmod +x "$UPSCALER_FOLDER/$UPSCALER_COMMAND"
  rm "$temp_installer" "$temp_sha"
fi

# Check sha256sum if checksum is available
verify_checksum() {
  local file_path=$1
  local expected_checksum=$2

  # Compute the checksum
  local actual_checksum
  actual_checksum=$($BIN_SHASUM "$file_path" | awk '{print $1}')

  # Compare the checksums
  if [[ "$actual_checksum" != "$expected_checksum" ]]; then
    error "Checksum verification failed for $file_path"
  fi
}

# Trapping exit to clean up temp files
trap cleanup EXIT INT

cleanup() {
  rm -f "$PROCESS_LOCK_FILE" "$SUCCESS_LOCK_FILE" "$FAILED_LOCK_FILE" "$SKIPPED_LOCK_FILE"
}

process_file() {
  local img output_img current_dir

  img=$0
  output_img="${img%.*}.${UPSCALER_MODEL}-${UPSCALER_FACTOR}.webp"
  current_dir=$(pwd)
  short_name=$(basename "$img")

  # Wait until the lock file is removed
  while [ -e "$PROCESS_LOCK_FILE" ]; do
    sleep 1
  done

  if [[ -e "$output_img" && $(du -k "$output_img" | cut -f1) -gt $(du -k "$img" | cut -f1) ]]; then
    echo -e "$short_name is already upscaled, skipping..."
    echo "$(basename "$output_img");;$(du -k "$output_img" | awk '{print $1}')" >>"$SKIPPED_LOCK_FILE"
  else
    # Create a lock file
    touch "$PROCESS_LOCK_FILE"

    # Use the upscaler command and suppress its output
    echo "Upscaling $short_name..."

    # Use parentheses to run commands in a subshell, so the cd command doesn't affect your main script
    (cd "$UPSCALER_FOLDER" && ./"$UPSCALER_COMMAND" -n "$UPSCALER_MODEL" -v -x -f webp -i "$img" -o "$output_img" >/dev/null 2>&1)

    # Check the status of the previous command
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      # If the command failed, append the image path to the failed results array
      echo "$img" >>"$FAILED_LOCK_FILE"
    else
      echo "$(basename "$output_img");;$(du -k "$output_img" | awk '{print $1}')" >>"$SUCCESS_LOCK_FILE"
    fi

    # Remove the lock file
    rm "$PROCESS_LOCK_FILE"
  fi

  # Change back to the original directory
  cd "$current_dir"
}

export -f process_file

#IMAGES=$(find "$1" -type f \( -iname '*.webp' -o -iname '*.png' -o -iname '*.jpg' \))
IMAGES=$(find "$1" -type f \( -iname '*.png' -o -iname '*.jpg' \))
if [ -z "$IMAGES" ]; then
  error "No images found in the directory."
else
  echo "$IMAGES" | xargs -I {} bash -c 'process_file "$1"' {}
fi

# Function to format and print results
format_and_print_results() {
  local color="$1"
  local title="$2"
  local columns="$3"
  local lock_file="$4"
  local parsed_results
  local header_len

  header_len=$(awk -F "," '{print NF}' <<<"${columns}")

  echo -e "\n${color}$title:${NC}"

  parsed_results=$(awk -v columns="$columns" '
  BEGIN {
    FS = ";;"
    header_len=split(columns, header_arr, ",");
    for (i = 1; i < header_len; i++) {
      printf("%s\t", header_arr[i])
    }
    printf("%s\n", header_arr[header_len])
  }
  {
    split(tolower($1), tpc, "_");
    topic = tpc[2];
    a[topic]++;
    sum[topic]+=$2
  }
  END {
    for (i in a) printf("%s\t%s\t%.2f\n", i, a[i], sum[i]/1024)
  }' "$lock_file")

  # Calculate column widths
  widths=$(awk '
  BEGIN {
    FS = "\t";
    max_width = 0;
    for (i = 1; i <= NF; i++) {
      col_width[i] = 0;
    }
  }
  {
    for (i = 1; i <= NF; i++) {
      if (length($i) > col_width[i]) col_width[i] = length($i);
    }
  }
  END {
    for (i = 1; i <= NF; i++) {
      printf("%d", col_width[i]);
      if (i < NF) {
        printf(" ");
      }
    }
  }' <<<"$parsed_results")

  # Print the formatted table
  awk -v header_len="$header_len" -v widths="$widths" -v YELLOW="${YELLOW}" -v GRAY="${GRAY}" -v GREEN="${GREEN}" -v NC="${NC}" -v FS="\t" '
    function repeat(s, n, r) {
      while (n--) r = r s;
      return r;
    }
    function print_line(color) {
      printf("│");
      for (i = 1; i <= header_len; i++) {
        printf(" %s%-*s%s", color, col_width[i], $i, NC);
        if (i < header_len) {
          printf(" │");
        }
      }
      printf(" │\n");
    }
    function print_horizontal_border(left_border, middle_border, right_border) {
      left_border = left_border == "" ? "┌" : left_border
      middle_border = middle_border == "" ? "┬" : middle_border
      right_border = right_border == "" ? "┐" : right_border

      printf(left_border);
      for (i = 1; i <= header_len; i++) {
        printf("%s", repeat("─", col_width[i] + 2));
        if (i < header_len) {
          printf(middle_border);
        }
      }
      printf(right_border "\n");
    }
    BEGIN {
      # Read column widths into an array
      split(widths, col_width, " ");

      # Print the top border
      print_horizontal_border();

      # Read and print the header row
      getline;
      print_line(YELLOW);

      # Print the border below the header
      print_horizontal_border("├", "┼", "┤");
    }
    {
      # Print the row data with proper spacing
      print_line(GREEN);
      row_count++;
    }
    END {
      # Print the bottom border
      print_horizontal_border("└", "┴", "┘\n");
    }' <<<"$parsed_results"
}

# Print the successful and failed results
if [[ -s "$SUCCESS_LOCK_FILE" ]]; then
  format_and_print_results "$GREEN" "Successful upscales" "Subject,Count,Size (MB)" "$SUCCESS_LOCK_FILE"
fi

if [[ -s "$FAILED_LOCK_FILE" ]]; then
  format_and_print_results "$RED" "Failed upscales" "Topic,Count" "$FAILED_LOCK_FILE"
fi

if [[ -s "$SKIPPED_LOCK_FILE" ]]; then
  format_and_print_results "$YELLOW" "Skipped upscales" "Subject,Count,Size (MB)" "$SKIPPED_LOCK_FILE"
fi

# Delete temp files
cleanup
