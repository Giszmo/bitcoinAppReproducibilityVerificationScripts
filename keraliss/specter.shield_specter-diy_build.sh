#!/bin/bash
# specter-diy_build.sh v1.0.0 - WalletScrutiny verification script for Specter-DIY
# Usage: specter-diy_build.sh --version VERSION [--binary PATH]

set -e

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

SCRIPT_VERSION="v1.0.0"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

if command -v docker &>/dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &>/dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither docker nor podman found. Please install one of them."
    exit 1
fi

VERSION=""
BINARY_PATH=""

usage() {
    echo 'NAME
       specter-diy_build.sh - verify Specter-DIY hardware wallet firmware

SYNOPSIS
       specter-diy_build.sh --version VERSION
       specter-diy_build.sh --version VERSION --binary PATH

DESCRIPTION
       Verifies the Specter-DIY unsigned upgrade binary builds reproducibly
       from source using the upstream Dockerfile
       (Python 3.9.15 + gcc-arm-none-eabi-9-2020-q2-update).

       Compares specter_upgrade_unsigned_vVERSION.bin against the binary
       built from source — direct SHA256 comparison, no signature stripping.

       --version   Firmware version without "v" prefix (e.g. 1.10.3)
       --binary    Path to official binary (optional; downloaded if omitted)

EXAMPLES
       specter-diy_build.sh --version 1.10.3
       specter-diy_build.sh --version 1.10.3 --binary /path/to/specter_upgrade_unsigned_v1.10.3.bin'
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --version) VERSION="$2"; shift ;;
        --binary)  BINARY_PATH="$2"; shift ;;
        --arch)    shift; continue ;;
        --type)    shift; continue ;;
        -h|--help) usage; exit 0 ;;
        *)         shift; continue ;;
    esac
    shift
done

if [[ -z "$VERSION" ]]; then
    echo "Error: --version is required"
    echo; usage; exit 1
fi

if [[ -n "$BINARY_PATH" ]]; then
    if [[ ! -f "$BINARY_PATH" ]]; then
        echo "Error: Binary file not found: $BINARY_PATH"
        exit 1
    fi
    [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
fi

OFFICIAL_FILENAME="specter_upgrade_unsigned_v${VERSION}.bin"
BUILT_ARTIFACT="release/specter_upgrade_unsigned.bin"
WORK_DIR="$(pwd)/specter-diy-work_${VERSION}"
IMAGE_TAG="specter_diy_builder_${VERSION}"

write_results() {
    local verdict="$1"
    local notes="$2"
    cat > "$RESULTS_FILE" << EOF
script_version: ${SCRIPT_VERSION}
verdict: ${verdict}
notes: |
  ${notes}
EOF
    echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

echo
echo "Verifying Specter-DIY v${VERSION}"
echo "Official binary: ${OFFICIAL_FILENAME}"
echo "Work directory:  ${WORK_DIR}"
echo
echo -e "${YELLOW}Note: This build compiles MicroPython + ARM firmware and may take 15-30 minutes.${NC}"
echo

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# ── Download or copy official binary ─────────────────────────────────────────

OFFICIAL_BIN="$WORK_DIR/$OFFICIAL_FILENAME"

if [[ -n "$BINARY_PATH" ]]; then
    cp "$BINARY_PATH" "$OFFICIAL_BIN"
    echo -e "${GREEN}Using provided binary: $BINARY_PATH${NC}"
else
    echo "Downloading official firmware..."
    DOWNLOAD_URL="https://github.com/cryptoadvance/specter-diy/releases/download/v${VERSION}/${OFFICIAL_FILENAME}"
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O "$OFFICIAL_BIN"; then
        echo -e "${RED}Error: Failed to download $DOWNLOAD_URL${NC}"
        write_results "ftbfs" "Specter-DIY v${VERSION}: Failed to download official binary from GitHub releases."
        exit 1
    fi
fi

# ── Clone repository ──────────────────────────────────────────────────────────

echo "Cloning Specter-DIY repository at v${VERSION}..."
if ! git clone --quiet --recurse-submodules --depth 1 --branch "v${VERSION}" \
        https://github.com/cryptoadvance/specter-diy.git "$WORK_DIR/specter-diy"; then
    echo -e "${RED}Error: Failed to clone repository at tag v${VERSION}${NC}"
    write_results "ftbfs" "Specter-DIY v${VERSION}: Failed to clone repository — tag v${VERSION} may not exist."
    exit 1
fi

# Use production public keys so the bootloader embeds the correct signing keys.
cp "$WORK_DIR/specter-diy/bootloader/keys/production/pubkeys.c" \
   "$WORK_DIR/specter-diy/bootloader/keys/selfsigned/pubkeys.c"

# ── Build Docker image ────────────────────────────────────────────────────────

echo "Building Docker image ${IMAGE_TAG}..."
if ! $CONTAINER_CMD build \
        --no-cache \
        --ulimit nofile=65536:65536 \
        -t "$IMAGE_TAG" \
        "$WORK_DIR/specter-diy"; then
    echo -e "${RED}Error: Failed to build Docker image${NC}"
    write_results "ftbfs" "Specter-DIY v${VERSION}: Docker image build failed."
    $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
    exit 1
fi

# ── Build firmware ────────────────────────────────────────────────────────────

echo "Building firmware (main bootloader assemble)..."

if ! $CONTAINER_CMD run --rm \
        --ulimit nofile=65536:65536 \
        --volume "$WORK_DIR/specter-diy":/app \
        -e HOST_UID=0 -e HOST_GID=0 \
        "$IMAGE_TAG" \
        bash ./build_firmware.sh main bootloader assemble; then
    echo -e "${RED}Error: Firmware build failed${NC}"
    write_results "ftbfs" "Specter-DIY v${VERSION}: Firmware build failed inside the container."
    $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
    exit 1
fi

BUILT_BIN="$WORK_DIR/specter-diy/${BUILT_ARTIFACT}"
if [[ ! -f "$BUILT_BIN" ]]; then
    echo -e "${RED}Error: Expected built artifact not found: $BUILT_BIN${NC}"
    write_results "ftbfs" "Specter-DIY v${VERSION}: Build completed but ${BUILT_ARTIFACT} not found."
    $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
    exit 1
fi

echo -e "${GREEN}Firmware build completed${NC}"

# ── Compare ───────────────────────────────────────────────────────────────────

echo
echo "Comparing binaries..."

OFFICIAL_HASH=$(sha256sum "$OFFICIAL_BIN" | cut -d' ' -f1)
BUILT_HASH=$(sha256sum "$BUILT_BIN"       | cut -d' ' -f1)

echo
echo "============================================================"
echo "VERIFICATION RESULTS:"
echo "Official: $OFFICIAL_HASH"
echo "Built:    $BUILT_HASH"
echo "============================================================"

if [[ "$OFFICIAL_HASH" == "$BUILT_HASH" ]]; then
    echo -e "${GREEN}✓ REPRODUCIBLE: Hashes match${NC}"
    write_results "reproducible" "Specter-DIY v${VERSION} builds reproducibly from source.
  Built using the upstream Dockerfile (Python 3.9.15, gcc-arm-none-eabi-9-2020-q2-update) in a containerized environment.
  Compared specter_upgrade_unsigned_v${VERSION}.bin against the built release/specter_upgrade_unsigned.bin — direct SHA256, no signature stripping required."
    EXIT_CODE=0
else
    echo -e "${RED}✗ NOT REPRODUCIBLE: Hashes differ${NC}"
    write_results "not_reproducible" "Specter-DIY v${VERSION}: Build succeeded but the unsigned upgrade binary does not match the official release.
  Official SHA256: ${OFFICIAL_HASH}
  Built SHA256:    ${BUILT_HASH}"
    EXIT_CODE=1
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

echo
echo "Cleaning up Docker resources..."
$CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
$CONTAINER_CMD image prune -f 2>/dev/null || true

echo
echo "Specter-DIY firmware verification complete."
echo "Results: $RESULTS_FILE"

exit $EXIT_CODE
