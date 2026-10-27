# Changelog

## [Unreleased]
<!-- New unreleased changes go here -->

## [v1.1.2] — 2026-10-27

### Fixed
- **Console sluggish on JetKVM (60 fps) consoles.** Three fixes:
  the view now hands frames to Core Animation (`layer.contents`, GPU
  scaling) instead of a CPU CoreGraphics blit into the Retina backing
  store on every frame; move-only mouse reports are coalesced to ~125 Hz
  with a trailing flush (macOS delivers mouseMoved at the mouse's polling
  rate, and flooding the device's HID queue lagged the cursor); the
  screen logger, when enabled, analyses at most 10 frames/s on JetKVM
  consoles instead of all 60.

## [v1.1.1] — 2026-10-27

### Fixed
- **JetKVM host saved with an empty password** now fails with "the device
  has a password — edit this host and enter it" instead of the opaque
  "signaling: there was a bad response" from the rejected WebSocket
  upgrade (an empty password means noPassword mode; the device is probed
  to tell the two apart).

## [v1.1.0] — 2026-10-27

### Added
- **JetKVM console support** — a third console type beside ATEN and VNC,
  speaking the device's native WebRTC console: local-auth login, WebSocket
  signaling (base64 JSON SDP offer/answer, trickle ICE), H.264 video via
  libwebrtc (stasel/WebRTC 154.0.0, VideoToolbox) painted into the shared
  Framebuffer — ConsoleView, ScreenLogger and the web API work unchanged.
  Input as JSON-RPC over the `rpc` data channel (`keyboardReport`,
  `absMouseReport` 0–32767, `wheelReport`); Power menu drives
  `setATXPowerAction` (needs the ATX extension); HDMI input state surfaces
  as "no video: no signal". Live-verified on firmware 0.5.9:
  1920×1080@60, ~57 fps delivered, input accepted. (docs/jetkvm.md)
- **First-time device setup in the connect path** — a JetKVM reporting
  `isSetup: false` is set up in local-password mode with the host's
  password, then logged into; factory-fresh devices just work.
- **JetKVM discovery with no infrastructure** — `JetKVMDiscovery` sweeps
  the local /24s (HTTP fingerprint of `/device/status`; the device offers
  no DNS-SD service to browse): **Connection → Discover JetKVMs** (⌘D)
  adds all new devices with one shared password; `smkvm-probe --discover
  [a.b.c]`; `GET /api/discover?subnet=a.b.c`.
- **Fleet web API** — `POST /api/hosts` (add/update a host, password into
  the password store) and `DELETE /api/hosts/{h}`, so tens of devices
  sync from a script; host `console` field now reports `jetkvm`.
- **Probe** — `--jetkvm` mode for the headless live test.

### Changed
- **Tests migrated from XCTest to swift-testing** — `swift test` now runs
  with the Command Line Tools alone (XCTest ships only inside Xcode); all
  37 tests pass.
- **`scripts/bundle.sh` embeds WebRTC.framework** in SMKVM.app (Contents/
  Frameworks + rpath), signing it with the app's identity.

### Fixed
- **JetKVM frames decoded but never rendered** — the remote RTCVideoTrack
  wrapper must be retained; its dealloc detaches the renderer adapters.

### Build
- `scripts/release.sh` builds the downloadable app: universal
  (arm64 + x86_64), ad-hoc signed, zipped without extended attributes,
  with a SHA-256 checksum. `scripts/bundle.sh` gains `SMKVM_UNIVERSAL`
  and `SMKVM_OUT`. (2026-09-30)

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
