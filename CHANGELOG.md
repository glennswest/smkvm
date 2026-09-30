# Changelog

## [Unreleased]

### 2026-09-30
- **chore:** MIT license.
- **BREAKING:** Bundle identifier is now `io.github.glennswest.smkvm`; settings saved under the previous ID must be copied with `defaults export <old-id> - | defaults import io.github.glennswest.smkvm -`.
- **docs:** README rewritten for public release (features, supported BMCs, credentials trade-off, iDRAC setup, web API, build, acknowledgements); lab-specific addresses removed from the repo.
- **docs:** API clients read the token from `SMKVM_API` in `~/.env`.
- **perf:** Web API server rewritten on BSD sockets: the Network.framework (NWListener) version took ~2 s to deliver a 15 KB screenshot to a remote client (0.25 s to first byte), the kernel-socket version ~3 ms.
- **fix:** A BMC that accepts the TCP connection but never completes the handshake (e.g. iDRAC still holding a previous VNC session) no longer leaves the console stuck on "connecting": handshakes time out (15 s ATEN, 20 s VNC) and the session retries.
- **feat:** Web API and browser page on port 8765 (all interfaces), token-authenticated (`Authorization: Bearer` or `?token=`; token in `~/Library/Application Support/SMKVM/api-token`, shown by **Connection → Web API…**). Hosts and status, connect/disconnect, screen PNG/JPEG with wait-for-change, MJPEG live stream, type text, key chords, mouse, screen-log toggle and listing. No power control by design. See `docs/api.md`.
- **fix:** `screen-change` captures could be half-drawn: a screen still filling up with text (e.g. the EFI shell's mapping table) counted as "replaced", and an early partial frame was saved. Replacement now requires old content to be erased or overwritten, or most of the old background painted over; added text just updates the reference screen, so the saved image is the fully drawn screen. `cls` and mode-change saves also use that settled screen.
- **feat:** Standard VNC console support for BMCs with a built-in VNC server (Dell iDRAC8 tested): RFB 3.3–3.8, VNC password auth (DES), Raw / CopyRect / Hextile / DesktopSize, X11 keysyms from HID usages. Per-host **Console** type (Supermicro ATEN | VNC + port) in the host editor and a Console column in the Hosts list.
- **feat:** Power menu on VNC hosts uses Redfish (`ComputerSystem.Reset`) with the host's web credentials.
- **feat:** `smkvm-probe --vnc PORT` and `--tap-hid HEX`.
- **fix:** Screen log missed clears that the BMC never showed as a blank frame (clear-and-redraw within one update, or a full repaint such as POST → setup). It now also saves the previous screen when most of its content is replaced (`-screen-change.png`); scrolling, typing, highlights and cursor blink don't count. Duplicate detection ignores cursor-sized differences.
- **BREAKING:** Passwords no longer use the Keychain (its "SMKVM wants to access key…" prompts kept appearing). They are stored in `~/Library/Application Support/SMKVM/passwords.json`, mode 0600, keyed `user@host`; removing a host removes its password. Passwords previously saved in the Keychain are not migrated — re-enter them in the host editor.
- **build:** `scripts/bundle.sh` signs with a stable identity (Apple Development, override `SMKVM_SIGN_IDENTITY`) instead of ad-hoc.
- **feat:** Adding a host pre-fills the user and password from the last host saved.
- **feat:** Screen log — per-host **Console → Log Screen on Clear** (⌘L) saves a PNG of the last screen with content whenever it is cleared (cls), the video mode changes, the signal drops or the session ends; identical screens are saved once. Files go to `~/Pictures/SMKVM/<host>/<date>/HHmmss.SSS-<reason>.png`; **Show Screen Log in Finder** (⇧⌘L). The window title counts screens logged.
- **fix:** App menu shortcuts work while the console has focus (other Cmd-combos still go to the host).
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
