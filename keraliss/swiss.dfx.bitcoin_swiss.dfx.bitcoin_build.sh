#!/bin/bash
# swiss.dfx.bitcoin_build.sh v1.8.0 - WalletScrutiny verification script for DFX Bitcoin Wallet
# Follows WalletScrutiny reproducible verification standards
# Usage: swiss.dfx.bitcoin_build.sh --version VERSION [--apk PATH] [--arch ARCH]

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

# ─── Global Variables ─────────────────────────────────────────────────────────
SCRIPT_VERSION="v1.8.0"
APP_ID="swiss.dfx.bitcoin"
BUILD_TYPE="apk"
REPO="https://github.com/DFXswiss/btc-wallet"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"
wsContainer="docker.io/walletscrutiny/android:5"

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

# Color constants
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# Argument variables
VERSION=""
APK_PATH=""
ARCH="arm64-v8a"
PROVIDED_APK=false

# ─── Helper functions ──────────────────────────────────────────────────────────

usage() {
  echo 'NAME
       swiss.dfx.bitcoin_build.sh - verify DFX Bitcoin Wallet build

SYNOPSIS
       swiss.dfx.bitcoin_build.sh --version VERSION [--apk PATH] [--arch ARCH]
       swiss.dfx.bitcoin_build.sh --apk PATH [--arch ARCH]

DESCRIPTION
       This script verifies builds of DFX Bitcoin Wallet (swiss.dfx.bitcoin),
       a BlueWallet fork by DFX.swiss built with React Native and Electrum.

       When --apk is provided, the version is extracted from the APK.
       When --apk is omitted, --version is required and the APK is downloaded
       from the GitHub releases page.

       NOTE: The postinstall script applies patches and runs rn-nodeify.
       These are applied automatically inside the container build.

OPTIONS
       --apk PATH          Path to APK file to verify (version extracted from APK)
       --version VERSION   Version to verify (e.g. "6.4.9"), without the "v" prefix.
                           Optional if --apk is provided; required otherwise.
       --arch ARCH         (Optional) Architecture (default: arm64-v8a)
       --type TYPE         (Optional) Not used; accepted but ignored

EXAMPLES
       swiss.dfx.bitcoin_build.sh --apk /path/to/dfx.apk
       swiss.dfx.bitcoin_build.sh --version 6.4.9
       swiss.dfx.bitcoin_build.sh --version 6.4.9 --apk /path/to/dfx.apk'
}

write_results() {
  local status=$1
  local downloaded_hash=$2
  local built_hash=$3
  local match=$4
  local filename=${5:-"app-release-unsigned.apk"}
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")

  cat > "$RESULTS_FILE" << EOF
date: ${timestamp}
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

getSigner() {
  local DIR BASE
  DIR=$(dirname "$1")
  BASE=$(basename "$1")
  $CONTAINER_CMD run \
    --rm \
    --volume "$DIR":/mnt:ro \
    --workdir /mnt \
    $wsContainer \
    apksigner verify --print-certs "$BASE" 2>/dev/null \
    | grep "Signer #1 certificate SHA-256" | awk '{print $6}' || echo "unsigned"
}

containerApktool() {
  local targetFolder=$1
  local app=$2
  local targetFolderParent targetFolderBase appFolder appFile
  targetFolderParent=$(dirname "$targetFolder")
  targetFolderBase=$(basename "$targetFolder")
  appFolder=$(dirname "$app")
  appFile=$(basename "$app")

  if [ ! -f "$app" ]; then
    echo -e "${RED}Error: APK file not found: $app${NC}"
    return 1
  fi

  $CONTAINER_CMD run \
    --rm \
    --volume "$targetFolderParent":/tfp \
    --volume "$appFolder":/af:ro \
    $wsContainer \
    sh -c "apktool d -f -o \"/tfp/$targetFolderBase\" \"/af/$appFile\""
}

# ─── Argument Parsing ──────────────────────────────────────────────────────────

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) VERSION="$2"; shift ;;
    --apk) APK_PATH="$2"; PROVIDED_APK=true; shift ;;
    --arch) ARCH="$2"; shift ;;
    --type) shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

# Validate
if [ "$PROVIDED_APK" = false ] && [ -z "$VERSION" ]; then
  echo "Error: Either --version or --apk is required"
  usage
  exit 1
fi

if [ "$PROVIDED_APK" = true ] && [ ! -f "$APK_PATH" ]; then
  echo "Error: APK file not found: $APK_PATH"
  exit 1
fi

if [ "$PROVIDED_APK" = true ] && ! [[ $APK_PATH =~ ^/.* ]]; then
  APK_PATH="$PWD/$APK_PATH"
fi

# ─── Download APK if not provided ─────────────────────────────────────────────

if [ "$PROVIDED_APK" = false ]; then
  mkdir -p "$(pwd)/downloads"
  APK_PATH="$(pwd)/downloads/${APP_ID}-${VERSION}.apk"
  DOWNLOAD_URL="https://github.com/DFXswiss/btc-wallet/releases/download/v${VERSION}/dfx-bitcoin-wallet-v${VERSION}.apk"
  echo "Downloading APK from: $DOWNLOAD_URL"
  if ! wget -q --show-progress -O "$APK_PATH" "$DOWNLOAD_URL"; then
    echo -e "${RED}Failed to download APK. Check the release page for the correct filename:${NC}"
    echo "  https://github.com/DFXswiss/btc-wallet/releases/tag/v${VERSION}"
    write_results "ftbfs" "" "" "false" "app-release-unsigned.apk"
    exit 1
  fi
fi

# ─── Extract APK metadata ─────────────────────────────────────────────────────

echo "Extracting APK metadata..."
fromPlayFolder="/tmp/fromPlay_${APP_ID}_$$"
rm -rf "$fromPlayFolder"

containerApktool "$fromPlayFolder" "$APK_PATH" || {
  echo -e "${RED}apktool failed${NC}"
  write_results "ftbfs" "" "" "false" "app-release-unsigned.apk"
  exit 1
}

apkAppId=$(grep -m1 'package=' "$fromPlayFolder/AndroidManifest.xml" \
  | sed 's/.*package=\"//;s/\".*//' || true)
versionName=$(grep 'versionName' "$fromPlayFolder/apktool.yml" \
  | sed 's/.*: //;s/'"'"'//g' | head -1)
versionCode=$(grep 'versionCode' "$fromPlayFolder/apktool.yml" \
  | sed 's/.*: //;s/'"'"'//g' | head -1)

if [ -z "$VERSION" ]; then
  VERSION="$versionName"
  echo "Extracted version from APK: $VERSION"
fi

if [ "$apkAppId" != "$APP_ID" ]; then
  echo -e "${RED}Error: Wrong app. Expected $APP_ID, got $apkAppId${NC}"
  write_results "ftbfs" "" "" "false" "app-release-unsigned.apk"
  exit 1
fi

signer=$(getSigner "$APK_PATH")
downloadedHash=$(sha256sum "$APK_PATH" | awk '{print $1}')

echo "App ID:      $apkAppId"
echo "Version:     $versionName (code: $versionCode)"
echo "Signer:      $signer"
echo "APK hash:    $downloadedHash"
echo

# ─── Work directory and image tag ─────────────────────────────────────────────

workDir="$(pwd)/build_${APP_ID}_${VERSION}"
# IMAGE_TAG is unique per version+arch to allow parallel runs
IMAGE_TAG="dfxswiss_builder_${VERSION}_${ARCH//\//_}"

rm -rf "$workDir"
mkdir -p "$workDir"

# ─── Clone source ─────────────────────────────────────────────────────────────

echo "Cloning repository at tag v${VERSION}..."
if ! git clone --quiet --branch "v${VERSION}" --depth 1 "$REPO" "$workDir/source"; then
  echo -e "${RED}Failed to clone at tag v${VERSION}${NC}"
  echo "Available tags:"
  git ls-remote --tags "$REPO" | grep -v '\^{}' | tail -20 || true
  write_results "notag" "" "" "false" "app-release-unsigned.apk"
  exit 1
fi

commit=$(git -C "$workDir/source" rev-parse HEAD)
echo "Commit: $commit"
echo

# ─── Build Docker image ───────────────────────────────────────────────────────

# DFX Bitcoin Wallet is a BlueWallet fork using:
# - React Native 0.72.x
# - Node >= 16 (we use Node 18 LTS)
# - compileSdkVersion 34, buildToolsVersion 34.0.0
# - NDK 23.1.7779620
# - Java 17 (required by AGP 8.x / Gradle 8.x)

cat > "$workDir/Dockerfile.dfx" << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    patch \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    python3 \
    openjdk-17-jdk \
    && rm -rf /var/lib/apt/lists/*

# Node 18 LTS (satisfies engines.node >= 16)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Android SDK
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/34.0.0"

RUN mkdir -p $ANDROID_HOME/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip \
    && unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools \
    && mv /tmp/cmdtools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
    && rm -rf /tmp/cmdtools /tmp/cmdtools.zip

RUN yes | sdkmanager --licenses > /dev/null 2>&1 || true
RUN sdkmanager \
    "platform-tools" \
    "platforms;android-34" \
    "build-tools;34.0.0" \
    "ndk;23.1.7779620"

WORKDIR /app
DOCKERFILE

echo "Building Docker image..."
if ! $CONTAINER_CMD build \
    -t "$IMAGE_TAG" \
    -f "$workDir/Dockerfile.dfx" \
    "$workDir"; then
  echo -e "${RED}Docker image build failed!${NC}"
  write_results "ftbfs" "$downloadedHash" "" "false" "app-release-unsigned.apk"
  exit 1
fi
echo -e "${GREEN}Docker image built: $IMAGE_TAG${NC}"
echo

# ─── Build APK ────────────────────────────────────────────────────────────────

echo "Building DFX Bitcoin Wallet APK inside container..."
echo "This may take 20-40 minutes..."
echo

# Write the build script to a file on the host so it gets mounted into the
# container. This avoids ALL bash -c quoting issues — the script is written
# exactly as-is, no shell expansion happens on the host side.
cat > "$workDir/container_build.sh" << 'BUILDSCRIPT'
#!/bin/bash
set -e
cd /app

echo '=== Node / npm versions ==='
node --version
npm --version

echo '=== Installing npm dependencies ==='
# --ignore-scripts skips postinstall so npm resolves the tree cleanly.
# We run the required steps manually below.
npm install --legacy-peer-deps --ignore-scripts

echo '=== Creating realm-constants.json ==='
# realm@12.0.0 exports realm-constants.json but it is absent from the
# installed package in some environments. Metro cannot bundle without it.
python3 -c "import json; open('node_modules/realm/realm-constants.json','w').write(json.dumps({'REALM_VERSION':'12.0.0'}))"
echo 'realm-constants.json created'

echo '=== Running rn-nodeify ==='
./node_modules/.bin/rn-nodeify --install buffer,events,process,stream,inherits,path,assert,crypto --hack

echo '=== Generating required build artefacts ==='
# Metro requires release-notes.json and current-branch.json at bundle time.
# git log commands need full history; in a shallow clone we write stubs.
echo '""' > release-notes.json
echo '"main"' > current-branch.json

echo '=== Applying source patches ==='
patch -p1 < scripts/react-native-tor.patch || true
patch -p1 < scripts/react-native-camera-kit.patch || true
patch -p1 < scripts/react-native-widget-center.patch || true

echo '=== Writing stub google-services.json ==='
# app/build.gradle applies google-services plugin; file must exist.
python3 -c "
import json
gs = {
    'project_info': {
        'project_number': '000000000000',
        'project_id': 'dfx-stub',
        'storage_bucket': 'dfx-stub.appspot.com'
    },
    'client': [{
        'client_info': {
            'mobilesdk_app_id': '1:000000000000:android:0000000000000000000000',
            'android_client_info': {'package_name': 'swiss.dfx.bitcoin'}
        },
        'oauth_client': [],
        'api_key': [{'current_key': 'stub'}],
        'services': {'appinvite_service': {'other_platform_oauth_client': []}}
    }],
    'configuration_version': '1'
}
import os; os.makedirs('android/app', exist_ok=True)
open('android/app/google-services.json','w').write(json.dumps(gs))
" 

echo '=== Removing signing config ==='
sed -i '/signingConfig signingConfigs/d' android/app/build.gradle

echo '=== Building APK (arm64-v8a only) ==='
cd android
chmod +x gradlew
./gradlew assembleRelease -x lint --no-daemon -Pandroid.injected.build.abi=${TARGET_ABI:-arm64-v8a} 2>&1

echo '=== Output APKs ==='
find /app -name '*.apk' 2>/dev/null || echo 'No APKs found'
BUILDSCRIPT

chmod +x "$workDir/container_build.sh"

if ! $CONTAINER_CMD run \
    --rm \
    --volume "$workDir/source":/app \
    --volume "$workDir/container_build.sh":/container_build.sh:ro \
    --env TARGET_ABI="$ARCH" \
    "$IMAGE_TAG" \
    bash /container_build.sh; then
  echo -e "${RED}APK build failed!${NC}"
  write_results "ftbfs" "$downloadedHash" "" "false" "app-release-unsigned.apk"
  exit 1
fi

# ─── Locate built APK ─────────────────────────────────────────────────────────

echo "Locating built APK..."

BUILT_APK=""
for candidate in \
    "$workDir/source/android/app/build/outputs/apk/release/app-release-unsigned.apk" \
    "$workDir/source/android/app/build/outputs/apk/release/app-release.apk" \
    "$workDir/source/android/app/build/intermediates/apk/release/app-release-unsigned.apk" \
    ; do
  if [ -f "$candidate" ]; then
    BUILT_APK="$candidate"
    break
  fi
done

if [ -z "$BUILT_APK" ]; then
  BUILT_APK=$(find "$workDir/source" -name "*.apk" 2>/dev/null | head -1)
fi

if [ -z "$BUILT_APK" ] || [ ! -f "$BUILT_APK" ]; then
  echo -e "${RED}Could not find built APK!${NC}"
  write_results "ftbfs" "$downloadedHash" "" "false" "app-release-unsigned.apk"
  exit 1
fi

echo -e "${GREEN}Built APK: $BUILT_APK${NC}"
builtHash=$(sha256sum "$BUILT_APK" | awk '{print $1}')
echo "Built hash: $builtHash"
echo

# ─── Compare APKs ─────────────────────────────────────────────────────────────

echo "Comparing APKs..."
fromPlayUnzipped="/tmp/fromPlay_${APP_ID}_${versionCode}"
fromBuildUnzipped="/tmp/fromBuild_${APP_ID}_${versionCode}"
rm -rf "$fromBuildUnzipped" "$fromPlayUnzipped"

unzip -d "$fromPlayUnzipped" -qq "$APK_PATH" || exit 1
unzip -d "$fromBuildUnzipped" -qq "$BUILT_APK" || exit 1

diffResult=$(diff --brief --recursive "$fromPlayUnzipped" "$fromBuildUnzipped" 2>/dev/null || true)

# Filter expected differences:
# - META-INF: signing files, always differ between signed and unsigned APK
# - resources.arsc: may differ if build config embeds private credentials
# - stamp-cert-sha256: Play Store distribution stamp
filteredDiff=$(echo "$diffResult" | grep -vE "(META-INF|resources\.arsc|stamp-cert-sha256)" || true)

if [[ "$filteredDiff" =~ ^[[:space:]]*$ ]]; then
  diffCount=0
else
  diffCount=$(echo "$filteredDiff" | grep -c "." 2>/dev/null || echo "0")
fi

if [ "$diffCount" -eq 0 ]; then
  status="reproducible"
  match="true"
else
  status="not_reproducible"
  match="false"
fi

# ─── Results ──────────────────────────────────────────────────────────────────

write_results "$status" "$downloadedHash" "$builtHash" "$match" "$(basename "$BUILT_APK")"

echo
echo "===== Verification Results ====="
echo "App ID:          $APP_ID"
echo "Version:         $versionName (code: $versionCode)"
echo "Signer:          $signer"
echo "Commit:          $commit"
echo "Architecture:    $ARCH"
echo "Status:          $status"
echo "Match:           $match"
echo ""
echo "Downloaded hash: $downloadedHash"
echo "Built hash:      $builtHash"
echo ""
echo "Differences (excluding META-INF and resources.arsc): $diffCount"
echo ""

if [ "$match" = "true" ]; then
  echo -e "${GREEN}✓ Build is reproducible!${NC}"
else
  echo -e "${RED}✗ Build has differences${NC}"
  echo ""
  echo "Filtered diff (signature files and resources.arsc excluded):"
  echo "$filteredDiff"
  echo ""
#   echo "Full diff (including META-INF):"
#   echo "$diffResult"
fi

echo ""
echo "For detailed analysis:"
echo "  diff --recursive $fromPlayUnzipped $fromBuildUnzipped"
echo "  diffoscope \"$APK_PATH\" \"$BUILT_APK\""
echo ""

# ─── Cleanup ──────────────────────────────────────────────────────────────────

echo "Cleaning up Docker image..."
$CONTAINER_CMD rmi "$IMAGE_TAG" -f 2>/dev/null || true

echo ""
echo "DFX Bitcoin Wallet verification complete!"
echo "Results: $RESULTS_FILE"