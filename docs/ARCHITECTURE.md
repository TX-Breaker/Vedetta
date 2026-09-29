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
VedettaCore   Models and persistence (JSON + Keychain), DeviceConnector (VIGI / ONVIF / RTSP brands),
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
- **Thread-confined writers.** `MP4Recorder` is always used from the queue that produces the samples.

## Tests

- `Tests/` — unit tests (RTSP auth/SDP/depacketizing, Profile G parsing, recorder matching, brand URLs, VIGI crypto)
  and the lockout scenarios (`LockoutTests`) against a simulated VIGI recorder, a fake RTSP server and a
  virtual clock: recorder offline for 2 minutes, wrong password, locked user, sign out offline/locked,
  switch user with live streams, cameras starting together with a wrong password.
- `scripts/regression.sh` — local bench (mediamtx + ffmpeg), mock VIGI NVR (`scripts/mock_nvr.py`), mock ONVIF
  NVR with Profile G and PTZ (`scripts/mock_onvif.py`), protocol tests with `vedetta-probe`, and the in-app
  self test (`Sources/Vedetta/SelfTest.swift`) in three languages.
