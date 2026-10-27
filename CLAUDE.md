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
swift test             # swift-testing — Command Line Tools are enough, no Xcode
scripts/bundle.sh      # release build → build/SMKVM.app (embeds WebRTC.framework)
```

Tests are swift-testing, not XCTest, deliberately: XCTest.framework ships
only inside Xcode.app and this project must build and test with the CLT
alone. Don't add XCTest-based tests back.

## Passwords and signing

BMC passwords live in `~/Library/Application Support/SMKVM/passwords.json`
(0600, `PasswordStore` in SMKVMCore, shared with smkvm-probe). **Owner
decision 2026-09-30: no Keychain** — its per-item access prompts were not
wanted; do not reintroduce it.

`scripts/bundle.sh` signs with the first Apple Development / Developer ID
identity (or `SMKVM_SIGN_IDENTITY`), falling back to ad-hoc.

## Version

Single source: `VERSION` (also stamped into the app's Info.plist by
`scripts/bundle.sh`). Current: 1.2.0.

## Layout

- `Sources/SMKVMCore` — protocol: BMC HTTP login/session key, RFB/ATEN
  handshake, message parsing, video decoders, key mapping. No UI.
  `JetKVM.swift` (WebRTC session: login/setup, signaling, video →
  Framebuffer, JSON-RPC input; see docs/jetkvm.md) and
  `JetKVMDiscovery.swift` (subnet sweep) live here; the WebRTC stack is
  the stasel/WebRTC binary package, pinned exact in Package.swift.
- `Sources/SMKVM` — AppKit app: host library (HostStore/HostsWindow/HostEditor),
  tabbed console windows (ConsoleWindowController/ConsoleView).
- `Sources/SMKVMCore/PasswordStore.swift` — password file (shared with the probe).
- `Sources/smkvm-probe` — headless live-test CLI.
- `Tests/SMKVMCoreTests` — decoder and parser tests.
- `docs/protocol.md` — the ATEN protocol as implemented here.

## Test lab

Verified against 8 × Supermicro X9 boards (WPCM450 BMC, ATEN firmware
"(c) 2010", RFB 003.008 on 5900, security type 16), 1 × Dell PowerEdge
R230 (iDRAC8 2.86, Enterprise, built-in VNC server on 5901) and 1 × JetKVM
(firmware 0.5.9: setup, login, 1080p60 video, input). Lab addresses,
credentials and the API-token distribution are kept outside this repo (the
repo is public) — never commit them.

## Work plan

- [x] Scaffold
- [x] Protocol spec (docs/protocol.md)
- [x] BMC HTTP login + session-key fetch
- [x] RFB/ATEN handshake
- [x] Hermon decoder (0x59/0x00, WPCM450) — live-verified (POST, BIOS setup, EFI shell, Linux console)
- [x] AST2100 decoder (0x57 — X10 boards; synthetic tests only)
- [x] `smkvm-probe` CLI: login → handshake → first frame → PNG (live test tool)
- [x] HID key mapping, ATEN key/pointer messages, keep-alive, reconnect — keyboard live-verified
- [x] Host library (multi-host), password file, tabbed consoles
- [x] Console view + input capture (UI side)
- [x] App bundle script
- [x] **Screen log**: per-host "Log Screen on Clear" — saves the settled
  screen on cls, screen replacement (not scroll/growth), mode change,
  no-signal and disconnect; dedup; ~/Pictures/SMKVM/<host>/<date>/.
  ScreenLogger is fed from the session thread (every update, not the
  coalesced UI frames).
- [x] **Dell iDRAC support** via the iDRAC's built-in VNC server (Dell's own
  5900 console is proprietary/encrypted): standard RFB client (VNC auth,
  Raw/CopyRect/Hextile, X11 keysyms), per-host console type. Live-verified:
  auth, video, key input. Power via Redfish not exercised live.
- [x] **Web API**: token-authenticated HTTP server in the app on all
  interfaces, port 8765; **no power endpoint** (owner decision). BSD sockets
  — an NWListener version took ~2 s per 15 KB to remote clients; don't go
  back. Live-verified from a remote host: screen.png ~30 ms, MJPEG ~8 fps,
  401 without token, 409 on a closed console.

## Next

- [x] **JetKVM support** (2026-10-27, v1.1.0) — third console type
      `jetkvm` on the device's WebRTC console; in-app first-time setup;
      infrastructure-free subnet discovery (⌘D / `--discover` /
      `GET /api/discover`); fleet API (`POST /api/hosts`, `DELETE`);
      probe `--jetkvm`; bundle embeds WebRTC.framework; docs/jetkvm.md.
      Live-verified end to end on firmware 0.5.9 (1080p60, ~57 fps
      delivered, input accepted). GUI console not yet exercised by hand —
      the engine is the probe-verified path. Known nits: first frame can
      take a few seconds (device keyframe cadence); wheel direction on
      real hardware unconfirmed; `no video` state only affects the status
      line.
- [ ] Settle remaining UNVERIFIED protocol items (docs/protocol.md): 0x37
  length (2 vs 3, `--mouse-info-len`), wheel encoding (buttons bits 3/4),
  mouse on ATEN.
- [ ] AST2100 live test on an X10 board.
- [ ] KVM-over-TLS (stunnel) for later X9 firmware.
- [ ] Virtual media (not started).
