#!/bin/bash
# im.adamant.adamant_build.sh v2.1.0 - Verification script for ADAMANT Messenger Android
# Follows WalletScrutiny reproducible verification standards
# Usage: im.adamant.adamant_build.sh --apk APK_PATH

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
SCRIPT_VERSION="v2.1.0"
BUILD_TYPE="apk"
workDir="$(pwd)/adamant-work"
RESULTS_FILE="$(pwd)/COMPARISON_RESULTS.yaml"

# Detect container runtime
if command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo "Using Docker for containerization"
elif command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo "Using Podman for containerization"
else
    echo "Error: Neither docker nor podman found. Please install one."
    exit 1
fi

# Color constants
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

# ADAMANT constants
repo="https://github.com/Adamant-im/adamant-im.git"
appId="im.adamant.adamant"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --apk) apkPath="$2"; shift ;;
    --help) echo "Usage: $0 --apk APK_PATH"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

if [ -z "$apkPath" ] || [ ! -f "$apkPath" ]; then
  echo -e "${RED}Error: Valid --apk path required${NC}"
  exit 1
fi

echo "Verifying ADAMANT Messenger Android APK"
echo "APK: $apkPath"
echo

# Prepare workspace
rm -rf "$workDir" || true
mkdir -p "$workDir"
cd "$workDir"

cp "$apkPath" original.apk

# Extract version
if command -v aapt &> /dev/null; then
  versionInfo=$(aapt dump badging original.apk 2>/dev/null | grep "package:")
  versionName=$(echo "$versionInfo" | grep -oP "versionName='[^']*'" | cut -d"'" -f2)
  versionCode=$(echo "$versionInfo" | grep -oP "versionCode='[^']*'" | cut -d"'" -f2)
  echo "Version Name: $versionName"
  echo "Version Code: $versionCode"
else
  echo -e "${YELLOW}Warning: aapt not found, version extraction skipped${NC}"
  versionName="unknown"
  versionCode="unknown"
fi

# Clone repo
git clone --recursive "$repo" adamant-im
cd adamant-im

# Checkout matching tag
if [ "$versionName" != "unknown" ]; then
  if git tag | grep -q "v${versionName}"; then
    git checkout "v${versionName}"
  elif git tag | grep -q "${versionName}"; then
    git checkout "${versionName}"
  else
    echo -e "${YELLOW}No tag for $versionName, using main${NC}"
    git checkout main
  fi
else
  git checkout main
fi

commit=$(git log -1 --format="%H")
echo -e "${GREEN}Repository ready at commit $commit${NC}"

# Build in Docker
echo "Building APK in container (this may take 20-40 minutes)..."

cat > Dockerfile.adamant << 'EOF'
FROM node:20-slim

RUN apt-get update && apt-get install -y \
    git openjdk-17-jdk android-sdk wget unzip \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/usr/lib/android-sdk
ENV PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

RUN mkdir -p $ANDROID_HOME/cmdline-tools \
    && cd $ANDROID_HOME/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-9477386_latest.zip \
    && unzip -q commandlinetools-linux-9477386_latest.zip \
    && mv cmdline-tools latest \
    && rm commandlinetools-linux-9477386_latest.zip

RUN yes | sdkmanager --licenses || true
RUN sdkmanager "platform-tools" "platforms;android-33" "build-tools;33.0.0"

WORKDIR /app
COPY . /app

RUN npm ci --include=dev
RUN npm install dotenv
RUN cp capacitor.env.example capacitor.env || touch capacitor.env

CMD ["sh", "-c", "npm run android:build"]
EOF

$CONTAINER_CMD build -t adamant-build -f Dockerfile.adamant .
$CONTAINER_CMD run --rm -v "$(pwd)":/app -w /app adamant-build

echo -e "${GREEN}Build completed${NC}"

# Locate built APK (broader search for Capacitor projects)
builtApk=$(find android -type f -name "*.apk" ! -name "*unsigned*" -print -quit)

if [ -z "$builtApk" ]; then
  echo -e "${RED}Built APK not found${NC}"
  exit 1
fi

echo -e "${GREEN}Found built APK: $builtApk${NC}"

# Compare
officialHash=$(sha256sum original.apk | awk '{print $1}')
builtHash=$(sha256sum "$builtApk" | awk '{print $1}')

echo "Official hash: $officialHash"
echo "Built hash:    $builtHash"

mkdir -p fromOfficial fromBuilt
unzip -q original.apk -d fromOfficial
unzip -q "$builtApk" -d fromBuilt

differences=$(diff -r fromOfficial fromBuilt 2>/dev/null | grep -v "META-INF" | grep "^Files" | wc -l || echo 0)

if [ "$officialHash" = "$builtHash" ]; then
  verdict="reproducible"
  echo -e "${GREEN}✓ APKs are identical${NC}"
elif [ "$differences" -eq 0 ]; then
  verdict="reproducible"
  echo -e "${GREEN}✓ Contents match (signatures differ)${NC}"
else
  verdict="not_reproducible"
  echo -e "${YELLOW}✗ Differences found ($differences files, excluding META-INF)${NC}"
fi

# Write results
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+0000")
cat > "$RESULTS_FILE" << EOF
date: $timestamp
script_version: $SCRIPT_VERSION
build_type: $BUILD_TYPE
results:
  - app_id: $appId
    version_name: $versionName
    version_code: $versionCode
    files:
      - filename: adamant-messenger.apk
        hash: $officialHash
        match: $([ "$verdict" = "reproducible" ] && echo true || echo false)
        expected_hash: $officialHash
        status: $verdict
        commit: $commit
        differences: $differences
EOF

echo -e "${GREEN}Results saved to $RESULTS_FILE${NC}"

# Cleanup
$CONTAINER_CMD rmi adamant-build >/dev/null 2>&1 || true

echo "Verification finished!"