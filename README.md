# smkvm

A native macOS console for older Supermicro BMCs (ATEN firmware) — no Java,
no `launch.jnlp`.

It logs into the BMC's web UI with your IPMI credentials, fetches a KVM
session key the same way the Java applet's JNLP does, and connects straight
to the BMC's ATEN-flavoured VNC service on port 5900.

## Build

```
scripts/bundle.sh
open build/SMKVM.app
```

Requires macOS 14+ and Xcode / Swift 6.

## Status

Early development — see `CHANGELOG.md`.
