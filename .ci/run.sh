#!/usr/bin/env bash
set -euo pipefail

# Real build logic — kept here in the private repo so the public runner reveals nothing.
# Decoy env (CFG_*) is mapped to the real names here, at runtime, off the public surface.
cd "$(cd "$(dirname "$0")/.." && pwd)"

# Coarse phase markers only (no code/file names) so we can see WHERE time goes in the
# public log without leaking what the project is. Verbose tool output is suppressed.
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

# Authenticate github.com (mirrors what actions/checkout sets up) for git fetches.
export GIT_TERMINAL_PROMPT=0
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global "http.https://github.com/.extraheader" \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
  printf 'machine github.com\n  login x-access-token\n  password %s\n' "$GH_TOKEN" > "$HOME/.netrc"
  chmod 600 "$HOME/.netrc"
fi

# --- TEMP 1-MIN PROBE: can this runner actually download a binary artifact? ---
ts "PROBE downloads"
URL="https://github.com/stasel/WebRTC/releases/download/120.0.0/WebRTC-M120.xcframework.zip"
echo "-- default:"
curl -fL --max-time 60 -o "$RUNNER_TEMP/w.zip" "$URL" \
  -w "  http=%{http_code} size=%{size_download} time=%{time_total}s ip=%{remote_ip}\n" 2>&1 || echo "  rc=$?"
echo "-- ipv4:"
curl -fL --ipv4 --max-time 60 -o "$RUNNER_TEMP/w4.zip" "$URL" \
  -w "  http=%{http_code} size=%{size_download} time=%{time_total}s ip=%{remote_ip}\n" 2>&1 || echo "  rc=$?"
echo "PROBE DONE"
exit 0
# --- end probe ---

ts "select xcode"
LATEST=$(ls -d /Applications/Xcode_*.app | sort -V | tail -n1)
sudo xcode-select -s "$LATEST/Contents/Developer"

ts "xcodegen"
command -v xcodegen >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 run "brew" brew install xcodegen
run "generate" xcodegen generate

# Resolve packages the STANDARD way: default location, no custom -clonedSourcePackagesDirPath
# (that custom path is what broke the binary-artifact downloads). Packages land in the
# project's DerivedData, which the workflow caches. Per-attempt cap + retry is just a safety
# net so a transient network stall can't run blind for an hour.
RLOG="$RUNNER_TEMP/resolve.log"
resolved=0
for attempt in 1 2 3; do
  : > "$RLOG"
  ts "resolve packages (attempt $attempt)"
  ( while true; do echo "   working... $(date -u +%H:%M:%S)Z"; sleep 20; done ) &
  MON=$!
  if perl -e 'alarm shift @ARGV; exec @ARGV' 600 \
       xcodebuild -resolvePackageDependencies -project Kulan.xcodeproj -scheme Kulan \
       >"$RLOG" 2>&1; then
    kill "$MON" 2>/dev/null || true
    echo "   resolve OK"
    resolved=1
    break
  fi
  kill "$MON" 2>/dev/null || true
  echo "   attempt $attempt failed — retry"
done
if [ "$resolved" -ne 1 ]; then
  echo "!! resolve still failing after retries"
  tail -30 "$RLOG"
  exit 1
fi

# Mode "a" (default) = compile check only, no signing. Anything else = build + ship.
if [ "${1:-a}" = "a" ]; then
  ts "compile (simulator)"
  run "compile" xcodebuild build -project Kulan.xcodeproj -scheme Kulan \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
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

ts "fastlane (cert + build + upload)"
run "fastlane" fastlane beta
ts "done"
