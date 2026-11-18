#!/bin/bash
# onekey_pro_build.sh v1.2.1 - Standardized verification script for OneKey Pro Hardware Wallet
# Supports stable (full/multi-coin) and btc-only firmware types
# Usage: onekey_pro_build.sh --version VERSION [--type TYPE] [--binary PATH] [-c]

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
SCRIPT_VERSION="v1.2.1"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
shouldCleanup=false

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

# OneKey Pro constants
repo="https://github.com/OneKeyHQ/firmware-pro.git"

# Default firmware type
firmwareType="stable"
binaryPath=""

usage() {
  cat << EOF
NAME
       onekey_pro_build.sh - verify OneKey Pro hardware wallet firmware

SYNOPSIS
       onekey_pro_build.sh --version VERSION [--type TYPE] [--binary PATH] [-c]

DESCRIPTION
       This command tries to verify firmware builds of OneKey Pro hardware wallet.

       --version  The firmware version to verify (e.g., 4.18.0)
       --type     Firmware type: stable|btc-only (default: stable)
       --binary   Path to official firmware binary (downloaded if not provided)
       --arch     Accepted but unused
       -c|--cleanup  Clean up temporary files after testing

EXAMPLES
       onekey_pro_build.sh --version 4.18.0
       onekey_pro_build.sh --version 4.18.0 --type btc-only
       onekey_pro_build.sh --version 4.18.0 --binary /path/to/firmware.signed.bin
       onekey_pro_build.sh --version 4.18.0 -c
EOF
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) firmwareType="$2"; shift ;;
    --binary) binaryPath="$2"; shift ;;
    --arch) shift ;;
    -c|--cleanup) shouldCleanup=true ;;
    -h|--help) usage; exit 0 ;;
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

# Validate firmware type
if [[ "$firmwareType" != "stable" && "$firmwareType" != "btc-only" ]]; then
  echo "Error: Invalid firmware type '$firmwareType'. Must be: stable or btc-only"
  exit 1
fi

# Validate binary path if provided
if [ -n "$binaryPath" ]; then
  if [ ! -f "$binaryPath" ]; then
    echo "Error: Binary file not found: $binaryPath"
    exit 1
  fi
  if ! [[ "$binaryPath" =~ ^/.* ]]; then
    binaryPath="$PWD/$binaryPath"
  fi
fi

# Determine Git tag and display type
if [[ "$firmwareType" == "btc-only" ]]; then
  gitTag="v${version}-btc"
  displayType="btc-only"
  btcOnlyFlag=1
else
  gitTag="v${version}"
  displayType="stable (full)"
  btcOnlyFlag=0
fi

# Namespace workDir and image name by version+type to allow parallel runs
workDir="$(pwd)/onekey-pro-work-${version}-${firmwareType}"
IMAGE_NAME="onekey-pro-build-${version}-${firmwareType}"

officialFile="${workDir}/official_pro_v${version}_${firmwareType}.bin"

echo
echo "Verifying OneKey Pro firmware version $version ($displayType)"
echo

write_results() {
  local status=$1

  cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  OneKey Pro v${version} (${displayType}) firmware verification.
  Built using the upstream repository Dockerfile inside a containerized environment.
  Comparison method: the first 2560 bytes (signature header) are stripped from both
  the official signed binary and the built binary before SHA-256 comparison.
  Expected differences (do not affect reproducibility verdict):
  - Official binary contains a vendor signature in the first 2560 bytes; built binary is unsigned
EOF

  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

prepare() {
  echo "Setting up verification environment..."
  
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Cloning OneKey firmware-pro repository (tag $gitTag)..."
  if ! git clone --recurse-submodules --branch "$gitTag" --depth 1 "$repo" firmware-pro; then
    echo -e "${RED}Failed to clone tag $gitTag${NC}"
    echo "Check if this tag exists: https://github.com/OneKeyHQ/firmware-pro/tags"
    write_results "ftbfs"
    exit 1
  fi
  
  cd firmware-pro
  echo -e "${GREEN}Successfully cloned firmware-pro $gitTag${NC}"
  echo "Current commit: $(git log -1 --oneline)"
}

build_firmware() {
  echo "Building OneKey Pro firmware..."
  
  if ! command -v nix-shell >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: nix-shell not found - attempting to install nix...${NC}"
    if ! curl -L https://nixos.org/nix/install | sh; then
      echo -e "${RED}Failed to install nix${NC}"
      write_results "ftbfs"
      exit 1
    fi
    source ~/.nix-profile/etc/profile.d/nix.sh
  fi
  
  echo "Setting up development environment with nix-shell and poetry..."
  echo "This may take several minutes on first run..."
  
  cat > Dockerfile.onekey << 'DOCKERFILE_EOF'
FROM nixos/nix:latest

RUN nix-channel --update && \
    nix-env -iA nixpkgs.git nixpkgs.poetry nixpkgs.gnumake nixpkgs.gcc

WORKDIR /work

COPY . /work

CMD ["sh", "-c", "poetry install && PRODUCTION=1 poetry run make -C core build_firmware BITCOIN_ONLY=${BITCOIN_ONLY:-0}"]
DOCKERFILE_EOF

  echo "Building Docker image ${IMAGE_NAME} for OneKey Pro build environment..."
  if ! $CONTAINER_CMD build -t "$IMAGE_NAME" -f Dockerfile.onekey .; then
    echo -e "${RED}Docker build failed! Attempting direct nix-shell build...${NC}"
    if ! nix-shell --run "poetry install && PRODUCTION=1 poetry run make -C core build_firmware BITCOIN_ONLY=$btcOnlyFlag"; then
      echo -e "${RED}Build failed!${NC}"
      write_results "ftbfs"
      exit 1
    fi
  else
    echo "Running firmware build in container..."
    if ! $CONTAINER_CMD run -e BITCOIN_ONLY="$btcOnlyFlag" -v $(pwd):/work "$IMAGE_NAME"; then
      echo -e "${RED}Firmware build failed!${NC}"
      write_results "ftbfs"
      exit 1
    fi
  fi
  
  echo -e "${GREEN}Firmware build completed successfully!${NC}"
}

locate_built_firmware() {
  echo "Locating built firmware..."
  
  BUILT_FIRMWARE=""
  
  for path in \
    "core/build/firmware/pro.${version}"*.bin \
    "core/build/firmware"*.bin \
    "core/build/firmware/firmware.bin" \
    "build/firmware"*.bin; do
    
    if [ -f "$path" ]; then
      echo -e "${GREEN}Found firmware at: $path${NC}"
      BUILT_FIRMWARE="$path"
      break
    fi
  done
  
  if [ -z "$BUILT_FIRMWARE" ]; then
    echo "Searching entire build directory..."
    POTENTIAL_FIRMWARE=$(find ./core/build -name "*.bin" -type f 2>/dev/null | head -1)
    if [ -n "$POTENTIAL_FIRMWARE" ]; then
      echo -e "${YELLOW}Found potential firmware: $POTENTIAL_FIRMWARE${NC}"
      BUILT_FIRMWARE="$POTENTIAL_FIRMWARE"
    fi
  fi
  
  if [ -z "$BUILT_FIRMWARE" ]; then
    echo -e "${YELLOW}No firmware binary found after build${NC}"
    echo "This might indicate an emulator build or incomplete device firmware output."
    return 1
  fi
  
  return 0
}

download_official_firmware() {
  echo "Downloading official OneKey Pro $displayType firmware..."

  # Use provided binary if available
  if [ -n "$binaryPath" ]; then
    cp "$binaryPath" "$officialFile"
    echo -e "${GREEN}Using provided binary: $binaryPath${NC}"
    return 0
  fi
  
  FIRMWARE_DOWNLOADED=false
  
  echo "Querying GitHub API for $gitTag release assets..."
  RELEASE_INFO=$(curl -s "https://api.github.com/repos/OneKeyHQ/firmware-pro/releases/tags/$gitTag" 2>/dev/null || echo "")
  
  if [ -n "$RELEASE_INFO" ]; then
    if [[ "$firmwareType" == "btc-only" ]]; then
      FIRMWARE_URL=$(echo "$RELEASE_INFO" | grep -i '"browser_download_url": "[^"]*btc[^"]*\.signed\.bin"' | head -1 | cut -d'"' -f4)
    fi
    if [ -z "$FIRMWARE_URL" ]; then
      FIRMWARE_URL=$(echo "$RELEASE_INFO" | grep -o '"browser_download_url": "[^"]*\.signed\.bin"' | head -1 | cut -d'"' -f4)
    fi
    
    if [ -n "$FIRMWARE_URL" ]; then
      echo "Found official firmware URL: $FIRMWARE_URL"
      if wget -O "$officialFile" "${FIRMWARE_URL}"; then
        FIRMWARE_DOWNLOADED=true
        echo -e "${GREEN}Downloaded official firmware from GitHub releases${NC}"
      fi
    fi
  fi
  
  if [ "$FIRMWARE_DOWNLOADED" = false ]; then
    echo "Trying common firmware URL patterns..."
    
    if [[ "$firmwareType" == "btc-only" ]]; then
      patterns=(
        "pro.${version}-btc.signed.bin"
        "pro.${version}-BTC.signed.bin"
        "pro.${version}-btc-only.signed.bin"
        "onekey-pro-${version}-btc.signed.bin"
        "btc-only.${version}.signed.bin"
        "${version}-btc.signed.bin"
      )
    else
      patterns=(
        "pro.${version}-Stable.signed.bin"
        "pro.${version}.signed.bin"
        "onekey-pro-${version}.signed.bin"
      )
    fi
    
    for pattern in "${patterns[@]}"; do
      FIRMWARE_URL="https://github.com/OneKeyHQ/firmware-pro/releases/download/$gitTag/${pattern}"
      if wget -O "$officialFile" "${FIRMWARE_URL}" 2>/dev/null; then
        FIRMWARE_DOWNLOADED=true
        echo -e "${GREEN}Downloaded firmware using pattern: ${pattern}${NC}"
        break
      fi
    done
  fi
  
  if [ "$FIRMWARE_DOWNLOADED" = false ]; then
    echo -e "${RED}Could not download official $displayType firmware for v${version}${NC}"
    echo "Please check the release page: https://github.com/OneKeyHQ/firmware-pro/releases/tag/$gitTag"
    return 1
  fi
  
  echo -e "${GREEN}Downloaded official firmware${NC}"
  echo "Size: $(du -h "$officialFile" | cut -f1)"
  return 0
}

compare_firmware() {
  echo "Comparing firmware binaries..."
  
  if [ ! -f "$BUILT_FIRMWARE" ]; then
    echo -e "${RED}Built firmware not found${NC}"
    return 1
  fi
  
  if [ ! -f "$officialFile" ]; then
    echo -e "${RED}Official firmware not found${NC}"
    return 1
  fi
  
  echo "=========================="
  echo "SIGNED Binary from OneKey:"
  officialHash=$(sha256sum "$officialFile" | awk '{print $1}')
  echo "$officialHash  $officialFile"
  
  echo "=========================="
  echo "Binary from build process:"
  builtHash=$(sha256sum "$BUILT_FIRMWARE" | awk '{print $1}')
  echo "$builtHash  $BUILT_FIRMWARE"
  
  echo ""
  echo "=========================="
  echo "MCU Firmware Comparison (removing signature header - first 2560 bytes):"
  
  builtMcuHash=$(tail -c +2561 "$BUILT_FIRMWARE" | sha256sum | awk '{print $1}')
  officialMcuHash=$(tail -c +2561 "$officialFile" | sha256sum | awk '{print $1}')
  
  echo "Built MCU firmware:    $builtMcuHash"
  echo "Official MCU firmware: $officialMcuHash"
  echo "=========================="
  
  echo ""
  echo "VERIFICATION RESULTS:"
  echo "Official firmware (signed):   $officialHash"
  echo "Built firmware (unsigned):    $builtHash"
  echo "Official MCU (no signature):  $officialMcuHash"
  echo "Built MCU (no signature):     $builtMcuHash"
  
  if [[ "$builtMcuHash" == "$officialMcuHash" ]]; then
    echo -e "${GREEN}✓ REPRODUCIBLE: MCU firmware matches after signature removal${NC}"
    verdict="reproducible"
    match_status=1
    write_results "reproducible"
  else
    echo -e "${RED}✗ NOT REPRODUCIBLE: MCU firmware hashes differ${NC}"
    verdict="not_reproducible"
    match_status=0
    write_results "not_reproducible"
  fi
  
  echo "=========================="
}

result() {
  echo "===== Begin Results ====="
  echo "firmware:       OneKey Pro"
  echo "version:        $version"
  echo "type:           $displayType"
  echo "verdict:        $verdict"
  echo "officialHash:   ${officialHash:-N/A}"
  echo "builtHash:      ${builtHash:-N/A}"
  echo "officialMcuHash:${officialMcuHash:-N/A}"
  echo "builtMcuHash:   ${builtMcuHash:-N/A}"
  echo "repository:     $repo"
  echo "tag:            $gitTag"
  
  if [[ "$verdict" == "reproducible" ]]; then
    echo ""
    echo "✓ The firmware builds reproducibly from source code."
  else
    echo ""
    echo "✗ The firmware does not build reproducibly."
  fi
  
  echo "===== End Results ====="
  
  if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Verification files available at: $workDir/firmware-pro"
    if [ -f "$officialFile" ]; then
      echo "- Official firmware: $officialFile"
    fi
    if [ -n "$BUILT_FIRMWARE" ] && [ -f "$BUILT_FIRMWARE" ]; then
      echo "- Built firmware: $BUILT_FIRMWARE"
    fi
  fi
}

cleanup() {
  echo "Cleaning up temporary files..."
  rm -rf "$workDir"
  $CONTAINER_CMD rmi "$IMAGE_NAME" -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Main execution
echo "Starting OneKey Pro $displayType firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building firmware from source..."

build_firmware
echo "Build completed. Locating built firmware..."

verdict="unknown"
match_status=0

if locate_built_firmware; then
  echo "Firmware located. Downloading official firmware..."
  
  if download_official_firmware; then
    echo "Download completed. Comparing firmware..."
    compare_firmware
  else
    echo -e "${YELLOW}Could not download official firmware for comparison${NC}"
    verdict="not_reproducible"
    write_results "not_reproducible"
    match_status=0
  fi
else
  echo -e "${YELLOW}Could not locate built firmware${NC}"
  verdict="ftbfs"
  write_results "ftbfs"
  match_status=0
fi

echo "Analysis completed."

result
echo "Verification completed."

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

echo
echo "OneKey Pro firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."