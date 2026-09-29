# Security Policy

## Supported versions

Security fixes are released for the latest minor version of Vedetta.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
[private vulnerability reporting](https://github.com/TX-Breaker/vedetta/security/advisories/new)
and include steps to reproduce. You will get an answer within 7 days.

## How Vedetta handles your data

- Device passwords are stored only in the macOS Keychain and are never written to disk, logs or crash reports.
- Self-signed device certificates are pinned on first use; a changed certificate blocks the connection.
- Vedetta connects only to the devices you add (and WS-Discovery on the local network). It has no
  accounts, cloud services, analytics or telemetry.
- Snapshots, recordings and exports are saved only to the folders you choose on your Mac.
