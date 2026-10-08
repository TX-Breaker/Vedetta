# Recorder accounts and lockout protection

Recorders lock a user — and often sound their buzzer — after a few failed logins (TP-Link VIGI: 5 consecutive
failures). A camera app that retries in a loop when the network drops, or that logs in once per camera, can lock
the account by itself. Vedetta is built so that this cannot happen. This page explains what it does and why.

## What Vedetta guarantees

| Situation | Behaviour |
|---|---|
| Launch | One check per device, with a request every user may make (VIGI: the API login; ONVIF: `GetDeviceInformation`). Video streams wait for its result. |
| Credentials not confirmed yet | Only **one** operation that sends the password runs at a time; all the others wait for its result. |
| Network down / recorder not answering | **No login at all.** A password-free check confirms it is down, then it is re-checked after 5 s, 10 s, 20 s… up to 5 minutes (±20 % jitter). When it answers again the **existing session is reused**. |
| Password refused | **Everything stops** immediately: no automatic attempt until you sign in again or press *Try Again* (one attempt). Sign-in screen + notification. |
| User locked by the recorder | Everything stops. If the recorder says when it unlocks, Vedetta waits until then and makes **one** attempt; otherwise it waits for you. |
| Password not available (Keychain access denied) | Nothing is attempted — never a login with an empty password. Sign-in screen. |
| One camera refuses the video (user without permission for it) | Only that camera stops; Vedetta first checks with a request every user may make that the password itself is still valid. |
| Sessions keep being closed soon after the login (same user signed in from another app) | No ping-pong of logins: new logins are spaced out 5 s, 10 s, 20 s… up to 5 minutes, and the log says "closed by the recorder … same user signed in elsewhere?". Give Vedetta its own user. |
| Several features at once | One shared session per recorder for live view, recordings, events and exports. |

RTSP video needs its own authentication for each stream (the protocol cannot reuse the web session). Streams start
only after the credentials have been confirmed, never repeat a refused password (not even on the same connection),
and a refusal stops them.

## Sign out and switch user

**Sign Out** (Vedetta menu, Settings › Accounts, device card) — in this order:

1. stops every automatic attempt and reconnection of that device;
2. closes its video streams (RTSP `TEARDOWN`) and interrupts its running exports;
3. ends the session on the recorder (`logout`) — only if the recorder is reachable and the account usable,
   **never logging in to do so**; otherwise only the local state is cleared and the recorder lets the session expire;
4. deletes the saved password from the Keychain and the session token;
5. shows the sign-in screen (address, user and password can all be changed).

**Switch User** does exactly the same, then asks for the new user: no session is left open on the recorder.

At launch, if the saved credentials are refused, Vedetta does not retry: it shows the sign-in screen.

## Use a dedicated user

Create a user on the recorder just for Vedetta with **live view and playback** permissions only, and sign in with
it. Even though Vedetta never retries a refused password, a separate user keeps the admin account — and the
recorder's own apps (VIGI Security Manager, mobile app, web interface) — unaffected. Vedetta warns when the user
name is `admin` and when a VIGI recorder reports an administrator account.

- VIGI recorders: in the settings (web interface or local screen) open user management and add a user.
- ONVIF: an "Operator" or "User" level is enough.
- Cameras the user may not see simply stay dark in Vedetta; hide them in Devices.

## Connection log

Every attempt is written to `~/Library/Application Support/Vedetta/Logs/connections.log` (Settings › Accounts ›
Connection log), tab-separated: time, device, action, result, detail. Rotated at about 1 MB (`connections.1.log`).
Passwords and session tokens are never written. Example:

```
2026-09-29T20:47:57.406+02:00  NVR (192.168.1.100)  probe (no password)  unreachable  check after a failed request
2026-09-29T20:47:57.406+02:00  NVR (192.168.1.100)  state                offline      …
2026-09-29T20:56:16.201+02:00  NVR (192.168.1.100)  login viewer         rejected     … (4 attempts left before the lock)
2026-09-29T20:56:16.202+02:00  NVR (192.168.1.100)  state                rejected     …
```

Results: `ok`, `done`, `network`, `rejected`, `denied`, `locked Ns`, `reachable`, `unreachable`, states
`online`, `unverified`, `offline`, `rejected`, `locked`, `missing-password`, `signed-out`, and `suppressed` (how many
automatic attempts were *not* made while blocked).

## If the account is already locked

- Wait for the unlock time (on many recorders 30 minutes), or unlock the user from the recorder's own screen, or restart it.
- The buzzer of the recorder can be silenced from its local screen.
- Then open Vedetta: it makes a single check.

Implementation: `Sources/NetKit/AccessGuard.swift` (see [ARCHITECTURE.md](ARCHITECTURE.md)); tests:
`Tests/VedettaCoreTests/LockoutTests.swift` and the `resilience` self test (`scripts/regression.sh resilience`).
