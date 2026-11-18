#!/bin/bash
# verify_portal.sh - Portal Hardware Wallet firmware verification
# Usage: verify_portal.sh --version <version> [--cleanup]

set -e

# Display disclaimer
echo -e "\033[1;33m"
echo "=============================================================================="
echo "                               DISCLAIMER"
echo "=============================================================================="
echo "This script is provided as-is without warranty. Use at your own risk."
echo "=============================================================================="
echo -e "\033[0m"
sleep 1

# Configuration
shouldCleanup=false
workDir="/tmp/portal-verification"
REPO_URL="https://github.com/TwentyTwoHW/portal-software"
TARGET_ARCH="thumbv7em-none-eabihf"

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
else
    echo "Error: Neither docker nor podman found."
    exit 1
fi

# Colors
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  echo 'Usage: verify_portal.sh --version <version> [--cleanup]
  
  --version   Firmware version/tag (e.g., "fw-v0.3.4")
  --cleanup   Remove temporary files after verification'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) version="$2"; shift ;;
    --cleanup) shouldCleanup=true ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ -z "$version" ]; then
  echo "Error: --version is required"
  usage
  exit 1
fi

echo ""
echo "Portal firmware verification - Version: $version"
echo ""

# Setup environment
prepare() {
  rm -rf "$workDir" || true
  mkdir -p "$workDir"
  cd "$workDir"
  
  echo "Downloading official firmware..."
  releaseUrl="https://api.github.com/repos/TwentyTwoHW/portal-software/releases/tags/${version}"
  firmwareBinUrl=$(curl -s "$releaseUrl" | jq -r '.assets[] | select(.name | test("firmware.*\\.bin$")) | .browser_download_url' | head -1)
  
  if [ -z "$firmwareBinUrl" ] || [ "$firmwareBinUrl" == "null" ]; then
    echo -e "${RED}Error: Could not find firmware binary for ${version}${NC}"
    exit 1
  fi
  
  wget --quiet --output-document "portal_${version}.bin" "$firmwareBinUrl"
  echo -e "${GREEN}Downloaded official firmware${NC}"
  
  echo "Cloning source code..."
  git clone --depth 1 --branch "$version" --recurse-submodules "$REPO_URL" portal_source
  echo -e "${GREEN}Source code cloned${NC}"
}

# Create Docker build environment
create_dockerfile() {
  cat > setup-toolchain.sh << 'SETUP_EOF'
#!/bin/bash
set -e
cd /workspace

# Detect Rust toolchain from flake.nix
TOOLCHAIN="nightly-2024-01-31"
if [ -f "flake.nix" ]; then
  NIGHTLY_DATE=$(grep -oP 'nightly\.\"\K[0-9]{4}-[0-9]{2}-[0-9]{2}' flake.nix | head -1)
  if [ -n "$NIGHTLY_DATE" ]; then
    TOOLCHAIN="nightly-$NIGHTLY_DATE"
  fi
fi

echo "Installing Rust toolchain: $TOOLCHAIN"
rustup toolchain install "$TOOLCHAIN" --profile minimal
rustup default "$TOOLCHAIN"
rustup target add thumbv7em-none-eabihf
rustup component add rust-src

echo "Toolchain ready: $(rustc --version)"
SETUP_EOF

  chmod +x setup-toolchain.sh

  cat > portal_build.dockerfile << 'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential curl wget git cmake pkg-config \
    libssl-dev libusb-1.0-0-dev libudev-dev \
    jq python3 binutils-arm-none-eabi \
    && rm -rf /var/lib/apt/lists/*

# Install LLVM 18 (clang-18 and lld required by Portal)
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc \
    && echo "deb http://apt.llvm.org/jammy/ llvm-toolchain-jammy-18 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y clang-18 lld-18 llvm-18 \
    && ln -sf /usr/bin/clang-18 /usr/bin/clang \
    && ln -sf /usr/bin/lld-18 /usr/bin/lld \
    && rm -rf /var/lib/apt/lists/*

# Install ARM GCC toolchain
RUN cd /tmp \
    && wget -q https://developer.arm.com/-/media/Files/downloads/gnu-rm/10.3-2021.10/gcc-arm-none-eabi-10.3-2021.10-x86_64-linux.tar.bz2 \
    && tar xf gcc-arm-none-eabi-10.3-2021.10-x86_64-linux.tar.bz2 -C /opt/ \
    && rm gcc-arm-none-eabi-10.3-2021.10-x86_64-linux.tar.bz2

ENV PATH="/opt/gcc-arm-none-eabi-10.3-2021.10/bin:${PATH}"

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /workspace
COPY setup-toolchain.sh /usr/local/bin/setup-toolchain.sh
RUN chmod +x /usr/local/bin/setup-toolchain.sh

ENTRYPOINT ["/bin/bash", "-c"]
EOF
}

# Build firmware
build_firmware() {
  echo ""
  echo "=== Building Firmware ==="
  
  create_dockerfile
  
  echo "Building Docker image..."
  DOCKER_BUILDKIT=1 $CONTAINER_CMD build -f portal_build.dockerfile -t portal_build . > /dev/null
  echo -e "${GREEN}Docker image ready${NC}"
  
  echo "Compiling firmware..."
  $CONTAINER_CMD run --rm \
    --mount type=bind,source=${PWD}/portal_source,target=/workspace \
    portal_build "
      /usr/local/bin/setup-toolchain.sh
      
      cd firmware
      
      # Set Portal-specific environment variables
      export CC_thumbv7em_none_eabihf=\"clang-18\"
      export CFLAGS_thumbv7em_none_eabihf=\"-flto -fno-data-sections -fno-function-sections -fno-PIC -fno-stack-protector --target=thumbv7em-none-eabihf -mcpu=cortex-m4 -mthumb\"
      
      # Build firmware
      if cargo build --release --target thumbv7em-none-eabihf 2>&1; then
        echo 'Build succeeded'
      else
        echo 'Build failed'
        exit 1
      fi
    " || return 1
  
  # Extract and convert firmware
  cd portal_source
  builtFirmware="firmware/target/thumbv7em-none-eabihf/release/firmware"
  
  if [ ! -f "$builtFirmware" ]; then
    echo -e "${RED}Firmware binary not found${NC}"
    cd ..
    return 1
  fi
  
  echo "Converting ELF to binary..."
  $CONTAINER_CMD run --rm \
    --mount type=bind,source=${PWD},target=/workspace \
    portal_build "
      arm-none-eabi-strip --strip-debug $builtFirmware -o ${builtFirmware}.stripped
      arm-none-eabi-objcopy -O binary ${builtFirmware}.stripped ${builtFirmware}.bin
    "
  
  cp "${builtFirmware}.bin" "../portal_${version}.built.bin"
  cd ..
  echo -e "${GREEN}Firmware built successfully${NC}"
}

# Compare firmware binaries
compare_firmware() {
  echo ""
  echo "=== Comparing Firmware ==="
  
  originalFw="portal_${version}.bin"
  builtFw="portal_${version}.built.bin"
  
  if [ ! -f "$builtFw" ]; then
    echo -e "${RED}Built firmware not available${NC}"
    return 1
  fi
  
  originalHash=$(sha256sum "$originalFw" | awk '{print $1}')
  builtHash=$(sha256sum "$builtFw" | awk '{print $1}')
  originalSize=$(stat -c%s "$originalFw")
  builtSize=$(stat -c%s "$builtFw")
  
  echo ""
  echo "Official firmware:"
  echo "  SHA256: $originalHash"
  echo "  Size:   $originalSize bytes"
  echo ""
  echo "Built firmware:"
  echo "  SHA256: $builtHash"
  echo "  Size:   $builtSize bytes"
  echo ""
  
  if [[ "$originalHash" == "$builtHash" ]]; then
    verdict="reproducible"
    echo -e "${GREEN}✓ REPRODUCIBLE${NC}"
    echo "Firmware binaries match exactly!"
    exit_code=0
  else
    verdict="not_reproducible"
    sizeDiff=$((builtSize - originalSize))
    echo -e "${YELLOW}✗ NOT REPRODUCIBLE${NC}"
    echo "Size difference: $sizeDiff bytes"
    echo ""
    echo "Possible causes:"
    echo "  - Non-deterministic compilation"
    echo "  - Different code layout/optimization decisions"
    echo "  - Build environment variations"
    exit_code=1
  fi
}

# Display results
show_results() {
  echo ""
  echo "=============================================="
  echo "===== Verification Results ====="
  echo "=============================================="
  echo "Firmware:    Portal Hardware Wallet"
  echo "Version:     $version"
  echo "Verdict:     $verdict"
  echo "Repository:  $REPO_URL"
  echo "Target:      $TARGET_ARCH"
  echo "=============================================="
  echo ""
  
  if [[ "$verdict" == "reproducible" ]]; then
    echo -e "${GREEN}✓ SUCCESS: Firmware is reproducible${NC}"
  else
    echo -e "${YELLOW}⚠ FAILED: Firmware is not reproducible${NC}"
    echo "The compiled binary does not match the official release."
  fi
  
  if [ "$shouldCleanup" = false ]; then
    echo ""
    echo "Files kept at: $workDir"
  fi
}

# Cleanup
cleanup() {
  echo "Cleaning up..."
  cd /
  rm -rf "$workDir"
  $CONTAINER_CMD rmi portal_build -f 2>/dev/null || true
}

# Main execution
prepare
if build_firmware; then
  compare_firmware
else
  verdict="build_failed"
  exit_code=1
fi

show_results

if [ "$shouldCleanup" = true ]; then
  cleanup
fi

exit ${exit_code:-1}