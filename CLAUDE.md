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
- `Sources/SMKVM` — AppKit app: connect window, console window/view, Keychain.
- `Tests/SMKVMCoreTests` — decoder and parser tests.
- `docs/protocol.md` — the ATEN protocol as implemented here.

## Test target

server1 BMC: 192.168.11.10 — ATEN firmware (c) 2010, RFB 003.008 on 5900,
security type 16.

## Work plan

- [x] Scaffold
- [ ] Protocol spec (docs/protocol.md)
- [ ] BMC HTTP login + session-key fetch
- [ ] RFB/ATEN handshake
- [ ] Video decoder(s) for the chip on server1
- [ ] Console view, keyboard + mouse input
- [ ] Connect window + Keychain
- [ ] App bundle script
