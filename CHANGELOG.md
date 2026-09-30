# Changelog

## [Unreleased]

### 2026-09-30
- **feat:** `--connect <host>` launch argument opens a saved host's console.
- **fix:** Screen-off no longer spins: the BMC answers each update request immediately with a screen-off rect, so polling now runs from the 1 s timer only.
- **feat:** `smkvm-probe --power on|off|reset|softoff` and `--save-every S`.
- **docs:** Live handshake results from server1–8 (X9 WPCM450) recorded in protocol.md.
- **feat:** ATEN iKVM protocol client (SMKVMCore): BMC web login (`login.cgi`, SID), JNLP ticket fetch with single-use RFB credentials, ATEN RFB handshake (security type 16, pipelined ClientInit), server message table, keep-alive, idle watchdog, screen-off polling, auto-reconnect with backoff, web logout.
- **feat:** Hermon video decoder (WPCM450, encoding 0x59/0x00) and AST2100 decoder (encoding 0x57, DCT + VQ).
- **feat:** USB HID keyboard mapping from macOS keycodes; 18-byte ATEN key/pointer events; stuck-key release on focus loss.
- **feat:** Keys menu (Print Screen, Scroll Lock, Pause, Insert, F13) and Power menu (on / reset / ACPI soft shutdown / off, with confirmation).
- **feat:** `smkvm-probe` — headless live test: logs the protocol and saves the first frame as PNG.
- **build:** App bundle allows plain-HTTP BMC web UIs (ATS exception).
- **docs:** `docs/protocol.md` — ATEN protocol spec used by the implementation.
- **feat:** Host library window — saved BMCs (name, address, user) with add/edit/remove; passwords in the Keychain; multi-select connect.
- **feat:** Consoles open as native window tabs, one per host; reconnecting a host focuses its existing console.
- **feat:** Console view (aspect-fit, mouse/wheel/keyboard capture), Keys menu with Ctrl-Alt-Del, `scripts/bundle.sh`.
- **chore:** Project scaffold — Swift package, AppKit app target, core library, docs.
