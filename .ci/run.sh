#!/usr/bin/env bash
set -euo pipefail

# Real build logic — kept here in the private repo so the public runner reveals nothing.
# Decoy env (CFG_*) is mapped to the real names here, at runtime, off the public surface.
cd "$(cd "$(dirname "$0")/.." && pwd)"

# Coarse phase markers only (no code, no file names) so we can see WHERE time goes
# in the public log without leaking what the project is. Verbose tool output is suppressed.
ts() { echo ">> $1  ($(date -u +%H:%M:%S)Z)"; }
run() {                       # run quietly; on failure, surface only error lines
  local label="$1"; shift
  local log="$RUNNER_TEMP/${label}.log"
  if ! "$@" >"$log" 2>&1; then
    echo "!! FAILED: $label"
    grep -iE "error:|❌|finished with errors|invalid|could not|fatal" "$log" | tail -40 || tail -40 "$log"
    exit 1
  fi
}

export ASC_KEY_ID="$CFG_A1"
export ASC_ISSUER_ID="$CFG_A2"
export ASC_TEAM_ID="$CFG_A3"

# Authenticate github.com git traffic (same trick actions/checkout uses). Swift's
# package resolver shells out to git; without this, fetches run unauthenticated and
# GitHub throttles them until the job times out. Uses the runner's own ephemeral token.
export GIT_TERMINAL_PROMPT=0   # never block waiting for credentials; fail fast instead
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global "http.https://github.com/.extraheader" \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
fi

SPM="$HOME/spm"   # stable package dir so the public workflow can cache it

ts "select xcode"
LATEST=$(ls -d /Applications/Xcode_*.app | sort -V | tail -n1)
sudo xcode-select -s "$LATEST/Contents/Developer"

ts "xcodegen"
command -v xcodegen >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 run "brew" brew install xcodegen
run "generate" xcodegen generate

ts "resolve packages"
# Live size counter (safe: shows only byte totals, no package names) so we can SEE
# whether it's downloading (growing) or truly frozen. Hard 30-min cap via perl alarm
# so a stall can never burn a blind hour again.
( while true; do echo "   spm=$(du -sh "$SPM" 2>/dev/null | cut -f1)  $(date -u +%H:%M:%S)Z"; sleep 20; done ) &
MON=$!
if perl -e 'alarm shift @ARGV; exec @ARGV' 1800 \
     xcodebuild -resolvePackageDependencies \
     -project Kulan.xcodeproj -scheme Kulan -clonedSourcePackagesDirPath "$SPM" \
     >"$RUNNER_TEMP/resolve.log" 2>&1; then
  kill "$MON" 2>/dev/null || true
  echo "   resolve OK  (spm=$(du -sh "$SPM" 2>/dev/null | cut -f1))"
else
  rc=$?
  kill "$MON" 2>/dev/null || true
  echo "!! resolve failed/timed out rc=$rc  (spm=$(du -sh "$SPM" 2>/dev/null | cut -f1))"
  echo "--- tail of resolve output (temporary debug) ---"
  tail -25 "$RUNNER_TEMP/resolve.log"
  exit 1
fi

# Mode "a" (default) = compile check only, no signing. Anything else = build + ship.
if [ "${1:-a}" = "a" ]; then
  ts "compile (simulator)"
  run "compile" xcodebuild build -project Kulan.xcodeproj -scheme Kulan \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -clonedSourcePackagesDirPath "$SPM" \
    -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
  ts "done"
  exit 0
fi

# --- ship path ---  (cert is created from the .p8 API key by fastlane; no .p12 needed)
ts "keychain + cert prep"
printf '%s' "$CFG_B1" > "$RUNNER_TEMP/AuthKey.p8"

KC="$RUNNER_TEMP/b.keychain-db"
security create-keychain -p "" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "" "$KC"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security default-keychain -s "$KC"

export ASC_KEY_PATH="$RUNNER_TEMP/AuthKey.p8"
export SIGN_KEYCHAIN="$KC"
export BUILD_NUMBER="$(date +%s)"   # timestamp: always increases, even on a fresh repo
export FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT=180
export FASTLANE_XCODEBUILD_SETTINGS_RETRIES=6
export CLONED_SOURCE_PACKAGES_PATH="$SPM"

ts "fastlane (cert + build + upload)"
run "fastlane" fastlane beta
ts "done"
