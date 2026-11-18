#!/bin/bash
# onekey_build.sh v3.1.0 - WalletScrutiny verification script for OneKey Hardware Wallets
# Usage: onekey_build.sh --version VERSION --type TYPE --hash HASH [--binary PATH]

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

SCRIPT_VERSION="v3.1.0"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

GREEN='\033[1;32m'
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

BINARY_PATH=""
VERSION=""
TYPE=""
SHORT_HASH=""

usage() {
  echo "Usage: $0 --version VERSION --type TYPE --hash HASH [--binary PATH]"
  echo "  --version   Firmware version without 'v' prefix (e.g., 3.12.0)"
  echo "  --type      Device type: mini|classic|touch"
  echo "  --hash      Short commit hash (e.g., 05bae9f)"
  echo "  --binary    Path to official .signed.bin (optional, auto-downloads if omitted)"
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
    --type)    TYPE="$2";        shift ;;
    --hash)    SHORT_HASH="$2";  shift ;;
    --arch)    shift ;;
    --date)    shift ;;
    -h|--help) usage; exit 0 ;;
    *)         shift; continue ;;
  esac
  shift
done

if [[ -z "$VERSION" ]]; then
  echo "Error: --version is required"; usage; exit 1
fi
if [[ -z "$TYPE" ]]; then
  echo "Error: --type is required"; usage; exit 1
fi
if [[ -z "$SHORT_HASH" ]]; then
  echo "Error: --hash is required"; usage; exit 1
fi
if [[ "$TYPE" != "mini" && "$TYPE" != "classic" && "$TYPE" != "touch" ]]; then
  echo "Error: --type must be mini, classic, or touch"; exit 1
fi

[[ -n "$BINARY_PATH" && "$BINARY_PATH" != /* ]] && BINARY_PATH="$PWD/$BINARY_PATH"

IMAGE_TAG="onekey_builder_${VERSION}_${TYPE}"
CONTAINER_NAME="onekey_build_${VERSION}_${TYPE}"
WORK_DIR="$(pwd)/onekey-work_${VERSION}_${TYPE}"

echo "Verifying OneKey ${TYPE} firmware v${VERSION} (${SHORT_HASH})"
echo

cleanup() {
  $CONTAINER_CMD rm "$CONTAINER_NAME" -f 2>/dev/null || true
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# Discover official firmware URL and extract BUILD_DATE from filename
OFFICIAL_URL=""
BUILD_DATE=""
if [[ -z "$BINARY_PATH" ]]; then
  echo "Querying GitHub releases for official firmware..."
  API_RESPONSE=$(curl -sf "https://api.github.com/repos/OneKeyHQ/firmware/releases/tags/${TYPE}%2Fv${VERSION}" 2>/dev/null || true)
  if [[ -n "$API_RESPONSE" ]]; then
    OFFICIAL_URL=$(echo "$API_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if a['name'].startswith('${TYPE}.') and 'Stable' in a['name'] and a['name'].endswith('.signed.bin'):
        print(a['browser_download_url'])
        break
" 2>/dev/null || true)
  fi
  if [[ -z "$OFFICIAL_URL" ]]; then
    write_results "ftbfs" "OneKey ${TYPE} v${VERSION}: Could not find official signed firmware in GitHub release ${TYPE}/v${VERSION}. The release may not have assets published yet."
    exit 1
  fi
  # Extract MMDD build date from filename: TYPE.VERSION-Stable-MMDD-HASH.signed.bin
  BUILD_DATE=$(basename "$OFFICIAL_URL" | grep -oP 'Stable-\K\d{4}' || true)
  echo "Official firmware: $(basename "$OFFICIAL_URL")"
  echo "Build date: ${BUILD_DATE}"
  echo
else
  BUILD_DATE=$(basename "$BINARY_PATH" | grep -oP 'Stable-\K\d{4}' || true)
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/firmware"

cat > "$WORK_DIR/onekey.dockerfile" << 'DOCKERFILE'
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt -y upgrade && \
    apt install -y curl xz-utils sudo git wget g++ locales binutils file coreutils && \
    locale-gen en_US.UTF-8
RUN groupadd -r nixbld && \
    useradd -m -s /bin/bash nixuser && \
    usermod -aG nixbld nixuser
RUN mkdir /nix && chown nixuser:nixuser /nix
USER nixuser
WORKDIR /home/nixuser
RUN curl -L https://nixos.org/nix/install | sh
ENV USER nixuser
ENV PATH /home/nixuser/.nix-profile/bin:/home/nixuser/.nix-profile/sbin:$PATH
ENV NIX_PATH /home/nixuser/.nix-defexpr/channels
SHELL ["/bin/bash", "-c"]
RUN mkdir -p /home/nixuser/output && chmod 755 /home/nixuser/output
DOCKERFILE

echo "Building Docker image..."
if ! $CONTAINER_CMD build --ulimit nofile=65536:65536 -t "$IMAGE_TAG" -f "$WORK_DIR/onekey.dockerfile" "$WORK_DIR"; then
  write_results "ftbfs" "OneKey ${TYPE} v${VERSION}: Docker image build failed."
  exit 1
fi

echo "Starting build container (this may take 20-40 minutes)..."
$CONTAINER_CMD rm "$CONTAINER_NAME" -f 2>/dev/null || true

$CONTAINER_CMD create --name "$CONTAINER_NAME" \
    --ulimit nofile=65536:65536 \
    -e TYPE="$TYPE" \
    -e VERSION="$VERSION" \
    -e SHORT_HASH="$SHORT_HASH" \
    -e BUILD_DATE="$BUILD_DATE" \
    "$IMAGE_TAG" \
    bash -c '
set -e
source /home/nixuser/.nix-profile/etc/profile.d/nix.sh
cd /home/nixuser

git clone https://github.com/OneKeyHQ/firmware.git
cd firmware
export PRODUCTION=1
export BUILD_DATE="${BUILD_DATE}"

git checkout "${TYPE}/v${VERSION}"
git submodule update --init --recursive

# Override the date-based build name with the official release date
sed -i "s/FIRMWARE_BUILD_DATE=\$(shell date \"+%m%d\")/FIRMWARE_BUILD_DATE=${BUILD_DATE}/" legacy/firmware/Makefile

[[ -f shell.nix ]] && sed -i "s|./pyright|./ci/pyright|" shell.nix

nix-shell --run "poetry install"

if [[ "${TYPE}" == "mini" ]]; then
    nix-shell --run "export ONEKEY_MINI=1 && export BUILD_DATE=${BUILD_DATE} && poetry run ./legacy/script/setup"
    nix-shell --run "export ONEKEY_MINI=1 && export BUILD_DATE=${BUILD_DATE} && poetry run ./legacy/script/cibuild"
    built=$(find ./legacy/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
elif [[ "${TYPE}" == "classic" ]]; then
    nix-shell --run "export BUILD_DATE=${BUILD_DATE} && poetry run ./legacy/script/setup"
    nix-shell --run "export BUILD_DATE=${BUILD_DATE} && poetry run ./legacy/script/cibuild"
    built=$(find ./legacy/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
elif [[ "${TYPE}" == "touch" ]]; then
    nix-shell --run "export BUILD_DATE=${BUILD_DATE} && poetry run make -C core build_boardloader"
    nix-shell --run "export BUILD_DATE=${BUILD_DATE} && poetry run make -C core build_bootloader"
    nix-shell --run "export BUILD_DATE=${BUILD_DATE} && poetry run make -C core build_firmware"
    nix-shell --run "poetry run core/tools/headertool.py -h core/build/firmware/touch*Stable*.bin"
    built=$(find ./core/build/firmware -name "${TYPE}*Stable*.bin" -type f | head -1)
fi

[[ -z "$built" || ! -f "$built" ]] && { echo "ERROR: Built firmware not found"; exit 1; }
cp "$built" /home/nixuser/output/built-firmware.bin
echo "Build complete."
'

$CONTAINER_CMD start -a "$CONTAINER_NAME" || true
$CONTAINER_CMD cp "$CONTAINER_NAME:/home/nixuser/output/built-firmware.bin" "$WORK_DIR/firmware/" 2>/dev/null || true
$CONTAINER_CMD rm "$CONTAINER_NAME" 2>/dev/null || true

if [[ ! -f "$WORK_DIR/firmware/built-firmware.bin" ]]; then
  write_results "ftbfs" "OneKey ${TYPE} v${VERSION}: Build failed — firmware binary not produced."
  cleanup
  exit 1
fi

# Get official firmware
if [[ -n "$BINARY_PATH" ]]; then
  cp "$BINARY_PATH" "$WORK_DIR/firmware/official-firmware.bin"
else
  echo "Downloading official firmware..."
  if ! wget -q --show-progress -O "$WORK_DIR/firmware/official-firmware.bin" "$OFFICIAL_URL"; then
    write_results "ftbfs" "OneKey ${TYPE} v${VERSION}: Build succeeded but official firmware download failed."
    cleanup
    exit 1
  fi
fi

built_hash=$(sha256sum "$WORK_DIR/firmware/built-firmware.bin" | awk '{print $1}')
official_hash=$(sha256sum "$WORK_DIR/firmware/official-firmware.bin" | awk '{print $1}')

# Determine TRZF header length: total_size - codelen (codelen at offset 0x0C).
# Signature region is bytes 0x120 through hdrlen-1 — OneKey signing keys that
# will never match in a community build. Strip that region in both files before
# comparing so we are comparing unsigned code against unsigned code.
hdrlen_val=$(python3 -c "
import struct
with open('$WORK_DIR/firmware/built-firmware.bin', 'rb') as f:
    data = f.read(16)
total = $(wc -c < "$WORK_DIR/firmware/built-firmware.bin")
codelen = struct.unpack_from('<I', data, 0x0C)[0]
print(total - codelen)
")
SIG_START=288   # 0x120
SIG_LEN=$((hdrlen_val - SIG_START))

cp "$WORK_DIR/firmware/built-firmware.bin"     "$WORK_DIR/firmware/built-stripped.bin"
cp "$WORK_DIR/firmware/official-firmware.bin"  "$WORK_DIR/firmware/official-stripped.bin"
dd if=/dev/zero of="$WORK_DIR/firmware/built-stripped.bin"    bs=1 seek=$SIG_START count=$SIG_LEN conv=notrunc 2>/dev/null
dd if=/dev/zero of="$WORK_DIR/firmware/official-stripped.bin" bs=1 seek=$SIG_START count=$SIG_LEN conv=notrunc 2>/dev/null

built_stripped_hash=$(sha256sum    "$WORK_DIR/firmware/built-stripped.bin"    | awk '{print $1}')
official_stripped_hash=$(sha256sum "$WORK_DIR/firmware/official-stripped.bin" | awk '{print $1}')

echo ""
echo "============================================================"
echo "VERIFICATION RESULTS:"
echo "Built (original):            $built_hash"
echo "Official (original):         $official_hash"
echo "Built (sig region zeroed):   $built_stripped_hash"
echo "Official (sig region zeroed):$official_stripped_hash"
echo "Signature region zeroed:     bytes $SIG_START-$((hdrlen_val-1)) (${SIG_LEN} bytes)"
echo "============================================================"
echo ""

verdict=""
if [[ "$built_hash" == "$official_hash" ]]; then
  verdict="reproducible"
  echo -e "${GREEN}✓ REPRODUCIBLE: Hashes match exactly (including signatures)${NC}"
  write_results "reproducible" "OneKey ${TYPE} v${VERSION} builds reproducibly from source using Nix inside a containerized Ubuntu 20.04 environment. SHA256 of built and official firmware match exactly."

elif [[ "$built_stripped_hash" == "$official_stripped_hash" ]]; then
  verdict="reproducible"
  echo -e "${GREEN}✓ REPRODUCIBLE: Stripped hashes match; only signature bytes differ (expected)${NC}"
  write_results "reproducible" "OneKey ${TYPE} v${VERSION} builds reproducibly from source using Nix inside a containerized Ubuntu 20.04 environment.
  Comparison method: TRZF header signature region (bytes 0x120-0x$(printf '%x' $((hdrlen_val-1))), ${SIG_LEN} bytes) is zeroed in both binaries before SHA-256 comparison.
  Expected differences (do not affect reproducibility verdict):
  - Signature region: OneKey signing keys applied post-build by the manufacturer — these will never match in a community build."

else
  verdict="not_reproducible"
  echo -e "${RED}✗ NOT REPRODUCIBLE: Stripped hashes differ${NC}"
  echo ""
  echo "Differences outside signature region:"
  cmp -l "$WORK_DIR/firmware/built-stripped.bin" "$WORK_DIR/firmware/official-stripped.bin" 2>/dev/null \
    | awk -v hdr="$hdrlen_val" -v sig_start="$SIG_START" -v sig_end="$((hdrlen_val-1))" '
      BEGIN { count=0 }
      {
        offset = $1 - 1
        if (offset >= sig_start && offset <= sig_end) next
        region = (offset < hdr) ? "header" : "code"
        printf "  offset 0x%06x (%s): built=0x%02x official=0x%02x\n", offset, region, strtonum("0"$2), strtonum("0"$3)
        count++
        if (count >= 50) { print "  ... (more diffs, showing first 50)"; exit }
      }' || true
  echo ""
  diff_count=$(cmp -l "$WORK_DIR/firmware/built-stripped.bin" "$WORK_DIR/firmware/official-stripped.bin" 2>/dev/null | wc -l | tr -d ' ')
  write_results "not_reproducible" "OneKey ${TYPE} v${VERSION}: Build produced a different firmware (${diff_count} bytes differ outside the signature region).
  Built SHA256:            ${built_hash}
  Official SHA256:         ${official_hash}
  Built stripped SHA256:   ${built_stripped_hash}
  Official stripped SHA256:${official_stripped_hash}"
fi

echo ""
echo "===== Begin Results ====="
echo "firmware:             OneKey ${TYPE}"
echo "version:              ${VERSION}"
echo "builtHash:            ${built_hash}"
echo "officialHash:         ${official_hash}"
echo "builtStrippedHash:    ${built_stripped_hash}"
echo "officialStrippedHash: ${official_stripped_hash}"
echo "repository:           https://github.com/OneKeyHQ/firmware.git"
echo "tag:                  ${TYPE}/v${VERSION}"
echo "commit:               ${SHORT_HASH}"
echo "buildDate:            ${BUILD_DATE}"
echo "verdict:              ${verdict}"
echo ""
if [[ "$verdict" == "reproducible" ]]; then
  echo "✓ The firmware builds reproducibly from source code."
else
  echo "✗ The firmware does not build reproducibly."
fi
echo "===== End Results ====="
echo ""
echo "Verification files: $WORK_DIR/firmware"
echo "Results: $RESULTS_FILE"

cleanup
