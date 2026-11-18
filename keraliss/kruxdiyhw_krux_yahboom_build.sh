#!/bin/bash
# krux_yahboom_build.sh v1.0.1 - WalletScrutiny verification script for Krux on K210 devices
# Covers: maixpy_yahboom, maixpy_cube, maixpy_wonder_mv
# Usage: krux_yahboom_build.sh --version VERSION [--binary ZIP] [--arch ARCH] [--type TYPE]

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

DEVICES=(
  maixpy_yahboom
  maixpy_cube
  maixpy_wonder_mv
)

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
       krux_yahboom_build.sh - verify Krux firmware for Yahboom, Cube, Wonder MV

SYNOPSIS
       krux_yahboom_build.sh --version VERSION [--binary ZIP]

DESCRIPTION
       Builds all three devices sequentially, sharing one repo clone and one zip
       download. Produces a combined COMPARISON_RESULTS.yaml.

       --version   Required. CalVer version without "v" prefix (e.g. 26.04.0)
       --binary    Optional. Path to official krux-vVERSION.zip (downloaded if omitted)
       --arch      Accepted but unused.
       --type      Accepted but unused.

EXAMPLES
       krux_yahboom_build.sh --version 26.04.0'
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

ZIP_NAME="krux-v${VERSION}.zip"
ZIP_URL="https://github.com/selfcustody/krux/releases/download/v${VERSION}/${ZIP_NAME}"
WORK_DIR="$(pwd)/krux-work_${VERSION}_other_a"

echo
echo "Krux v${VERSION} — Yahboom / Cube / Wonder MV"
echo "Note: first device compiles the Kendryte toolchain from scratch (~30-60 min)."
echo "Subsequent devices reuse Docker layer cache and are much faster."
echo

# ── Clone repo ────────────────────────────────────────────────────────────────

echo "Cloning Krux repository at tag v${VERSION}..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if ! git clone --quiet --depth 1 --branch "v${VERSION}" "$REPO" "$WORK_DIR/src"; then
  echo -e "${RED}Failed to clone repository at tag v${VERSION}${NC}"
  write_results "ftbfs" "Krux v${VERSION}: Failed to clone repository. Check that the version tag exists."
  exit 1
fi

commit=$(git -C "$WORK_DIR/src" rev-parse HEAD)
echo -e "${GREEN}Cloned at commit: $commit${NC}"

echo "Initializing submodules..."
if ! git -C "$WORK_DIR/src" submodule update --init --recursive --depth 1; then
  echo -e "${RED}Failed to initialize submodules${NC}"
  write_results "ftbfs" "Krux v${VERSION}: Failed to initialize git submodules."
  exit 1
fi

# ── Download official zip ─────────────────────────────────────────────────────

officialZip="$WORK_DIR/$ZIP_NAME"

if [[ -n "$BINARY_PATH" ]]; then
  echo "Using provided zip: $BINARY_PATH"
  cp "$BINARY_PATH" "$officialZip"
else
  echo "Downloading official release: $ZIP_URL"
  if ! wget -q --show-progress -O "$officialZip" "$ZIP_URL"; then
    echo -e "${RED}Failed to download official release zip${NC}"
    write_results "ftbfs" "Krux v${VERSION}: Failed to download official release zip from GitHub."
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

# ── Build and compare each device ─────────────────────────────────────────────

declare -A FW_OFFICIAL FW_BUILT KF_OFFICIAL KF_BUILT
failedDevices=()

for DEVICE in "${DEVICES[@]}"; do
  IMAGE_TAG="krux_builder_${VERSION}_${DEVICE}"
  CONTAINER_NAME="krux_extract_${VERSION}_${DEVICE}"
  BUILT_DIR="$WORK_DIR/built_${DEVICE}"

  echo ""
  echo "============================================================"
  echo "Building: $DEVICE"
  echo "============================================================"

  if ! $CONTAINER_CMD build \
      --ulimit nofile=65536:65536 \
      --build-arg DEVICE="$DEVICE" \
      -t "$IMAGE_TAG" \
      "$WORK_DIR/src"; then
    echo -e "${RED}Docker build failed for $DEVICE${NC}"
    failedDevices+=("$DEVICE")
    $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
    continue
  fi

  mkdir -p "$BUILT_DIR"
  $CONTAINER_CMD create --name "$CONTAINER_NAME" "$IMAGE_TAG" >/dev/null
  $CONTAINER_CMD cp "${CONTAINER_NAME}:/src/firmware/Kboot/build/firmware.bin" "$BUILT_DIR/firmware.bin"
  $CONTAINER_CMD cp "${CONTAINER_NAME}:/src/firmware/Kboot/build/kboot.kfpkg"  "$BUILT_DIR/kboot.kfpkg"
  $CONTAINER_CMD rm "$CONTAINER_NAME" >/dev/null
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true

  FW_OFFICIAL[$DEVICE]=$(sha256sum "$WORK_DIR/official/krux-v${VERSION}/${DEVICE}/firmware.bin" | awk '{print $1}')
  FW_BUILT[$DEVICE]=$(sha256sum "$BUILT_DIR/firmware.bin"                                       | awk '{print $1}')
  KF_OFFICIAL[$DEVICE]=$(sha256sum "$WORK_DIR/official/krux-v${VERSION}/${DEVICE}/kboot.kfpkg"  | awk '{print $1}')
  KF_BUILT[$DEVICE]=$(sha256sum "$BUILT_DIR/kboot.kfpkg"                                        | awk '{print $1}')

  echo "  firmware.bin  official: ${FW_OFFICIAL[$DEVICE]}"
  echo "  firmware.bin  built:    ${FW_BUILT[$DEVICE]}"
  echo "  kboot.kfpkg   official: ${KF_OFFICIAL[$DEVICE]}"
  echo "  kboot.kfpkg   built:    ${KF_BUILT[$DEVICE]}"

  if [[ "${FW_OFFICIAL[$DEVICE]}" == "${FW_BUILT[$DEVICE]}" && \
        "${KF_OFFICIAL[$DEVICE]}" == "${KF_BUILT[$DEVICE]}" ]]; then
    echo -e "  ${GREEN}✓ $DEVICE: MATCH${NC}"
  else
    echo -e "  ${RED}✗ $DEVICE: MISMATCH${NC}"
    failedDevices+=("$DEVICE")
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "FINAL SUMMARY:"
for DEVICE in "${DEVICES[@]}"; do
  if [[ -n "${FW_BUILT[$DEVICE]:-}" && "${FW_OFFICIAL[$DEVICE]}" == "${FW_BUILT[$DEVICE]}" && \
        "${KF_OFFICIAL[$DEVICE]}" == "${KF_BUILT[$DEVICE]}" ]]; then
    echo -e "  ${GREEN}✓ $DEVICE${NC}"
  else
    echo -e "  ${RED}✗ $DEVICE${NC}"
  fi
done
echo "============================================================"

if [[ ${#failedDevices[@]} -eq 0 ]]; then
  echo -e "${GREEN}✓ ALL REPRODUCIBLE${NC}"
  write_results "reproducible" "Krux v${VERSION} builds reproducibly on Yahboom K210 (maixpy_yahboom), Maix Cube (maixpy_cube), and Wonder MV (maixpy_wonder_mv). firmware.bin and kboot.kfpkg match the official release zip exactly for each device. Build uses the upstream multi-stage Dockerfile (gcc:9.5.0-bullseye base with the Kendryte K210 RISC-V toolchain compiled from source). Expected differences (do not affect reproducibility verdict): - ktool-linux, ktool-mac, ktool-mac-10, ktool-win.exe: pre-built flash tool binaries from selfcustody/ktool, not compiled from source, excluded from comparison."
else
  echo -e "${RED}✗ FAILED: ${failedDevices[*]}${NC}"
  write_results "not_reproducible" "Krux v${VERSION}: failed or mismatched on: ${failedDevices[*]}."
fi

$CONTAINER_CMD image prune -f 2>/dev/null || true

echo ""
echo "Done. Results written to: $RESULTS_FILE"
