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
- `KVMClient` is currently a stub with the final interface; the protocol
  implementation replaces its bodies.
- `Tests/SMKVMCoreTests` — decoder and parser tests.
- `docs/protocol.md` — the ATEN protocol as implemented here.

## Test target

server1 BMC: 192.168.11.10 — ATEN firmware (c) 2010, RFB 003.008 on 5900,
security type 16.

## Work plan

- [x] Scaffold
- [x] Protocol spec (docs/protocol.md)
- [ ] BMC HTTP login + session-key fetch
- [ ] RFB/ATEN handshake
- [ ] Hermon decoder (0x59/0x00, WPCM450 — server1)
- [ ] AST2100 decoder (0x57 — X10 boards)
- [ ] `smkvm-probe` CLI: login → handshake → first frame → PNG (live test tool)
- [ ] HID key mapping, ATEN key/pointer messages, keep-alive, reconnect
- [x] Host library (multi-host), Keychain, tabbed consoles
- [x] Console view + input capture (UI side)
- [ ] App bundle script

## In progress (2026-09-30)

Implementing SMKVMCore protocol per docs/protocol.md §10: BMCWeb (login.cgi,
jwsk JNLP, logout), Socket (blocking POSIX, TCP_NODELAY), KVMClient session
thread, HermonDecoder, KeyMap. Then probe CLI and live test on server1;
then AST2100.

Open questions to settle live (see protocol.md UNVERIFIED): server msg 0x37
length (2 vs 3), whether 0x15 keep-alive is accepted on 2010 firmware, JNLP
argument layout, wheel encoding.
