# smkvm

A native macOS console for older Supermicro BMCs (ATEN firmware) — no Java,
no `launch.jnlp`.

It logs into the BMC's web UI with your IPMI credentials, fetches a KVM
session key the same way the Java applet's JNLP does, and connects straight
to the BMC's ATEN-flavoured VNC service on port 5900.

## Using it

- **Hosts** window (⌘0) lists saved BMCs. Add one with ⌘N: name, BMC address,
  IPMI user and password. Passwords are kept in
  `~/Library/Application Support/SMKVM/passwords.json` (readable only by you;
  deliberately not the Keychain, to avoid its access prompts).
- Double-click a host, or select several and press Connect. Each console
  opens as a tab; drag a tab out for its own window.
- `open SMKVM.app --args --connect server1` opens a saved host's console at
  launch (by name or address; repeatable).
- **Console → Log Screen on Clear** (⌘L, remembered per host) saves a PNG
  every time the screen is cleared — the last screen that had content on it,
  not the blank one — plus on video-mode changes, loss of signal and
  disconnect. Files: `~/Pictures/SMKVM/<host>/<date>/HHmmss.SSS-<reason>.png`
  (reason is `cls`, `screen-change`, `mode-change`, `no-signal` or
  `disconnect`). `screen-change` covers a clear-and-redraw too fast for the
  BMC to show a blank frame, and full repaints; scrolling doesn't count. ⇧⌘L opens
  the folder.
- **Keys → Send Ctrl-Alt-Del** for the combos macOS would otherwise eat.

## Web API

SMKVM serves a token-protected HTTP API and a browser page on port 8765 so
a remote agent can watch consoles and type into them live — see
[`docs/api.md`](docs/api.md). Connection → Web API… shows the URL and token.

## Build

```
scripts/bundle.sh
open build/SMKVM.app
```

Requires macOS 14+ and Xcode / Swift 6.

## Supported BMCs

| BMC chip | Typical boards | Video |
|---|---|---|
| Nuvoton WPCM450 ("Hermon") | X8, most X9 | encoding 0x59 — supported |
| ASPEED AST2100/2300/2400 | X10 | encoding 0x57 — supported (untested live) |
| Dell iDRAC8 (Enterprise) | PowerEdge 13G (e.g. R230) | built-in VNC server — supported |

### Dell iDRAC

Dell's own virtual console (port 5900) is proprietary and encrypted; SMKVM
uses the iDRAC's built-in VNC server instead (needs an Enterprise licence).
Enable it once:

```
racadm set iDRAC.VNCServer.Password <up to 8 chars>
racadm set iDRAC.VNCServer.Enable 1
racadm set iDRAC.VNCServer.Timeout 10800
```

Add the host with **Console: VNC**, port 5901, the iDRAC login as user and
the VNC password as password (the Power menu uses Redfish with the same
user/password, so keep the VNC password equal to the login password). The
iDRAC takes 6–11 s to accept a VNC session and allows one at a time.

Later X9 firmware that wraps the KVM port in TLS ("KVM SSL" on) is not
supported yet; turn KVM SSL off in the BMC web UI.

## Live test from the terminal

```
swift run smkvm-probe 192.168.11.10 ADMIN --seconds 15 --png server1.png
```

Uses `$SMKVM_PASSWORD` or the app's password file. Prints the handshake and
protocol log and saves the first frame.

## Status

Early development — see `CHANGELOG.md` and `docs/protocol.md`.
