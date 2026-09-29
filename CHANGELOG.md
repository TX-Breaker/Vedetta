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
- Account protection against recorder lockouts: one shared session per recorder, a single login attempt at a
  time, no logins while the recorder is unreachable (password-free checks with exponential backoff and jitter,
  5 s → 5 min), automatic attempts stopped on refused credentials or a locked user (resumed only after the
  unlock time reported by the recorder), never a login with an empty password when the Keychain denies access.
- Sign out and Switch user (app menu, Settings › Accounts, device card): closes the streams, ends the session
  on the recorder, deletes the saved password and returns to the sign-in screen; works offline and when locked.
- Local connection log (time, result, error code; no passwords) and advice to use a dedicated view-only user.
- Live view: drag a tile onto another to swap cameras; camera names always / on hover / never; picture fit, fill or
  stretch (4:3 sub-streams without cropping the camera clock); the grid no longer slides under the toolbar.
- Snapshots and recordings on the Mac always come from the full-quality stream, even when tiles show the light one.
- Recordings: single-key keyboard shortcuts, mouse-wheel zoom around the pointer and on-screen buttons for one-hand
  use (zoom, scroll, center, selection start/end); choice to include audio when saving recordings.
- Settings: tolerant reading across versions, automatic backup, damaged files set aside, flushed on quit;
  File › Export/Import Settings (devices, cameras, layout, preferences; never passwords).
- English, Italian and French localizations with automatic language detection and an in-app override.
- Regression suite with local mock recorders and an in-app end-to-end self test, including the account
  protection scenarios (recorder offline for 2 minutes, refused password, locked user, sign out while offline,
  switch user with live streams).

### Fixed (before release)
- RTSP TEARDOWN was never sent when a stream closed, leaving sessions open on the recorder.
- A refused RTSP password was sent twice on the same connection.
