#!/bin/bash
# seedsigner_build.sh v1.0.1 - WalletScrutiny verification script for SeedSigner
# Usage: seedsigner_build.sh --version VERSION --arch ARCH [--binary PATH]

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

SCRIPT_VERSION="v1.0.1"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

if command -v docker &>/dev/null && docker info &>/dev/null; then
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
ARCH=""
BINARY_PATH=""

usage() {
    echo 'NAME
       seedsigner_build.sh - verify SeedSigner OS firmware

SYNOPSIS
       seedsigner_build.sh --version VERSION --arch ARCH
       seedsigner_build.sh --version VERSION --arch ARCH --binary PATH

DESCRIPTION
       Verifies SeedSigner OS disk images build reproducibly from source using
       the upstream Buildroot-based Docker build system (seedsigner-os).

       --version   Application version (e.g. 0.8.6)
       --arch      Board target: pi0, pi02w, or pi4
       --binary    Path to official .img file (optional; downloaded if omitted)

       Board mapping:
         pi0     Raspberry Pi Zero / Pi Zero W  (seedsigner_os.VERSION.pi0.img)
         pi02w   Raspberry Pi Zero 2W / Pi3     (seedsigner_os.VERSION.pi02w.img)
         pi4     Raspberry Pi 4 / Pi 400        (seedsigner_os.VERSION.pi4.img)

EXAMPLES
       seedsigner_build.sh --version 0.8.6 --arch pi0
       seedsigner_build.sh --version 0.8.6 --arch pi02w
       seedsigner_build.sh --version 0.8.6 --arch pi4'
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --version) VERSION="$2"; shift ;;
        --arch)    ARCH="$2";    shift ;;
        --binary)  BINARY_PATH="$2"; shift ;;
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

if [[ -z "$ARCH" ]]; then
    echo "Error: --arch is required (pi0, pi02w, or pi4)"
    echo; usage; exit 1
fi

case "$ARCH" in
    pi0|pi02w|pi4) ;;
    *)
        echo "Error: --arch must be pi0, pi02w, or pi4, got: $ARCH"
        exit 1
        ;;
esac

if [[ -n "$BINARY_PATH" ]]; then
    if [[ ! -f "$BINARY_PATH" ]]; then
        echo "Error: Binary file not found: $BINARY_PATH"
        exit 1
    fi
    [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
fi

OFFICIAL_FILENAME="seedsigner_os.${VERSION}.${ARCH}.img"
WORK_DIR="$(pwd)/seedsigner-work_${VERSION}_${ARCH}"
IMAGE_TAG="seedsigner_builder_${VERSION}_${ARCH}"

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
echo "Verifying SeedSigner v${VERSION} (${ARCH})"
echo "Official binary: ${OFFICIAL_FILENAME}"
echo "Work directory:  ${WORK_DIR}"
echo
echo -e "${YELLOW}Note: Buildroot-based build may take 25 minutes to 2.5 hours and requires ~25 GB disk space.${NC}"
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
    DOWNLOAD_URL="https://github.com/SeedSigner/seedsigner/releases/download/${VERSION}/${OFFICIAL_FILENAME}"
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O "$OFFICIAL_BIN"; then
        echo -e "${RED}Error: Failed to download $DOWNLOAD_URL${NC}"
        write_results "ftbfs" "SeedSigner v${VERSION} (${ARCH}): Failed to download official image from GitHub releases."
        exit 1
    fi
fi

# ── Clone seedsigner-os repository ───────────────────────────────────────────

echo "Cloning seedsigner-os repository at v${VERSION}..."
if ! git clone --quiet --recurse-submodules \
        https://github.com/SeedSigner/seedsigner-os.git "$WORK_DIR/seedsigner-os"; then
    echo -e "${RED}Error: Failed to clone seedsigner-os${NC}"
    write_results "ftbfs" "SeedSigner v${VERSION} (${ARCH}): Failed to clone seedsigner-os repository."
    exit 1
fi

cd "$WORK_DIR/seedsigner-os"

if ! git checkout "$VERSION" 2>/dev/null; then
    echo -e "${YELLOW}Tag v${VERSION} not found in seedsigner-os, using default branch${NC}"
fi

git submodule update --init --recursive

# ── Build firmware ────────────────────────────────────────────────────────────

echo "Building SeedSigner OS image for ${ARCH} (this will take a long time)..."

# DOCKER_DEFAULT_PLATFORM=linux/amd64 is required for reproducible builds
# even on ARM hosts (Apple M1/M2, etc.)
if ! DOCKER_DEFAULT_PLATFORM=linux/amd64 \
     SS_ARGS="--${ARCH} --app-branch=${VERSION}" \
     "$CONTAINER_CMD" compose up --force-recreate --build; then
    echo -e "${RED}Error: Firmware build failed${NC}"
    write_results "ftbfs" "SeedSigner v${VERSION} (${ARCH}): docker compose build failed."
    exit 1
fi

cd - > /dev/null

BUILT_BIN="$WORK_DIR/seedsigner-os/images/${OFFICIAL_FILENAME}"
if [[ ! -f "$BUILT_BIN" ]]; then
    echo -e "${RED}Error: Expected built image not found: $BUILT_BIN${NC}"
    write_results "ftbfs" "SeedSigner v${VERSION} (${ARCH}): Build completed but ${OFFICIAL_FILENAME} not found in images/."
    exit 1
fi

echo -e "${GREEN}Firmware build completed${NC}"

# ── Compare ───────────────────────────────────────────────────────────────────

echo
echo "Comparing disk images..."

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
    write_results "reproducible" "SeedSigner v${VERSION} (${ARCH}) builds reproducibly from source.
  Built using the upstream seedsigner-os Buildroot system (BR2_REPRODUCIBLE=y) inside a Docker container.
  Direct SHA256 comparison of disk images — no signature stripping required."
    EXIT_CODE=0
else
    echo -e "${RED}✗ NOT REPRODUCIBLE: Hashes differ${NC}"
    write_results "not_reproducible" "SeedSigner v${VERSION} (${ARCH}): Build succeeded but the disk image does not match the official release.
  Official SHA256: ${OFFICIAL_HASH}
  Built SHA256:    ${BUILT_HASH}"
    EXIT_CODE=1
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

echo
echo "Cleaning up Docker resources..."
"$CONTAINER_CMD" compose -f "$WORK_DIR/seedsigner-os/docker-compose.yml" down 2>/dev/null || true
$CONTAINER_CMD image prune -f 2>/dev/null || true

echo
echo "SeedSigner firmware verification complete."
echo "Results: $RESULTS_FILE"

exit $EXIT_CODE
