# Changelog

## [Unreleased]
<!-- New unreleased changes go here -->

## [v1.0.0] — 2026-09-30

First public release.

### Added
- **Supermicro / ATEN iKVM client** (X8/X9/X10-era BMCs), no Java: BMC web
  login (`login.cgi`), JNLP session-key fetch, ATEN RFB handshake (security
  type 16, pipelined ClientInit), ATEN server messages, keep-alive, idle
  watchdog, handshake timeouts, screen-off polling at 1 Hz, auto-reconnect
  with a fresh key and backoff, web logout.
- **Video decoders:** Hermon (Nuvoton WPCM450, encoding 0x59/0x00) —
  verified on real hardware; AST2100 (ASPEED, encoding 0x57, DCT + VQ) —
  synthetic tests only.
- **Standard VNC client** for BMCs with a built-in VNC server (Dell iDRAC8
  verified): RFB 3.3–3.8, VNC password auth, Raw / CopyRect / Hextile /
  DesktopSize, X11 keysyms; power via Redfish.
- **App:** host library (add/edit/remove, per-host console type, credentials
  pre-filled from the last host), consoles as native window tabs,
  `--connect <host>` launch argument, keyboard (USB HID mapping, stuck-key
  release on focus loss) and mouse, Keys menu (Ctrl-Alt-Del, Print Screen,
  Scroll Lock, Pause, Insert, F13), Power menu with confirmation; app menu
  shortcuts work while a console has focus.
- **Screen log** (per host, ⌘L): saves the last complete screen when it is
  cleared, replaced (not scrolled or still being drawn), changes video mode,
  loses signal, or the session ends; de-duplicated; `~/Pictures/SMKVM/`.
- **Web API** on port 8765, token-authenticated: host status,
  connect/disconnect, screen PNG/JPEG with wait-for-change, MJPEG live view,
  text and key-chord input, mouse, screen-log control and listing, plus a
  browser page. No power control by design. Served on kernel sockets
  (~3 ms per screenshot to a remote client).
- **`smkvm-probe`** CLI: headless session with protocol log and frame
  capture (`--vnc`, `--tap-hid`, `--save-every`, `--power`).

### Changed
- BMC passwords are kept in `~/Library/Application Support/SMKVM/passwords.json`
  (mode 0600) rather than the Keychain, whose per-item prompts were too
  intrusive.
- `scripts/bundle.sh` signs with a stable Apple Development / Developer ID
  identity when available; the app allows plain-HTTP BMC web UIs.
- Bundle identifier `io.github.glennswest.smkvm`.

### Documentation
- `docs/protocol.md` — the ATEN iKVM protocol as implemented, with results
  from real hardware.
- `docs/api.md` — web API reference.
- README for public release; MIT license.
