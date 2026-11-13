# Vedetta documentation

Everything about Vedetta, for people who use it and for people who build it.

## Using Vedetta

| | |
|---|---|
| Complete user guide | [user-guide.md](user-guide.md) |
| Keyboard shortcuts | [keyboard-shortcuts.md](keyboard-shortcuts.md) |
| Problems and solutions | [troubleshooting.md](troubleshooting.md) |
| Recorder accounts and lockout protection | [account-protection.md](account-protection.md) |
| Where settings and files are kept, backup | [settings-and-data.md](settings-and-data.md) |

## Building and maintaining

| | |
|---|---|
| Build, run, test, translate, release | [developer-guide.md](developer-guide.md) |
| How the code is organized and why | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Copying the project to another computer | [moving-to-another-computer.md](moving-to-another-computer.md) |
| How Vedetta came to be | [STORY.md](STORY.md) |
| Version history | [CHANGELOG](../CHANGELOG.md) |
| Contributing, security, code of conduct | [CONTRIBUTING](../CONTRIBUTING.md) · [SECURITY](../SECURITY.md) · [CODE_OF_CONDUCT](../CODE_OF_CONDUCT.md) |

## Quick facts

- Native macOS app (Swift 6 toolchain, SwiftUI Liquid Glass, VideoToolbox hardware decoding), macOS 26+, Apple Silicon.
- Devices: TP-Link VIGI NVRs (JSON API + RTSP), ONVIF NVRs and cameras of any brand (Profile S/G, PTZ),
  Hikvision/Dahua/Reolink/Uniview recorders over RTSP, any RTSP stream.
- No accounts, no cloud, no telemetry. Passwords only in the macOS Keychain.
- The interface is available in English, Italian and French and follows the language of macOS (it can be changed
  in Settings).
