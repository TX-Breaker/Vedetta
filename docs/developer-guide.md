# Developer guide

How to build, run, test, translate and release Vedetta. Architecture: [ARCHITECTURE.md](ARCHITECTURE.md).
Copying the project to another computer: [moving-to-another-computer.md](moving-to-another-computer.md).

## Requirements

- Apple Silicon Mac, macOS 26 or later.
- Swift 6.2+ toolchain: **Xcode 26+** or the **Command Line Tools** (`xcode-select --install`).
- `git`. For the regression suite: `brew install mediamtx ffmpeg` and `python3`.

Check a machine with `scripts/bootstrap.sh` (read-only: it only reports what is missing).

### Which SDK

`scripts/sdk.sh` (sourced by the build scripts) picks the SDK: `SDKROOT` if set, else full Xcode when installed
and licensed, else the newest **macOS 26.x SDK of the Command Line Tools**. The macOS 27 SDK shipped with the
Command Line Tools lacks the SwiftUI macro plug-ins that only Xcode provides, so it cannot build the app; with
Xcode installed any SDK works. If `xcodebuild` says the license is not accepted: `sudo xcodebuild -license accept`.
When calling `swift` by hand with only the Command Line Tools, export the SDK first:

```bash
source scripts/sdk.sh && swift build
```

## Build and run

```bash
swift build                          # all modules (debug)
scripts/build-app.sh                 # dist/Vedetta.app (release, arm64, ad-hoc signed, Hardened Runtime)
scripts/build-app.sh --install       # … and copy to /Applications + pin to the Dock
                                     #   (quits a running Vedetta first; never launches it)
scripts/package.sh                   # dist/release/Vedetta-<version>-macOS.{zip,dmg} + SHA256SUMS.txt
scripts/export-source.sh             # dist/transfer/: git bundle + source zip to move the project
```

- Version: `VERSION` file (or `VEDETTA_VERSION`); build number: number of commits (or `VEDETTA_BUILD`).
- Signing: ad-hoc by default; `VEDETTA_SIGN_IDENTITY="Developer ID Application: …"` for distribution.
  Notarization in `package.sh`: set `NOTARY_PROFILE` to a `notarytool` keychain profile.
- Ad-hoc signatures change at every build, so macOS asks again for Keychain access after each update; a stable
  Developer ID signature avoids it.
- Run from the terminal with a clean, isolated data folder: `VEDETTA_DEV=1 dist/Vedetta.app/Contents/MacOS/Vedetta`.

## Project layout

```
Package.swift                 SwiftPM manifest (tools 6.2, Swift 5 language mode, macOS 26)
Sources/
  VedettaL10n/                L("…") lookup and language selection
  RTSPKit/                    RTSP/RTP client, auth, SDP, depacketizers
  MediaKit/                   display view, decoding, audio, MP4 writer
  NetKit/                     TLS pinning, AccessGuard (lockout protection), AccessLog, reachability probes
  ONVIFKit/                   discovery, SOAP/WS-Security, media, PTZ, Profile G
  VigiKit/                    TP-Link VIGI JSON API
  VedettaCore/                models, storage, DeviceClients, connection wizard, live/playback/exports
  Vedetta/                    SwiftUI app (+ SelfTest.swift, dev only)
  vedetta-probe/              command line diagnostics
Tests/                        unit tests (Swift Testing)
Resources/                    Info.plist, localizations (strings.tsv → .lproj)
scripts/                      build, package, regression, test bench, mocks, tools
docs/                         this documentation
.github/                      CI, release workflow, issue/PR templates
private/, dist/, .build/, scripts/testenv/   ignored (local only)
```

## Tests

### Unit tests

```bash
swift test                                   # all
swift test --filter LockoutTests             # one suite
```

With only the Command Line Tools the Swift Testing macro plug-in is occasionally not found on the first build:
run `swift build --build-tests` again (the regression script retries automatically).

Main suites: RTSP (auth, SDP, depacketizers), ONVIF Profile G parsing, VIGI crypto, recorder matching and brand
URLs, **LockoutTests** (simulated VIGI recorder with single nonce, sessions and lockout after 5 failures, fake RTSP
server with per-user permissions, virtual clock: recorder offline 2 minutes, wrong password, locked user, sign out
offline/locked, switch user with live streams, cameras starting together, dedicated user with partial permissions)
and **SettingsTests** (old/new/damaged settings files, backups, export format).

### Regression suite

```bash
scripts/regression.sh              # everything (~35 minutes)
scripts/regression.sh selftest     # only the in-app self tests
scripts/regression.sh vigi         # only the VIGI self test (~5 minutes)
scripts/regression.sh resilience   # only the account-protection scenario (~9 minutes)
scripts/regression.sh perf         # only the 16-camera performance and idle checks (~2 minutes)
```

Report: `scripts/testenv/regression-report.txt`. Sections: build · unit tests and translations · test bench ·
protocol tests with `vedetta-probe` · app bundle · in-app self tests (VIGI in Italian and English, ONVIF in
French, account protection) · 16-camera performance · idle CPU/memory.

The **test bench** (`scripts/test-rtsp-server.sh start|stop`) runs mediamtx with Digest auth and ffmpeg test
streams laid out like a VIGI NVR (`live/<ch>/<1|2>/avm`, `replay/…`), with two users (`USER`/`PASS`,
`VUSER`/`VPASS`) generated in `scripts/testenv/credentials`. Mocks:

- `scripts/mock_nvr.py <port> <credentials>` — VIGI JSON API over HTTPS: RSA login with a single nonce, several
  sessions, lockout after 5 failures (buzzer counter), logout. Control on `<port>+2` (plain HTTP):
  `GET /stats`, `POST /control {"offline":true, "password":"…", "expire":true, "lock":90, "reset":true}`.
- `scripts/mock_onvif.py <port> <credentials>` — ONVIF NVR with Profile G and PTZ (`MOCK_CHANNELS=16` for load tests).

The **in-app self test** (`Sources/Vedetta/SelfTest.swift`) drives the real app — windows, real mouse and
keyboard events — and writes a JSON report. Environment variables:

| Variable | Meaning |
|---|---|
| `VEDETTA_DEV=1` | isolated data (`Vedetta-Dev`, Keychain `it.vedetta.devices.dev`), no notifications |
| `VEDETTA_DEV_CONFIG` | JSON `{kind, address, httpPort, rtspPort, user, pass}` connected at launch |
| `VEDETTA_DEV_SECTION` | section to open (`live`, `playback`, …) |
| `VEDETTA_KEEP_STREAMS=1` | keep streams running when the window is hidden or covered (load tests) |
| `VEDETTA_SELFTEST=1`, `VEDETTA_SELFTEST_OUT` | run the self test, report path |
| `VEDETTA_SELFTEST_SCENARIO` | `full` (default) or `resilience` |
| `VEDETTA_SELFTEST_RESTART_MARKER` | file the test writes (`stop`/`start`/`restart`) to control the RTSP bench |
| `VEDETTA_MOCK_CONTROL` | mock NVR control URL |
| `VEDETTA_USER`, `VEDETTA_PASS`, `VEDETTA_VUSER`, `VEDETTA_VPASS` | test credentials (never on the command line) |

### vedetta-probe

```bash
VEDETTA_USER=… VEDETTA_PASS=… .build/debug/vedetta-probe rtsp rtsp://host/live/1/1/avm 5 --record out.mp4 --snapshot out.jpg
.build/debug/vedetta-probe discover                      # WS-Discovery
.build/debug/vedetta-probe vigi 192.168.1.100             # VIGI API: login, info, channels, recordings, events
.build/debug/vedetta-probe nvr 192.168.1.100 554          # full connection wizard for a VIGI NVR
.build/debug/vedetta-probe recorder 192.168.1.50         # any-brand NVR (ONVIF, then brand layouts)
.build/debug/vedetta-probe brand 192.168.1.50 hikvision  # RTSP-only brand layout
.build/debug/vedetta-probe onvif http://…/onvif/device_service
.build/debug/vedetta-probe ptz http://…/onvif/device_service
```

Be careful with real recorders: a wrong `VEDETTA_PASS` is a failed login for the recorder.

## Translations

All texts are English keys in `L("…")` calls; translations live in one table,
`Resources/Localization/strings.tsv` (English · Italian · French, tab-separated).

```bash
python3 scripts/l10n.py            # generate .lproj files + check
python3 scripts/l10n.py --check    # check only: every key translated, placeholders (%@) match, no unused rows
```

Adding a language: add a column to the table and the language code in `scripts/l10n.py`, `Resources/Info.plist`
(`CFBundleLocalizations`) and `AppLanguage` (`Sources/VedettaL10n/L10n.swift`). Texts written only to the
connection log stay in English on purpose.

## Conventions

- Swift 5 language mode; networking and file I/O off the main actor; the main actor receives state, never frames.
- Every operation that sends device credentials goes through the device's `AccessGuard`
  (`DeviceClients.shared.accessGuard(for:)`); never create API clients or RTSP connections with credentials
  outside it, never with an empty password.
- Settings types decode field by field with defaults (see `Models.swift`, "Tolerant decoding"): add new fields
  there with a default.
- Streams are shared through `StreamPool`; balance every `acquire` with a `release`.
- User-visible texts via `L("English text")`, then add the row to `strings.tsv`.

## Continuous integration and releases

- `.github/workflows/ci.yml`: translations check, build, unit tests, app bundle (macOS 26 runner, Xcode).
- `.github/workflows/release.yml`: on a `v*` tag builds, optionally signs/notarizes (secrets
  `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`,
  `NOTARY_PASSWORD`) and publishes zip + DMG + checksums to GitHub Releases.
- Release checklist: update `VERSION` and `CHANGELOG.md`, run `scripts/regression.sh`, commit, tag `vX.Y.Z`, push
  the tag.
