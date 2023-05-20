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
GREEN=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 2 || printf '')
YELLOW=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 3 || printf '')
CYAN=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 6 || printf '')
GRAY=$([ "$NUM_COLORS" -gt 7 ] && tput setaf 7 || printf '')
NC=$([ "$NUM_COLORS" -gt 7 ] && tput sgr0 || printf '')

# Helper functions
error() {
  echo -e "${RED}Error: $*${NC}" >&2
  exit 1
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
PROCESS_LOCK_FILE="$(mktemp /tmp/upscaler.sh.lock.XXXXXX)" && rm -f "$PROCESS_LOCK_FILE"
SUCCESS_LOCK_FILE=$(mktemp /tmp/upscaler.sh.success.XXXXXX)
FAILED_LOCK_FILE=$(mktemp /tmp/upscaler.sh.failed.XXXXXX)
export UPSCALER_FOLDER UPSCALER_COMMAND UPSCALER_FACTOR PROCESS_LOCK_FILE SUCCESS_LOCK_FILE FAILED_LOCK_FILE
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
  echo -e "\n${CYAN}Environment Variables:${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_FOLDER${NC}        ${GRAY}Path to the upscaler binary (default: \"${UPSCALER_FOLDER}\")${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_COMMAND${NC}       ${GRAY}The upscaler command (default: \"${UPSCALER_COMMAND}\")${NC}"
  echo -e "  ${CYAN}MJU_UPSCALER_FACTOR${NC}        ${GRAY}The upscale factor (default: \"${UPSCALER_FACTOR}\")${NC}"

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
    if [[ "$UPSCALER_FACTOR" != "4k" && "$UPSCALER_FACTOR" != "8k" ]]; then
      error "Invalid factor $UPSCALER_FACTOR. Must be 4k or 8k."
    fi
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

if [[ ! -v "POSITIONAL_ARGS[0]" ]]; then
  error "Invalid PATH provided."
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

# Check if UPSCALER_FOLDER exists
if [[ ! -d "$UPSCALER_FOLDER" ]]; then
  temp_installer="$(mktemp /tmp/upscaler.bin.XXXXXX)"
  temp_sha="$(mktemp /tmp/upscaler.sha.XXXXXX)"
  release="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-$PLATFORM.zip"

  echo "Upscaler folder not found. Attempting to download..."
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

# Check if factor is 4k or 8k
if [[ "$UPSCALER_FACTOR" != "4k" && "$UPSCALER_FACTOR" != "8k" ]]; then
  error "Invalid upscale factor: \"$UPSCALER_FACTOR\". Only \"4k\" and \"8k\" are supported."
fi

# Trapping exit to clean up temp files
trap cleanup EXIT INT

cleanup() {
  rm -f "$PROCESS_LOCK_FILE" "$SUCCESS_LOCK_FILE" "$FAILED_LOCK_FILE"
}

# Function to format and print results
format_and_print_results() {
  local color=$1
  shift

  for item in "$@"; do
    echo -e "${color}$item${NC}\n"
  done
}

process_file() {
  local img model output_img current_dir

  img=$0
  model="realesrgan-x4plus"
  output_img="${img%.*}.$model-${UPSCALER_FACTOR}.webp"
  current_dir=$(pwd)
  short_name=$(basename "$img")

  # Wait until the lock file is removed
  while [ -e "$PROCESS_LOCK_FILE" ]; do
    sleep 1
  done

  if [[ -e "$output_img" && $(du -k "$output_img" | cut -f1) -gt $(du -k "$img" | cut -f1) ]]; then
    echo "$short_name is already upscaled, skipping..."
    return
  fi

  # Create a lock file
  touch "$PROCESS_LOCK_FILE"

  # Use the upscaler command and suppress its output
  echo "Upscaling $img"

  # Use parentheses to run commands in a subshell, so the cd command doesn't affect your main script
  (cd "$UPSCALER_FOLDER" && ./$UPSCALER_COMMAND -n "$model" -v -x -f webp -i "$img" -o "$output_img" >/dev/null 2>&1)
#  (cd "$UPSCALER_FOLDER" && ls -l "$img" >/dev/null 2>&1)

  # Check the status of the previous command
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    # If the command failed, append the image path to the failed results array
    echo "$img" >>"$FAILED_LOCK_FILE"
  else
    echo "$(basename "$short_name");;$(du -k "$img" | awk '{print $1}')" >>"$SUCCESS_LOCK_FILE"
  fi

  # Remove the lock file
  rm "$PROCESS_LOCK_FILE"

  # Change back to the original directory
  cd "$current_dir"
}

export -f process_file

IMAGES=$(find "$1" -type f \( -iname \*.jpg -o -iname \*.png \))
if [ -z "$IMAGES" ]; then
  error "No images found in the directory."
else
  echo "$IMAGES" | xargs -I {} bash -c 'process_file "$1"' {}
fi

# After processing the directory, read the results from the temporary files
#mapfile -t RESULTS_FAILED <"$FAILED_LOCK_FILE"
#RESULTS_SUCCESS=$(awk -F";;" 'BEGIN{print "Subject\tCount\tSize (MB)"} {a[$1]++; sum[$1]+=$2} END{for (i in a) printf("%s\t%s\t%.2f", i, a[i], sum[i]/1024)}' "$SUCCESS_LOCK_FILE")
if [ -s "$FAILED_LOCK_FILE" ]; then
  mapfile -t RESULTS_FAILED <"$FAILED_LOCK_FILE"
fi
if [ -s "$SUCCESS_LOCK_FILE" ]; then
  RESULTS_SUCCESS=$(awk -F";;" 'BEGIN{print "Subject\tCount\tSize (MB)"} {a[$1]++; sum[$1]+=$2} END{for (i in a) printf("%s\t%s\t%.2f", i, a[i], sum[i]/1024)}' "$SUCCESS_LOCK_FILE")
fi

# Print the results
print_results() {
  echo -e "$RESULTS_SUCCESS" >combined.tsv

  # Calculate column widths
  widths=$(awk '
  BEGIN {
      FS = "\t";
      folder_width = count_width = size_width = 0;
  }
  {
      if (length($1) > folder_width) folder_width = length($1);
      if (length($2) > count_width) count_width = length($2);
      if (length($3) > size_width) size_width = length($3);
  }
  END {
      printf("%d %d %d", folder_width, count_width, size_width);
  }' combined.tsv)

  # Read column widths into an array
  IFS=' ' read -ra w <<<"$widths"

  # Print the formatted table
  awk -v folder_width="${w[0]}" -v count_width="${w[1]}" -v size_width="${w[2]}" -v YELLOW="${YELLOW}" -v GRAY="${GRAY}" -v GREEN="${GREEN}" -v NC="${NC}" -v FS="\t" '
  function repeat(s, n,    r) {
    while (n--) r = r s;
    return r;
  }
  BEGIN {
    # Print the top border
    printf("┌%s┬%s┬%s┐\n", repeat("─", folder_width + 2), repeat("─", count_width + 2), repeat("─", size_width + 2));

    # Read and print the header row
    getline;
    printf("│ %s%-*s%s │ %s%*s%s │ %s%*s%s │\n", YELLOW, folder_width, $1, NC, YELLOW, count_width, $2, NC, YELLOW, size_width, $3, NC);

    # Print the border below the header
    printf("├%s┼%s┼%s┤\n", repeat("─", folder_width + 2), repeat("─", count_width + 2), repeat("─", size_width + 2));
  }
  {
    # Print the row data with proper spacing
    printf("│ %s%-*s%s │ %s%*s%s │ %s%*s%s │\n", CYAN, folder_width, $1, NC, GRAY, count_width, $2, NC, GREEN, size_width, $3, NC);
  }
  END {
    # Print the bottom border
    printf("└%s┴%s┴%s┘\n", repeat("─", folder_width + 2), repeat("─", count_width + 2), repeat("─", size_width + 2));
  }
 ' combined.tsv && rm -f combined.tsv
}

# Print the successful and failed results
if [[ -v "RESULTS_SUCCESS[@]" ]]; then
  echo -e "\n${GREEN}Successful upscales:${NC}"
  print_results
fi

if [[ -v "RESULTS_FAILED[@]" ]]; then
  echo -e "${RED}Failed upscales:"
  format_and_print_results "${RED}" "${RESULTS_FAILED[@]}"
fi

# Delete temp files
cleanup
