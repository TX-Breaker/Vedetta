<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Vedetta icon">
</p>

<h1 align="center">Vedetta</h1>

<p align="center">
  <b>A fast, native Mac app for your security cameras and NVRs.</b><br>
  Live view, recordings with calendar and timeline, MP4 export, events and notifications.<br>
  TP-Link VIGI · Hikvision · Dahua · Reolink · Uniview · any ONVIF or RTSP device.
</p>

<p align="center">
  <a href="https://github.com/TX-Breaker/vedetta/releases/latest"><img src="https://img.shields.io/github/v/release/TX-Breaker/vedetta?label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/languages-EN%20·%20IT%20·%20FR-teal" alt="Languages">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="https://github.com/TX-Breaker/vedetta/actions"><img src="https://github.com/TX-Breaker/vedetta/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center">
  <a href="README.it.md">Italiano</a> · <a href="README.fr.md">Français</a>
</p>

---

Vedetta replaces heavyweight Windows video-management software (often run on the Mac through
Wine/CrossOver) with a truly native app: hardware video decoding, a Liquid Glass interface for macOS 26,
and a tiny CPU footprint — **16 cameras live at ~10–13 % CPU** on an Apple Silicon Mac.

> Screenshots: see [docs/images](docs/images) (add yours before publishing a release).

## Features

- **Live view** — grids of 1, 4, 6, 8, 9 and 16 tiles, pages and automatic tour, drag & drop cameras,
  full screen, separate windows for other monitors, digital zoom, audio, snapshots and local MP4 recording.
  Small tiles automatically use the light sub-stream; enlarged tiles switch to high quality.
- **Recordings** — month calendar with recording days, zoomable 24-hour timeline with recording gaps and
  colour-coded events (motion, people, vehicles, line crossing, intrusion…), synchronized playback of up
  to 4 cameras, pause, frame-by-frame, ±10 s, jump to previous/next event, speed control when supported.
- **Export to MP4** — save any time range or single event on your Mac with **no re-encoding**
  (H.264/H.265 as recorded), queue with progress, cancel, retry and resume after restart.
- **Events & notifications** — daily event list with filters; macOS notifications for new detections;
  click a notification to replay the moment.
- **PTZ** — joystick, zoom, speed and saved positions for motorized ONVIF cameras.
- **Devices** — automatic discovery on the local network (WS-Discovery), one-screen setup, channel
  renaming/hiding, and the device web interface inside the app for advanced settings.
- **Efficient** — streams pause when the window is hidden or the Mac sleeps, reconnect automatically,
  and share one connection per camera.
- **Private** — passwords stay in the macOS Keychain; Vedetta only talks to devices on your network.
  No accounts, no cloud, no telemetry.
- **Multilingual** — English, Italiano, Français. Vedetta follows the language of macOS and can be
  switched in Settings.

## Supported devices

| Device | Live | Recordings (calendar, timeline, export) | Events |
|---|:-:|:-:|:-:|
| **TP-Link VIGI** recorders (NVR) | ✓ | ✓ | ✓ + notifications |
| **ONVIF recorders of any brand** (Hikvision, Dahua, Uniview, Reolink…) | ✓ | ✓ with ONVIF Profile G | ✓ + notifications |
| **Hikvision / Dahua** recorders without ONVIF (RTSP) | ✓ | ✓ by picking a time (no recording list) | – |
| **Reolink / Uniview** recorders without ONVIF (RTSP) | ✓ | – | – |
| **ONVIF cameras** of any brand, including PTZ | ✓ + PTZ | ✓ if the camera records (Profile G) | ✓ |
| Any **RTSP** stream | ✓ | – | – |

Video: H.264 and H.265/HEVC. Audio: G.711 (µ-law/A-law), AAC, PCM.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Cameras/NVR reachable on your network (or through a VPN such as Tailscale/WireGuard for remote access).

## Install

1. Download `Vedetta-x.y.z-macOS.dmg` from the [latest release](https://github.com/TX-Breaker/vedetta/releases/latest).
2. Drag **Vedetta** to **Applications**.
3. First launch: if the build is not notarized, macOS may say it cannot verify the developer.
   Right-click Vedetta → **Open**, or run `xattr -dr com.apple.quarantine /Applications/Vedetta.app`.
4. Allow **Local Network** access when macOS asks — Vedetta needs it to find and reach your devices.
5. Choose what to connect (VIGI NVR, NVR of another brand, ONVIF camera or RTSP address), enter the
   password, done.

## Build from source

```bash
git clone https://github.com/TX-Breaker/vedetta.git
cd vedetta
scripts/build-app.sh --install     # builds dist/Vedetta.app, installs it in /Applications and pins it to the Dock
```

Requires the macOS 26 SDK (Xcode 26+ or the Command Line Tools with the 26.x SDK) and Swift 6.2+.
Package a release with `scripts/package.sh` (zip + DMG + SHA-256; optional notarization).

## Tests

```bash
swift test                        # unit tests
scripts/regression.sh             # full regression: protocols against local mock NVRs, in-app end-to-end
                                  # self tests in IT/EN/FR, reconnection, 16-camera performance, hangs, memory
```

The regression suite needs `mediamtx` and `ffmpeg` (`brew install mediamtx ffmpeg`) and runs entirely on
your Mac — no real camera required.

## Translations

All texts live in one table, [`Resources/Localization/strings.tsv`](Resources/Localization/strings.tsv)
(English key · Italiano · Français). Run `python3 scripts/l10n.py` to regenerate the macOS `.strings`
files and check that nothing is missing. New languages are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Architecture

Swift packages, no third-party runtime dependencies:

| Module | Role |
|---|---|
| `RTSPKit` | RTSP/RTP client (TCP interleaved, Digest/Basic auth), H.264/H.265/AAC/G.711 depacketizers |
| `MediaKit` | VideoToolbox display layer, audio playback, MP4 writer without re-encoding, snapshots |
| `ONVIFKit` | WS-Discovery, SOAP with WS-Security, media, PTZ, Profile G recording search and replay |
| `VigiKit` | TP-Link VIGI NVR JSON API (login, channels, recording search, events) |
| `VedettaCore` | Devices, live stream pool, synchronized playback, exports, brand-neutral playback backends |
| `Vedetta` | SwiftUI app (Liquid Glass) |

More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Privacy & security

Passwords are stored only in the macOS Keychain. Self-signed device certificates are pinned on first use
and you are warned if they change. Vedetta makes no connections outside your local network.
Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## Disclaimer

Vedetta is an independent open-source project. It is **not affiliated with, endorsed by or sponsored by**
TP-Link, Hikvision, Dahua, Reolink, Uniview, EZVIZ or the ONVIF organization. All trademarks belong to
their respective owners and are used only to describe compatibility. Interoperability with VIGI recorders
is based on their public web interface and documented RTSP/ONVIF endpoints.

## License

[MIT](LICENSE) © 2026 TX-Breaker and Vedetta contributors.
