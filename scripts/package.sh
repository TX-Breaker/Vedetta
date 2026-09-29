#!/bin/zsh
# Packages dist/Vedetta.app for a GitHub release: zip + DMG + SHA-256 checksums.
# Optional notarization (Developer ID builds): set NOTARY_PROFILE to a notarytool keychain profile.
# Usage: scripts/build-app.sh && scripts/package.sh
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
VERSION=${VEDETTA_VERSION:-$(cat VERSION)}
APP=dist/Vedetta.app
[[ -d $APP ]] || { echo "build first: scripts/build-app.sh"; exit 1; }
OUT=dist/release
rm -rf $OUT && mkdir -p $OUT
ZIP=$OUT/Vedetta-$VERSION-macOS.zip
DMG=$OUT/Vedetta-$VERSION-macOS.dmg

ditto -c -k --sequesterRsrc --keepParent $APP $ZIP

STAGE=$(mktemp -d)
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
hdiutil create -volname "Vedetta $VERSION" -srcfolder $STAGE -ov -format UDZO $DMG >/dev/null
rm -rf $STAGE

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple $DMG
  xcrun stapler staple $APP && ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
fi

( cd $OUT && shasum -a 256 *.zip *.dmg > SHA256SUMS.txt )
ls -lh $OUT
