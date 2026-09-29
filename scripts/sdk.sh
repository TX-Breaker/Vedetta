# Sourced by the build scripts (zsh or bash): picks the macOS SDK to build with, with no fixed paths.
# 1. SDKROOT already set → kept.  2. Full Xcode installed and licensed → its SDK.
# 3. Command Line Tools only → the newest macOS 26.x SDK (the macOS 27 SDK of the CLT lacks the SwiftUI
#    macro plug-ins that only Xcode ships).  4. Otherwise the toolchain default.
if [ -z "${SDKROOT:-}" ]; then
  if xcodebuild -version >/dev/null 2>&1; then
    export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  else
    _vedetta_sdk="$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -name 'MacOSX26*.sdk' 2>/dev/null | sort -V | tail -1)"
    [ -n "$_vedetta_sdk" ] && export SDKROOT="$_vedetta_sdk"
    unset _vedetta_sdk
  fi
fi
