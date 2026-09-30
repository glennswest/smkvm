# SMKVM web API

The app serves an HTTP API and a browser page on **port 8765, all network
interfaces** (change with `defaults write io.github.glennswest.smkvm apiPort <n>`). It is
meant for a remote agent (e.g. an AI coding agent on another machine) to watch
consoles and type into them in real time. There is **no power control** in
the API by design.

Everything goes through the app's real console windows: `connect` opens a
tab in the app, and input shows up on screen as it is sent.

## Auth

Every `/api` request needs the token, as `Authorization: Bearer <token>` or
`?token=<token>`. The token is generated on first launch and stored in
`~/Library/Application Support/SMKVM/api-token` (mode 0600); **Connection →
Web API…** shows and copies it. `/` (the browser page) needs no token itself
and asks for it once.

A convenient place for clients to keep it is `~/.env` as `SMKVM_API`:

```
set -a; . ~/.env; set +a
curl -H "Authorization: Bearer $SMKVM_API" http://<mac>:8765/api/hosts
```

## Endpoints

`{h}` is a host's name or address (e.g. `server1`, `bmc1.example.lan`, `10.0.0.10`).

| Method | Path | Body / query | Result |
|---|---|---|---|
| GET | `/api` | | this reference as JSON |
| GET | `/api/hosts` | | all hosts: name, address, console type, open, status, seq, size |
| GET | `/api/hosts/{h}` | | one host |
| POST | `/api/hosts/{h}/connect` | | opens the console tab |
| POST | `/api/hosts/{h}/disconnect` | | closes it |
| GET | `/api/hosts/{h}/screen.png` | `wait_change=S`, `after=SEQ` | current screen as PNG |
| GET | `/api/hosts/{h}/screen.jpg` | same + `quality=0..1` | as JPEG |
| GET | `/api/hosts/{h}/frame` | same | `{seq, changed, width, height, status}` |
| GET | `/api/hosts/{h}/stream.mjpg` | `fps=1..30`, `quality` | live MJPEG (`<img src>` works) |
| POST | `/api/hosts/{h}/type` | `{"text": "ls -l\n", "delay_ms": 15}` | types text (US layout, `\n` = Enter) |
| POST | `/api/hosts/{h}/key` | `{"keys": "ctrl+alt+delete"}` or `{"keys": ["esc","down","enter"]}`; `hold_ms`, `delay_ms` | presses chords in order |
| POST | `/api/hosts/{h}/mouse` | `{"x":100,"y":200,"action":"click\|double\|move\|down\|up","button":"left\|right\|middle"}` | framebuffer pixels |
| POST | `/api/hosts/{h}/screenlog` | `{"enabled": true}` | turns screen logging on/off |
| GET | `/api/hosts/{h}/screens` | `limit=N` | logged screenshots, newest first |
| GET | `/api/hosts/{h}/screens/{date}/{file}` | | one logged screenshot |

Input endpoints on a console that isn't open return **409**; `connect` first.

### Waiting for the screen

- `screen.png?wait_change=10` returns as soon as the screen *visibly*
  changes (cursor blink ignored), or after 10 s with the current screen.
- `frame` gives a sequence number; `screen.png?after=<seq>&wait_change=10`
  returns once the screen has moved past that frame. Typical agent loop:
  send keys → `screen.png?wait_change=5` → read it → repeat.

### Key names

`enter esc tab backspace space delete insert home end pgup pgdn up down
left right f1…f24 printscreen scrolllock pause numlock capslock menu ctrl
shift alt win rctrl rshift ralt rwin`, or any single character; join with
`+` for chords.
