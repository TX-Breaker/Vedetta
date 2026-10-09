# Troubleshooting

| Problem | Cause and solution |
|---|---|
| "Vedetta cannot be opened because the developer cannot be verified" | Unsigned build. Right-click Vedetta in Applications → **Open** (once). Or `xattr -dr com.apple.quarantine /Applications/Vedetta.app`. |
| "Accessing saved passwords…" stays on screen | macOS is asking permission to read the Keychain (usually after an update of an unsigned build). Enter your Mac password and choose **Always Allow**. If you choose *Deny*, Vedetta shows the sign-in screen and attempts nothing. |
| Cameras never connect, "Network unreachable" | Local Network permission denied: System Settings › Privacy & Security › Local Network › enable **Vedetta**. |
| "The recorder refused the user name or password" | Password changed on the recorder, or wrong. Vedetta stopped every attempt. Sign in again from the sign-in screen (or Settings › Accounts). |
| "The recorder locked this user…" / the NVR buzzer sounds | Too many failed logins (possibly from other apps using the same user). Vedetta attempts nothing until the unlock time. Unlock the user on the recorder's own screen or restart it, then use a dedicated user — see [account-protection.md](account-protection.md). |
| "Recorder not reachable. Vedetta checks again at…" | The recorder does not answer (switched off, network problem, address changed). Vedetta checks it without the password with growing pauses; **Check Now** in the banner forces a check. The video comes back by itself. |
| Some tiles have black bars / are narrower | Their sub-stream is 4:3 (e.g. 640×480) while the tiles are 16:9. On the recorder set the camera's **sub-stream** to a 16:9 resolution (e.g. 640×360). Or Quality › Picture in the tiles › **Stretch**. **Fill** crops the edges, including the camera clock. |
| Connection log shows "session closed by the recorder" and a login almost every minute | Another app (VIGI mobile app, web interface, VIGI Security Manager…) is signed in with the same user and takes the session over. Vedetta spaces its logins out, but give Vedetta a user of its own. |
| "Device error 509 Bandwidth Limit Exceeded", or an HD tile showing the light stream with a gauge icon | The recorder's outgoing bandwidth limit is reached, so it refuses new HD streams (light streams usually still fit). Common causes: other viewers at the same time (mobile app, web interface, other computers), cloud upload, or sessions left open on the recorder after a network drop. Vedetta switches that tile to the light stream and tries HD again every 10 minutes; snapshots and recordings fall back to the available quality and tell you. Fix: close the other viewers, lower the camera's main-stream bitrate/resolution on the recorder, or restart the recorder. |
| Camera name not visible on the tiles | Quality › Camera names › **Always**. |
| "Access to this camera was refused" on one tile | The user has no permission for that camera. Grant it on the recorder or hide the camera (Devices). |
| Snapshot/recording quality | They always use the main (full-quality) stream. If a camera's main stream is low, raise it on the recorder. |
| No recordings in the calendar / "Cannot read the list of recordings" | ONVIF recorders need Profile G (recording search). Hikvision/Dahua without ONVIF: choose the brand in the advanced options; playback works by picking a time. Reolink/Uniview over RTSP: live view only. |
| Saved recording has no sound | "Include the audio" was off, or the camera does not record audio. |
| Settings seem lost | Settings are read field by field; a damaged file is kept as `settings.unreadable-….json` and the automatic backup `settings.json.bak` is used. You can also import an exported settings file (File › Import Settings…). See [settings-and-data.md](settings-and-data.md). |
| Something else | Settings › Accounts › Connection log shows every connection attempt with its error code. Attach it to an issue (remove addresses if you prefer). |
