# Settings and data

Where Vedetta keeps things, how settings survive updates, and how to back them up or move them.

## Where

| What | Where |
|---|---|
| Devices and cameras (no passwords) | `~/Library/Application Support/Vedetta/devices.json` |
| Preferences | `~/Library/Application Support/Vedetta/settings.json` |
| Live layout (grid, tile order, page) | `~/Library/Application Support/Vedetta/layout.json` |
| Export queue | `~/Library/Application Support/Vedetta/exports.json` |
| Pinned device certificates | `~/Library/Application Support/Vedetta/trusted-certificates.json` |
| Connection log | `~/Library/Application Support/Vedetta/Logs/connections.log` (+ `connections.1.log`) |
| Passwords | macOS Keychain, service `it.vedetta.devices`, one item per device (account = device ID) |
| Interface language, last section | `defaults read it.vedetta.app` (`AppleLanguages`, `VedettaLanguageOverride`, `LastSection` — the last one is never read or written by test runs) |
| Snapshots | `~/Pictures/Vedetta` (Settings › Folders) |
| Live recordings / exports | `~/Movies/Vedetta/<Recordings>` and `~/Movies/Vedetta/<Exports>` (folder names in the interface language) |

Settings › Advanced › Configuration › *Show in Finder* opens the folder.

## How settings are kept

- **Saved on every change**, atomically (write to a temporary file, then rename), off the main thread; pending
  writes are flushed when the app quits.
- **Read field by field.** Every value has a default: a file written by an older or newer version, a value of
  the wrong type or an unknown option never makes the whole file unreadable — only that field falls back to its
  default. Example: the 1.0 "Fill the tiles" switch becomes *Picture in the tiles: Fill*.
- A device with a damaged camera entry keeps its other cameras.
- **Automatic backup**: at the first save of each launch the previous file is copied to `<name>.json.bak`.
- **Damaged file**: it is moved aside as `<name>.unreadable-<date>.json` (kept for inspection) and the `.bak`
  is used instead.

## Export and import

**File › Export Settings…** (or Settings › Advanced › *All settings and devices › Export…*) writes one JSON file:

```json
{
  "format": "it.vedetta.settings",
  "version": 1,
  "appVersion": "1.0.0",
  "exportedAt": "2026-09-29T21:00:00Z",
  "language": "en",
  "settings": { "tileFit": "stretch", "tileLabels": "always", "exportAudio": true, "…": "…" },
  "layout":   { "grid": "eight", "slots": ["<channel id>", null, "…"], "page": 0 },
  "devices":  [ { "id": "…", "kind": "vigiNVR", "host": "192.168.1.100", "username": "viewer", "channels": [ … ] } ]
}
```

- **No passwords** (they stay in the Keychain) and no session tokens. The file does contain addresses, user
  names and camera names: keep it private.
- **File › Import Settings…** replaces devices, cameras, layout and preferences after a confirmation. Devices whose
  password is not in this Mac's Keychain show the sign-in screen: nothing is attempted with an empty password.
- Moving to a new Mac: export on the old one, import on the new one, sign in once per device.

## Reset

Quit Vedetta, then remove `~/Library/Application Support/Vedetta` (and, if you want, the Keychain items of service
`it.vedetta.devices` with Keychain Access). Snapshots, recordings and exports in your folders are not touched.

## Development and tests never touch this data

Test and development runs (`VEDETTA_DEV=1`, command line tools, `swift test`, the regression suite) use
`~/Library/Application Support/Vedetta-Dev`, the Keychain service `it.vedetta.devices.dev`, media folders inside
`Vedetta-Dev`, and never post notifications.
