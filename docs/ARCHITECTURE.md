# Architecture

Vedetta is a Swift package (Swift 6.2 tools, Swift 5 language mode) with no third-party runtime
dependencies. Every module has a single responsibility:

```
VedettaL10n   L("…") lookup, AppLanguage (system language detection + override)
RTSPKit       RTSP 1.0 client over TCP (interleaved RTP), Digest/Basic auth, SDP, RTP depacketizers
              (H.264 RFC 6184, H.265 RFC 7798, AAC RFC 3640, G.711, L16), ONVIF replay RTP extension
MediaKit      CMSampleBuffer building, AVSampleBufferDisplayLayer view (hardware decode, zoom as a layer
              transform), audio decode/playback, MP4 writer without re-encoding, on-demand snapshots
NetKit        URLSession delegate with trust-on-first-use certificate pinning, tolerant JSON helpers,
              AccessGuard (per-device lockout protection), AccessLog (connection log), password-free probes
ONVIFKit      WS-Discovery, SOAP 1.2 + WS-UsernameToken, Device/Media/Media2/PTZ, Profile G search + replay
VigiKit       TP-Link VIGI NVR JSON API (RSA login, channels, recording days/segments, events)
VedettaCore   Models and persistence (tolerant JSON + backups, Keychain, settings export), DeviceClients (one
              session + AccessGuard per device), DeviceConnector (VIGI / ONVIF / RTSP brands),
              LiveStream + StreamPool (shared, auto-reconnecting live streams), PlaybackSession
              (synchronized multi-channel replay on a shared CMTimebase), PlaybackBackend (brand-neutral
              calendar/timeline/replay), ExportManager (persistent MP4 export queue)
Vedetta       SwiftUI app (Liquid Glass): Live, Recordings, Events, Exports, Album, Devices, Settings,
              menu bar extra, notifications, in-app self test (dev only)
vedetta-probe Command line diagnostics for streams and devices
```

## Key design choices

- **Hardware decoding only.** Live and playback frames go straight to `AVSampleBufferDisplayLayer`; the CPU
  only parses RTP. Snapshots decode the last GOP on demand.
- **One connection per camera stream.** `StreamPool` shares streams between views, keeps them for a few
  seconds after the last viewer leaves and suspends everything when no window is visible.
- **Brand-neutral playback.** `PlaybackBackend` hides how recordings are listed and opened
  (VIGI JSON API + RTSP replay URLs, ONVIF Profile G `FindRecordings`/`FindEvents`/`GetReplayUri`,
  Hikvision/Dahua RTSP replay layouts). Several `ReplayTarget`s are tried in order.
- **Never block the main thread.** Network, Keychain (which can wait for a macOS permission prompt) and file
  I/O run off the main actor; the MainActor receives state changes, never frames.
- **Account protection (`AccessGuard`).** Every operation that sends a device's credentials — VIGI login,
  ONVIF request, RTSP connection — goes through the device's guard. While the credentials are unconfirmed a
  single operation runs and the others wait for its result; `.rejected`, `.locked`, `.missingPassword` and
  `.signedOut` block every automatic attempt (a lock with a known unlock time allows one attempt after it).
  Network failures are confirmed with a password-free probe and then retried only as probes, with
  exponential backoff and jitter; clients keep their session tokens and reuse them when the device is back.
  A refusal on a single camera/operation while the credentials are confirmed is checked against a request
  every user may make before stopping everything (dedicated users with limited permissions). VIGI logins
  are also serialized with an async mutex (the firmware keeps a single login nonce). `DeviceClients` owns
  one guard and one API client per device, so the whole app shares a single session.
- **Full-quality captures.** Tiles show the light sub-stream when small, but snapshots and recordings on the
  Mac acquire the channel's main stream from `StreamPool` (shared with any tile already showing it), wait for the
  first key frame, capture, and release it — the pool closes it a few seconds later if nobody watches it.
  `AppModel.liveRecordings` tracks recordings per channel, independently of what the tiles display.
- **Live grid.** `GridKind.frames` gives unit rectangles; `LiveGridGeometry` turns them into points and is shared
  with the tiles through the environment so a tile can be dragged onto another (a `DragGesture` in the grid
  coordinate space; `AppModel.assign` swaps). `VideoDisplayView` returns nil from `hitTest`, so every mouse
  event reaches SwiftUI. The grid stays inside the safe area, below the toolbar.
- **Playback keyboard.** A local key monitor, active only while the Recordings view is in the key window and no
  text field or sheet is active, maps single keys to actions (one-hand use); the timeline's scroll monitor
  zooms around the pointer or scrolls, per settings.
- **Settings persistence.** `JSONStore` writes atomically on a shared utility queue (flushed on quit), keeps a
  `.bak` of the previous version per launch and sets unreadable files aside. `AppSettings`, `Device`, `Channel`
  and `LiveLayout` decode field by field with defaults (`KeyedDecodingContainer.value(_:_:)`), so files from
  other versions are never discarded. `SettingsBackup` is the export/import format (no secrets).
- **Thread-confined writers.** `MP4Recorder` is always used from the queue that produces the samples.

## Tests

- `Tests/` — unit tests (RTSP auth/SDP/depacketizing, Profile G parsing, recorder matching, brand URLs, VIGI crypto)
  and the lockout scenarios (`LockoutTests`) against a simulated VIGI recorder, a fake RTSP server and a
  virtual clock: recorder offline for 2 minutes, wrong password, locked user, sign out offline/locked,
  switch user with live streams, cameras starting together with a wrong password.
- `scripts/regression.sh` — local bench (mediamtx + ffmpeg), mock VIGI NVR (`scripts/mock_nvr.py`), mock ONVIF
  NVR with Profile G and PTZ (`scripts/mock_onvif.py`), protocol tests with `vedetta-probe`, and the in-app
  self test (`Sources/Vedetta/SelfTest.swift`) in three languages; it drives the real windows with real mouse
  and key events (tile drag, playback shortcuts) and checks geometry (grid below the toolbar), capture
  resolutions, export tracks and settings persistence. See [developer-guide.md](developer-guide.md).
