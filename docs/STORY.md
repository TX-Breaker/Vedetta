# The story of Vedetta

*How a Mac user got tired of running Windows camera software in a box, and what it took to replace it.*

---

## 1. The itch

The house had a TP-Link VIGI recorder, a handful of VIGI cameras and one motorized camera.
The recorder works well. The software to watch it on a Mac did not exist: the official client, VIGI Security
Manager, is a Windows program. On the Mac it ran inside CrossOver, a Windows compatibility layer.

It worked, more or less. It also used **100–150 % of a CPU core and about 2 GB of memory** just to show a grid of
cameras, and the picture glitched. Every time it was opened the question was the same: *why does watching my own front door cost this much?*

The answer was not "optimize the Windows app". The answer was to start over, natively.

## 2. The rules we set on day one

Before the first line of code, a few decisions were written down and never reopened:

- **A complete native rewrite.** Swift, SwiftUI with the Liquid Glass look of macOS 26, AppKit where it is needed,
  VideoToolbox for hardware decoding. No code, files or assets from the original Windows software, ever. The
  original installation was treated as read-only and its saved passwords were never touched.
- **Talk to devices only through public, documented doors**: the recorder's own web interface API, RTSP and ONVIF.
- **Not a VIGI-only app.** Anyone with a Hikvision, Dahua, Reolink or Uniview recorder, or with ONVIF cameras of any
  brand, should be at home too. VIGI support stays first-class, but nothing in the interface assumes it.
- **No third-party runtime dependencies, no cloud, no accounts, no telemetry.** Passwords live only in the macOS
  Keychain, and the app talks only to devices on your network.

## 3. Building the engine

A camera app is mostly plumbing, so most of the work went into the plumbing.

- **RTSPKit**: an RTSP/RTP client written from scratch, over TCP, with Digest and Basic authentication, and
  depacketizers for H.264, H.265, AAC and G.711. It also understands the ONVIF replay extension that stamps every
  recorded frame with its real time.
- **MediaKit**: frames go straight from the network to `AVSampleBufferDisplayLayer`. The Mac's media engine
  decodes them, and the CPU only shuffles packets. Zoom is a layer transform, so it costs no pixel work. MP4 files
  are written **without re-encoding**: what the camera recorded is exactly what lands on your disk.
- **ONVIFKit** and **VigiKit**: WS-Discovery to find devices, SOAP with WS-Security, PTZ, Profile G for recordings
  on recorders of any brand, and the VIGI JSON API (with its RSA-encrypted login) for calendars, timelines and events.
- **VedettaCore**: one shared stream per camera however many windows show it, streams that pause when nothing is
  visible, synchronized playback of up to four cameras on one clock, and a persistent export queue.

The result: **sixteen cameras live at about 10–13 % CPU** on an Apple Silicon Mac, measured by the regression
suite, against a single core pegged by the old setup.

## 4. The day the recorder screamed

Then came the most instructive bug of the whole project.

One evening the real recorder **locked its admin account and started sounding its buzzer**. Nobody had typed a
wrong password. Vedetta had done it by itself.

The post-mortem was humbling, because no single piece was wrong; together they added up:

- the event monitor logged in once per camera every minute;
- every live stream retried its own login when the network hiccupped;
- channel discovery probed cameras in parallel, so one wrong password became eight failed logins at once;
- when macOS refused Keychain access after an update, the app tried to log in with an *empty* password;
- the VIGI firmware keeps a single login nonce, so two logins at the same moment made one of them fail.

The recorder, quite rightly, counted the failures and locked the door.

So we built **AccessGuard**: one guard per device, through which every operation that sends a password must pass.

- While the credentials are not confirmed, **only one** attempt runs; everything else waits for its result.
- **Network problems never cause logins.** An unreachable recorder is checked with password-free probes, at
  5 s, 10 s, 20 s… up to 5 minutes with jitter, and the existing session is reused when it comes back.
- **A refused password or a locked user stops everything** until you act. If the recorder says when it will
  unlock, Vedetta waits for exactly that moment and makes one attempt.
- **Never an empty password.** Missing password → sign-in screen, no attempt.
- **Sign Out** and **Switch User** that truly end the session on the recorder, and a local connection log
  (without passwords) that explains what happened and when.

Every scenario from that evening became a test against a simulated recorder with a virtual clock: recorder offline
for two minutes, wrong password, locked user, cameras starting together with a wrong password, a session taken
over by another app. That whole class of bug is now covered by tests that run on every change.

## 5. Testing without a camera

You cannot ask contributors to own an NVR, and you should not hammer a real one while testing. So the project
carries its own test bench:

- **mediamtx + ffmpeg** publish test streams laid out exactly like a VIGI recorder;
- **mock recorders** in Python: a VIGI JSON API with a single nonce, sessions and lockout after five failures,
  and an ONVIF NVR with Profile G recordings and PTZ;
- an **in-app self test** that drives the real windows with real mouse and keyboard events, in English, Italian and
  French: it drags tiles, plays, pauses, seeks, exports, checks capture resolutions, watches for UI freezes and
  memory, and verifies that settings survive a restart.

Development runs are fully isolated (their own data folder and Keychain service), a lesson learned when an early
test run sent fake notifications to the real app.

## 6. Polishing what people touch

With the engine stable, the work moved to the details that make an app pleasant every day:

- drag a tile onto another to swap cameras, and choose whether camera names show always, on hover or never;
- snapshots and recordings always at the camera's full resolution, even when the tile shows the light stream;
- a recordings view usable with one hand: single-key shortcuts, the mouse wheel zooming the timeline around
  the pointer, buttons for everything;
- settings that never get lost: saved as you go, readable across versions, with automatic backups and an
  export/import that never includes passwords;
- graceful behaviour when the recorder runs out of outgoing bandwidth (RTSP 509): the tile switches to the light
  stream, says so, and tries HD again ten minutes later.

## 7. How it was made

Vedetta was designed and built by one person, **TX-Breaker**, working with an AI pair-programmer.
The human set the goals, made the product calls and tested every version against a real
house full of cameras. The AI wrote and reviewed code, ran the test benches
and kept the project's decision log. Every change went through the same gate: build, unit tests, translation
check, and the regression suite against the simulated recorders.

## 8. Where it stands

- Version **1.0.0**, MIT licensed, English, Italian and French.
- About **14,000 lines of Swift** in seven libraries plus the app and a diagnostics tool, plus a test bench and **47 unit tests**, among them the
  lockout scenarios.
- TP-Link VIGI, ONVIF recorders and cameras of any brand, Hikvision, Dahua, Reolink and Uniview over RTSP, and any
  RTSP stream.

If it makes watching your own cameras on a Mac as light as it should be, it did its job. Issues, translations and pull requests are
welcome: see [CONTRIBUTING.md](../CONTRIBUTING.md).
