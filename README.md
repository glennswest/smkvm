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
- **Keys → Send Ctrl-Alt-Del** for the combos macOS would otherwise eat.

## Build

```
scripts/bundle.sh
open build/SMKVM.app
```

Requires macOS 14+ and Xcode / Swift 6.

## Status

Early development — see `CHANGELOG.md`.
