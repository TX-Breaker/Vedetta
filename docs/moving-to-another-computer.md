# Moving the project to another computer

## 1. Make the package (current Mac)

```bash
cd vedetta
git status                      # everything must be committed
scripts/export-source.sh        # creates dist/transfer/
```

`dist/transfer/` contains:

| File | Content |
|---|---|
| `Vedetta-source-<version>.bundle` | **the whole git repository in one file**: every commit, branch and tag (e.g. `v1.0.0`) |
| `Vedetta-source-<version>.zip` | the files of the current commit, without history |
| `README.txt` | short instructions |
| `SHA256SUMS.txt` | checksums to verify the copy (`shasum -a 256 -c SHA256SUMS.txt`) |

If the ignored `private/` folder exists (local notes, never published), the script also adds
`Vedetta-local-only-<version>.zip` with it: copy it for yourself, never publish it.

Copy the folder to the other computer in any way (USB drive, AirDrop, external disk, cloud): a few MB.

Not included on purpose: `dist/` and `.build/` (build products, regenerated), `scripts/testenv/` (test
credentials generated on each machine), app settings and passwords.

## 2. Restore (other Mac)

```bash
git clone Vedetta-source-1.0.0.bundle vedetta
cd vedetta
git remote remove origin        # the bundle is no longer needed as origin
git log --oneline --decorate    # history and the v1.0.0 tag are there
```

Without git: unzip the source zip (folder `vedetta/`).

## 3. Build

```bash
scripts/bootstrap.sh            # checks the requirements and reports what is missing (changes nothing)
scripts/build-app.sh            # dist/Vedetta.app   (--install copies it to /Applications)
scripts/package.sh              # dist/release/…zip and …dmg
swift test                      # tests (optional)
```

Requirements: **Apple Silicon Mac, macOS 26 or later**, Xcode or the Command Line Tools
(`xcode-select --install`). With the Command Line Tools only, a macOS 26.x SDK is needed (the script finds it);
if only the macOS 27 SDK is installed, install Xcode (and accept its license: `sudo xcodebuild -license accept`).
For the full regression suite: `brew install mediamtx ffmpeg`.

> **Windows or Linux PC**: the code can be copied, kept and edited anywhere (plain text files; the zip opens
> directly), but the app builds and runs **only on a Mac** (SwiftUI, VideoToolbox, AppKit).

## 4. App settings (optional)

1. On the old Mac, in Vedetta: **File › Export Settings…**
2. On the new Mac: **File › Import Settings…**
3. Sign in once per device: passwords are never in the file (they stay in the Keychain).

## 5. Keeping both Macs in sync

A bundle is a copy: changes made on one Mac do not reach the other by themselves. The simplest way is a hosted
repository (e.g. GitHub, private or public) with `git push` / `git pull`. Otherwise re-export the bundle and pull
the new commits from it:

```bash
# on Mac A
scripts/export-source.sh
# on Mac B, inside the project
git pull /path/to/Vedetta-source-1.0.0.bundle main --tags
```
