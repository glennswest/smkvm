# ATEN / Supermicro iKVM protocol: specification for a native client

Scope: the Supermicro/ATEN "Java iKVM" console used on X8, X9 and X10 boards. The BMCs covered are the Nuvoton/Winbond WPCM450 ("Hermon"), the Renesas SH7757 on some X9 boards, and ASPEED AST2100/2300/2400.
Compiled 2026-09-30 from actual source code. The sources are listed in §0, and each claim is tagged with the sources that back it.
Anything that is not corroborated, or where the sources disagree, is marked **UNVERIFIED**.

All multi-byte RFB fields are **big-endian** unless stated otherwise. The only little-endian data is the Hermon RGB555
pixels and the dword order of the AST2100 bit-stream.

---

## 0. Sources (all read as raw source code)

| Tag | Source | What it is |
|---|---|---|
| **KK** | github.com/kelleyk/noVNC branch `bmc-support`: `core/rfb.js`, `core/ast2100/{ast2100,ast2100util,ast2100const,ast2100idct}.js`, `core/input/keysym.js` (XK2HID) | Original noVNC ATEN support by jimdigriz, extended by kelleyk with a clean-room AST2100 decoder. Proposed upstream as novnc/noVNC PR #408, then #445, then #614, never merged. The repo is MPL-2.0 for core files. The ast2100 files carry only "(c) 2015-2017 Kevin Kelley". |
| **PR408** | novnc/noVNC PR #408 diff (jimdigriz) | First ATEN auth/Hermon code. Tested on X7SPA-F, X8DTL, X8SIE-F, X9SCL/X9SCM, X9SCM-F, X9DRD-iF, X9SRE, X9DRL, X10SLD |
| **AP** | github.com/thefloweringash/aten-proxy `main.cc` | C++ ATEN-to-VNC proxy. Tested on **X9SCM-iiF (WPCM450)**. GPL |
| **DC** | github.com/vdudouyt/decaffeine-ipmi `src/{rfb,jnlp,transport}.rs` | Rust native client, 2025/26 |
| **AT** | github.com/tjone270/ATENtion `src/ATENtion.Core/**` | C# native client, MIT, 2026. Reverse-engineered from `iKVM64.dll` with Ghidra FUN_ addresses. Marked "VERIFIED LIVE" on **X9DRH-7F**, a later X9 firmware with stunnel TLS |
| **MK** | github.com/mkrasselt1/supermicro-kvm-html5 (`server.py`, `novnc/core/decoders/aten/hermon.js`, `rfb.js`) | Python proxy plus patched noVNC. Tested on **X9SCL/X9SCM, Nuvoton WPCM450**, ATEN fw 2016-11-10 (v0352) |
| **MP** | github.com/MishaProductions/AtenKVMClient `Core/VNC/Ast2100Decoder.cs`, `Ast2100Const.cs`, `Windows/VNC/VNCViewer.axaml.cs`, `Core/IPMI/HTTP/IpmiHttpClient.cs` | C# client. Its `Ast2100Decoder` is a port of **Supermicro's own HTML5 iKVM viewer decoder**, which is the ASPEED reference decoder, and it is more complete than KK's |
| **OSSO** | ossobv/vcutil `ipmikvm`, plus the osso.nl 2025 blog | Login and JNLP fetch variants across firmware |
| **X9C** | github.com/edsai/x9-bmc-cert-rebuild `README.md`, `DIAGNOSIS.md` | X9 iKVM TLS (stunnel) certificate expiry of 2026-05-17 |

Suggested cross-checks: AP, DC and MK are the smallest and closest to your board. AT is the most detailed on client-to-server extras.

---

## 1. Which encoding does my board use?

| Chip | Boards (examples) | RFB rect encoding | Pixel data |
|---|---|---|---|
| Winbond/Nuvoton **WPCM450** ("Hermon") | X8 (X8DTL, X8SIE-F …), most X9 (X9SCL/SCM, X9SRE, X9DRL, X9DRD …), X7SPA-F | **0x59 (89) "ATEN_HERMON"**. Old firmware puts **0x00** in the encoding field; treat 0 as 0x59 (KK, PR408, MP). DC and AT ignore the field altogether | 16-bit **RGB555 little-endian**, 16×16 tiles or a raw full frame |
| Renesas SH7757 (some X9) | UNVERIFIED which boards | same as Hermon (KK comment: heuristic #0 covers "older Winbond/Nuvoton or Renesas BMC") | same |
| **ASPEED AST2100 / AST2300 / AST2400** | X9 boards with AST (rare), X10 (X10SL7-F, X10SLD-F, X10SLM-F, X10SLE …), X11 | **0x57 (87) "ATEN_AST2100"** | JPEG-like DCT plus VQ codec (§7) |
| (named only) | – | 0x58 ATEN_ASTJPEG, 0x60 ATEN_YARKON, 0x61 ATEN_PILOT3 | **UNVERIFIED**, no decoders exist |

**For your target (X9-era, "(c) ATEN 2010" web UI, plain RFB 003.008 on :5900, security type 16), the board is almost certainly a WPCM450 and uses the Hermon encoding (§6).**
You get RGB555 16×16 tiles plus occasional raw full frames. Implement AST2100 only if you also want X10 boards.

AT's native decoder also contains palette-4/8, bit-plane plus RLE "type 2/4/5" paths (in `AtenTileDecoder.cs`, `BitPlaneDeinterleave.cs`, `AtenRle.cs`).
These belong to other ATEN chip families. Their wire layouts are **UNVERIFIED** (AT's own words), and your board should not need them.

---

## 2. HTTP side (web UI): login, JNLP, logout

### 2.1 Login

```
POST /cgi/login.cgi            (http:// on old firmware; https:// on later; try both – MK, OSSO)
Content-Type: application/x-www-form-urlencoded
body: name=<urlenc user>&pwd=<urlenc pass>          (OSSO also appends &check=00)
→ Set-Cookie: SID=<token>; path=/
```

- Take the `SID=` Set-Cookie that has **no `expires`**. Some firmware first sends a clearing `SID=; expires=1970…` cookie (MK).
- **Success detection:** a 200 alone is not enough. A success body contains `url_redirect.cgi?url_name=mainmenu`. Failure shows `url_name=login_alert`, `alert(`, or a `<META HTTP-EQUIV="refresh" CONTENT="0;URL=/">` bounce (OSSO). Some firmware returns an empty 200 on failure (OSSO).
- Some later firmware base64-encodes the credentials. If the login page's JS uses `btoa`, send `name=base64(user)&pwd=base64(pass)`, with `=`→`%3D` and `+`→`%2B` (OSSO). This is **UNVERIFIED** on 2010 firmware, which is very likely plain.
- HTTP 400 from login.cgi means newer (X11/X12) firmware that wants Redfish sessions (AT). Not relevant to X9.
- MK waits 1 s after login before fetching the JNLP, and retries once on HTTP 500 because the session is not ready yet.
- Send the cookie as `Cookie: SID=<sid>`. MK also adds `langSetFlag=0; language=English`. Send `Referer: <base>/cgi/url_redirect.cgi?url_name=man_ikvm` (MK, OSSO).

### 2.2 Fetch the JNLP (this also "arms" the KVM port and mints the session token)

Try these in order until the body starts with `<jnlp`:

```
GET /cgi/url_redirect.cgi?url_name=ikvm&url_type=jwsk
GET /cgi/url_redirect.cgi?url_name=man_ikvm&url_type=jwsk
```

- A "File Not Found" or 404 response on later firmware means the BMC is in HTML5 console mode.
  - AT switches it to Java mode as follows:
    1. `GET /cgi/url_redirect.cgi?url_name=topmenu` and scrape `CSRF_TOKEN` (the first quoted `[A-Za-z0-9]{6,}` after that label).
    2. `POST /cgi/op.cgi` with body `op=remote_console&ikvm_setting=0` and header `CSRF_TOKEN: <tok>`.
  - MP instead reads the HTML5 page `url_redirect.cgi?url_name=man_ikvm_html5_bootstrap` and pulls the token from the `entry_value` input's `value="…"`.
  - X9/2010 firmware has neither. Expect the plain jwsk to work.
- **Fallback:** if the JNLP fetch fails, MK uses the **SID itself as the RFB username and password token**. It works on its WPCM450 X9SCM, but this is **UNVERIFIED** in general.

### 2.3 JNLP `<argument>` list (`main-class="tw.com.aten.ikvm.KVMMain"`)

Take the `<argument>` elements in order. Layout according to AT (from `javap` of `iKVM__V1.69.39.0x0.jar`) and DC:

| idx | meaning | notes |
|---|---|---|
| 0 | BMC host/IP to connect to | |
| **1** | **RFB "username"**: a per-session token (e.g. `Cl8xFRaBRZTRMIR`) | **send in the 24-byte user field** |
| **2** | **RFB "password"**: a token, often base64-looking (e.g. `jwGwerg==`). AT says it equals arg 1 on its firmware | **send in the 24-byte password field** |
| 3 | host display name / "null" / access mode | MK calls it `access_mode` |
| 4 | iKVM port. With stunnel this is the local stunnel accept port (e.g. 63630). With TLS off it is the plaintext RFB port | |
| 5 | virtual media / IPMI port (623) | |
| 6 | company id | |
| 7 | board id | |
| 8 | **stunnel/TLS enable** ("1" = mutual TLS) | |
| 9 | server RFB port when TLS (5900) | |

- Connect rule (AT): if arg8=="1" and arg9>0, connect to arg9 **with mutual TLS**. Otherwise connect to arg4 in plaintext.
- DC tries four combinations (declared transport first, then the other, on BMC IP then codebase host) and accepts one only if it answers `RFB `.
- Some firmware (OVH and similar) prepend URL arguments before the host. MP locates the host argument by value (`== host`) and takes the next two as user and password.
- The embedded server certificate (`-----BEGIN CERTIFICATE-----…`) may appear as an argument on TLS firmware (AT, OSSO).
- **UNVERIFIED for your 2010 firmware:** how many arguments there are and whether args 8 and 9 exist.
  **Action:** dump your actual JNLP once. Your observation (plain RFB on 5900) means TLS is off and arg4 is probably 5900.
- The **tokens are single-use and expire quickly** (DC: "RFB handshake/auth: failed to fill whole buffer" = expired jnlp). Fetch a fresh JNLP for every connection.

### 2.4 Other useful CGI (optional)

- Power: `POST /cgi/ipmi.cgi` with body `POWER_INFO.XML=(1,N)`, where N=1 on, 0 off, 2 cycle, 3 reset, 5 ACPI soft shutdown. Status: `POWER_INFO.XML=(0,0)` (MK, X9SCM). Power can also be sent in-band (§5.7).
- Screenshot preview: `url_redirect.cgi?url_name=Snapshot&url_type=img&time_stamp=…`, or `CapturePreview.cgi` (MP).

### 2.5 Logout

`GET /cgi/logout.cgi` with `Cookie: SID=<sid>`. This endpoint is documented in CVE-2013-3622 (the SID-parsing overflow in logout.cgi, fixed from SMT_X9_315). Logging out ends the web session. HandleIKVMMessage code 3 in MP says an active KVM session is **kicked on web logout**, so log out only after the KVM session ends (§5.8).

---

## 3. Transport

- **Old firmware (your case):** plain TCP to 5900. Disable Nagle (AT does).
- **Later X9 firmware (3.x, e.g. SMT_X9_315+ … 3.62):** the BMC runs stunnel, which does **mutual TLS on 5900**, and the plaintext iKVM server listens on **63630** only when "KVM SSL" is disabled (AT, X9C). The TLS certs live in `/etc/stunnel/{server.crt,server.key,client.crt}` in read-only cramfs. They expired **2026-05-17 09:44:10 UTC** on every X9, so TLS connects now fail on a correctly set clock (X9C, AT). Workarounds:
  1. Disable KVM SSL in the web UI, then use plaintext 63630.
  2. Roll the BMC clock back before 2026-05-17 and present the bundled client cert from the JAR.
  3. Reflash with x9-bmc-cert-rebuild.

  Inside the TLS the protocol is identical.
- AST2400 X10 boards may send the banner `RFB 055.008\n` instead of 003.008 (MP detects this as "IsAST2400"). **Echo back whatever the server sent.**

---

## 4. RFB handshake as ATEN implements it

Consensus of AP, DC, AT, MK and PR408, all tested on X9 WPCM450 or X9DRH:

```
S→C  12  "RFB 003.008\n"                 (may be "RFB 055.008\n" on AST2400)
C→S  12  echo the server's 12 bytes verbatim
S→C   1  u8 nTypes  (=1)          if 0: u32 len + reason string, fail
S→C   n  u8 types[] (=[0x10])
C→S   1  u8 0x10                  (AT: native client picks the LAST type offered)
S→C  24  opaque 24-byte blob ("challenge"); read and ignore
C→S  48  user[24] ‖ pass[24]      ASCII, NUL-padded, no terminator required
                                   (AP limits each to ≤23 chars so there is always a NUL)
S→C   4  u32 SecurityResult        0 = OK
                                   ≠0 → (AT/MP) u32 len + reason; KK: 1=failed, 2=too many attempts
C→S   1  ClientInit shared-flag    AP/DC/AT send 0; MK/MP send 1; both work
S→C      ServerInit (ATEN variant, below)
```

**The 24-byte blob is NOT TightVNC tunnel negotiation.** Although the type is 16 ("Tight"), ATEN sends no tunnel or auth capability lists and expects no tunnel choice. The client sends nothing between the type byte and the 48-byte credentials.

- KK's heuristic identifies the server as "ATEN" if the first 4 blob bytes, read as a u32 "numTunnels", are 0 or >0x1000000.
- PR408's older test is `(u32 & 0xFFFF0FF0) == 0xAFF90FB0` on old boards.
- AST2400 (X10): the first 4 bytes are 0 and the next u32 is 0 or has low 16 bits == 0x0100.

In all cases the total is **24 bytes**.

- **Bug warning:** KK's `bmc-support` heuristic-#0 path skips only 20 bytes (4+16). MK fixed this to 24 on WPCM450. Use 24.
- AT says the blob is not observed to feed into the credentials. Just skip it.

**Timing quirk (MK, WPCM450):** "The BMC has a very short (<100 ms) timeout between sending the auth result and expecting ClientInit." MK writes `creds(48) ‖ 0x01` in a single TCP segment before it has even read SecurityResult.
A native client should do one of two things:
- send ClientInit immediately after reading SecurityResult==0, with no UI round-trip in between, or
- pipeline the ClientInit byte right after the 48 credential bytes, as MK does.

If auth fails, the stray ClientInit byte is harmless because the server closes the connection.

### 4.1 ServerInit (ATEN)

```
u16  width         ┐ placeholders; NOT the real resolution. AT: "frequently a portrait
u16  height        ┘ 480x640"; MP reads them as height,width. Real size comes from 1st FBU.
16   PIXEL_FORMAT  ignore (AP: "complete garbage"). Real Hermon pixels are RGB555 LE.
                   KK/PR408: "ATEN iKVM lies and only does 15 bit depth with RGB555".
u32  nameLen
     name[nameLen]
12   ATEN trailer (KK/MK/MP):
       8  bytes  unknown (MP: "sessionID")
       u8 IKVMVideoEnable
       u8 IKVMKMEnable       (0 ⇒ video-only session, no keyboard/mouse; MP)
       u8 IKVMKickEnable
       u8 VUSBEnable         (virtual media)
```

AT describes the same 12 bytes as "4 bytes, u32, 4 bytes". **All sources agree that exactly 12 bytes follow the name.** There is no TightVNC capability block after them.

---

## 5. Client → server messages

### 5.1 SetPixelFormat (0) / SetEncodings (2)

- **Do not send SetPixelFormat.** It is ignored; Hermon always sends RGB555 (KK, MK: "ATEN ignores it and lies about depth").
- SetEncodings (standard: `[2][pad][u16 n][s32 enc…]`) is optional. AP, DC and AT never send it and still get video. KK and MK send a list including 0x57, 0x58, 0x59, 0x60, 0x61, and MP sends a standard list. All work, so the BMC evidently ignores it.
- Recommendation: skip it, or send `[0x57,0x59]` if you want symmetry. Whether it is harmful on 2010 firmware is **UNVERIFIED**.

### 5.2 FramebufferUpdateRequest (3), standard 10 bytes

```
u8 3 | u8 incremental | u16 x | u16 y | u16 w | u16 h
```

- The BMC ignores the rect and always refers to the whole screen (DC). AP sends 0,0,0,0, and MP even sends the fields little-endian, which still works.
- **The server only sends video in response to FBURs.** Send one non-incremental FBUR right after ServerInit, then **one incremental FBUR after each FramebufferUpdate is consumed** (KK, AP, DC, MP).
- AT keeps **2 FBURs in flight** (pipeline depth 2) for throughput. It re-sends a non-incremental FBUR on resolution change, and runs a 1 s timer that sends an incremental FBUR if none is outstanding.
- While the screen is off (§6.4), AP sends non-incremental FBURs, and MP sends a non-incremental FBUR every 1 s until video returns. Do this, or the display may never come back after a reboot or mode change (see the emmericp reports in PR408/#445).
- AT watchdog: with no inbound message for N seconds, send one non-incremental FBUR (a live BMC always answers, even on a static screen). At 10 s, declare the link dead.

### 5.3 KeyEvent (4), ATEN form, **18 bytes**, verified by AP, DC, AT, KK, MK and MP

```
off 0  u8   4
off 1  u8   0            (AT: this is the "encrypted" flag; 0 = plaintext)
off 2  u8   down         1 = press, 0 = release
off 3  u8   0
off 4  u8   0
off 5  u32  key          BIG-endian, = USB HID Usage ID (keyboard page 0x07), NOT an X11 keysym
off 9  9×u8 0
```

- Send modifiers as separate key events. The BMC's virtual USB keyboard builds the HID report, so case and shift come from Shift being held (AT: verified with upper case, shifted symbols, both Shifts, and Ctrl+Alt+Del). Left and right modifiers are distinct (0xE0–0xE7); KK collapses right onto left.
- **Lock keys (AT, from native `keyboardAction`):** for Caps 0x39, Scroll 0x47 and Num 0x53 the native client sends `usage | 0xFF00` when the corresponding **local** lock is currently OFF, and the raw usage when it is ON. This keeps the host's lock state in sync.
  Never apply 0xFF00 to other keys: it bypasses modifier-state tracking and breaks Shift.
  Whether 2010 firmware honours this is **UNVERIFIED**; sending the raw usage is always safe.
- Release all held keys when your window loses focus (AT mirrors native `releasePressedKeys`).
- The HID usage table is in §9. A macOS `kVK_*` → HID map is included.

### 5.4 PointerEvent (5), ATEN form, **18 bytes**, verified by KK, AT, MK and MP

```
off 0  u8   5
off 1  u8   0            encrypted flag (0 = plaintext)
off 2  u8   buttonMask   bit0 left, bit1 middle, bit2 right  (standard RFB)
off 3  u16  x            BIG-endian, ABSOLUTE framebuffer pixel (0..w-1)
off 5  u16  y            BIG-endian, absolute (0..h-1)
off 7  11×u8 0
```

- **Wheel:** KK passes the RFB mask (bits 3 and 4 = wheel up/down). AT notes the native `mouseAction` carries `{x, y, state, -wheel}` but does not show where the wheel goes. **UNVERIFIED**; try mask bits 3/4 first.
- **Encrypted variant (AT):** `[5][1][AES-128-ECB(16 bytes: mask, x_hi, x_lo, y_hi, y_lo, 11 random)]`, also 18 bytes. The key derivation from the session token is not reversed. The plaintext form is accepted on AT's X9. Use plaintext.
- **Mouse mode (AT, native `setMouseMode`):** `[0x36][0x00][mode]` with 1 = Absolute, 2 = Relative ("normal"), 3 = Single. Send `[0x36,0,1]` once after connect so absolute coordinates track. Relevance to 2010 firmware is **UNVERIFIED**; KK, MK and MP never send it and absolute works on X9SCM.
- Coalesce moves; AT paces them to ≥8 ms apart.

### 5.5 Keep-alive

- AT (native `sendKeepAliveAck`, `keepAliveTask`): send `[0x15][u32 BE 1][u32 BE 0]` (9 bytes) **every 3 s**. AT reports: "without it the BMC keeps streaming video but stops servicing the client's keyboard/mouse/power".
- The server's own keep-alive is message **0x16** (1 byte body, §6.1), and "Ack" suggests 0x15 answers it. Recommendation: send 0x15 on a 3 s timer **and** in response to each 0x16.
- AP, DC and KK do not send it and still work on X9SCM, so it is harmless at worst. **UNVERIFIED** on 2010 firmware.

### 5.6 Video start sequence (AT native DecodeThread; optional; UNVERIFIED on 2010 firmware)

After ServerInit, AT sends:

1. `[0x37]`: 1 byte, "updateInfo".
2. `[0x07][0x07][0x80]`: "runImage", i.e. type 7 followed by u16 0x0780. Sent once.
3. A non-incremental FBUR.
4. `[0x36,0,1]` (mouse mode).

The minimal clients (AP, DC) send only the FBUR and get video on WPCM450. Start minimal. If input is dead, add 0x15 keep-alives and 0x36.

### 5.7 Other client messages (AT, verified on X9DRH-7F)

- Power: `[0x1A][code]`, 2 bytes, where code 0 = off, 1 = on, 2 = reset, 3 = soft-off (ACPI). MP sends the same `[26][type]`.
- Keyboard/mouse USB hot-plug (re-enumerate virtual HID): `[0x3A]`, 1 byte. **AT warns it toggles**, so do not auto-send it.
- AST2100 quality: `[0x32][u8 lumaQT 0..11][u8 chromaQT 0..11][u16 BE 444|422]`, 5 bytes (KK `atenChangeVideoSettings`). AST only.

### 5.8 Client-side cut text / others

No ATEN support is known. Do not send them.

---

## 6. Server → client messages

Read one type byte, then:

| type | name (source) | body length after the type byte |
|---|---|---|
| **0x00** | FramebufferUpdate | variable, see §6.2 |
| 0x01 / 0x02 / 0x03 | standard SetColourMap / Bell / CutText | standard. Not seen from ATEN; MP handles 1 |
| **0x04** | "Front Ground Event" (KK), cursor shape (AT) | KK/AP/DC/MK/MP: **20** fixed. AT: `u32 x, u32 y, u32 w, u32 h, u32 flag` (=20 bytes); **if flag==1, a further u32 plus w×h×2 bytes of cursor bitmap follow**. Implement AT's form: it reduces to 20 when flag≠1 |
| **0x16** (22) | Keep-alive (KK), status (AT) | **1** |
| 0x33 (51) | "Video Get Info" (KK, MK) | **4** |
| 0x35 (53) | keyboard+mouse status (AT only) | **5** |
| **0x37** (55) | "Mouse Get Info" (KK), mouse status (AT) | **2** per KK/AP/DC/MK (AP tested on X9SCM-iiF), but **3** per AT (X9DRH-7F, later firmware). **UNVERIFIED which applies to your firmware.** Likely firmware-dependent. Default to 2 on 2010 firmware and log hex if the stream desyncs |
| **0x39** (57) | "Session Message" (KK), privilege grant (AT) | **264** = u32 + u32 + 256 bytes. See §6.1 |
| **0x3C** (60) | "Get Viewer Lang" (KK), screen status (AT) | **8** |
| other | – | unknown length, so the stream cannot be resynced. Fail and reconnect (AT, AP abort) |

Note that ATEN reuses standard numbers: 4 would normally be ResizeFrameBuffer and 0x16 has no standard meaning, so switch on the ATEN table first.

### 6.1 0x39 session / privilege message

```
u32 a  | u32 b | char[256] text (NUL-terminated)  "<sid> <ROLE|user> <clientip>"
```

- **AT:** `controlling = !(a == 1 && b == 4)`. So a=1, b=4 means view-only / not in control; any other combination (e.g. a=1, b=1 for an ADMIN in control) means you hold input control.
- **MP** interprets the first u32 as a counter and the second word as four decimal digits `ctrl_code = Σ byte[i]·10^(3-i)`:

  | code | meaning |
  |---|---|
  | 0, 1 | user joined |
  | 2 | user left |
  | 3 | **disconnected because web logout happened** |
  | 4 | too many users |
  | 8 | BIOS update in progress |
  | 9 | firmware update in progress |

  Both readings are partially **UNVERIFIED**; show the text in the UI.

### 6.2 FramebufferUpdate (type 0), ATEN framing, common to Hermon and AST

```
u8  pad
u16 nRects             usually 1; 0 is legal ("nothing changed", AT)
per rect:
  u16 x, u16 y, u16 w, u16 h      (x=y=0 in practice; w,h = CURRENT SCREEN RESOLUTION)
  s32 encoding                    0x59 Hermon (or 0x00 on old fw), 0x57 AST2100
  u32 mode                        KK "mysteryFlag": seems 0 in text mode/BIOS, 1 in graphics (UNVERIFIED)
  u32 dataLen                     number of payload bytes that follow
  u8  payload[dataLen]
```

The two extra u32 fields after the standard 12-byte rect header are the ATEN-specific per-rect fields.
**Always consume exactly `dataLen` bytes**, as AT and DC do. This keeps you aligned even if the inner parse fails.

**Resolution:** the rect's w×h is the live screen resolution on every update (AT). If (w, h) is sane (1..4096) and differs from the current size, resize and request a non-incremental FBUR. KK and noVNC start with a dummy 10000×10000 framebuffer and resize on the first FBU.

### 6.3 Hermon payload (encoding 0x59 / 0x00), WPCM450, your board

Payload = a 10-byte sub-header, then a body. The sub-header is checked by KK/PR408/MK/AP/DC/AT/MP:

```
off 0  u8   type          0 = incremental 16×16 tiles ("subrects"), 1 = raw full frame
off 1  u8   pad
off 2  u32  count         (BE) number of tiles for type 0; ignore for type 1
off 6  u32  totalLen      (BE) == dataLen (KK fails on mismatch; MK only warns)
off 10 body               (totalLen − 10) bytes
```

**Type 0 (tiles):** `count` segments of **518 bytes** each:

```
u16 a, u16 b     unknown (4 bytes, skip)
u8  row          tile row    → pixel y = row*16
u8  col          tile column → pixel x = col*16
512 bytes        16×16 pixels, row-major, 2 bytes/pixel RGB555 LE
```

Tiles at the right and bottom edge overhang non-multiple-of-16 resolutions (e.g. 800×600 is 37.5 tile rows). Clip them rather than rejecting them. AT warns that treating overhang as an error and requesting keyframes "stormed full frames at the BMC".

**Type 1 (raw):** body = `w*h*2` bytes, row-major, full screen, RGB555 LE. AP and AT treat it as the whole screen at (0,0).

**Pixel conversion** (AP, AT, MK, DC):

```
v = byte[0] | byte[1] << 8          // little-endian u16
R5 = (v >> 10) & 31;  G5 = (v >> 5) & 31;  B5 = v & 31      // bit 15 unused
R8 = R5 << 3 | R5 >> 2   (AT uses R5<<3; MK uses R5*255/31)
```

KK obtains the same result by applying the server's `big_endian` flag. AP, DC, AT and MK hard-code little-endian. Use little-endian.

### 6.4 "No signal" / screen off

- The rect has **w = 0xFD80, h = 0xFE20** (−640 and −480 as int16; noVNC checks 64896×65056). DataLen is **0** on X9SCL/SCM (emmericp in PR #408) and is sometimes **10** (PR408 original).
- Consume `dataLen` bytes, show a "No signal" screen, and keep sending **non-incremental** FBURs, e.g. every 1 s (AP, MP), until a normal rect arrives.
- AT also sees "heartbeat rectangles with garbage dimensions (64896×65056)" and never resizes on them.
- An AST rect with w, h normal but `dataLen == 0` also means off or rebooting (KK).
- "Unsupported encoding −41877984"-style garbage has been reported while the host reboots and changes modes (emmericp). This comes from not consuming bytes correctly. Consuming `dataLen` and the AT 0x04 cursor handling avoid it.

### 6.5 AST2100 payload (encoding 0x57)

`payload[dataLen]` is one complete codec frame (KK: exactly one rect per FBU). Pass it to the §7 decoder together with the rect's w and h. The decoder paints only the blocks it contains, onto a persistent framebuffer.

---

## 7. AST2100 video codec (encoding 0x57): port-ready description

Primary references:
- KK `core/ast2100/*.js`: <https://raw.githubusercontent.com/kelleyk/noVNC/bmc-support/core/ast2100/ast2100.js>, `ast2100util.js`, `ast2100const.js`, `ast2100idct.js`. Clean-room, © Kevin Kelley. The repo is MPL-2.0; the files carry only a copyright line (**license UNVERIFIED**).
- MP `KVMClient/Core/VNC/Ast2100Decoder.cs` plus `Ast2100Const.cs`. This is a port of Supermicro's HTML5 viewer, i.e. the ASPEED reference. No license file, so treat it as reference only.

The two agree on everything below except the noted IDCT typo.

### 7.1 Frame layout

```
byte 0   lumaQTSelector    0..11  (quality; 11 = best)
byte 1   chromaQTSelector  0..11
byte 2-3 u16 BE subsampling: 444 (0x01BC) = 4:4:4, 8×8 MCU
                             422 (0x01A6) = actually 4:2:0, 16×16 MCU (4 Y + Cb + Cr)
byte 4.. bit-stream
```

### 7.2 Bit reader (important: dword byte order)

The bit-stream starts at byte 4. It is consumed as **32-bit little-endian words**, and **within each word bits are read MSB-first**:

```
word_k = data[4+4k] | data[5+4k]<<8 | data[6+4k]<<16 | data[7+4k]<<24
bitstream = word_0 bits 31..0, then word_1 bits 31..0, …
```

KK does this by treating the frame's first dword as the header and skipping 32 bits. MP starts reading at index 4 with `GetQBytesFromBuffer` (little-endian) and keeps a 64-bit window (`mCodebuf`/`mNewbuf`). JPEG `0xFF` stuffing/markers are **not** used (KK: "ATEN scan data does not treat 0xFF bytes specially").

- `peek(n)` = top n bits of the window.
- `read(n)` = peek then advance.
- Zero-pad past the end: Huffman peeks 16 bits, which can run past the data.

### 7.3 Block loop

The state is the MCU position `(mx, my)`, reset to (0,0) at every frame. The DC predictors `prevDC[Y, Cb, Cr]` are also reset to 0 at every frame.

```
mcu = (subsampling==444) ? 8 : 16
wMCU = ceil(w / mcu);  hMCU = ceil(h / mcu)
loop:
  code = read(4)
  switch code:
    0x0  JPEG block, no position                  → decodeDCT(QT pair 0)
    0x8  JPEG block with position: mx=read(8), my=read(8) → decodeDCT(QT pair 0)
    0x4  "LOW_JPEG" block, no position            → decodeDCT(QT pair 1 = "advance" tables)
    0xC  "LOW_JPEG" with position (x8,y8)         → decodeDCT(QT pair 1)
    0x5/0x6/0x7   VQ block, 1/2/4 colours, no position   → decodeVQ(bits = code-5 → 0,1,2)
    0xD/0xE/0xF   VQ block with position: mx=read(8), my=read(8), then as 5/6/7
    0x9  END OF FRAME → stop
    else error (0x1,0x2,0x3,0xA,0xB)
  after each block: advance(): mx++; if mx>=wMCU {mx=0; my++}; if my>=hMCU {my=0}
```

- MP uses `mTmpWidth/mcu` after rounding the width up to a multiple of mcu, which is the same as ceil.
- MP caps the loop at max(w·h/64, 4096) blocks as a safety net. Do the same.
- Position bits: after the 4-bit code, X comes first, then Y (`mTxb = codebuf>>20 & 0xFF`, `mTyb = codebuf>>12 & 0xFF`). The positioned header is therefore 20 bits and the plain one is 4 bits.
- **LOW_JPEG (0x4/0xC):** KK throws on these ("haven't seen traffic"). MP decodes them with quant tables built from `mAdvanceSelector`, which its code effectively sets to 0 (Tbl_000Y/UV) before loading. That is **UNVERIFIED**: implement it as "use the second QT pair". Until you have captured traffic, building that pair from selector 0 is a guess.

### 7.4 DCT block (decodeDCT)

**Data units:**
- 4:4:4 reads Y, Cb, Cr (three 8×8 units).
- 4:2:0 reads Y0, Y1, Y2, Y3, Cb, Cr.

  Y0 = top-left, Y1 = top-right, Y2 = bottom-left, Y3 = bottom-right. Chroma is upsampled by 2 in both directions: pixel (i, j) of the 16×16 MCU uses `Cb[(j>>1)*8 + (i>>1)]`.

**Each unit is baseline-JPEG Huffman coded:**
- DC: `cat = huffDC.decode()`, `diff = extend(read(cat), cat)`, `prevDC[c] += diff`, `coef[0] = prevDC[c]`. The predictor is per component, and all four Y blocks share one predictor.
- AC: for k in 1..63, read `rs = huffAC.decode()`, with `r = rs>>4` and `s = rs & 15`:
  - `s == 0 && r == 0` is EOB.
  - `s == 0 && r == 15` is ZRL (16 zeros).
  - Otherwise skip r zeros, then `coef[zigzag[k]] = extend(read(s), s)`.
- `extend(v, s)`: `v < 1<<(s-1) ? v - (1<<s) + 1 : v` (the standard JPEG EXTEND). KK and MP implement the same thing differently.

**Tables and dequantisation:**
- Huffman tables are the **standard JPEG Annex K tables**: DC luma, DC chroma, AC luma, AC chroma. Y uses the luma tables; Cb and Cr use the chroma tables. Verbatim copies are in Appendix A.
- Quantisation: `QT_Y = ATEN_QT_LUMA[lumaSel]` and `QT_C = ATEN_QT_CHROMA[chromaSel]`, both 64 entries in **natural (row-major) order**. MP's `Tbl_000Y … Tbl_Q11Y` are identical. Precompute
  `q[r*8+c] = trunc(QT[r*8+c] * aan[r] * aan[c] * 65536)`
  with `aan = [1, 1.387039845, 1.306562965, 1.175875602, 1, 0.785694958, 0.541196100, 0.275899379]`.
- Dequantise with `(coef * q) >> 16`.

**IDCT:** libjpeg `jidctfst` (AAN) in integer form with CONST_BITS = 8 and PASS1_BITS = 0:
- `MULTIPLY(v, c) = (v*c) >> 8`, with `c ∈ {277, 362, 473, 669}` for 1.082392200, 1.414213562, 1.847759065 and 2.613125930.
- Pass 1 works on columns, dequantising as it goes and using the DC-only shortcut. The workspace values are unscaled.
- Pass 2 works on rows. `out = clamp((val >> 3) + 128, 0, 255)`.
- **KK bug:** KK's row pass writes `out[6] = tmp0 - tmp6`. libjpeg and the ASPEED reference (MP) use **`tmp1 - tmp6`**. Use tmp1.

**YCbCr→RGB** (both sources, same integer tables):

```
Y'  = (0x129FC*y  - 0x121FC0) >> 16      // ≈ 1.164*(y-16)
R   = clamp(Y' + ((0x19900*cr - 0xCC0000)  >> 16))            // 1.596*(cr-128)
G   = clamp(Y' + ((0x688000 - 0xD000*cr) >> 16) + ((0x328000 - 0x6400*cb) >> 16))
B   = clamp(Y' + ((0x20400*cb - 0x1018000) >> 16))            // 2.016*(cb-128)
```

These are arithmetic shifts on signed int32. KK writes the constants as 0xFF340000, 0xFFEDE040 and 0xFEFE8000 and relies on JS ToInt32; the signed forms above are equivalent. MP computes the same with `FIX(1.597656)`, `FIX(2.015625)`, `−FIX(0.8125)`, `−FIX(0.390625)`, `FIX(1.164)` and `+0.5` rounding. The results can differ by ±1 LSB from KK; either is fine.

**Placement:** the MCU is written at `(mx*mcu, my*mcu)`, clipped to w×h.

### 7.5 VQ block (decodeVQ)

VQ blocks are always 8×8. They only appear in 4:4:4 mode; both sources reject VQ in 4:2:0.

The persistent state lasts across blocks and frames: a 4-entry codebook of YCbCr colours, initialised to
`[0x008080, 0xFF8080, 0x808080, 0xC08080]` (black, white, two greys; MP stores them as 0x00YYCbCr).

```
nColours = 1 << bits          (bits = 0,1,2 → 1,2,4 colours)
for i in 0..<nColours:
    update = read(1); slot = read(2)
    if update: codebook[slot] = (Y=read(8), Cb=read(8), Cr=read(8))     // 27 bits total
    lookup[i] = slot                                                     // 3 bits if no update
for p in 0..<64 (row-major):
    idx = bits==0 ? 0 : read(bits)
    pixel p = YCbCr→RGB(codebook[lookup[idx]])
```

MP names these VQ_UPDATE_LENGTH = 27 and VQ_NO_UPDATE_LENGTH = 3, confirming the widths.

Quality and mode can change on any frame, because every frame carries the selectors. Rebuild the QT tables when the selectors change. For a native client, write straight into a BGRA buffer and invalidate dirty MCU rects.

---

## 8. Known quirks checklist

1. **Fresh JNLP token per connect.** Tokens are single-use and expire. A stale token shows up as the connection closing during auth.
2. **24-byte blob after selecting security type 16.** Do not do TightVNC tunnel negotiation.
3. **ClientInit must follow SecurityResult within ~100 ms** (MK). Pipeline it.
4. **ServerInit** size and pixel format are placeholders. Skip exactly 12 trailer bytes after the name.
5. **Encoding field 0 means Hermon** on old firmware. AT and DC ignore the field altogether.
6. **Screen off** is signalled by w/h = 0xFD80/0xFE20 (−640/−480). While it lasts, keep polling with non-incremental FBURs.
7. **An FBUR is required after every update.** The server never pushes unsolicited video.
8. **Resolution changes** arrive as new w, h in the rect header. Resize, then send a non-incremental FBUR.
9. **Only one viewer can control at a time.** 0x39 tells you whether you have control. A web-UI logout kicks the KVM session.
10. **TLS:** later X9 firmware wraps 5900 in mutual TLS (stunnel), with certificates that expired on 2026-05-17. Your 2010 firmware is plaintext.
11. **The server message 0x37 length is 2 vs 3 depending on firmware** (UNVERIFIED). Unknown message types are fatal, so log a hex dump of the next 32 bytes for debugging.
12. **Input stops working after a while** without the 0x15 keep-alive (AT, on later firmware). Send it every 3 s.
13. **Stuck keys:** release all held keys and buttons on focus loss.
14. Only one FBU rect is expected for AST (KK throws otherwise). AT shows that 0 rects is legal.
15. AST2400 banner can be `RFB 055.008`.
16. Mouse coordinates are absolute framebuffer pixels. Scale from view to framebuffer and clamp to 0..w−1 / 0..h−1.

---

## 9. Key codes: USB HID usage (page 7)

Send these as the u32 in KeyEvent:

| key | HID | key | HID |
|---|---|---|---|
| a–z | 0x04–0x1D | 1–9, 0 | 0x1E–0x26, 0x27 |
| Return | 0x28 | Escape | 0x29 |
| Backspace | 0x2A | Tab | 0x2B |
| Space | 0x2C | - _ | 0x2D |
| = + | 0x2E | [ { | 0x2F |
| ] } | 0x30 | \ \| | 0x31 |
| Non-US # ~ | 0x32 | ; : | 0x33 |
| ' " | 0x34 | \` ~ | 0x35 |
| , < | 0x36 | . > | 0x37 |
| / ? | 0x38 | Caps Lock | 0x39 |
| F1–F12 | 0x3A–0x45 | PrintScreen | 0x46 |
| Scroll Lock | 0x47 | Pause | 0x48 |
| Insert | 0x49 | Home | 0x4A |
| PageUp | 0x4B | Delete (fwd) | 0x4C |
| End | 0x4D | PageDown | 0x4E |
| Right | 0x4F | Left | 0x50 |
| Down | 0x51 | Up | 0x52 |
| NumLock | 0x53 | KP / | 0x54 |
| KP * | 0x55 | KP - | 0x56 |
| KP + | 0x57 | KP Enter | 0x58 |
| KP 1–9 | 0x59–0x61 | KP 0 | 0x62 |
| KP . | 0x63 | Non-US \ \| (ISO) | 0x64 |
| Application/Menu | 0x65 | KP = | 0x67 |
| F13–F24 | 0x68–0x73 | LCtrl | 0xE0 |
| LShift | 0xE1 | LAlt | 0xE2 |
| LGUI | 0xE3 | RCtrl | 0xE4 |
| RShift | 0xE5 | RAlt | 0xE6 |
| RGUI | 0xE7 | | |

Everything in the table through 0x63, plus 0xE0–0xE7, is used by AT, KK or MP. 0x32, 0x64, 0x65, 0x67 and 0x68+ come from the USB HID spec and are untested against ATEN (**UNVERIFIED**).

**macOS `kVK_*` (Carbon virtual keycode) → HID.** This is a standard mapping (the ANSI layout; HID is positional, so it works for any layout):

```
kVK_ANSI_A 0x00→04  S 0x01→16  D 0x02→07  F 0x03→09  H 0x04→0B  G 0x05→0A  Z 0x06→1D  X 0x07→1B
C 0x08→06  V 0x09→19  ISO_Section 0x0A→64  B 0x0B→05  Q 0x0C→14  W 0x0D→1A  E 0x0E→08  R 0x0F→15
Y 0x10→1C  T 0x11→17  1 0x12→1E  2 0x13→1F  3 0x14→20  4 0x15→21  6 0x16→23  5 0x17→22
= 0x18→2E  9 0x19→26  7 0x1A→24  - 0x1B→2D  8 0x1C→25  0 0x1D→27  ] 0x1E→30  O 0x1F→12
U 0x20→18  [ 0x21→2F  I 0x22→0C  P 0x23→13  Return 0x24→28  L 0x25→0F  J 0x26→0D  ' 0x27→34
K 0x28→0E  ; 0x29→33  \ 0x2A→31  , 0x2B→36  / 0x2C→38  N 0x2D→11  M 0x2E→10  . 0x2F→37
Tab 0x30→2B  Space 0x31→2C  ` 0x32→35  Delete(backspace) 0x33→2A  Escape 0x35→29
RightCommand 0x36→E7  Command 0x37→E3  Shift 0x38→E1  CapsLock 0x39→39  Option 0x3A→E2
Control 0x3B→E0  RightShift 0x3C→E5  RightOption 0x3D→E6  RightControl 0x3E→E4
F17 0x40→6C  KP. 0x41→63  KP* 0x43→55  KP+ 0x45→57  KPClear(NumLock) 0x47→53  KP/ 0x4B→54
KPEnter 0x4C→58  KP- 0x4E→56  F18 0x4F→6D  F19 0x50→6E  KP= 0x51→67  KP0 0x52→62  KP1 0x53→59
KP2 0x54→5A  KP3 0x55→5B  KP4 0x56→5C  KP5 0x57→5D  KP6 0x58→5E  KP7 0x59→5F  F20 0x5A→6F
KP8 0x5B→60  KP9 0x5C→61  F5 0x60→3E  F6 0x61→3F  F7 0x62→40  F3 0x63→3C  F8 0x64→41  F9 0x65→42
F11 0x67→44  F13 0x69→68  F16 0x6A→6B  F14 0x6B→69  F10 0x6D→43  F12 0x6F→45  F15 0x71→6A
Help/Insert 0x72→49  Home 0x73→4A  PageUp 0x74→4B  ForwardDelete 0x75→4C  F4 0x76→3D  End 0x77→4D
F2 0x78→3B  PageDown 0x79→4E  F1 0x7A→3A  Left 0x7B→50  Right 0x7C→4F  Down 0x7D→51  Up 0x7E→52
```

Modifier keys arrive through `flagsChanged:` on macOS, not keyDown/keyUp, so derive down/up from the change in the flags. Map Command to GUI (0xE3/0xE7). Offer a menu for PrintScreen, Pause, ScrollLock and Ctrl+Alt+Del, since Mac keyboards lack them.

---

## 10. Minimal session algorithm (Swift-oriented)

```
1  POST login.cgi → SID; GET jwsk JNLP → host, user=arg1, pass=arg2, port (arg4, or arg9 with TLS if arg8=="1")
2  TCP connect (NWConnection / POSIX socket, TCP_NODELAY)
3  read 12, write same 12
4  read u8 n, n bytes; require 0x10; write 0x10
5  read 24 (discard); write user24‖pass24 [‖ 0x00 ClientInit pipelined]
6  read u32 result (0 ok); if not pipelined: write 0x00 immediately
7  read ServerInit: 2+2+16, u32 len, name, 12
8  write FBUR(non-incremental, 0,0,w,h)       [optional: 0x37; 7,0x07,0x80; 0x36,0,1]
9  timers: every 3 s write [0x15,0,0,0,1,0,0,0,0]; watchdog 5 s → FBUR(full), 10 s → reconnect
10 loop: t = read u8
     0x00 → parse FBU (§6.2); per rect consume dataLen; decode Hermon/AST; then write FBUR(incremental)
            (if screen-off sentinel: paint "No signal", write FBUR(full) at ≤1 Hz)
     0x04 → 20 bytes (+4 + w*h*2 if flag==1)
     0x16 → 1 (optionally reply 0x15 ack)
     0x33 → 4    0x35 → 5    0x37 → 2 (or 3, see §6)    0x39 → 264    0x3C → 8
     else → protocol error, reconnect with fresh JNLP
11 input: key → 18-byte type 4 with HID; mouse → 18-byte type 5 absolute
12 on close: GET /cgi/logout.cgi
```

---

## Live results (smkvm, 2026-09-30)

Tested against 8 × X9 WPCM450 BMCs (ATEN firmware
"(c) 2010"). First pass with the hosts powered off; video later verified
on POST, BIOS setup, EFI shell and Linux console screens:

- **Verified:** plain `POST /cgi/login.cgi` (name/pwd, not base64) → SID;
  `url_redirect.cgi?url_name=ikvm&url_type=jwsk` returns the JNLP with **8
  arguments** (no TLS args 8/9); RFB on 5900 plaintext; security type 0x10
  followed by a 24-byte blob starting `a7 f9` (PR408's `0xAFF90FB0` pattern);
  credentials = JNLP args 1/2; pipelined ClientInit (shared=1) accepted;
  ServerInit name `ATEN iKVM Server`, 12-byte trailer ending `01 01 01 01`.
- **0x39** arrives right after ServerInit: a=1, b=1, text
  `"<n> ADMIN <client-ip>"` — in control.
- **Screen off:** the BMC answers every FBUR at once with the 0xFD80×0xFE20
  rect, so replying to each one spins (~1000/s). Poll at 1 Hz instead.
- **0x15 keep-alive** every 3 s: accepted (session stayed up, no errors).
- **Verified later:** Hermon tile decode on real traffic (800×600 text and
  graphics modes), resolution changes, keyboard input.
- Still UNVERIFIED: 0x37 length, 0x04 cursor messages, mouse and wheel,
  in-band power.

## Appendices

The research copy of this spec carried verbatim third-party decoder source
(kelleyk/noVNC `core/ast2100/*.js`, mkrasselt1/supermicro-kvm-html5
`hermon.js`). They are not reproduced here for licensing reasons; see the URLs
in §0 and §7. smkvm's decoders are independent implementations of §6.3 and §7.
