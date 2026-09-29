#!/bin/zsh
# Checks that this Mac can build and test Vedetta, and says what is missing. Changes nothing.
# Usage: scripts/bootstrap.sh
ROOT=${0:A:h:h}
cd $ROOT
ok() { print -r -- "  ✔ $1"; }
ko() { print -r -- "  ✘ $1"; MISSING=1; }
info() { print -r -- "  · $1"; }
MISSING=0
print "Vedetta — build requirements"
[[ $(uname -m) == arm64 ]] && ok "Apple Silicon Mac" || ko "Apple Silicon Mac required (this is $(uname -m))"
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MAJOR >= 26 )) && ok "macOS $(sw_vers -productVersion)" || ko "macOS 26 or later required (this is $(sw_vers -productVersion))"
if xcode-select -p >/dev/null 2>&1; then ok "developer tools: $(xcode-select -p)"
else ko "developer tools missing: run  xcode-select --install  (or install Xcode from the App Store)"; fi
if xcodebuild -version >/dev/null 2>&1; then ok "$(xcodebuild -version | head -1)"
else info "full Xcode not usable (not installed, or license not accepted: sudo xcodebuild -license accept) — the Command Line Tools are enough"; fi
if command -v swift >/dev/null; then
  SV=$(swift --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')
  [[ ${SV%%.*} -ge 6 ]] && ok "Swift $SV" || ko "Swift 6.2 or later required (found $SV)"
else ko "swift not found"; fi
source $ROOT/scripts/sdk.sh
[[ -n ${SDKROOT:-} ]] && ok "SDK: $SDKROOT" || info "SDK: default of the toolchain"
command -v git >/dev/null && ok "git" || ko "git missing"
print "Optional (only for scripts/regression.sh):"
for t in mediamtx ffmpeg python3; do
  command -v $t >/dev/null && ok "$t" || info "$t missing: brew install ${t/python3/python}"
done
print
if (( MISSING )); then print "Fix the ✘ items, then run: scripts/build-app.sh"; exit 1; fi
print "Ready. Build the app with:   scripts/build-app.sh     (add --install to copy it to /Applications)"
print "Unit tests:                  swift test"
