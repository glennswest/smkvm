# JetKVM, as implemented

How SMKVM speaks to a JetKVM (`Sources/SMKVMCore/JetKVM.swift`,
`JetKVMDiscovery.swift`). Verified against a real device on firmware 0.5.9:
first-time setup, login, 1920×1080@60 H.264 video (~57 fps delivered end to
end), keyboard report accepted. Sources of truth: the device firmware at
github.com/jetkvm/kvm (`web.go`, `webrtc.go`, `cloud.go`, `jsonrpc.go`).

## 1. Auth and first-time setup

Everything is plain HTTP on port 80.

- `GET /device/status` → `{"isSetup": bool}` — answers before setup and
  without auth. This is also the discovery fingerprint (§6).
- Device never set up: `POST /device/setup`
  `{"localAuthMode": "password", "password": …}` (8–72 chars). The reply
  carries the `authToken` cookie, like a login. SMKVM does this
  automatically when it meets an `isSetup: false` device, using the host's
  saved password.
- Normal login: `POST /auth/login-local` `{"password": …}` → 200 with a
  `Set-Cookie: authToken=…`. Repeated failures are rate-limited per IP
  (429 + Retry-After).
- An empty password means noPassword mode: no login, no cookie.

## 2. Signaling

`GET /webrtc/signaling/client`, upgraded to a WebSocket (the `authToken`
cookie must be on the upgrade request). JSON text messages, `{type, data}`:

| direction | type | data |
|---|---|---|
| device → client | `device-metadata` | `{deviceVersion}` — sent immediately; SMKVM starts the peer connection on it |
| client → device | `offer` | `{sd: base64(JSON {type:"offer", sdp})}` |
| device → client | `answer` | `base64(JSON {type:"answer", sdp})` |
| both ways | `new-ice-candidate` | `{candidate, sdpMid, sdpMLineIndex}` |

The device drops client candidates that arrive before its answer is out
(`currentSession` isn't set yet), so SMKVM queues local candidates and
flushes them after `setRemoteDescription`. Connectivity would survive the
drop anyway (peer-reflexive candidates from our STUN checks), but flushing
is cleaner. The WebSocket stays open for the life of the session and is
pinged every ~8 s.

## 3. The WebRTC session

libwebrtc (stasel/WebRTC, the packaged Google build) with unified plan.
Before the offer, SMKVM creates:

- data channel `rpc` — JSON-RPC 2.0, §4;
- a recv-only video transceiver;
- a recv-only audio transceiver — the device always attaches an audio
  track, and offering audio keeps the answer's m-line order valid.

The device picks H.264 (or H.265 when the offer carries it) and streams the
HDMI capture; VideoToolbox decodes. Decoded frames arrive through an
`RTCVideoRenderer` attached to the remote video track and are converted
(vImage, BT.709, NV12/I420/BGRA pixel buffers) into the shared
`Framebuffer`, so ConsoleView, the ScreenLogger and the web API behave
exactly as for ATEN/VNC consoles.

**Pitfall (cost: frames decoded, none rendered):** the `RTCVideoTrack`
obtained from `pc.transceivers` is a wrapper whose dealloc detaches its
renderer adapters. Keep a strong reference to the track for the session.

One session at a time: a second client (the web UI, cloud) taking over
makes the device send the `otherSessionConnected` RPC event and close the
old peer connection. SMKVM reports it and stops, instead of reconnecting
into a takeover war.

## 4. Input and state — JSON-RPC over `rpc`

`{"jsonrpc":"2.0","method":…,"params":{…},"id":n}`; events from the device
are notifications (no id).

| method | params | use |
|---|---|---|
| `keyboardReport` | `modifier` (bitmask E0–E7), `keys` (≤ 6 HID usages) | whole keyboard state, not transitions |
| `absMouseReport` | `x`, `y` (0–32767), `buttons` (HID: 1 left, 2 right, 4 middle) | absolute move; framebuffer coords are scaled |
| `wheelReport` | `wheelY`, `wheelX` | scroll; RFB wheel bits 8/16 become ±1 |
| `setATXPowerAction` | `action`: `power-short` \| `power-long` \| `reset` | Power menu (needs the ATX extension) |
| `getVideoState` | | asked once when the channel opens |
| `ping` | | keep-alive every 2 s |

Events handled: `videoInputState` (`{ready, error, width, height, fps}`,
error one of `no_signal`, `no_lock`, `out_of_range` → status
"no video: …"), `otherSessionConnected` (§3). Everything else is logged.

## 5. KVMClient integration

`ConsoleKind.jetkvm` is the third kind beside `.aten` and `.vnc`. The
session thread runs `JetKVMSession.run()` (blocking) instead of a socket
loop; the standard reconnect/backoff wrapper applies, with login failures
and takeover treated as fatal. Input routing differences: keyboard state is
rebuilt from the held-keys set on every change; wheel bits are stripped
from pointer events; power maps on/soft-off → `power-short`,
off → `power-long`, reset → `reset`.

## 6. Discovery

JetKVMs advertise only their own hostname over mDNS — there is no DNS-SD
service to browse — so discovery is an HTTP sweep
(`JetKVMDiscovery.scan`): every local non-loopback /24 (or a given
prefix), `GET /device/status` with a 1 s timeout, 64 probes in flight; a
200 whose JSON has an `isSetup` bool is a JetKVM. A /24 takes ~4 s.
Exposed as **Connection → Discover JetKVMs**, `smkvm-probe --discover`,
and `GET /api/discover`.
