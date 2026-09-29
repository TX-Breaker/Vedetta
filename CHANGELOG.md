# Changelog

All notable changes to Vedetta are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-09-29

First public release.

### Added
- Native macOS 26 app with a Liquid Glass interface, hardware (VideoToolbox) H.264/H.265 decoding.
- Live view: 1/4/6/8/9/16-tile layouts, pages, automatic tour, drag & drop, full screen, detached windows,
  digital zoom, audio, snapshots, local MP4 recording, automatic main/sub stream selection.
- Recordings: calendar, zoomable 24-hour timeline with recording gaps and colour-coded events,
  synchronized playback of up to 4 cameras, pause, frame step, ±10 s, previous/next event, speed control.
- MP4 export without re-encoding with a persistent download queue (cancel, retry, resume).
- Events list with filters and macOS notifications that open the matching recording.
- PTZ joystick, zoom and presets for ONVIF cameras.
- Devices: TP-Link VIGI NVRs (JSON API + RTSP), ONVIF NVRs of any brand (Profile S/G), Hikvision, Dahua,
  Reolink and Uniview recorders over RTSP, ONVIF cameras of any brand, plain RTSP streams.
- Automatic discovery (WS-Discovery), Keychain storage, certificate pinning for self-signed devices.
- Streams pause when no window is visible and reconnect automatically.
- English, Italian and French localizations with automatic language detection and an in-app override.
- Regression suite with local mock recorders and an in-app end-to-end self test.
