# CLAUDE.md — smkvm

Native macOS client for the Supermicro / ATEN Java iKVM console (X8/X9/X10-era
BMCs). Replaces the `launch.jnlp` + Java Web Start path: it logs into the BMC
web UI, obtains the KVM session key itself, and speaks ATEN's RFB variant on
port 5900 directly.

## Build

This is a macOS app, so — unlike the Linux projects — it is built and tested
**on the Mac** (the machine it runs on; same principle as the cross-project
"build where it runs" rule).

```
swift build            # debug
swift test
scripts/bundle.sh      # release build → build/SMKVM.app
```

## Version

Single source: `VERSION` (also stamped into the app's Info.plist by
`scripts/bundle.sh`). Current: 0.1.0.

## Layout

- `Sources/SMKVMCore` — protocol: BMC HTTP login/session key, RFB/ATEN
  handshake, message parsing, video decoders, key mapping. No UI.
- `Sources/SMKVM` — AppKit app: host library (HostStore/HostsWindow/HostEditor),
  tabbed console windows (ConsoleWindowController/ConsoleView), Keychain.
- `Sources/smkvm-probe` — headless live-test CLI.
- `Tests/SMKVMCoreTests` — decoder and parser tests.
- `docs/protocol.md` — the ATEN protocol as implemented here.

## Test target

server1 BMC: 192.168.11.10 — ATEN firmware (c) 2010, RFB 003.008 on 5900,
security type 16.

## Work plan

- [x] Scaffold
- [x] Protocol spec (docs/protocol.md)
- [x] BMC HTTP login + session-key fetch
- [x] RFB/ATEN handshake
- [x] Hermon decoder (0x59/0x00, WPCM450 — server1)
- [x] AST2100 decoder (0x57 — X10 boards; synthetic tests only)
- [x] `smkvm-probe` CLI: login → handshake → first frame → PNG (live test tool)
- [x] HID key mapping, ATEN key/pointer messages, keep-alive, reconnect
- [x] Host library (multi-host), Keychain, tabbed consoles
- [x] Console view + input capture (UI side)
- [x] App bundle script

## Next

- [ ] **Live test on server1** — blocked on the BMC password being in the
  Keychain (`security add-generic-password -s smkvm.bmc -a ADMIN@192.168.11.10 -w`).
  Run `swift run smkvm-probe 192.168.11.10`; settle the UNVERIFIED items:
  0x37 length (2 vs 3, `--mouse-info-len`), 0x15 keep-alive acceptance
  (`--no-keepalive`), JNLP argument layout, wheel encoding (buttons bits 3/4).
- [ ] AST2100 live test on an X10 board.
- [ ] KVM-over-TLS (stunnel) for later X9 firmware.
- [ ] Virtual media (not started).
