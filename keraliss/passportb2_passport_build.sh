#!/bin/bash
# passport_build.sh v3.0.0 - Standardized verification script for Passport Hardware Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: passport_build.sh --version VERSION --type TYPE
#        passport_build.sh --version VERSION --type TYPE --binary PATH

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
SCRIPT_VERSION="v3.0.0"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

# Color constants (defined before first use)
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither docker nor podman found. Please install Docker or Podman."
    exit 1
fi

# Input variables
version=""
screen=""
binaryPath=""

usage() {
    echo 'NAME
       passport_build.sh - verify Passport hardware wallet firmware

SYNOPSIS
       passport_build.sh --version VERSION --type TYPE
       passport_build.sh --version VERSION --type TYPE --binary PATH

DESCRIPTION
       This command verifies firmware builds of Passport hardware wallet.
       Follows the WalletScrutiny standardized verification script format.

       --version   Firmware version (e.g., "2.4.0")
       --type      Screen type: color or mono
       --binary    Path to official firmware binary to verify against (optional)

EXAMPLES
       passport_build.sh --version 2.4.0 --type color
       passport_build.sh --version 2.4.0 --type mono
       passport_build.sh --version 2.4.0 --type color --binary /path/to/firmware.bin'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --type) screen="$2"; shift ;;
    --binary) binaryPath="$2"; shift ;;
    --arch) shift ;;   # accepted but unused (single arch device)
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate inputs
if [ -z "$version" ]; then
    echo "Error: --version is required!"
    echo
    usage
    exit 1
fi

if [ -z "$screen" ]; then
    echo "Error: --type is required!"
    echo
    usage
    exit 1
fi

if [[ "$screen" != "color" && "$screen" != "mono" ]]; then
    echo "Error: --type must be 'color' or 'mono', got: $screen"
    exit 1
fi

# Validate and absolutify binary path if provided
if [ -n "$binaryPath" ]; then
    if [ ! -f "$binaryPath" ]; then
        echo "Error: Binary file not found: $binaryPath"
        exit 1
    fi
    if ! [[ "$binaryPath" =~ ^/.* ]]; then
        binaryPath="$PWD/$binaryPath"
    fi
fi

# Namespace workDir and image name by version+type to allow parallel runs
workDir="$(pwd)/passport-work-${version}-${screen}"
dockerImage="foundation-devices/passport2-${version}-${screen}:latest"

# Derive firmware filenames from screen type
if [[ "$screen" == "color" ]]; then
    fileName="v${version}-passport.bin"
elif [[ "$screen" == "mono" ]]; then
    fileName="v${version}-founders-passport.bin"
fi

gitRevision="v$version"

echo
echo "Verifying Passport firmware version $version ($screen)"
echo

# ── Results ──────────────────────────────────────────────────────────────────

write_results() {
    local status=$1

    cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ${status}
notes: |
  Passport v${version} (${screen}) firmware verification.
  Built using the upstream Foundation Devices Dockerfile inside a containerized environment.
  Comparison method: the first 2048 bytes (header, signatures, zeroed padding) are stripped
  from the official signed binary before SHA-256 comparison against the unsigned built binary.
  Expected differences (do not affect reproducibility verdict):
  - Official binary contains a vendor header and signatures in the first 2048 bytes; built binary is unsigned
EOF

    echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

# ── Prepare ───────────────────────────────────────────────────────────────────

prepare() {
    echo "Setting up Passport firmware verification..."
    echo "Firmware version: $version"
    echo "Screen type:      $screen"
    echo "Firmware file:    $fileName"
    echo "Git revision:     $gitRevision"

    rm -rf "$workDir"
    mkdir -p "$workDir"

    echo -e "${GREEN}Environment prepared${NC}"
}

# ── Build ─────────────────────────────────────────────────────────────────────

build_firmware() {
    echo "Starting Passport firmware build..."

    cd "$workDir"

    # Get the official firmware binary
    if [ -n "$binaryPath" ]; then
        cp "$binaryPath" "$workDir/${fileName}"
        echo -e "${GREEN}Using provided binary: $binaryPath${NC}"
    else
        echo "Downloading firmware binary..."
        if ! wget -q --show-progress \
            "https://github.com/Foundation-Devices/passport2/releases/download/v${version}/${fileName}"; then
            echo -e "${RED}Error: Failed to download firmware binary${NC}"
            write_results "ftbfs"
            exit 1
        fi
    fi

    # Clone the repository at the specified release tag
    echo "Cloning Passport repository..."
    if ! git clone --quiet https://github.com/Foundation-Devices/passport2.git; then
        echo -e "${RED}Error: Failed to clone repository${NC}"
        write_results "ftbfs"
        exit 1
    fi

    cd passport2

    echo "Checking out revision: $gitRevision"
    if ! git checkout "$gitRevision"; then
        echo -e "${RED}Error: Failed to checkout revision $gitRevision${NC}"
        write_results "ftbfs"
        exit 1
    fi

    # Build the Docker image for reproducible builds
    echo "Building Docker image ${dockerImage}..."
    if ! $CONTAINER_CMD build --no-cache -t "$dockerImage" .; then
        echo -e "${RED}Error: Failed to build Docker image${NC}"
        write_results "ftbfs"
        exit 1
    fi

    # Build mpy-cross inside the container
    echo "Building mpy-cross..."
    if ! $CONTAINER_CMD run --rm \
        --volume "$PWD":/workspace \
        --user "$(id -u):$(id -g)" \
        --workdir /workspace \
        --env MPY_CROSS="/workspace/mpy-cross/mpy-cross-docker" \
        "$dockerImage" \
        make -C mpy-cross PROG=mpy-cross-docker BUILD=build-docker; then
        echo -e "${RED}Error: Failed to build mpy-cross${NC}"
        write_results "ftbfs"
        exit 1
    fi

    # Select build flags for the target screen type
    if [[ "$screen" == "color" ]]; then
        buildCommand=(make -C ports/stm32/
            LV_CFLAGS='-DLV_COLOR_DEPTH=16 -DLV_COLOR_16_SWAP -DLV_TICK_CUSTOM=1 -DSCREEN_MODE_COLOR -DHAS_FUEL_GAUGE'
            BOARD=Passport
            SCREEN_MODE=COLOR
            FROZEN_MANIFEST='boards/Passport/manifest.py')
    elif [[ "$screen" == "mono" ]]; then
        buildCommand=(make -C ports/stm32/
            LV_CFLAGS='-DLV_COLOR_DEPTH=16 -DLV_COLOR_16_SWAP -DLV_TICK_CUSTOM=1 -DSCREEN_MODE_MONO'
            BOARD=Passport
            SCREEN_MODE=MONO
            FROZEN_MANIFEST='boards/Passport/manifest.py')
    fi

    echo "Building firmware for $screen model..."
    if ! $CONTAINER_CMD run --rm \
        --volume "$PWD":/workspace \
        --user "$(id -u):$(id -g)" \
        --workdir /workspace \
        --env MPY_CROSS="/workspace/mpy-cross/mpy-cross-docker" \
        "$dockerImage" \
        "${buildCommand[@]}"; then
        echo -e "${RED}Error: Failed to build firmware${NC}"
        write_results "ftbfs"
        exit 1
    fi

    local builtBin="$workDir/passport2/ports/stm32/build-Passport/firmware-${screen^^}.bin"
    if [ ! -f "$builtBin" ]; then
        echo -e "${RED}Error: Built firmware not found at: $builtBin${NC}"
        write_results "ftbfs"
        exit 1
    fi

    echo -e "${GREEN}Firmware build completed successfully${NC}"
}

# ── Compare ───────────────────────────────────────────────────────────────────

compare_firmware() {
    echo "Analyzing verification results..."

    local builtBin="$workDir/passport2/ports/stm32/build-Passport/firmware-${screen^^}.bin"
    local officialBin="$workDir/${fileName}"
    local strippedBin="$workDir/passport2/no-header-${fileName}"

    if [ ! -f "$builtBin" ]; then
        echo -e "${RED}Built firmware not found: $builtBin${NC}"
        write_results "ftbfs"
        exit 1
    fi

    if [ ! -f "$officialBin" ]; then
        echo -e "${RED}Official firmware not found: $officialBin${NC}"
        write_results "ftbfs"
        exit 1
    fi

    # Strip the first 2048 bytes (header + signatures + zeroed padding)
    dd if="$officialBin" of="$strippedBin" ibs=2048 skip=1 status=none

    local builtHash officialHash strippedHash
    builtHash=$(sha256sum "$builtBin" | cut -d' ' -f1)
    officialHash=$(sha256sum "$officialBin" | cut -d' ' -f1)
    strippedHash=$(sha256sum "$strippedBin" | cut -d' ' -f1)

    echo ""
    echo "============================================================"
    echo "VERIFICATION RESULTS:"
    echo "Official firmware (signed):  $officialHash"
    echo "Official firmware (stripped): $strippedHash"
    echo "Built firmware:              $builtHash"
    echo "============================================================"

    if [[ "$builtHash" == "$strippedHash" ]]; then
        verdict="reproducible"
        echo -e "${GREEN}✓ REPRODUCIBLE: Built firmware matches stripped official binary${NC}"
        write_results "reproducible"
        exit_code=0
    else
        verdict="not_reproducible"
        echo -e "${RED}✗ NOT REPRODUCIBLE: Firmware hashes differ${NC}"
        write_results "not_reproducible"
        exit_code=1
    fi

    echo ""
    echo "===== Begin Results ====="
    echo "firmware:        Passport"
    echo "version:         $version"
    echo "type:            $screen"
    echo "verdict:         $verdict"
    echo "builtHash:       $builtHash"
    echo "officialHash:    $officialHash"
    echo "strippedHash:    $strippedHash"
    echo "repository:      https://github.com/Foundation-Devices/passport2"
    echo "tag:             $gitRevision"
    echo ""
    if [[ "$verdict" == "reproducible" ]]; then
        echo "✓ The firmware builds reproducibly from source code."
    else
        echo "✗ The firmware does not build reproducibly."
    fi
    echo "===== End Results ====="
    echo ""
    echo "Verification files:"
    echo "  Official (signed):   $officialBin"
    echo "  Official (stripped): $strippedBin"
    echo "  Built:               $builtBin"
    echo ""
    echo "Results file: $RESULTS_FILE"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    echo "Cleaning up container resources..."
    $CONTAINER_CMD image rm "$dockerImage" -f 2>/dev/null || true
    $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# ── Main execution ─────────────────────────────────────────────────────────────

echo "Starting Passport firmware verification..."
echo "This process may take 15-30 minutes depending on your system."
echo

prepare
echo "Environment prepared. Building firmware..."

build_firmware
echo "Build completed. Comparing firmware..."

compare_firmware
echo "Comparison completed."

cleanup

echo
echo "Passport firmware verification finished!"
echo "COMPARISON_RESULTS.yaml has been generated in the current directory."

exit ${exit_code:-1}