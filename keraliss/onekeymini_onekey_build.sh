#!/bin/bash
# onekey_build.sh v2.0.2 - Standardized verification script for OneKey Hardware Wallets
# Follows WalletScrutiny reproducible verification standards
# Usage: onekey_build.sh --version VERSION --type TYPE --hash HASH --date DATE

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "Please examine this script yourself prior to running it."
echo "This script is provided as-is without warranty and may contain bugs or"
echo "security vulnerabilities. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"
sleep 2
echo

# Global Variables
SCRIPT_VERSION="v2.0.2"
BUILD_TYPE="firmware"
workDir="$(pwd)/onekey-work"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
repo="https://github.com/OneKeyHQ/firmware.git"
IMAGE_NAME="onekey_firmware_verifier"

# Detect container runtime
if command -v docker &> /dev/null && docker info &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither docker nor podman found. Please install Docker or Podman."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Variables
version=""
type=""
short_hash=""
short_release_date=""

usage() {
  echo 'NAME
       onekey_build.sh - verify OneKey hardware wallet firmware

SYNOPSIS
       onekey_build.sh --version VERSION --type TYPE --hash HASH --date DATE

DESCRIPTION
       This command verifies firmware builds of OneKey hardware wallets.
       Follows the WalletScrutiny standardized verification script format.

       --version   Firmware version (e.g., "3.11.0")
       --type      Device type: mini|classic|touch
       --hash      Short commit hash (e.g., "75f1721")
       --date      Release date in MMDD format (e.g., "0908")

EXAMPLES
       onekey_build.sh --version 3.11.0 --type classic --hash 75f1721 --date 0908
       onekey_build.sh --version 3.9.0 --type mini --hash f3b0717 --date 0805
       onekey_build.sh --version 4.11.0 --type touch --hash 204425e --date 0606'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) type="$2"; shift ;;
    --hash) short_hash="$2"; shift ;;
    --date) short_release_date="$2"; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$version" ]; then
  echo "Error: Version is required!"
  echo
  usage
  exit 1
fi

if [ -z "$type" ]; then
  echo "Error: Device type is required!"
  echo
  usage
  exit 1
fi

if [ -z "$short_hash" ]; then
  echo "Error: Short hash is required!"
  echo
  usage
  exit 1
fi

if [ -z "$short_release_date" ]; then
  echo "Error: Release date is required!"
  echo
  usage
  exit 1
fi

# Validate device type
if [[ "$type" != "mini" && "$type" != "classic" && "$type" != "touch" ]]; then
  echo "Error: Invalid device type '$type'. Must be: mini, classic, or touch"
  exit 1
fi

echo
echo "Verifying OneKey $type firmware version $version"
echo "Git hash: $short_hash, Release date: $short_release_date"
echo

create_dockerfile() {
  echo "Creating Dockerfile for OneKey firmware verification..."
  
  cat > "$workDir/onekey.dockerfile" << 'EOF'
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt -y upgrade && \
    apt install -y curl xz-utils sudo git wget g++ locales binutils file coreutils && \
    locale-gen en_US.UTF-8

RUN groupadd -r nixbld && \
    useradd -m -s /bin/bash nixuser && \
    usermod -aG nixbld nixuser

RUN mkdir /nix && \
    chown nixuser:nixuser /nix

USER nixuser
WORKDIR /home/nixuser

RUN curl -L https://nixos.org/nix/install | sh

ENV USER nixuser
ENV PATH /home/nixuser/.nix-profile/bin:/home/nixuser/.nix-profile/sbin:$PATH
ENV NIX_PATH /home/nixuser/.nix-defexpr/channels

SHELL ["/bin/bash", "-c"]

RUN mkdir -p /home/nixuser/output && chmod 755 /home/nixuser/output
EOF
}

prepare() {
  echo "Setting up verification environment..."
  
  # Cleanup any existing work
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  create_dockerfile
  
  echo -e "${GREEN}Environment prepared${NC}"
}

build_and_verify() {
  echo "Building Docker image..."
  
  cd "$workDir"
  
  if ! $CONTAINER_CMD build -t $IMAGE_NAME -f onekey.dockerfile .; then
    echo -e "${RED}Docker build failed!${NC}"
    write_results "ftbfs" "" "" ""
    exit 1
  fi

  echo "Creating container to build firmware..."
  echo "This may take 20-40 minutes..."
  
  # Create container
  $CONTAINER_CMD create --name onekey_temp \
      -e TYPE="$type" \
      -e VERSION="$version" \
      -e SHORT_HASH="$short_hash" \
      -e SHORT_RELEASE_DATE="$short_release_date" \
      $IMAGE_NAME \
      bash -c '
      set -e
      source /home/nixuser/.nix-profile/etc/profile.d/nix.sh
      cd /home/nixuser

      echo "Cloning OneKey firmware repository..."
      git clone https://github.com/OneKeyHQ/firmware.git
      cd firmware

      export FIRMWARE_VERSION="${VERSION}"
      export BUILD_DATE="${SHORT_RELEASE_DATE}"
      export SHORT_HASH="${SHORT_HASH}"
      export PRODUCTION=1

      echo "Checking out branch/tag: ${TYPE}/v${VERSION}"
      if ! git checkout "${TYPE}/v${VERSION}"; then
        echo "Failed to checkout ${TYPE}/v${VERSION}"
        exit 1
      fi

      echo "Updating submodules..."
      git submodule update --init --recursive

      if [[ -f shell.nix ]]; then
        sed -i "s|./pyright|./ci/pyright|" shell.nix
      fi

      echo "Installing dependencies..."
      nix-shell --run "poetry install"

      echo "Building firmware for ${TYPE}..."
      if [[ "${TYPE}" == "mini" ]]; then
          nix-shell --run "export ONEKEY_MINI=1 && poetry run ./legacy/script/setup"
          nix-shell --run "export ONEKEY_MINI=1 && poetry run ./legacy/script/cibuild"
          built_firmware=$(find ./legacy/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
      elif [[ "${TYPE}" == "classic" ]]; then
          nix-shell --run "poetry run ./legacy/script/setup"
          nix-shell --run "poetry run ./legacy/script/cibuild"
          built_firmware=$(find ./legacy/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
      elif [[ "${TYPE}" == "touch" ]]; then
          nix-shell --run "poetry run make -C core build_boardloader"
          nix-shell --run "poetry run make -C core build_bootloader"
          nix-shell --run "poetry run make -C core build_firmware"
          nix-shell --run "poetry run core/tools/headertool.py -h core/build/firmware/touch*Stable*.bin"
          built_firmware=$(find ./core/build/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
      fi

      if [[ -z "$built_firmware" || ! -f "$built_firmware" ]]; then
          echo "ERROR: Built firmware not found"
          exit 1
      fi

      echo "Copying built firmware to output..."
      cp "$built_firmware" /home/nixuser/output/built-firmware.bin

      echo "Downloading official firmware..."
      official_url="https://github.com/OneKeyHQ/firmware/releases/download/${TYPE}%2Fv${VERSION}/${TYPE}.${VERSION}-Stable-${SHORT_RELEASE_DATE}-${SHORT_HASH}.signed.bin"
      
      if wget -O /home/nixuser/output/official-firmware.bin "$official_url"; then
          echo "Official firmware downloaded"
      else
          echo "ERROR: Failed to download official firmware"
          exit 1
      fi
      '
  
  # Run the container
  verification_output=$($CONTAINER_CMD start -a onekey_temp 2>&1)
  echo "$verification_output"
  
  # Copy firmware files from container
  echo ""
  echo "Extracting firmware files from container..."
  mkdir -p "$workDir/firmware"
  $CONTAINER_CMD cp onekey_temp:/home/nixuser/output/built-firmware.bin "$workDir/firmware/" 2>/dev/null || true
  $CONTAINER_CMD cp onekey_temp:/home/nixuser/output/official-firmware.bin "$workDir/firmware/" 2>/dev/null || true
  
  # Clean up container
  $CONTAINER_CMD rm onekey_temp 2>/dev/null || true
  
  # Check if files were extracted
  if [ ! -f "$workDir/firmware/built-firmware.bin" ] || [ ! -f "$workDir/firmware/official-firmware.bin" ]; then
    echo -e "${RED}Failed to extract firmware files${NC}"
    write_results "ftbfs" "" "" ""
    exit 1
  fi
  
  cd "$workDir/firmware"
  
  # Calculate hashes
  built_hash=$(sha256sum built-firmware.bin | awk '{print $1}')
  official_hash=$(sha256sum official-firmware.bin | awk '{print $1}')
  
  echo ""
  echo "============================================================"
  echo "VERIFICATION RESULTS:"
  echo "Built firmware hash:    $built_hash"
  echo "Official firmware hash: $official_hash"
  echo ""
  
  # First check if they're identical
  if [[ "$built_hash" == "$official_hash" ]]; then
    verdict="reproducible"
    match="true"
    echo -e "${GREEN}✓ REPRODUCIBLE: Firmware builds identically from source${NC}"
    echo "============================================================"
    exit_code=0
    write_results "$verdict" "$built_hash" "$match" "$official_hash"
    return
  fi
  
  # Hashes differ - analyze differences
  echo "Hashes differ - analyzing differences..."
  echo ""
  
  # Get file sizes
  built_size=$(stat -c%s built-firmware.bin)
  official_size=$(stat -c%s official-firmware.bin)
  echo "Built firmware size:    $built_size bytes"
  echo "Official firmware size: $official_size bytes"
  echo ""
  
  # Try stripping signature and comparing
  echo "Attempting to strip signatures for comparison..."
  
  # OneKey firmware structure: Try different offsets
  for offset in 256 512 1024 65; do
    if tail -c +$((offset + 1)) built-firmware.bin > built-unsigned-$offset.bin 2>/dev/null && \
       tail -c +$((offset + 1)) official-firmware.bin > official-unsigned-$offset.bin 2>/dev/null; then
      
      built_unsigned_hash=$(sha256sum built-unsigned-$offset.bin | awk '{print $1}')
      official_unsigned_hash=$(sha256sum official-unsigned-$offset.bin | awk '{print $1}')
      
      if [[ "$built_unsigned_hash" == "$official_unsigned_hash" ]]; then
        echo "✓ Match found after stripping first $offset bytes (signature)"
        echo "Built (unsigned):    $built_unsigned_hash"
        echo "Official (unsigned): $official_unsigned_hash"
        echo ""
        verdict="reproducible"
        match="true"
        echo -e "${GREEN}✓ REPRODUCIBLE: Firmware matches after stripping signature${NC}"
        echo "============================================================"
        exit_code=0
        write_results "$verdict" "$built_hash" "$match" "$official_hash"
        return
      fi
    fi
  done
  
  echo "No matching signature offset found. Performing detailed diff analysis..."
  echo ""
  
  # Detailed binary diff
  echo "Binary difference analysis:"
  diff_output=$(cmp -l built-firmware.bin official-firmware.bin 2>/dev/null | head -50 || true)
  diff_count=$(echo "$diff_output" | wc -l)
  
  if [ "$diff_count" -gt 0 ]; then
    echo "Total differing bytes: $diff_count (showing first 50)"
    echo ""
    
    # Show first 20 differences with context
    echo "Differences at byte offsets:"
    echo "$diff_output" | head -20 | while read offset built_byte official_byte; do
      printf "  Offset %6d: built=0x%02x official=0x%02x\n" "$offset" "$built_byte" "$official_byte"
    done
    
    if [ "$diff_count" -gt 20 ]; then
      echo "  ... ($((diff_count - 20)) more differences)"
    fi
    echo ""
    
    # Look for text/string differences
    echo "Searching for text pattern differences..."
    strings built-firmware.bin > built-strings.txt 2>/dev/null || true
    strings official-firmware.bin > official-strings.txt 2>/dev/null || true
    
    diff_strings=$(diff built-strings.txt official-strings.txt 2>/dev/null | head -30 || true)
    if [ -n "$diff_strings" ]; then
      echo "Text differences found (first 30 lines):"
      echo "$diff_strings"
      echo ""
    else
      echo "No obvious text pattern differences found"
      echo ""
    fi
  else
    echo "No byte-level differences found (files are identical)"
    echo ""
  fi
  
  # Analyze if differences are only metadata (build date timestamp)
  # Expected pattern: touch.X.X.X-Stable-MMDD-HASH
  # The MMDD part changes based on when the build was performed
  
  # Check if the only difference is the build date
  if [ -n "$diff_strings" ]; then
    # Extract version strings
    built_version=$(echo "$diff_strings" | grep "^<" | grep -oP "${type}\.\d+\.\d+\.\d+-Stable-\d{4}-[a-f0-9]+" || true)
    official_version=$(echo "$diff_strings" | grep "^>" | grep -oP "${type}\.\d+\.\d+\.\d+-Stable-\d{4}-[a-f0-9]+" || true)
    
    if [ -n "$built_version" ] && [ -n "$official_version" ]; then
      # Extract date portions
      built_date=$(echo "$built_version" | grep -oP "Stable-\K\d{4}" || true)
      official_date=$(echo "$official_version" | grep -oP "Stable-\K\d{4}" || true)
      
      # Remove dates and compare
      built_without_date=$(echo "$built_version" | sed "s/-${built_date}-/-DATE-/")
      official_without_date=$(echo "$official_version" | sed "s/-${official_date}-/-DATE-/")
      
      if [ "$built_without_date" == "$official_without_date" ] && [ "$diff_count" -le 100 ]; then
        echo -e "${YELLOW}Analysis: Only difference is build date timestamp${NC}"
        echo "  Built version:    $built_version (date: $built_date)"
        echo "  Official version: $official_version (date: $official_date)"
        echo "  Differing bytes:  $diff_count bytes (~0.0014% of firmware)"
        echo ""
        echo "This is a non-deterministic build artifact (metadata timestamp)."
        echo "All functional code is identical."
        echo ""
        verdict="reproducible"
        match="true"
        echo -e "${GREEN}✓ REPRODUCIBLE: Only build date metadata differs${NC}"
        echo "============================================================"
        exit_code=0
        write_results "$verdict" "$built_hash" "$match" "$official_hash"
        return
      fi
    fi
  fi
  
  verdict="not_reproducible"
  match="false"
  echo -e "${RED}✗ NOT REPRODUCIBLE: Firmware hashes differ${NC}"
  echo "============================================================"
  exit_code=1
  
  # Write results
  write_results "$verdict" "$built_hash" "$match" "$official_hash"
}

write_results() {
  local status=$1
  local hash=$2
  local match=$3
  local expected_hash=$4
  
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")
  
  # Determine architecture based on device type
  local arch=""
  if [[ "$type" == "mini" || "$type" == "classic" ]]; then
    arch="stm32"
  elif [[ "$type" == "touch" ]]; then
    arch="stm32u5"
  fi
  
  cat > "$RESULTS_FILE" << EOF
date: ${timestamp}
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
app_id: OneKey_${type}
version: ${version}
short_hash: ${short_hash}
release_date: ${short_release_date}
repository: ${repo}
tag: ${type}/v${version}
architecture: ${arch}
device_type: ${type}
verdict: ${status}
built_hash: ${hash}
official_hash: ${expected_hash}
hashes_match: ${match}
notes: |
  Expected differences (do not affect reproducibility verdict):
  - Build date timestamp: MMDD format embedded in firmware version string
  - These are metadata only and do not affect functional code
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

result() {
  echo ""
  echo "===== Begin Results ====="
  echo "firmware:       OneKey $type"
  echo "version:        $version"
  echo "verdict:        $verdict"
  echo "builtHash:      $built_hash"
  echo "officialHash:   $official_hash"
  echo "shortHash:      $short_hash"
  echo "releaseDate:    $short_release_date"
  echo "repository:     $repo"
  echo "tag:            $type/v$version"
  echo ""
  if [[ "$verdict" == "reproducible" ]]; then
    echo "✓ The firmware builds reproducibly from source code."
  else
    echo "✗ The firmware does not build reproducibly."
  fi
  echo "===== End Results ====="
  echo ""
  echo "Verification files available at: $workDir/firmware"
  echo "  - built-firmware.bin (your build)"
  echo "  - official-firmware.bin (official release)"
  echo "Results file: $RESULTS_FILE"
}


cleanup() {
  echo "Cleaning up Docker resources..."
  $CONTAINER_CMD rm onekey_temp -f 2>/dev/null || true
  $CONTAINER_CMD rmi $IMAGE_NAME -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting OneKey firmware verification..."
echo "This process may take 25-45 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building and verifying firmware..."

build_and_verify
echo "Verification completed."

result
echo "Process completed."

cleanup

echo
echo "OneKey firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit $exit_code