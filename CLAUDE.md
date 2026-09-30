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

## Passwords and signing

BMC passwords live in `~/Library/Application Support/SMKVM/passwords.json`
(0600, `PasswordStore` in SMKVMCore, shared with smkvm-probe). **Owner
decision 2026-09-30: no Keychain** — its per-item access prompts were not
wanted; do not reintroduce it.

`scripts/bundle.sh` signs with the first Apple Development / Developer ID
identity (or `SMKVM_SIGN_IDENTITY`), falling back to ad-hoc.

## Version

Single source: `VERSION` (also stamped into the app's Info.plist by
`scripts/bundle.sh`). Current: 0.1.0.

## Layout

- `Sources/SMKVMCore` — protocol: BMC HTTP login/session key, RFB/ATEN
  handshake, message parsing, video decoders, key mapping. No UI.
- `Sources/SMKVM` — AppKit app: host library (HostStore/HostsWindow/HostEditor),
  tabbed console windows (ConsoleWindowController/ConsoleView).
- `Sources/SMKVMCore/PasswordStore.swift` — password file (shared with the probe).
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
- [x] Host library (multi-host), password file, tabbed consoles
- [x] Console view + input capture (UI side)
- [x] App bundle script

## Next

- [x] **Web API**: HTTP server in the app on all interfaces (owner: must be
  reachable from stormcentral, 192.168.8.170), token auth, **no power
  endpoint** (owner decision) (8765, `HTTPServer` in core on NWListener, `APIController` in
  the app routing to console windows on the main actor). Endpoints: hosts +
  status, screen.png (with wait-for-change), type text, keys/chords, mouse,
  power, connect/disconnect, screen-log listing; small HTML page at `/`.
  Purpose: let Claude drive and watch consoles (input + output).

- [x] **Dell iDRAC support**: PowerEdge R230, iDRAC8 fw 2.86,
  Enterprise licence, 192.168.11.151. Dell's own console (5900) is
  proprietary/encrypted; use the iDRAC's built-in **VNC server** instead
  (`racadm set iDRAC.VNCServer.Enable 1`, port 5901, VNC password ≤ 8 chars,
  SSL off). Add a standard RFB client (VNC auth, Raw/CopyRect/Hextile,
  X11 keysyms) and a per-host device type (Supermicro ATEN | VNC).
  Done: r230 (192.168.11.151) configured — VNC enabled, password = login
  password, Timeout 10800. Live-verified: auth, Hextile video (Linux
  console), key input (Shift tap woke the console). Power via Redfish not
  yet exercised live.

- [x] **Screen log**: per-host "Log Screen on Clear" — save the
  last content frame as PNG on cls (screen goes uniform), mode change,
  no-signal and disconnect; dedup; ~/Pictures/SMKVM/<host>/<date>/.
  Core: ScreenLogger fed from the session thread (every update, not the
  coalesced UI frames). UI: Console menu toggle + open folder.

- [x] Live handshake on server1–8.g11.lo (X9 WPCM450) — login, JNLP,
  auth, ServerInit, keep-alive all verified; see protocol.md "Live results".
- [ ] **Live video/input test** — all eight hosts were powered off; needs a
  powered-on host (owner to power one on). Then settle:
  0x37 length (2 vs 3, `--mouse-info-len`), 0x15 keep-alive acceptance
  (`--no-keepalive`), JNLP argument layout, wheel encoding (buttons bits 3/4).
- [ ] AST2100 live test on an X10 board.
- [ ] KVM-over-TLS (stunnel) for later X9 firmware.
- [ ] Virtual media (not started).
