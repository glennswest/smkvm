# smkvm

A native macOS console for older Supermicro BMCs (ATEN firmware) — no Java,
no `launch.jnlp`.

It logs into the BMC's web UI with your IPMI credentials, fetches a KVM
session key the same way the Java applet's JNLP does, and connects straight
to the BMC's ATEN-flavoured VNC service on port 5900.

## Using it

- **Hosts** window (⌘0) lists saved BMCs. Add one with ⌘N: name, BMC address,
  IPMI user and password (stored in the macOS Keychain).
- Double-click a host, or select several and press Connect. Each console
  opens as a tab; drag a tab out for its own window.
- `open SMKVM.app --args --connect server1` opens a saved host's console at
  launch (by name or address; repeatable).
- **Keys → Send Ctrl-Alt-Del** for the combos macOS would otherwise eat.

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

Later X9 firmware that wraps the KVM port in TLS ("KVM SSL" on) is not
supported yet; turn KVM SSL off in the BMC web UI.

## Live test from the terminal

```
swift run smkvm-probe 192.168.11.10 ADMIN --seconds 15 --png server1.png
```

Uses `$SMKVM_PASSWORD` or the app's Keychain item. Prints the handshake and
protocol log and saves the first frame.

## Status

Early development — see `CHANGELOG.md` and `docs/protocol.md`.
