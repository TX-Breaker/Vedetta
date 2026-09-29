# Vedetta — User guide

Vedetta is a native Mac app to watch security cameras live, review the recordings of network video recorders
(NVRs) and save them on the Mac. This guide covers every feature.

---

## 1. Installation

1. Open `Vedetta-x.y.z-macOS.dmg` and drag **Vedetta** to **Applications**.
2. First launch: if macOS says it cannot verify the developer, right-click Vedetta → **Open** (only once;
   signed and notarized builds do not ask).
3. Allow **Local Network** access when macOS asks: without it Vedetta cannot reach cameras and recorders.
4. If macOS asks to use a **Keychain** password, enter your Mac password and choose **Always Allow**. With
   unsigned builds this comes back after each update.

Requirements: Apple Silicon Mac, macOS 26 or later.

## 2. Connecting a device

On first launch Vedetta asks **what you want to connect**; later use **File › Add device…** (⌘N) or
**Add device** at the bottom of the sidebar.

| Choice | For |
|---|---|
| **VIGI NVR** | TP-Link VIGI recorders: live view, recordings, events and notifications |
| **Other NVR brands** | Hikvision, Dahua, Reolink, Uniview and any ONVIF NVR |
| **ONVIF camera** | ONVIF cameras of any brand, including motorized (PTZ) ones |
| **RTSP address** | Any `rtsp://…` stream |

- Devices **found automatically** on the network are listed at the top: one click fills the form.
- Enter **address**, **user** and **password**. **Advanced options** change the ports (HTTPS, RTSP), the ONVIF
  service address and, for other brands, the brand (needed when the NVR has no ONVIF: live view and, for
  Hikvision/Dahua, recordings then work over RTSP).
- **Use a dedicated user** instead of `admin`: create a user on the recorder with live view and playback
  permissions only. If the admin account got locked you would also lose the recorder management. The form warns
  you when you type `admin`.

## 3. Live view

- **Layout**: 1, 4, 6 (1+5), 8 (1+7), 9 or 16 tiles (grid button in the toolbar, or **View › Layout**). With more
  cameras than tiles, change **page** with the toolbar arrows or ⌥⌘← / ⌥⌘→; the **automatic tour** (⌥⌘T) pages by itself.
- **Put a camera in a tile**: drag it from the sidebar, or click an empty tile → choose.
- **Rearrange tiles**: drag a tile onto another → the two cameras **swap**; onto an empty tile → it moves there.
- **Enlarge**: double-click a tile (again to go back to the grid).
- **Digital zoom**: pinch on the trackpad; drag to move around the enlarged picture.
- **Tile buttons** (on hover): audio, snapshot, record, PTZ, enlarge.
- **Context menu** (right-click): snapshot, record, review the last hour, open in a new window (for another
  monitor), remove from tile.
- **Quality** (sliders button in the toolbar):
  - *Quality*: Automatic (light stream in small tiles, high quality when enlarged), High, Low.
  - *Picture in the tiles*: **Whole picture** (black bars when shapes differ), **Fill** (crops the edges),
    **Stretch** (fills without cropping, slightly distorted).
  - *Camera names*: **Always**, **When the pointer is over the tile**, **Never**.
  - *Show video information*: codec, resolution, frame rate, bitrate, HD/SD.
- **Snapshots and recordings** always use the **full-quality** (main) stream of the camera, even when the tile
  shows the light one. Folders: Settings › Folders.
- **PTZ**: on motorized cameras, PTZ button → joystick, zoom, speed, saved positions.
- Streams pause when the window is not visible (saves CPU) and resume by themselves.

> **Black bars on some cameras?** Their sub-stream is 4:3 (e.g. 640×480) while the tiles are 16:9. Best fix: on
> the NVR, set those cameras' sub-stream to 16:9 (e.g. 640×360). Otherwise choose *Stretch*. *Fill* crops the
> edges — and the camera clock with them.

## 4. Recordings

1. On the left pick the **day** in the calendar (days with recordings are marked) and up to **4 cameras** of the
   same recorder: they play **synchronized**.
2. The **timeline** shows 24 hours: one lane per camera (continuous recording, events, alarms), coloured events
   on top, the playhead. **Click** a moment to jump there.
3. Controls: previous/next event, −10 s, play/pause, +10 s, next frame, speed (0.5×–16× when the NVR supports
   it), snapshot.
4. **Events of the day** (left): filters for motion, people, vehicles, lines and intrusions, areas, other. Click
   an event to review it; right-click → *Export this event*.

### Zooming and scrolling the timeline

- **Mouse wheel** over the timeline: **zoom around the pointer**; **Shift + wheel** (or horizontal wheel /
  two-finger swipe) scrolls. Settings › Video › Recordings can swap them: wheel scrolls, ⌘ + wheel zooms.
- **24h / 6h / 1h / 10m** buttons on the right of the timeline.
- Under the timeline: **zoom −/+**, **move ‹ ›**, **center on the playhead** and **Keyboard shortcuts**.

Everything works **with one hand**: mouse only (wheel + buttons) or keyboard only (single keys, no chords).
Full list: [keyboard-shortcuts.md](keyboard-shortcuts.md).

### Saving recordings on the Mac

- **Save on this Mac**: choose start, end and cameras.
- **Selection**: scissors → drag on the timeline, or **Start here / End here** (keys **I** / **O**) at the
  playhead, then **Save selection**.
- **Include the audio**: switch in the save window (remembered). Without audio the file is smaller.
- Video is copied **without re-encoding** (original H.264/H.265) into MP4. Progress, cancel, retry and resume
  after restart in the **Exports** section.

## 5. Events, notifications, album

- **Events**: detections of the day with filters; click to open the moment in Recordings.
- **Notifications** (Settings › General): Vedetta checks events every minute and notifies you; click the
  notification to review the moment.
- **Album**: snapshots and recordings made on this Mac.

## 6. Devices and accounts

- **Devices** (bottom of the sidebar): per recorder refresh the camera list, open the web interface (all NVR
  settings), edit credentials, **Switch User…**, **Sign Out…**, remove. Per camera: rename, show/hide.
- **Sign Out** (Vedetta menu, Settings › Accounts, device card): closes the video, ends the session on the NVR,
  deletes the saved password and shows the sign-in screen, where you can enter another address, user or
  password. Works with the NVR offline or the user locked (then only the local state is cleared).
- **Switch User**: signs out completely, then asks for the new user.
- **Lockout protection**: Vedetta never repeats a refused password, makes one attempt at a time and, when the NVR
  does not answer, checks it without sending the password. Details: [account-protection.md](account-protection.md).
- **Connection log**: Settings › Accounts › Connection log (time, result, error code; never passwords).

## 7. Settings

| Tab | Content |
|---|---|
| General | Language (automatic, Italian, English, French), open at login, menu bar, notifications, Touch ID lock |
| Accounts | User of each device, Switch User, Sign Out, dedicated-user advice, connection log |
| Video | Quality, picture in the tiles, camera names, video information, automatic tour; Recordings: mouse wheel, audio in saved recordings |
| Folders | Snapshots, live recordings, exports |
| Advanced | Device certificates, cache, configuration folder, **export/import all settings**, about |

Settings are **saved automatically** on every change. **File › Export Settings…** writes a file with devices,
cameras, layout and preferences (no passwords); **File › Import Settings…** restores it, also on another Mac.
Details: [settings-and-data.md](settings-and-data.md).

## 8. Menu bar and lock

- With "Keep running in the menu bar when the window is closed" Vedetta keeps working (notifications, exports)
  with the window closed; the menu bar icon opens the sections.
- "Lock the app with Touch ID or your Mac password" asks for it when the app opens.

## 9. Problems

See [troubleshooting.md](troubleshooting.md): permissions, Keychain, black bars, locked user, NVR offline,
recordings not found, restoring settings.
