#!/bin/bash
# lnbits-hardware-wallet_build.sh v1.5.0 - WalletScrutiny verification script for LNbits WALLY Hardware Wallet
# Usage: lnbits-hardware-wallet_build.sh --version VERSION [--binary PATH] [--arch FQBN] [--type TYPE]

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

SCRIPT_VERSION="v1.6.0"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
REPO="https://github.com/lnbits/hardware-wallet.git"

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if command -v docker &>/dev/null; then
  CONTAINER_CMD="docker"
  echo "Using Docker for containerization"
elif command -v podman &>/dev/null; then
  CONTAINER_CMD="podman"
  echo "Using Podman for containerization"
else
  echo "Error: Neither docker nor podman found. Please install one of them."
  write_results "ftbfs" "LNbits WALLY: Neither docker nor podman found. Please install Docker or Podman."
  exit 1
fi

VERSION=""
BINARY_PATH=""
ARCH="esp32:esp32:lilygo_t_display"
TYPE=""

usage() {
  echo 'NAME
       lnbits-hardware-wallet_build.sh - verify LNbits WALLY hardware wallet firmware

SYNOPSIS
       lnbits-hardware-wallet_build.sh --version VERSION [--binary PATH] [--arch FQBN]

DESCRIPTION
       Builds the LNbits WALLY ESP32 firmware from source using arduino-cli inside
       a container and compares wallet.ino.bin against the official binary distributed
       in the repository.

       --version   Required. Version without "v" prefix (e.g. 0.4)
       --binary    Optional. Path to official wallet.ino.bin (downloaded if omitted)
       --arch      Arduino board FQBN (default: esp32:esp32:lilygo_t_display)
       --type      Accepted but unused.

EXAMPLES
       lnbits-hardware-wallet_build.sh --version 0.4
       lnbits-hardware-wallet_build.sh --version 0.3 --binary /path/to/wallet.ino.bin'
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
    --arch)    ARCH="$2";        shift ;;
    --type)                      shift ;;
    -h|--help) usage; exit 0 ;;
    *)         shift; continue ;;
  esac
  shift
done

if [[ -z "$VERSION" ]]; then
  echo -e "${RED}Error: --version is required.${NC}"
  echo
  usage
  write_results "ftbfs" "LNbits WALLY: Missing required parameter --version."
  exit 1
fi

if [[ -n "$BINARY_PATH" ]]; then
  if [[ ! -f "$BINARY_PATH" ]]; then
    echo -e "${RED}Error: Binary file not found: $BINARY_PATH${NC}"
    write_results "ftbfs" "LNbits WALLY v${VERSION}: provided --binary file not found: ${BINARY_PATH}"
    exit 1
  fi
  [[ "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"
fi

IMAGE_TAG="lnbits_hardware_wallet_builder_${VERSION}"
WORK_DIR="$(pwd)/lnbits-hardware-wallet-work_${VERSION}"

echo
echo "LNbits WALLY firmware verification — version: ${VERSION}"
echo

# ── Clone repo ────────────────────────────────────────────────────────────────

echo "Cloning lnbits/hardware-wallet..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if ! git clone --quiet --depth 1 --branch "v${VERSION}" "$REPO" "$WORK_DIR/src" 2>/dev/null; then
  echo -e "${YELLOW}Tag v${VERSION} not found, cloning main branch...${NC}"
  if ! git clone --quiet --depth 1 "$REPO" "$WORK_DIR/src"; then
    write_results "ftbfs" "LNbits WALLY v${VERSION}: Failed to clone repository."
    exit 1
  fi
fi

commit=$(git -C "$WORK_DIR/src" rev-parse HEAD)
echo -e "${GREEN}Cloned at commit: $commit${NC}"

# ── Get official binary ───────────────────────────────────────────────────────

if [[ -n "$BINARY_PATH" ]]; then
  echo "Using provided official binary: $BINARY_PATH"
  cp "$BINARY_PATH" "$WORK_DIR/official.bin"
else
  # The official binary's location has moved twice as the project has grown:
  #   - up to v0.5:  committed directly in the repo tree
  #   - v0.6-v0.8.0: single-board release asset "Bowser-HWW-firmware-vX.Y.Z.bin"
  #   - v0.8.1+:     multi-board release assets "Bowser-Wallet-vX.Y.Z-<target>.bin"
  #                  (lilygo_tdisplay, esp32_3248s035c, waveshare_esp32_c6_lcd_1_3)
  # We build for "lilygo_tdisplay" (see ARCH/BUILD_TARGET below), so fetch that asset.
  OFFICIAL_URL="https://github.com/lnbits/hardware-wallet/releases/download/v${VERSION}/Bowser-Wallet-v${VERSION}-lilygo_tdisplay.bin"
  echo "Downloading official binary from: $OFFICIAL_URL"
  if ! curl -fsSL "$OFFICIAL_URL" -o "$WORK_DIR/official.bin"; then
    OFFICIAL_URL="https://github.com/lnbits/hardware-wallet/releases/download/v${VERSION}/Bowser-HWW-firmware-v${VERSION}.bin"
    echo "Not a multi-board release, trying single-board release asset: $OFFICIAL_URL"
    if ! curl -fsSL "$OFFICIAL_URL" -o "$WORK_DIR/official.bin"; then
      OFFICIAL_URL="https://raw.githubusercontent.com/lnbits/hardware-wallet/main/installer/firmware/esp32/v${VERSION}/wallet.ino.bin"
      echo "Not found as a release asset, trying repo tree: $OFFICIAL_URL"
      if ! curl -fsSL "$OFFICIAL_URL" -o "$WORK_DIR/official.bin"; then
        write_results "ftbfs" "LNbits WALLY v${VERSION}: Could not download official firmware from the multi-board release asset (Bowser-Wallet-v${VERSION}-lilygo_tdisplay.bin), the single-board release asset (Bowser-HWW-firmware-v${VERSION}.bin), or the repo tree (installer/firmware/esp32/v${VERSION}/wallet.ino.bin)."
        exit 1
      fi
    fi
  fi
fi

officialSha=$(sha256sum "$WORK_DIR/official.bin" | awk '{print $1}')
echo -e "${GREEN}Official SHA-256: $officialSha${NC}"

# ── Build Docker image ────────────────────────────────────────────────────────

echo
echo "Building Docker image with arduino-cli and ESP32 board support..."
echo "Note: ESP32 core download may take several minutes on first run."

if ! $CONTAINER_CMD build \
    --ulimit nofile=65536:65536 \
    -t "$IMAGE_TAG" - << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# The official release workflow runs on a GitHub Actions runner with HOME=/home/runner.
# The ESP32 core's headers get compiled with __FILE__-based absolute paths that end up
# embedded as literal strings in the shipped binary (assert/log macros in the HAL layer),
# so building under a different HOME (e.g. /root here) produces a differently-pathed but
# functionally identical binary. Matching the exact HOME eliminates that diff category.
ENV HOME=/home/runner
RUN mkdir -p /home/runner

RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    ca-certificates \
    python3 \
    python3-serial \
    && rm -rf /var/lib/apt/lists/*

# Install the exact arduino-cli version/checksum pinned by the project's own release
# workflow (.github/workflows/deploy-webapp.yml) — not "whatever's latest," which is
# what the generic install.sh script would give us.
RUN curl --fail --location --silent --show-error \
      https://github.com/arduino/arduino-cli/releases/download/v1.5.1/arduino-cli_1.5.1_Linux_64bit.tar.gz \
      --output /tmp/arduino-cli.tar.gz && \
    echo "28a8e119c498a25607821c36cb2dc49e8463941b261a0d99091baa7bc692dd2b  /tmp/arduino-cli.tar.gz" | sha256sum --check --strict && \
    tar -xzf /tmp/arduino-cli.tar.gz -C /usr/local/bin && \
    rm /tmp/arduino-cli.tar.gz

# Configure ESP32 board support - URL matches the project's own release workflow
# (.github/workflows/deploy-webapp.yml) exactly, not just any mirror of the index.
RUN arduino-cli config init && \
    arduino-cli config add board_manager.additional_urls \
    https://espressif.github.io/arduino-esp32/package_esp32_index.json && \
    arduino-cli core update-index && \
    arduino-cli core install esp32:esp32@2.0.17

RUN mkdir -p /home/runner/Arduino/libraries
DOCKERFILE
then
  echo -e "${RED}Docker image build failed.${NC}"
  write_results "ftbfs" "LNbits WALLY v${VERSION}: Failed to build Docker image with arduino-cli and ESP32 support."
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
  exit 1
fi

# Capture installed ESP32 core version for notes
ESP32_CORE_VERSION=$($CONTAINER_CMD run --rm "$IMAGE_TAG" \
  arduino-cli core list 2>/dev/null | grep "^esp32:esp32 " | awk '{print $2}' || echo "unknown")
echo "Installed ESP32 core: $ESP32_CORE_VERSION"

# ── Compile firmware ──────────────────────────────────────────────────────────
# Mounted and invoked to match the release workflow's own $GITHUB_WORKSPACE path
# (/home/runner/work/hardware-wallet/hardware-wallet) exactly — __FILE__-based paths
# for the *source* files (not just the ESP32 core headers) also get embedded as literal
# strings in the shipped binary, so this must match too, not just the arduino-cli HOME.

srcDir="$(realpath "$WORK_DIR/src")"
workspacePath="/home/runner/work/hardware-wallet/hardware-wallet"
BUILD_TARGET="lilygo_tdisplay"

if [[ -f "$srcDir/tools/build_firmware.sh" ]]; then
  # v0.8.1+ ships its own per-board build script (tools/build_firmware.sh), which sets
  # the FQBN, wally build flags, and TFT setup for each target authoritatively. This
  # replaced our own hand-rolled arduino-cli invocation below — trust the project's
  # script over reconstructing its flags ourselves, since board-specific flags have
  # changed release to release (e.g. the FQBN for "lilygo_tdisplay" is deliberately
  # esp32:esp32:ttgo-lora32, NOT the ESP32 core's own "lilygo_t_display" board entry -
  # see the comment in their tools/build_firmware.sh).
  echo
  echo "Compiling firmware via tools/build_firmware.sh (target: ${BUILD_TARGET})..."
  ARCH="(managed by tools/build_firmware.sh: ${BUILD_TARGET})"

  if ! $CONTAINER_CMD run --rm \
      --ulimit nofile=65536:65536 \
      -v "$srcDir":"$workspacePath" \
      -w "$workspacePath" \
      "$IMAGE_TAG" \
      bash "tools/build_firmware.sh" "$BUILD_TARGET" "firmware-build/${BUILD_TARGET}"; then
    write_results "ftbfs" "LNbits WALLY v${VERSION}: 'tools/build_firmware.sh ${BUILD_TARGET}' failed. See build log for the underlying arduino-cli error."
    $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
    exit 1
  fi

  BUILT_BIN="$srcDir/firmware-build/${BUILD_TARGET}/wallet.ino.bin"
else
  # Pre-v0.8.1: no per-board build script exists yet, fall back to a direct
  # arduino-cli invocation matching the release workflow of that era.
  echo
  echo "Compiling firmware (board: ${ARCH})..."

  if ! $CONTAINER_CMD run --rm \
      --ulimit nofile=65536:65536 \
      -v "$srcDir":"$workspacePath" \
      "$IMAGE_TAG" \
      arduino-cli compile --clean \
        --fqbn "$ARCH" \
        --libraries "$workspacePath/libraries" \
        --build-path "$workspacePath/firmware-build" \
        "$workspacePath/wallet"; then
    write_results "ftbfs" "LNbits WALLY v${VERSION}: Arduino compilation failed with board FQBN '${ARCH}' and ESP32 core ${ESP32_CORE_VERSION}. The firmware may require a specific ESP32 Arduino core version. The project documents no automated build system."
    $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
    exit 1
  fi

  BUILT_BIN="$srcDir/firmware-build/wallet.ino.bin"
fi

if [[ ! -f "$BUILT_BIN" ]]; then
  write_results "ftbfs" "LNbits WALLY v${VERSION}: Compilation appeared to succeed but wallet.ino.bin was not found in the output directory ($BUILT_BIN)."
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
  exit 1
fi

echo -e "${GREEN}Compilation succeeded.${NC}"

# ── Compare ───────────────────────────────────────────────────────────────────

builtSha=$(sha256sum "$BUILT_BIN" | awk '{print $1}')
diffBytes=$(cmp -l "$WORK_DIR/official.bin" "$BUILT_BIN" 2>/dev/null | wc -l | tr -d ' ')

echo
echo "============================================================"
echo "COMPARISON RESULTS:"
echo "  official SHA-256: $officialSha"
echo "  built SHA-256:    $builtSha"
echo "  differing bytes:  $diffBytes / $(stat -c%s "$WORK_DIR/official.bin")"
echo "============================================================"

if [[ "$officialSha" == "$builtSha" ]]; then
  verdict="reproducible"
  echo -e "${GREEN}REPRODUCIBLE${NC}"
  notes="LNbits WALLY firmware v${VERSION} builds reproducibly from source using arduino-cli with ESP32 Arduino core ${ESP32_CORE_VERSION} inside a containerized Ubuntu 22.04 environment. Board target: ${ARCH}. wallet.ino.bin matches the official binary distributed in the repository at installer/firmware/esp32/v${VERSION}/wallet.ino.bin."
else
  verdict="not_reproducible"
  echo -e "${RED}NOT REPRODUCIBLE${NC}"
  notes="LNbits WALLY firmware v${VERSION} does not byte-for-byte reproduce: ${diffBytes} of $(stat -c%s "$WORK_DIR/official.bin") bytes differ (built with arduino-cli ${ESP32_CORE_VERSION} core, ${ARCH}, matching the exact toolchain version and \$HOME/\$GITHUB_WORKSPACE paths used by the project's own release workflow). See review.md for a byte-offset breakdown of where the diff falls.
  Official SHA-256: ${officialSha}
  Built SHA-256:    ${builtSha}
  Differing bytes:  ${diffBytes} / $(stat -c%s "$WORK_DIR/official.bin")"
fi

echo
echo "===== Begin Results ====="
echo "firmware:       LNbits WALLY (Bowser HWW)"
echo "version:        $VERSION"
echo "verdict:        $verdict"
echo "officialHash:   $officialSha"
echo "builtHash:      $builtSha"
echo "diffBytes:      $diffBytes"
echo "repository:     $REPO"
echo "tag:            v$VERSION"
echo "commit:         $commit"
if [[ "$verdict" == "reproducible" ]]; then
  echo "✓ The firmware builds reproducibly from source code."
else
  echo "✗ The firmware does not build byte-for-byte reproducibly (see diffBytes)."
fi
echo "===== End Results ====="

write_results "$verdict" "$notes"

# ── Cleanup ───────────────────────────────────────────────────────────────────

echo
echo "Cleaning up Docker resources..."
$CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
$CONTAINER_CMD image prune -f 2>/dev/null || true

echo
echo "Done. Results written to: $RESULTS_FILE"
