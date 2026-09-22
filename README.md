# LanScreen

Low-latency screen streaming from an Apple Silicon Mac to a 2010 iMac running
OS X 10.9.5, over a direct Ethernet cable.

Hardware H.264 encode on the M1 Pro, RTP over raw UDP, hardware decode and
zero-copy OpenGL rendering on the iMac.

Licensed under the [GNU GPL v3](LICENSE).

```
 MacBook Pro M1 Pro (10.0.0.1)                  iMac 2010 (10.0.0.2)
 ─────────────────────────────                  ────────────────────
 ScreenCaptureKit                                    NSOpenGLView
        │  BGRA, GPU-scaled                               ▲
        ▼                                                 │ IOSurface texture
 VideoToolbox H.264                                 VideoToolbox decode
   Baseline, no B-frames                                  ▲
        │  AVCC                                           │ AVCC
        ▼                                                 │
 RTP packetizer  ──── UDP :5000 ───────────────►  RTP depacketizer
 (RFC 6184 FU-A)                                   (FU-A reassembly)
        ▲                                                 │
        └──────────── UDP :5001 ◄─────────────────────────┘
              keyframe requests, stats, RTT probes
```

## What to expect

Measured on an M1 Pro over loopback at 1280×720, 60 fps input, 104 steady-state
frames:

| Stage | Measured |
|---|---|
| Capture (ScreenCaptureKit delivers on change) | up to 1 frame (16.7 ms at 60 fps) |
| **Encode → packetize → wire → depacketize → decode** | **median 14.3 ms** (min 11.8, p95 15.5) |
| of which: decode alone | 2.9 ms |
| OpenGL present, vsync off | < 1 ms |

So roughly **30–35 ms glass-to-glass** at 60 fps, most of it the one frame of
capture plus the encoder's own pipelining.

That pipelining is the dominant cost and it scales with the input frame
interval, not with our code. Feeding the encoder at 120 fps instead of 60 drops
the measured 14.3 ms to 8.6 ms. `RealTime`, `AllowFrameReordering = false` and
`MaxFrameDelayCount` are already set; the Apple Silicon encoder rejects the
last one outright, and `PrioritizeEncodingSpeedOverQuality` measured as a wash.

Sub-frame latency is not achievable with an H.264 round trip. One frame of
capture is the floor before anything else happens.

### If you are measuring with VLC, you are measuring VLC

VLC defaults to `--network-caching=1000`, a **one second** jitter buffer. That
is almost exactly the delay people report when they test this with VLC, and it
has nothing to do with the pipeline. See section 7 for how to measure properly.

## Second monitor, not a mirror

Capturing an existing display shows the iMac what is already on the MacBook's
screen. For the iMac to be a genuine *second* monitor, macOS has to believe a
second monitor is plugged in. Three ways to arrange that:

| Approach | Notes |
|---|---|
| **Virtual display** (default) | Uses CoreGraphics' private `CGVirtualDisplay`. No hardware, no extra port. Verified working on macOS 27. |
| **Hardware dummy plug** | A £8 headless HDMI/DisplayPort adapter. Fully supported API, costs a port. Select "Existing display" and pick it. |
| **DriverKit display extension** | The sanctioned modern path. Needs a special entitlement from Apple and is a project in its own right. Not done here. |

The virtual display is created when you press Start and removed when you press
Stop, so windows you moved onto it will jump back when the stream ends. It is
private API: `LSVirtualDisplay` looks every class up at runtime, so a macOS
that drops or renames them reports "not supported" and you fall back to a dummy
plug rather than the app failing to launch.

Set the display size to the iMac's native resolution. Once the client has said
hello, the host shows the resolution the client reported and offers a **Match**
button.

## 1. Network setup

Connect the two machines with a single Ethernet cable. Both ends auto-MDIX, so
a normal straight-through cable is fine. The M1 Pro will need a USB-C or
Thunderbolt Ethernet adapter.

On **each** machine, System Preferences ▸ Network ▸ Ethernet:

| | Host (M1 Pro) | Client (iMac) |
|---|---|---|
| Configure IPv4 | Manually | Manually |
| IP address | `10.0.0.1` | `10.0.0.2` |
| Subnet mask | `255.255.255.0` | `255.255.255.0` |
| Router | *(leave blank)* | *(leave blank)* |
| DNS | *(leave blank)* | *(leave blank)* |

Leaving the router blank keeps the machines' normal internet connection (Wi-Fi)
working — only 10.0.0.x traffic uses the cable.

Confirm with `ping -c3 10.0.0.2` from the host.

### Optional: jumbo frames

Fewer, larger packets means less per-packet overhead on the old machine's NIC.
Set **MTU: Custom 9000** under Network ▸ Ethernet ▸ Advanced ▸ Hardware on both
machines, then pick the 8900-byte option in the host UI.

Check your USB-C adapter supports it first — many cap at 4000 or ignore the
setting, and a mismatched MTU shows up as everything working until the first
keyframe, then nothing.

### Optional: bigger socket buffers on the iMac

The client asks for an 8 MB receive buffer. OS X clamps that to
`kern.ipc.maxsockbuf`. If the client logs a complaint about it:

```bash
sudo sysctl -w kern.ipc.maxsockbuf=8388608
```

To make it stick across reboots, add `kern.ipc.maxsockbuf=8388608` to
`/etc/sysctl.conf`.

## 2. Build the host (M1 Pro, current Xcode)

```bash
./Host/build_app.sh
open build/LanScreenHost.app
```

The first launch will ask for Screen Recording permission. Grant it in
System Settings ▸ Privacy & Security ▸ Screen Recording and relaunch.

Note: there is no `NSScreenCaptureUsageDescription` Info.plist key — screen
recording is not one of the usage-string permissions. What matters is that the
app is a real bundle with a stable bundle ID and a signature, which
`build_app.sh` produces. If a rebuild makes macOS forget the grant, remove the
app from that Screen Recording list and add it back.

The app is deliberately **unsandboxed**. A sandboxed app cannot open a raw UDP
socket to an arbitrary host without the network-client entitlement, and
combining screen capture with the sandbox is a fight with no upside for a LAN
tool.

## 3. Build the client (iMac, Xcode 6.2)

### Get the source across

The build compiles `Common/rtp_protocol.c`, the single shared copy of the wire
format, so `Client/` on its own is not enough.

**Over the cable** (easiest once the network from section 1 is up). On the
MacBook:

```bash
./Tools/serve_to_imac.sh
```

Then on the iMac, in Terminal:

```bash
cd ~
curl -O http://10.0.0.1:8000/LanScreen-client.tar.gz
mkdir -p LanScreen && tar xzf LanScreen-client.tar.gz -C LanScreen
cd LanScreen
```

Ctrl-C the server on the MacBook once it has transferred.

`scp` is deliberately not used here: current OpenSSH refuses the SHA-1 host
keys that OS X 10.9's sshd offers, so it fails with "no matching host key type"
unless you re-enable deprecated crypto. Plain HTTP over a cable between two
machines you own avoids the argument.

**Or a USB stick.** Copy the `Common`, `Client` folders and `README.md` — that
is all the iMac needs.

### Build

```bash
./Client/build.sh
```

Expected output:

```
==> Xcode    /Applications/Xcode6.2.app/Contents/Developer
==> SDK      .../SDKs/MacOSX10.9.sdk
==> compiler .../XcodeDefault.xctoolchain/usr/bin/clang
==> target   macOS 10.9 x86_64

Built: /Users/you/LanScreen/build/LanScreenClient.app
```

If Xcode 6.2 is somewhere the script does not look:

```bash
DEVELOPER_DIR=/Applications/Xcode6.2.app/Contents/Developer ./Client/build.sh
```

The script finds the Developer directory itself and exports it, so you do not
need to have run `xcode-select`. It drives `clang` against the 10.9 SDK and
assembles the `.app` by hand — deliberately, because a hand-written `.pbxproj`
that Xcode 6.2 accepts is far more fragile than a shell script, and this way
you can build over SSH or from a Terminal window without launching the IDE.

**This build only works on the iMac.** Current Xcode toolchains no longer ship
`libarclite_macosx.a`, which ARC needs for a deployment target below 10.11, so
running the same script on the MacBook stops with an explanation rather than a
cryptic linker error. To build a test client for the modern Mac, see section 7.

### If the build fails

| Message | Fix |
|---|---|
| `could not find an Xcode installation` | Pass `DEVELOPER_DIR=/Applications/Xcode6.2.app/Contents/Developer` |
| `could not find a macOS SDK under ...` | Xcode 6.2 is installed but incomplete — open it once so it finishes installing components |
| `rtp_protocol.h file not found` | You copied `Client/` without `Common/`. Copy the whole tree |
| `xcrun: error: active developer path ... does not exist` | `sudo xcode-select -s /Applications/Xcode6.2.app/Contents/Developer` |
| `clang: command not found` | Open Xcode 6.2 once and let it install its command line tools |

<details>
<summary>Building in the Xcode 6.2 GUI instead</summary>

1. File ▸ New ▸ Project ▸ OS X ▸ Application ▸ Cocoa Application.
2. Uncheck "Use Storyboards" and "Create Document-Based Application".
3. Delete the generated `AppDelegate.*`, `MainMenu.xib`, and `main.m`.
4. Drag in everything from `Client/src/` and `Common/rtp_protocol.c`.
5. Build Settings ▸ Header Search Paths: add the path to `Common/include`.
6. Build Settings ▸ Base SDK: OS X 10.9; Deployment Target: 10.9.
7. Build Phases ▸ Link Binary With Libraries, add: `VideoToolbox`,
   `CoreMedia`, `CoreVideo`, `OpenGL`, `IOSurface`, `ImageIO`, `CoreServices`.
8. Info ▸ delete the "Main nib file base name" key.

The source deliberately avoids anything newer than Xcode 6.2 understands: no
nullability annotations, no lightweight generics, no `@import`.
</details>

### First run

```bash
./build/LanScreenClient.app/Contents/MacOS/LanScreenClient \
    -host 10.0.0.1 -windowed YES -stats YES
```

Run it windowed with statistics the first time — if something is wrong, the
overlay says what. Once it works, drop the flags for fullscreen.

You can also double-click the `.app`, but then it uses whatever `defaults` you
have set rather than command-line arguments:

```bash
defaults write com.lanscreen.client host 10.0.0.1
```

## 4. Run

In the host app, pick a **Source**:

- **Virtual display** — creates a headless second monitor. Set the size to the
  iMac's native resolution (1920×1080 for the 21.5", 2560×1440 for the 27" —
  but see the resolution warning in section 6).
- **Existing display** — mirrors a display that already exists, including a
  hardware dummy plug.

On the iMac:

```bash
./build/LanScreenClient.app/Contents/MacOS/LanScreenClient -host 10.0.0.1
```

Then press **Start** in the host app. If you chose the virtual display, open
System Settings ▸ Displays to arrange where it sits relative to the built-in
screen.

The client announces itself on the control channel, and the host answers by
forcing an immediate keyframe — so the order you start them in does not matter.
Start either one first.

### Client options

Settings are read from the command line, or from `defaults`, or fall back to
built-in values.

```bash
# windowed, with the statistics overlay showing
LanScreenClient -host 10.0.0.1 -windowed YES -stats YES

# force BGRA output if 2vuy misbehaves on this hardware
LanScreenClient -host 10.0.0.1 -pixelFormat bgra

# persist a setting instead of passing it every time
defaults write com.lanscreen.client host 10.0.0.1
```

| Key | Default | Meaning |
|---|---|---|
| `host` | `10.0.0.1` | Host address for the control channel |
| `videoPort` | `5000` | UDP port to receive RTP on |
| `controlPort` | `5001` | Host's control port |
| `windowed` | `NO` | Run in a window instead of fullscreen |
| `vsync` | `NO` | Wait for vblank (cleaner, ~1 refresh slower) |
| `stats` | `NO` | Show the statistics overlay |
| `pixelFormat` | auto | `2vuy` or `bgra` |

### Client keys

| Key | Action |
|---|---|
| `S` | Toggle statistics overlay |
| `V` | Toggle vsync — tearing vs. latency |
| `K` | Force a keyframe request |
| `F` | Toggle fullscreen |
| `Q` / `Esc` | Quit |

## 5. Power: staying awake, and waking up

Two separate problems with two separate mechanisms.

### Staying awake while you are using the MacBook

The iMac has no idea anything is happening: nobody is touching its keyboard or
mouse, so Energy Saver blanks the display on its usual timer and your second
monitor goes dark mid-sentence.

The client takes an `IOPMAssertionTypePreventUserIdleDisplaySleep` assertion for
as long as a stream is arriving, and releases it the moment the stream stops. So
the iMac stays lit while you are using it and sleeps normally when you are not.
Nothing to configure.

You can see the assertion in the client's statistics overlay (press `S`), or on
the iMac with:

```bash
pmset -g assertions
```

### Waking the iMac when you come back to the MacBook

This uses Wake-on-LAN. The host sends a magic packet — six `0xFF` bytes followed
by the iMac's MAC address sixteen times — which the network card recognises on
its own while the rest of the machine is asleep.

**On the iMac, tick Energy Saver ▸ "Wake for network access".** Without it the
card is powered down in sleep and none of this does anything.

The host sends a magic packet when:

- you press Start,
- this Mac wakes from sleep,
- and then every three seconds for about thirty seconds, until the client
  checks in. The Ethernet link has to renegotiate after a wake, so a single
  packet sent immediately usually goes nowhere.

It sends to both the iMac's own address and the subnet broadcast, on ports 9 and
7, because sleeping cards differ in what they will accept. The socket is bound
to this Mac's address on the direct link, so the packet leaves by the cable
rather than following the default route out over Wi-Fi.

### The MAC address

The host needs the iMac's MAC and **cannot look it up itself**. Since macOS 11
hardware addresses are masked from unentitled apps — `getifaddrs`, `arp` and the
routing `sysctl` all return `02:00:00:00:00:00` or nothing, signed or not.

So the client reports its own. OS X 10.9 predates that restriction, so it reads
its real address and sends it in the HELLO message; the host stores it and
reuses it from then on. **Connect once with the iMac awake and waking works from
then on.**

To set it up before the first connection, run this on the MacBook with the iMac
awake and paste the result into the host's Client MAC field:

```bash
arp -n 10.0.0.2
```

(That works in Terminal, which has permissions the app does not.)

If the client ever reports `02:00:00:00:00:00`, it refuses to send it rather
than have the host store a wake address that can never work.

### Sleeping together

With "Stop streaming when this Mac sleeps" on, the host sends BYE as the MacBook
goes to sleep. The client drops its keep-awake assertion and the iMac sleeps on
its own schedule, instead of sitting lit up all night showing a frozen frame.

## 6. Tuning

Start at **1280×720 @ 60 fps** and work up. The 2010 iMac's GPU decodes 1080p
in hardware, but how comfortably depends on which GPU it has.

| Symptom | Change |
|---|---|
| Client stutters, `decode` over ~15 ms | Drop resolution, or 60 → 30 fps |
| Blocky during motion | Raise bitrate |
| `packets lost` climbing | Lower bitrate; check the cable; raise `kern.ipc.maxsockbuf` |
| Tearing | Press `V` for vsync, costs ~1 refresh |
| Above 1080p | Don't. The old GPU falls back to software decode |

Baseline profile is the default and the right choice: no CABAC, no B-frames,
and it is what the 2010-era hardware decoder handles best. Main profile is
offered for a few percent better quality per bit, and uses CAVLC entropy coding
even then for the same reason.

## 7. Testing without the iMac

Three levels, fastest first.

### Headless loopback — unit tests plus a real encode/decode round trip

```bash
./Tests/run_loopback_test.sh
```

Runs deterministic unit tests (FU-A reassembly byte-for-byte, AVCC framing, RTP
sequence wraparound at 65535, the packet-loss recovery state machine, control
message round trips), then encodes real H.264 with the host's own VideoToolbox
and RTP code, sends it over a real UDP socket, and decodes it with the client's
real receive/depacketize/decode path. Reports the latency distribution.

`FRAMES` and `FPS` are overridable: `FRAMES=150 FPS=120 ./Tests/run_loopback_test.sh`

### Render test — the OpenGL path, checked numerically

```bash
./Tests/run_render_test.sh
```

Builds the client natively for this Mac, sends it a four-quadrant colour
pattern, has it snapshot its own framebuffer, and checks the colours survived
`BGRA → H.264 → 2vuy → GL_YCBCR_422_APPLE → RGB`. A wrong colour matrix, a
video-range mismatch, or a flipped image fails here instead of surprising you
once the code is on a machine in another room. Opens a window for a second or
two.

It leaves `build/LanScreenClient.app` as a native binary — re-run
`./Client/build.sh` on the iMac for the real 10.9 build.

### Full host, real client, one machine

The honest local latency test. Set the host's client address to `127.0.0.1`,
build the client natively, and run it:

```bash
ARCH=$(uname -m) MIN_VERSION=14.0 ./Client/build.sh
./build/LanScreenClient.app/Contents/MacOS/LanScreenClient \
    -host 127.0.0.1 -windowed YES -stats YES
```

Press Start in the host. The client's overlay shows its own decode and render
times; the host shows capture-to-wire and an estimated glass-to-glass figure.

### Watching in VLC or ffplay

The host writes an SDP file once it is streaming; **Reveal test .sdp** in the
Network section opens it in the Finder.

**Do not judge latency from VLC's defaults.** It buffers a full second:

```bash
vlc --network-caching=0 --no-audio /path/to/lanscreen.sdp
```

`ffplay` is better behaved for this:

```bash
ffplay -protocol_whitelist file,udp,rtp -fflags nobuffer -flags low_delay \
       -framedrop -probesize 32 -analyzeduration 0 /path/to/lanscreen.sdp
```

Even then you are measuring that player's presentation timing, not the
pipeline. Use the real client for a real number.

## 8. Troubleshooting

**About a second of delay when testing with VLC** — That is VLC's own
`--network-caching`, which defaults to 1000 ms. Run it with
`--network-caching=0`, or better, use the real client (section 7).

**The iMac's screen blanks while I am using it** — The keep-awake assertion is
not being taken. Check the client overlay (`S`) for "awake assertion held". If
it says released, the stream is not arriving. If the client logs that it could
not prevent display sleep, set the iMac's Energy Saver display sleep to Never as
a workaround.

**The iMac does not wake up** — In order of likelihood: "Wake for network
access" is not ticked in the iMac's Energy Saver; the host has no MAC address
for it (check the Power section of the host window); or the MacBook's Ethernet
adapter has not finished renegotiating. The host retries for thirty seconds
after a wake, so give it that long. Press "Wake now" to test a single packet —
it reports which addresses it sent to and from.

**Waking works but the iMac shows nothing** — It woke but the host is not
streaming. Turn on Start automatically, or press Start.

**Host: "Could not create a virtual display"** — The private API is gone or
changed on this macOS. Switch Source to "Existing display" and use a hardware
HDMI dummy plug instead.

**Virtual display appears but shows an empty desktop** — That is correct; it is
a new, empty display. Drag a window onto it, or set it as the main display in
System Settings ▸ Displays.

**Host: "Could not list displays"** — Screen Recording permission. System
Settings ▸ Privacy & Security ▸ Screen Recording. Remove and re-add the app if
it is already listed.

**Client: black screen, "Waiting for…"** — Check `ping` works both directions.
Check the host's client IP field. If the overlay says *"receiving packets but no
complete frame yet"*, packets are arriving but frames are not completing, which
almost always means an MTU mismatch: set both machines back to MTU 1500 and the
host to the 1400-byte packet size.

**Client: "Could not create a decode session"** — The stream uses something this
machine cannot decode. Switch the host to Baseline profile and drop to 1080p or
below.

**Green blocks or smearing that never clears** — Should be impossible; the
client refuses to decode anything until a clean IDR arrives. If you see it, the
back-channel is not getting through. Check that the host's control port is
reachable and watch the *Keyframe requests* counter in the host UI.

**Picture freezes when the screen is static** — Should not happen.
ScreenCaptureKit stops delivering frames when nothing changes, so the host
re-encodes the last frame as a keyframe once a second to cover exactly this. If
it does freeze, the heartbeat is not reaching the client.

**Host UI shows "Encoder hints the hardware declined"** — Harmless.
`MaxFrameDelayCount` in particular is rejected by the Apple Silicon encoder;
`RealTime` and `AllowFrameReordering` already do the work that setting would.

## 9. What this does not do

- **No audio.** Video only.
- **No wake from a powered-off iMac.** Wake-on-LAN wakes a sleeping machine, not
  a shut down one.
- **No input forwarding.** The iMac is a display, not a control surface.
- **No encryption.** Plain RTP on a direct cable between two machines you own.
  Do not run this across a network you do not control.
- **IPv4 only**, one client at a time.

## Licence

Copyright (C) 2026 Kendal Percimoney.

LanScreen is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.

That is copyleft: if you distribute a modified version, you have to release your
changes under the GPL too.

Two things the licence does not cover:

- **H.264 is patent-encumbered.** An open source licence grants copyright
  permission, not patent permission. In practice this matters little here
  because the encoding and decoding are done by Apple's VideoToolbox on Apple
  hardware, which Apple licenses, but the distinction is worth knowing if you
  port the codec parts elsewhere.
- **`CGVirtualDisplay` is private Apple API.** Using it is a choice about
  stability and App Store eligibility, not about licensing. See
  `Host/VirtualDisplay/`.

## Layout

```
Common/                  the wire format, compiled into both ends
  include/rtp_protocol.h
  rtp_protocol.c
Host/                    Swift + SwiftUI, macOS 13+
  Sources/
    LanScreenHostApp.swift   UI
    StreamController.swift   pipeline wiring, heartbeat, stats
    CaptureEngine.swift      ScreenCaptureKit
    VideoEncoder.swift       VideoToolbox H.264
    RTPPacketizer.swift      AVCC -> RFC 6184
    ControlChannel.swift     back-channel, host side
    UDPSocket.swift          POSIX sockets
Client/                  Objective-C, OS X 10.9 SDK
  src/
    LSReceiver.m         bound socket, receive thread
    LSDepacketizer.m     FU-A reassembly, loss detection
    LSDecoder.m          VideoToolbox decode thread
    LSGLView.m           IOSurface -> OpenGL, zero copy
    LSControlClient.m    back-channel, client side
    LSAppDelegate.m      window, overlay, keys
Host/VirtualDisplay/
  LSVirtualDisplay.m     private CGVirtualDisplay, looked up at runtime
  WakeOnLAN.swift        magic packets, bound to the direct link
Client/src/
  LSPowerManager.m       keeps the iMac awake while a stream is showing
Tools/
  serve_to_imac.sh       packages the client source and serves it to the iMac
Tests/
  depacketizer_test.m    unit tests
  loopreceive.m          loopback receiver + latency measurement
  LoopSend/main.swift    loopback sender
  checkpattern.m         colour round-trip verification
  WakeCheck/main.swift   Wake-on-LAN subnet maths and interface selection
  run_loopback_test.sh   headless: unit tests + encode/decode round trip
  run_render_test.sh     the OpenGL path, checked numerically
```
