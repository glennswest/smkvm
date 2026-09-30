# SMKVM

A native macOS console for server BMCs — no Java, no `launch.jnlp`, no
browser plugins.

Older Supermicro boards (X8/X9/X10) only offer a Java Web Start KVM viewer
that barely runs on a modern Mac. SMKVM talks to the BMC directly: it logs
into the BMC's web UI, fetches the one-time KVM session key the Java
launcher would have used, and speaks ATEN's modified VNC protocol itself.
Dell iDRAC8 is supported through the iDRAC's built-in VNC server.

It also serves a small token-protected web API, so a script or an AI agent
on another machine can watch a console and type into it.

## Features

- **Supermicro / ATEN iKVM** — web login, session key, ATEN RFB handshake,
  video for both BMC families (see below), keyboard and mouse.
- **Dell iDRAC8** (and other standard VNC servers) — VNC password auth,
  Raw / CopyRect / Hextile, power via Redfish.
- **Many hosts** — a saved host list; each console opens as a native
  window tab. Reconnects automatically with a fresh session key.
- **Keys a Mac lacks** — Ctrl-Alt-Del, Print Screen, Scroll Lock, Pause,
  Insert, F13; ⌘-shortcuts go to the server except the app's own.
- **Power menu** — on / reset / ACPI shutdown / off, with confirmation.
- **Screen log** — optionally saves a PNG of each screen as it is cleared
  or replaced (e.g. every page of a BIOS or boot sequence).
- **Web API** — screenshots, wait-for-change, MJPEG live view, text and key
  input, mouse; token-authenticated. No power control by design.
- **`smkvm-probe`** — a headless CLI that runs a session, logs the protocol
  and saves frames; handy for new firmware.

## Supported BMCs

| BMC | Typical boards | Status |
|---|---|---|
| Nuvoton WPCM450 ("Hermon"), ATEN firmware | Supermicro X8, most X9 | supported, verified |
| ASPEED AST2100/2300/2400, ATEN firmware | Supermicro X10 | supported, tested on synthetic data only |
| Dell iDRAC8 Enterprise (built-in VNC server) | PowerEdge 13G, e.g. R230 | supported, verified |

Not supported yet: later X9 firmware with **KVM SSL** enabled (the KVM
port is wrapped in TLS) — turn KVM SSL off in the BMC web UI. Newer
Supermicro boards (X11+) have an HTML5 console and don't need this.

## Using it

- **Connection → Hosts** (⌘0) lists saved BMCs; **Add Host…** (⌘N) takes
  a name, BMC address, user, password and console type. A new host starts
  with the credentials of the last one you saved.
- Double-click a host (or select several and press Connect). Each console
  opens as a tab; drag it out for its own window.
- `open SMKVM.app --args --connect server1` opens saved hosts at launch
  (by name or address; repeatable).
- **Console → Log Screen on Clear** (⌘L, per host) saves the last complete
  screen whenever it is cleared or replaced, plus on video-mode changes,
  loss of signal and disconnect — scrolling and typing don't count. Files:
  `~/Pictures/SMKVM/<host>/<date>/HHmmss.SSS-<reason>.png`, reason one of
  `cls`, `screen-change`, `mode-change`, `no-signal`, `disconnect`.
  **Show Screen Log in Finder** is ⇧⌘L.

### Credentials

BMC passwords are stored in `~/Library/Application Support/SMKVM/passwords.json`,
readable only by your user (mode 0600). This is deliberately not the
Keychain: its per-item access prompts were more friction than lab BMC
credentials warrant. If that trade-off doesn't suit you, keep the file on
an encrypted volume or don't save passwords.

### Dell iDRAC

Dell's own virtual console is proprietary and encrypted, so SMKVM uses the
iDRAC's built-in VNC server (needs an Enterprise licence). Enable it once:

```
racadm set iDRAC.VNCServer.Password <up to 8 characters>
racadm set iDRAC.VNCServer.Enable 1
racadm set iDRAC.VNCServer.Timeout 10800
```

Add the host with **Console: VNC**, port 5901, the iDRAC login as user and
the VNC password as password. The Power menu uses Redfish with the same
user and password, so keep the VNC password equal to the login password.
The iDRAC takes several seconds to accept a VNC session and allows one at a
time.

## Web API

While the app runs it serves an HTTP API and a browser page on port 8765
(all interfaces; change with `defaults write io.github.glennswest.smkvm apiPort <n>`).
Every `/api` call needs the token from
`~/Library/Application Support/SMKVM/api-token` (created on first launch;
**Connection → Web API…** shows and copies it):

```
curl -H "Authorization: Bearer $TOKEN" http://<mac>:8765/api/hosts
curl -H "Authorization: Bearer $TOKEN" -o s.png "http://<mac>:8765/api/hosts/server1/screen.png?wait_change=5"
curl -H "Authorization: Bearer $TOKEN" -d '{"text":"ls -l\n"}' http://<mac>:8765/api/hosts/server1/type
curl -H "Authorization: Bearer $TOKEN" -d '{"keys":"ctrl+alt+delete"}' http://<mac>:8765/api/hosts/server1/key
```

The API is plain HTTP: anyone who can see the traffic can read the token.
Use it on a trusted network. Full reference: [`docs/api.md`](docs/api.md).

## Build

Requires macOS 14+ and Xcode / Swift 6.

```
swift build
swift test
scripts/bundle.sh          # release build → build/SMKVM.app
open build/SMKVM.app
```

`scripts/bundle.sh` signs with your first Apple Development / Developer ID
identity if you have one (override with `SMKVM_SIGN_IDENTITY`), otherwise
ad-hoc.

### Live test from the terminal

```
SMKVM_PASSWORD=… swift run smkvm-probe <bmc> ADMIN --seconds 15 --png out.png
swift run smkvm-probe <idrac> root --vnc 5901 --png out.png
```

The password comes from `$SMKVM_PASSWORD` or the app's password file. The
probe prints the handshake and protocol log and saves frames
(`--save-every S`); `--tap-hid e1` taps Shift to wake a blanked console.

## How it works

[`docs/protocol.md`](docs/protocol.md) documents the ATEN iKVM protocol as
implemented: the web login and JNLP session key, the security-type-16
handshake, ATEN's message set, the Hermon (WPCM450) tile format and the
AST2100 DCT/VQ codec, plus results from real hardware.

## Acknowledgements

The protocol notes were assembled from the work of people who reverse
engineered ATEN's iKVM before: kelleyk's and jimdigriz's noVNC ATEN
support, thefloweringash/aten-proxy, vdudouyt/decaffeine-ipmi,
tjone270/ATENtion, mkrasselt1/supermicro-kvm-html5 and
MishaProductions/AtenKVMClient. SMKVM's decoders are independent
implementations; the AST2100 quantisation tables are the ASPEED reference
values those projects also use.

## License

MIT — see [`LICENSE`](LICENSE).

## Status

Version 1.0.0 — in daily use on the hardware above. See
[`CHANGELOG.md`](CHANGELOG.md).
