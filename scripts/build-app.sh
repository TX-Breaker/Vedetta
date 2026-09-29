#!/bin/zsh
# Builds dist/Vedetta.app (release, arm64), signs it ad-hoc with Hardened Runtime.
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications and pins it to the Dock)
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
VERSION=${VEDETTA_VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}
BUILD=${VEDETTA_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
# Signing: ad-hoc by default; set VEDETTA_SIGN_IDENTITY="Developer ID Application: …" for distribution builds.
SIGN_IDENTITY=${VEDETTA_SIGN_IDENTITY:--}

# Use full Xcode when available, otherwise the Command Line Tools with the macOS 26.5 SDK.
if xcodebuild -version >/dev/null 2>&1; then
  export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
else
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi

swift build -c release --product Vedetta

# Icon
ICONSET=.build/AppIcon.iconset
if [[ ! -f .build/AppIcon.icns || scripts/make-icon.swift -nt .build/AppIcon.icns ]]; then
  rm -rf $ICONSET && mkdir -p $ICONSET
  swift scripts/make-icon.swift .build/icon-1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s .build/icon-1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    d=$((s * 2)); sips -z $d $d .build/icon-1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o .build/AppIcon.icns
fi

APP=dist/Vedetta.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Vedetta $APP/Contents/MacOS/Vedetta
cp .build/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
# Localizations (generated from Resources/Localization/strings.tsv)
python3 scripts/l10n.py >/dev/null || { echo "localization check failed: run python3 scripts/l10n.py"; exit 1; }
for lp in Resources/Localization/*.lproj; do cp -R $lp $APP/Contents/Resources/; done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > $APP/Contents/Info.plist
printf 'APPL????' > $APP/Contents/PkgInfo
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --options runtime --entitlements Resources/Vedetta.entitlements --sign - $APP
else
  codesign --force --deep --options runtime --timestamp --entitlements Resources/Vedetta.entitlements --sign "$SIGN_IDENTITY" $APP
fi
codesign --verify --strict $APP
echo "built $APP ($VERSION build $BUILD)"

if [[ "${1:-}" == "--install" ]]; then
  # Quit it only if it is running ("tell application" would otherwise launch it and connect to the devices).
  if pgrep -xq Vedetta; then osascript -e 'tell application "Vedetta" to quit' >/dev/null 2>&1 || true; sleep 1; fi
  rm -rf /Applications/Vedetta.app
  ditto $APP /Applications/Vedetta.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Vedetta.app
  # Pin to the Dock once.
  if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "/Applications/Vedetta.app"; then
    defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file:///Applications/Vedetta.app/</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
    killall Dock
  fi
  echo "installed /Applications/Vedetta.app"
fi
