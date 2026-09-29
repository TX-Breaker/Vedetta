#!/bin/zsh
# Makes a transfer package of the source code, to copy the project to another computer:
#   Vedetta-source-<version>.bundle   the whole git repository (history, tags) in one file
#   Vedetta-source-<version>.zip      the files of the current commit (no history)
#   README.txt                        how to restore and build
#   Vedetta-local-only-<version>.zip  private/ and GITHUB_PUBLISHING.txt, when present: for your other Mac,
#                                     NEVER to be published
#   SHA256SUMS.txt
# Only committed files are included: commit first. Ignored folders (private/, dist/, scripts/testenv/) are not.
# Usage: scripts/export-source.sh [output folder]     (default: dist/transfer)
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
VERSION=$(cat VERSION)
OUT=${1:-dist/transfer}
[[ -z $(git status --porcelain) ]] || print "warning: uncommitted changes are NOT included — commit them first."
rm -rf $OUT && mkdir -p $OUT
BUNDLE=$OUT/Vedetta-source-$VERSION.bundle
ZIP=$OUT/Vedetta-source-$VERSION.zip
git bundle create $BUNDLE --all
git bundle verify $BUNDLE >/dev/null
git archive --format=zip --prefix=vedetta/ -o $ZIP HEAD
COMMIT=$(git rev-parse --short HEAD)
cat > $OUT/README.txt <<TXT
Vedetta $VERSION — source code (commit $COMMIT)

1. Copy this folder to the other Mac.
2. Restore the repository with its full history:
       git clone Vedetta-source-$VERSION.bundle vedetta && cd vedetta && git remote remove origin
   Or, without history: unzip Vedetta-source-$VERSION.zip.
3. Check the requirements:  scripts/bootstrap.sh
4. Build:                   scripts/build-app.sh   (--install copies it to /Applications); packages: scripts/package.sh
Requires an Apple Silicon Mac with macOS 26+, and Xcode or the Command Line Tools.
App settings and passwords are not part of the code: use File › Export Settings / Import Settings in Vedetta.
Full guide: docs/moving-to-another-computer.md
If Vedetta-local-only-$VERSION.zip is present: it holds your private development material (prompt, research,
publishing kit). Unzip it inside the project folder on the other Mac. NEVER publish it.
TXT
# Local-only material (development prompt, research, publishing kit…): copied for yourself, never published.
LOCAL=()
[[ -d private ]] && LOCAL+=(private)
[[ -f GITHUB_PUBLISHING.txt ]] && LOCAL+=(GITHUB_PUBLISHING.txt)
if (( ${#LOCAL} )); then
  zip -qry $OUT/Vedetta-local-only-$VERSION.zip $LOCAL -x '*.DS_Store'
  print "Vedetta-local-only-$VERSION.zip: private material for your other Mac — NEVER publish it." > $OUT/LOCAL-ONLY-DO-NOT-PUBLISH.txt
fi
( cd $OUT && shasum -a 256 *.bundle *.zip > SHA256SUMS.txt )
ls -lh $OUT
