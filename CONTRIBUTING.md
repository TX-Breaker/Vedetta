# Contributing to Vedetta

Thanks for helping! Bug reports, device compatibility reports, translations and pull requests are welcome.

Full documentation: [docs/](docs/README.md) — start with [docs/developer-guide.md](docs/developer-guide.md).

## Development setup

- macOS 26+, Apple Silicon, Xcode 26+ (or Command Line Tools with the macOS 26.x SDK), Swift 6.2+.
- `brew install mediamtx ffmpeg` for the local test bench.

```bash
swift build                       # build all modules
swift test                        # unit tests
scripts/build-app.sh --install    # build and install dist/Vedetta.app
scripts/regression.sh             # full regression suite (~35 minutes, no real camera needed)
```

The regression suite starts a local RTSP server (mediamtx + ffmpeg test streams), a mock VIGI NVR and a mock
ONVIF NVR, then runs protocol tests and the in-app self test (`VEDETTA_DEV=1 VEDETTA_SELFTEST=1`) in
Italian, English and French. Please run it before opening a pull request that touches networking,
playback or exports.

## Code style

- Match the surrounding code: small types, no third-party runtime dependencies.
- Never block the main thread (network, Keychain and file I/O happen off the main actor).
- User-visible text goes through `L("English text")` — never hard-code a translated string.

## Translations

All texts are in [`Resources/Localization/strings.tsv`](Resources/Localization/strings.tsv):
`English key <TAB> Italian <TAB> French`.

1. Add or edit rows (placeholders are `%@`; reorder them in a translation with `%1$@`, `%2$@`).
2. Run `python3 scripts/l10n.py` — it regenerates the `.lproj` files and fails if a key used in the code
   is missing or placeholders don't match.

To add a new language: add a column to the TSV, the language code to `LANGS` in `scripts/l10n.py`,
`CFBundleLocalizations` in `Resources/Info.plist` and `AppLanguage` in `Sources/VedettaL10n/L10n.swift`.

## Reporting device compatibility

Open an issue with the brand, model and firmware of your recorder/camera, which protocol you used
(VIGI, ONVIF, RTSP) and what works or doesn't. Never include passwords, public IP addresses or serial numbers.

## Commit and PR guidelines

- One topic per pull request, with a short description of the change and how you tested it.
- Update `CHANGELOG.md` under an "Unreleased" heading.
