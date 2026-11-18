#!/bin/bash
# krux_m5stickv_build.sh v1.0.1 - WalletScrutiny verification script for Krux on M5StickV
# Usage: krux_m5stickv_build.sh --version VERSION [--binary ZIP] [--arch ARCH] [--type TYPE]

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
REPO="https://github.com/selfcustody/krux.git"
DEVICE="maixpy_m5stickv"

GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

if command -v docker &>/dev/null && docker info &>/dev/null; then
  CONTAINER_CMD="docker"
  echo "Using Docker for containerization"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
  echo "Using Podman for containerization"
else
  echo "Error: Neither docker nor podman found. Please install Docker or Podman."
  exit 1
fi

VERSION=""
BINARY_PATH=""

usage() {
  echo 'NAME
       krux_m5stickv_build.sh - verify Krux firmware for M5StickV

SYNOPSIS
       krux_m5stickv_build.sh --version VERSION [--binary ZIP]

DESCRIPTION
       Builds Krux firmware for the M5StickV device from source using the upstream
       multi-stage Dockerfile and compares firmware.bin and kboot.kfpkg against
       the official release zip.

       --version   Required. CalVer version without "v" prefix (e.g. 26.04.0)
       --binary    Optional. Path to official krux-vVERSION.zip (downloaded if omitted)
       --arch      Accepted but unused (device is fixed: maixpy_m5stickv)
       --type      Accepted but unused.

EXAMPLES
       krux_m5stickv_build.sh --version 26.04.0
       krux_m5stickv_build.sh --version 26.04.0 --binary /path/to/krux-v26.04.0.zip'
}

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

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --binary)  BINARY_PATH="$2"; shift ;;
    --version) VERSION="$2";     shift ;;
    --arch)                      shift ;;
    --type)                      shift ;;
    -h|--help) usage; exit 0 ;;
    *)         shift; continue ;;
  esac
  shift
done

if [[ -z "$VERSION" ]]; then
  echo "Error: --version is required"
  echo
  usage
  exit 1
fi

if [[ -n "$BINARY_PATH" ]]; then
  if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Error: Binary file not found: $BINARY_PATH"
    exit 1
  fi
  [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
fi

WORK_DIR="$(pwd)/krux-work_${VERSION}_${DEVICE}"
ZIP_NAME="krux-v${VERSION}.zip"
ZIP_URL="https://github.com/selfcustody/krux/releases/download/v${VERSION}/${ZIP_NAME}"
IMAGE_TAG="krux_builder_${VERSION}_${DEVICE}"
CONTAINER_NAME="krux_extract_${VERSION}_${DEVICE}"

echo
echo "Krux v${VERSION} — M5StickV (${DEVICE})"
echo "Note: first run compiles the Kendryte K210 toolchain from scratch (~30-60 min)."
echo

# ── Clone repo ────────────────────────────────────────────────────────────────

echo "Cloning Krux repository at tag v${VERSION}..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if ! git clone --quiet --depth 1 --branch "v${VERSION}" "$REPO" "$WORK_DIR/src"; then
  echo -e "${RED}Failed to clone repository at tag v${VERSION}${NC}"
  write_results "ftbfs" "Krux v${VERSION} (${DEVICE}): Failed to clone repository. Check that the version tag exists."
  exit 1
fi

commit=$(git -C "$WORK_DIR/src" rev-parse HEAD)
echo -e "${GREEN}Cloned at commit: $commit${NC}"

echo "Initializing submodules (vendor dependencies)..."
if ! git -C "$WORK_DIR/src" submodule update --init --recursive --depth 1; then
  echo -e "${RED}Failed to initialize submodules${NC}"
  write_results "ftbfs" "Krux v${VERSION} (${DEVICE}): Failed to initialize git submodules."
  exit 1
fi

# ── Get official zip ──────────────────────────────────────────────────────────

officialZip="$WORK_DIR/$ZIP_NAME"

if [[ -n "$BINARY_PATH" ]]; then
  echo "Using provided zip: $BINARY_PATH"
  cp "$BINARY_PATH" "$officialZip"
else
  echo "Downloading official release: $ZIP_URL"
  if ! wget -q --show-progress -O "$officialZip" "$ZIP_URL"; then
    echo -e "${RED}Failed to download official release zip${NC}"
    write_results "ftbfs" "Krux v${VERSION} (${DEVICE}): Failed to download official release zip from GitHub."
    exit 1
  fi
fi

officialZipSha=$(sha256sum "$officialZip" | awk '{print $1}')
echo -e "${GREEN}Official zip SHA256: $officialZipSha${NC}"

publishedSha=$(wget -qO- "${ZIP_URL}.sha256.txt" | awk '{print $1}' || true)
if [[ -n "$publishedSha" && "$officialZipSha" != "$publishedSha" ]]; then
  echo -e "${RED}Warning: zip SHA256 mismatch — expected $publishedSha got $officialZipSha${NC}"
fi

echo "Extracting official zip..."
mkdir -p "$WORK_DIR/official"
unzip -q "$officialZip" -d "$WORK_DIR/official"

# ── Build firmware ────────────────────────────────────────────────────────────

echo ""
echo "Building firmware for ${DEVICE}..."

if ! $CONTAINER_CMD build \
    --ulimit nofile=65536:65536 \
    --build-arg DEVICE="$DEVICE" \
    -t "$IMAGE_TAG" \
    "$WORK_DIR/src"; then
  echo -e "${RED}Docker build failed${NC}"
  write_results "ftbfs" "Krux v${VERSION} (${DEVICE}): Docker image build failed."
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
  exit 1
fi

mkdir -p "$WORK_DIR/built"
$CONTAINER_CMD create --name "$CONTAINER_NAME" "$IMAGE_TAG" >/dev/null
$CONTAINER_CMD cp "${CONTAINER_NAME}:/src/firmware/Kboot/build/firmware.bin" "$WORK_DIR/built/firmware.bin"
$CONTAINER_CMD cp "${CONTAINER_NAME}:/src/firmware/Kboot/build/kboot.kfpkg"  "$WORK_DIR/built/kboot.kfpkg"
$CONTAINER_CMD rm "$CONTAINER_NAME" >/dev/null

echo -e "${GREEN}Build succeeded${NC}"

# ── Compare ───────────────────────────────────────────────────────────────────

officialFirmwareSha=$(sha256sum "$WORK_DIR/official/krux-v${VERSION}/${DEVICE}/firmware.bin" | awk '{print $1}')
builtFirmwareSha=$(sha256sum "$WORK_DIR/built/firmware.bin"                                  | awk '{print $1}')
officialKfpkgSha=$(sha256sum "$WORK_DIR/official/krux-v${VERSION}/${DEVICE}/kboot.kfpkg"    | awk '{print $1}')
builtKfpkgSha=$(sha256sum "$WORK_DIR/built/kboot.kfpkg"                                     | awk '{print $1}')

echo ""
echo "============================================================"
echo "COMPARISON RESULTS:"
echo "  firmware.bin  official: $officialFirmwareSha"
echo "  firmware.bin  built:    $builtFirmwareSha"
echo "  kboot.kfpkg   official: $officialKfpkgSha"
echo "  kboot.kfpkg   built:    $builtKfpkgSha"
echo "============================================================"

if [[ "$officialFirmwareSha" == "$builtFirmwareSha" && \
      "$officialKfpkgSha"    == "$builtKfpkgSha" ]]; then
  echo -e "${GREEN}✓ REPRODUCIBLE${NC}"
  write_results "reproducible" "Krux v${VERSION} on M5StickV (${DEVICE}) builds reproducibly from source using the upstream multi-stage Dockerfile (gcc:9.5.0-bullseye base with the Kendryte K210 RISC-V toolchain compiled from source). firmware.bin and kboot.kfpkg match the official release zip exactly. Expected differences (do not affect reproducibility verdict): - ktool-linux, ktool-mac, ktool-mac-10, ktool-win.exe: pre-built flash tool binaries from selfcustody/ktool, not compiled from source, excluded from comparison."
else
  echo -e "${RED}✗ NOT REPRODUCIBLE${NC}"
  write_results "not_reproducible" "Krux v${VERSION} on M5StickV (${DEVICE}): firmware.bin or kboot.kfpkg did not match the official release zip."
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

echo "Cleaning up Docker resources..."
$CONTAINER_CMD rm "$CONTAINER_NAME" -f 2>/dev/null || true
$CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
$CONTAINER_CMD image prune -f 2>/dev/null || true

echo ""
echo "Done. Results written to: $RESULTS_FILE"
