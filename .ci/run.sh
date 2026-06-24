#!/usr/bin/env bash
set -euo pipefail

# Real build logic — kept here in the private repo so the public runner reveals nothing.
# Decoy env (CFG_*) is mapped to the real names here, at runtime, off the public surface.
cd "$(cd "$(dirname "$0")/.." && pwd)"

export ASC_KEY_ID="$CFG_A1"
export ASC_ISSUER_ID="$CFG_A2"
export ASC_TEAM_ID="$CFG_A3"

LATEST=$(ls -d /Applications/Xcode_*.app | sort -V | tail -n1)
sudo xcode-select -s "$LATEST/Contents/Developer"
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
xcodebuild -resolvePackageDependencies -project Kulan.xcodeproj -scheme Kulan

# Mode "a" (default) = compile check only, no signing. Anything else = build + ship.
if [ "${1:-a}" = "a" ]; then
  xcodebuild build -project Kulan.xcodeproj -scheme Kulan \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
  exit 0
fi

# --- ship path ---
printf '%s' "$CFG_B1" > "$RUNNER_TEMP/AuthKey.p8"
echo "$CFG_B2" | openssl base64 -d -A > "$RUNNER_TEMP/dist.p12"

KC="$RUNNER_TEMP/b.keychain-db"
security create-keychain -p "" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "" "$KC"
security import "$RUNNER_TEMP/dist.p12" -k "$KC" -P "$CFG_B3" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

export ASC_KEY_PATH="$RUNNER_TEMP/AuthKey.p8"
export BUILD_NUMBER="$(date +%s)"   # timestamp: always increases, even on a fresh repo
export FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT=180
export FASTLANE_XCODEBUILD_SETTINGS_RETRIES=6
fastlane beta
