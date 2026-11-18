#!/bin/bash
# com.lnflash.flash_build.sh v1.10.1 - WalletScrutiny verification script for Flash Mobile
# Follows WalletScrutiny reproducible verification standards
# Usage: com.lnflash.flash_build.sh --version VERSION [--apk PATH] [--arch ARCH]
#
# Flash Mobile is a Bitcoin/Lightning wallet distributed via GitHub releases.
# Source: https://github.com/lnflash/flash-mobile

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

# Script metadata
SCRIPT_VERSION="v1.10.1"
APP_ID="com.lnflash"
REPO="https://github.com/lnflash/flash-mobile"
BUILD_TYPE="apk"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

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
VERSION=""
APK_PATH=""
ARCH="arm64-v8a"
PROVIDED_APK=false

usage() {
  echo 'NAME
       com.lnflash.flash_build.sh - verify Flash Mobile wallet build

SYNOPSIS
       com.lnflash.flash_build.sh --version VERSION [OPTIONS]
       com.lnflash.flash_build.sh --apk PATH [OPTIONS]

DESCRIPTION
       This script verifies builds of Flash Mobile (com.lnflash.flash) according
       to WalletScrutiny standards.

       Flash Mobile is distributed via GitHub releases (not the Play Store).
       The APK can be downloaded from:
         https://github.com/lnflash/flash-mobile/releases

OPTIONS
       --version VERSION   Version to verify (e.g. "0.4.9-beta")
       --apk PATH          Path to the APK file to verify
       --arch ARCH         (Optional) Architecture (default: arm64-v8a)
       --type TYPE         (Optional) Not used for Flash; ignored if provided

EXAMPLES
       com.lnflash.flash_build.sh --version 0.4.9-beta
       com.lnflash.flash_build.sh --version 0.4.9-beta --apk flash.apk'
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) VERSION="$2"; shift ;;
    --apk) APK_PATH="$2"; PROVIDED_APK=true; shift ;;
    --arch) ARCH="$2"; shift ;;
    --type) shift ;;   # Accepted but ignored
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate: need at least version or APK
if [ -z "$VERSION" ] && [ "$PROVIDED_APK" = false ]; then
  echo "Error: --version is required (or --apk to auto-extract version)"
  echo
  usage
  exit 1
fi

# Validate APK path if provided
if [ "$PROVIDED_APK" = true ] && [ ! -f "$APK_PATH" ]; then
  echo "Error: APK file not found: $APK_PATH"
  exit 1
fi

# Make APK path absolute
if [ "$PROVIDED_APK" = true ] && ! [[ "$APK_PATH" =~ ^/.* ]]; then
  APK_PATH="$PWD/$APK_PATH"
fi

# Image name includes arch/version to support parallel runs
IMAGE_TAG="flash_mobile_builder_${ARCH}_${VERSION//[^a-zA-Z0-9]/_}"
workDir="$(pwd)/flash-mobile-work-${ARCH}-${VERSION//[^a-zA-Z0-9]/_}"

# ─────────────────────────────────────────────────────────────
# Helper: run apktool inside the walletscrutiny container
# ─────────────────────────────────────────────────────────────
wsContainer="docker.io/walletscrutiny/android:5"

containerApktool() {
  local targetFolder=$1
  local app=$2
  local targetFolderParent
  targetFolderParent=$(dirname "$targetFolder")
  local targetFolderBase
  targetFolderBase=$(basename "$targetFolder")
  local appFolder
  appFolder=$(dirname "$app")
  local appFile
  appFile=$(basename "$app")

  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  echo "Running apktool..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume "$targetFolderParent":/tfp \
    --volume "$appFolder":/af:ro \
    $wsContainer \
    sh -c "apktool d -f -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""; then
    echo -e "${RED}apktool failed${NC}"
    return 1
  fi
}

getSigner() {
  local DIR
  DIR=$(dirname "$1")
  local BASE
  BASE=$(basename "$1")
  $CONTAINER_CMD run \
    --rm \
    --volume "$DIR":/mnt:ro \
    --workdir /mnt \
    $wsContainer \
    apksigner verify --print-certs "$BASE" 2>/dev/null \
      | grep "Signer #1 certificate SHA-256" \
      | awk '{print $6}' || echo "unsigned"
}

write_results() {
  local status=$1
  local match=$2
  local downloaded_hash=$3
  local built_hash=$4
  local filename=$5

  cat > "$RESULTS_FILE" << EOF
date: $(date -u +"%Y-%m-%dT%H:%M:%S+0000")
script_version: ${SCRIPT_VERSION}
build_type: ${BUILD_TYPE}
results:
  - architecture: ${ARCH}
    files:
      - filename: ${filename}
        status: ${status}
        match: ${match}
        hash:
          downloaded: ${downloaded_hash}
          built: ${built_hash}
EOF
  echo -e "${GREEN}Results written to: $RESULTS_FILE${NC}"
}

# ─────────────────────────────────────────────────────────────
# Step 1 – Download the official APK from GitHub releases
# ─────────────────────────────────────────────────────────────
download_apk() {
  local tag="v${VERSION}-beta"
  # Flash Mobile releases APKs from GitHub. The naming observed in the repo
  # follows the pattern: flash-mobile-release.apk  (single universal APK)
  # If that fails we also try the arch-split variant.
  local base_url="${REPO}/releases/download/${tag}"

  local candidates=(
    "flash-release.apk"
    "flash-mobile-release.apk"
    "app-release.apk"
    "LNFlash-${VERSION}.apk"
  )

  echo "Downloading official APK from GitHub releases (tag: ${tag})..."
  mkdir -p "$workDir"

  for fname in "${candidates[@]}"; do
    local url="${base_url}/${fname}"
    echo "  Trying: $url"
    if wget -q --spider "$url" 2>/dev/null; then
      wget -q -O "$workDir/official.apk" "$url"
      echo -e "${GREEN}Downloaded: $fname${NC}"
      OFFICIAL_APK_NAME="$fname"
      return 0
    fi
  done

  echo -e "${RED}Could not find APK in GitHub release ${tag}.${NC}"
  echo "Please download it manually from:"
  echo "  ${REPO}/releases/tag/${tag}"
  echo "and re-run with: --apk /path/to/downloaded.apk --version ${VERSION}"
  write_results "ftbfs" "false" "" "" "flash-release.apk"
  exit 1
}

# ─────────────────────────────────────────────────────────────
# Step 2 – Extract metadata from the APK
# ─────────────────────────────────────────────────────────────
extract_metadata() {
  local apk="$1"
  local tmpDir="/tmp/flash_apktool_$$"
  rm -rf "$tmpDir"

  containerApktool "$tmpDir" "$apk" || exit 1

  appId=$(cat "$tmpDir/AndroidManifest.xml" | head -n 1 | sed 's/.*package=\"//g' | sed 's/\".*//g')
  versionName=$(cat "$tmpDir/apktool.yml" | grep versionName | sed 's/.*\: //g' | sed "s/'//g")
  versionCode=$(cat "$tmpDir/apktool.yml" | grep versionCode | sed 's/.*\: //g' | sed "s/'//g")

  rm -rf "$tmpDir"

  if [ -z "$appId" ]; then
    echo "Error: could not determine appId from APK"
    exit 1
  fi

  echo "App ID:       $appId"
  echo "Version name: $versionName"
  echo "Version code: $versionCode"
}

# ─────────────────────────────────────────────────────────────
# Step 3 – Build from source inside a container
# ─────────────────────────────────────────────────────────────
build_apk() {
  local tag="v${VERSION}-beta"

  echo "Cloning ${REPO} at tag ${tag}..."
  cd "$workDir"
  rm -rf source
  if ! git clone --quiet --branch "$tag" --depth 1 "$REPO" source; then
    echo -e "${RED}Failed to clone repository at tag $tag${NC}"
    write_results "notag" "false" "" "" "flash-release.apk"
    exit 1
  fi

  commit=$(git -C source log -n 1 --pretty=format:%H)
  echo "Commit: $commit"

  # Build a self-contained Docker image with Node 18, Java 17, Android SDK
  # Uses Yarn 1 classic to match the project's yarn.lock format
  echo "Building Docker image (${IMAGE_TAG})..."
  cat > "$workDir/Dockerfile.flash" << 'DOCKERFILE_END'
FROM node:20-bullseye

ARG DEBIAN_FRONTEND=noninteractive

# Install Java 17, Android SDK dependencies, and build tools
RUN apt-get update && apt-get install -y \
    openjdk-17-jdk-headless \
    wget \
    unzip \
    git \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Set JAVA_HOME
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# Install Android SDK command-line tools
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools

RUN mkdir -p $ANDROID_SDK_ROOT/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
        -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-extracted && \
    mv /tmp/cmdline-tools-extracted/cmdline-tools $ANDROID_SDK_ROOT/cmdline-tools/latest && \
    rm /tmp/cmdline-tools.zip

# Accept licenses and install required SDK components
RUN yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"

# Use Yarn 1 classic - matches the project yarn.lock format
# Disable corepack so it does not intercept and upgrade to Yarn 4
RUN corepack disable && npm install -g yarn@1.22.22

WORKDIR /app
DOCKERFILE_END

  if ! $CONTAINER_CMD build \
    -t "$IMAGE_TAG" \
    -f "$workDir/Dockerfile.flash" \
    "$workDir"; then
    echo -e "${RED}Docker image build failed!${NC}"
    write_results "ftbfs" "false" "" "" "flash-release.apk"
    exit 1
  fi

  # Write the in-container build script to a file to avoid quoting issues with bash -c
  cat > "$workDir/container_build.sh" << 'CONTAINER_SCRIPT_END'
#!/bin/bash
set -e

echo "=== Yarn version ==="
yarn --version

echo "=== Installing JS dependencies ==="
yarn install --ignore-scripts --ignore-engines --network-timeout 300000

echo "=== Generating native code ==="
if [ -f src/scripts/write-version.js ]; then
  node src/scripts/write-version.js
fi

echo "=== Patching build.gradle to remove signing requirement ==="
APP_BUILD_GRADLE="android/app/build.gradle"
if [ ! -f "$APP_BUILD_GRADLE" ]; then
  echo "ERROR: $APP_BUILD_GRADLE not found"
  ls android/ || true
  exit 1
fi
echo "Patching: $APP_BUILD_GRADLE"
sed -i '/signingConfig signingConfigs/d' "$APP_BUILD_GRADLE"
sed -i 's|storeFile file.*|// storeFile removed for reproducibility check|g' "$APP_BUILD_GRADLE"

echo "=== Building release APK (unsigned) ==="
cd android
chmod +x gradlew
./gradlew assembleRelease --no-daemon -x lint -x test

echo "=== Build complete ==="
find . -name "*.apk" -type f | head -20
CONTAINER_SCRIPT_END

  chmod +x "$workDir/container_build.sh"

  echo "Building Flash Mobile APK inside container..."
  if ! $CONTAINER_CMD run \
    --rm \
    --volume "$workDir/source":/app \
    --volume "$workDir/container_build.sh":/container_build.sh:ro \
    "$IMAGE_TAG" \
    bash /container_build.sh; then
    echo -e "${RED}APK build failed inside container!${NC}"
    write_results "ftbfs" "false" "" "" "flash-release.apk"
    exit 1
  fi

  echo -e "${GREEN}Build completed!${NC}"
}

# ─────────────────────────────────────────────────────────────
# Step 4 – Find the built APK
# ─────────────────────────────────────────────────────────────
find_built_apk() {
  local candidates=(
    "$workDir/source/android/app/build/outputs/apk/release/app-release.apk"
    "$workDir/source/android/app/build/outputs/apk/release/app-release-unsigned.apk"
    "$workDir/source/android/app/build/outputs/apk/prodRelease/app-prodRelease.apk"
  )

  for path in "${candidates[@]}"; do
    if [ -f "$path" ]; then
      BUILT_APK="$path"
      echo "Built APK found: $BUILT_APK"
      return 0
    fi
  done

  # Fallback: find any release APK
  BUILT_APK=$(find "$workDir/source/android" -name "*.apk" -path "*/release/*" | head -1)
  if [ -n "$BUILT_APK" ]; then
    echo "Built APK found (fallback): $BUILT_APK"
    return 0
  fi

  echo -e "${RED}No built APK found!${NC}"
  return 1
}

# ─────────────────────────────────────────────────────────────
# Step 5 – Compare APKs
# ─────────────────────────────────────────────────────────────
compare_apks() {
  local official_apk="$1"
  local built_apk="$2"

  local official_hash
  official_hash=$(sha256sum "$official_apk" | awk '{print $1}')
  local built_hash
  built_hash=$(sha256sum "$built_apk" | awk '{print $1}')

  echo "Official APK hash: $official_hash"
  echo "Built APK hash:    $built_hash"

  local fromOfficialDir="/tmp/flash_official_${versionCode}_$$"
  local fromBuiltDir="/tmp/flash_built_${versionCode}_$$"
  rm -rf "$fromOfficialDir" "$fromBuiltDir"

  unzip -d "$fromOfficialDir" -qq "$official_apk" || true
  unzip -d "$fromBuiltDir"   -qq "$built_apk"    || true

  local diffResult
  diffResult=$(diff --brief --recursive "$fromOfficialDir" "$fromBuiltDir" 2>/dev/null || true)

  # Strip META-INF (signing), png, and xml files - these are expected to differ
  local filteredDiff
  filteredDiff=$(echo "$diffResult" | grep -vE "(META-INF|\.png|\.xml|^$)" || true)

  # Count png/xml diffs separately for reporting
  local totalDiff noisyDiff diffCount
  totalDiff=$(echo "$diffResult" | grep -vE "(META-INF|^$)" | grep -c "." || echo "0")
  noisyDiff=$(echo "$diffResult" | grep -vE "(META-INF|^$)" | grep -cE "(\.png|\.xml)" || echo "0")

  if [ -n "$filteredDiff" ]; then
    diffCount=$(echo "$filteredDiff" | grep -c "." || echo "0")
  else
    diffCount=0
  fi

  local status match
  if [ "$diffCount" -eq 0 ]; then
    status="reproducible"
    match="true"
  else
    status="not_reproducible"
    match="false"
  fi

  local filename
  filename=$(basename "$official_apk")

  echo ""
  echo "===== Verification Results ====="
  echo "App ID:          $appId"
  echo "Version:         $versionName (code: $versionCode)"
  echo "Signer:          $signer"
  echo "Commit:          $commit"
  echo "Architecture:    $ARCH"
  echo "Status:          $status"
  echo "Match:           $match"
  echo ""
  echo "Official hash:   $official_hash"
  echo "Built hash:      $built_hash"
  echo ""
  echo "Total differences (excluding META-INF signing): $totalDiff"
  echo "  - png/xml files (excluded from verdict):      $noisyDiff"
  echo "  - other files (used for verdict):             $diffCount"
  if [ -n "$filteredDiff" ]; then
    echo ""
    echo "Significant differences:"
    echo "$filteredDiff"
  fi
  echo "============================="

  if [ "$match" = "true" ]; then
    echo -e "${GREEN}✓ Build is reproducible!${NC}"
  else
    echo -e "${RED}✗ Build has unexpected differences${NC}"
  fi

  write_results "$status" "$match" "$official_hash" "$built_hash" "$filename"

  rm -rf "$fromOfficialDir" "$fromBuiltDir"
}

cleanup() {
  echo "Cleaning up container image..."
  $CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true
  $CONTAINER_CMD image prune -f 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────
echo "Flash Mobile Verification"
echo "Version: ${VERSION:-<from APK>}"
echo "Arch:    $ARCH"
echo ""

mkdir -p "$workDir"

# Obtain the official APK
if [ "$PROVIDED_APK" = true ]; then
  cp "$APK_PATH" "$workDir/official.apk"
  OFFICIAL_APK_NAME=$(basename "$APK_PATH")
  echo "Using provided APK: $APK_PATH"
else
  download_apk
fi

# Extract metadata from official APK
echo ""
echo "Extracting APK metadata..."
signer=$(getSigner "$workDir/official.apk")
extract_metadata "$workDir/official.apk"

# If version not yet set (APK-only flow), extract it from the APK.
# NOTE: versionName from the APK (e.g. "0.4.9") may differ from the git tag
# suffix (e.g. "0.4.9-beta"). When --version is explicitly provided the user
# must pass the full version string that matches the git tag (minus the "v"
# prefix), e.g. "0.4.9-beta". That value is used for cloning; versionName is
# only used for display and metadata.
if [ -z "$VERSION" ]; then
  VERSION="$versionName"
  echo "Extracted version from APK: $VERSION"
  echo "NOTE: if the git tag differs (e.g. v${VERSION}-beta), re-run with:"
  echo "      --version ${VERSION}-beta --apk <path-to-apk>"
  # Re-set paths that depend on version
  IMAGE_TAG="flash_mobile_builder_${ARCH}_${VERSION//[^a-zA-Z0-9]/_}"
  workDir="$(pwd)/flash-mobile-work-${ARCH}-${VERSION//[^a-zA-Z0-9]/_}"
  mkdir -p "$workDir"
  cp "$APK_PATH" "$workDir/official.apk"
fi

# Validate we have the right app
if [ -n "$appId" ] && [ "$appId" != "$APP_ID" ]; then
  echo -e "${YELLOW}Warning: expected app ID $APP_ID, got $appId${NC}"
  echo "Continuing anyway — update APP_ID in the script if the app ID has changed."
fi

# Build
echo ""
echo "Starting build process. This may take 20-40 minutes..."
build_apk

# Locate built APK
if ! find_built_apk; then
  write_results "ftbfs" "false" "" "" "flash-release.apk"
  cleanup
  exit 1
fi

# Compare
echo ""
echo "Comparing APKs..."
compare_apks "$workDir/official.apk" "$BUILT_APK"

cleanup

echo ""
echo "Verification complete. Results: $RESULTS_FILE"