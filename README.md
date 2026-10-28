# LanScreen

A 2010 iMac on OS X 10.9.5 as a second display for an Apple silicon Mac, over a
direct Ethernet cable. The iMac's own keyboard and mouse can drive the Mac, and
the Mac's sound can play on the iMac.

The Mac captures a virtual display with ScreenCaptureKit and encodes it in
hardware with VideoToolbox. The stream goes over RTP on plain UDP, and the iMac
decodes it with VideoToolbox and draws it with OpenGL straight from the
decoder's IOSurface, without copying it.

Licensed under the [GNU GPL v3](LICENSE).

```
 MacBook Pro M1 Pro (10.0.0.1)                  iMac 2010 (10.0.0.2)
 ─────────────────────────────                  ────────────────────
 ScreenCaptureKit                                    NSOpenGLView
        │  4:2:0, GPU-scaled                              ▲
        ▼                                                 │ IOSurface texture
 VideoToolbox H.264                                 VideoToolbox decode
   High profile, no B-frames                              ▲
        │  AVCC                                           │ AVCC
        ▼                                                 │
 RTP packetizer  ──── UDP :5000 ───────────────►  RTP depacketizer
 (RFC 6184 FU-A)                                   (FU-A reassembly)

 system audio    ──── UDP :5002 ───────────────►  AudioQueue
   (PCM)

 control         ◄─── UDP :5001 ───────────────►  control
   to the iMac:  the pointer, volume, brightness, pings
   to the Mac:   keyboard and mouse, "frame decoded", keyframe requests, stats
```

## What to expect

On the Mac, capture to a decoded frame takes about **8 ms**, measured through
the loopback harness on the M1 Pro with the real encoder, sockets and decoder.
Before that comes up to one frame of capture, because the screen is only
captured when it changes.

On the iMac, decoding is the slow part. OS X 10.9 decodes H.264 on the iMac's
CPU, at about 18 ms a frame plus 14 ms a megabit, so how smoothly things move
depends on the bitrate:

- **Typing and the pointer.** Typing makes small frames, which the iMac
  decodes in about 20 ms. The pointer is not in the video at all: it is sent
  on its own 120 times a second and drawn by the iMac, so it moves at once
  whatever the video is doing.
- **Zooming a photo or scrolling fast** makes big frames. The iMac can decode
  roughly 36 frames a second at the default 25 Mb/s, and 17 at 49. The host
  sends the next frame the moment the iMac says it has decoded the last one, so
  a busy picture gets fewer frames rather than falling behind.
- **When the screen stops**, the host sends the picture again 0.3 s later at
  near-lossless quality (50.4 dB), so a still picture is sharp whatever the
  bitrate.

Everything that was measured on the way, and what was tried and dropped, is in
[docs/NOTES.md](docs/NOTES.md).

### If you are measuring with VLC, you are measuring VLC

VLC defaults to `--network-caching=1000`, a **one second** jitter buffer. That
is almost exactly the delay people report when they test this with VLC, and it
has nothing to do with the pipeline. See section 8 for how to measure properly.

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

## Tested devices

| Role | Machine | OS | Status |
|---|---|---|---|
| Host | MacBook Pro (M1 Pro) | macOS 27.0 | Working |
| Client | iMac 21.5-inch, Mid 2010 | OS X 10.9.5, Xcode 6.2 | Working, in daily use |
| Client | the same iMac | Windows 7 x64 | Phase 0: builds, not yet run end to end |

The 21.5-inch panel is 1920×1080, which happens to be exactly the resolution
this is tuned for: the stream maps 1:1 with no scaling at either end.

Not tested, in rough order of how likely they are to work:

- **iMac 27-inch, Mid 2010.** Same vintage, but its panel is 2560×1440, which
  is a lot more for a CPU decoder. Stream 1080p to it and let the iMac scale,
  rather than matching its native resolution.
- **Other macOS versions on the host.** Needs macOS 13 or later; the virtual
  display uses private API that could change in any release.
- **Anything between OS X 10.10 and macOS 12** as a client. The client only
  needs 10.9 APIs, so it should be fine, but nobody has run it.

## Install from a release

Each [release](https://github.com/kendalpercimoney/imac-second-display/releases)
has the two apps, zipped, if you would rather not compile anything:

| App | Runs on | Architecture | Minimum OS | Signing |
|---|---|---|---|---|
| `LanScreenHost.app` | the Mac | arm64 | macOS 13 | Ad-hoc |
| `LanScreenClient.app` | the iMac | x86_64 | OS X 10.9 | Unsigned |

The client was built on the iMac itself with Xcode 6.2, because no current
toolchain can target 10.9 (section 3).

Neither is notarised, so macOS quarantines them after download and refuses to
open them. On the Mac, clear that with:

```bash
xattr -dr com.apple.quarantine LanScreenHost.app
```

On OS X 10.9, right-click the client and choose Open instead.

The host needs three permissions on the Mac. It asks for each the first time it
needs it:

- **Screen Recording**, to capture the display.
- **Accessibility**, so the iMac's keyboard and mouse can reach the Mac. The
  menu bar panel says when it is missing and has an Allow button.
- **Local Network**, to send to the iMac.

Permissions are tied to the app's signature, and a release is signed ad-hoc, so
each update is a new app to macOS: it asks for Screen Recording and
Accessibility again, separately from a copy you built yourself. The first launch
after an update can also find every packet refused while macOS re-checks Local
Network. The host notices, relaunches itself once, and the picture appears about
ten seconds later.

**Update both apps together.** The protocol between them grows between
releases. A host paired with an older client still streams, and its panel says
what that client cannot do.

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

### No jumbo frames

Leave the MTU at 1500 on both machines. Jumbo frames are not available on this
pair: the iMac's built-in Ethernet needs a third-party kext for an MTU above
1500, and a USB Ethernet adapter on an Apple silicon Mac is held to 1500 by
macOS. The host used to offer an 8900-byte packet size; it no longer does, and
if a larger size is ever configured it cuts packets to what the link carries.

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

The first launch asks for Screen Recording permission. Grant it in System
Settings ▸ Privacy & Security ▸ Screen Recording and relaunch. Accessibility is
granted the same way, for the iMac's keyboard and mouse.

**The signature decides whether those grants survive a rebuild.** macOS keys
them to the signature's designated requirement. `build_app.sh` signs with this
Mac's Apple Development certificate when it has one, and then a rebuild is the
same app to macOS and keeps its permissions. Any Apple ID can make one, free, in
Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates. Without one it signs ad-hoc,
whose requirement is the hash of that exact binary, so every rebuild asks again.
`LS_SIGN_IDENTITY` picks a different certificate, and `-` forces ad-hoc.

That certificate is named after its owner's Apple ID, often an email address,
and the signature carries the name. So do not publish a build signed with it;
section 12 makes one that is safe to publish.

There is no `NSScreenCaptureUsageDescription` Info.plist key, because screen
recording is not one of the usage-string permissions. What matters is that the
app is a real bundle with a stable bundle ID and a signature, which
`build_app.sh` produces. If macOS still forgets a grant, remove the app from
that list in System Settings and add it back.

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

**Or share the folder.** Turn on File Sharing on the Mac, connect to it from
the iMac's Finder, and build in place:

```bash
cd /Volumes/<you>/<path>/LanScreen
./Client/build.sh
```

That puts the client straight into `build/` on the Mac, which is also where
`Tools/make_release.sh` looks for it.

### Getting the built client back

There is no scp in either direction. To bring the app the iMac just built back
to this Mac, serve it from the iMac — in the directory that contains
`LanScreenClient.app`:

```bash
python -m SimpleHTTPServer 8000
```

and pull it here:

```bash
./Tools/fetch_from_imac.sh
```

It checks what arrived: an x86_64 Mach-O with a 10.x deployment target, and not
the same bytes that are already in `build/`. A 404 page saved under the right
filename looks fine until someone runs it on the iMac.

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
cryptic linker error. To build a test client for the modern Mac, see section 8.

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
  but see the resolution warning in section 7).
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
| `audioPort` | `5002` | UDP port to receive audio on |
| `windowed` | `NO` | Run in a window instead of fullscreen |
| `vsync` | `NO` | Wait for vblank (cleaner, ~1 refresh slower) |
| `stats` | `NO` | Show the statistics overlay |
| `audio` | `YES` | `NO` never plays the Mac's sound, and tells the host not to send it |
| `input` | `YES` | `NO` never hands the iMac's keyboard and mouse to the Mac |
| `pixelFormat` | auto | `2vuy` or `bgra` |
| `colourCheck` | `YES` | `NO` skips the colour self-check and uses the driver's conversion |
| `diagnose` | `NO` | `YES` logs, every 5 s, the centre pixel of the decoded frame and of what was drawn, plus packet and decode counts |
| `ackFrames` | `YES` | `NO` stops telling the host when each frame is decoded, so its fallback pacing can be tested |
| `decodeDelayMs`, `decodeDelayPerMbitMs` | `0` | Testing only: slow every decode by this much, plus this much per megabit, so a fast Mac can stand in for the iMac |

### Client keys

While the iMac's keyboard is its own, that is, before you click the picture or
after Control-Option-Escape:

| Key | Action |
|---|---|
| `S` | Toggle statistics overlay |
| `V` | Toggle vsync: tearing against latency |
| `K` | Force a keyframe request |
| `F` | Toggle fullscreen |
| `Q` / `Esc` | Quit |

While the keyboard is driving the Mac, every key goes to the Mac, Q and Esc
included. Control-Option-Escape gives it back.

## 5. Keyboard, mouse, sound and brightness

The switches are in the host's menu bar panel.

**Use the iMac's keyboard and mouse** (on by default). When the client's window
comes to the front, or you click the picture, the iMac's keyboard and mouse
drive the Mac. The pointer moves across both displays, off the edge of the
virtual display and on to the Mac's own screen, the way a second monitor's
would. **Control-Option-Escape** gives them back, and so does switching away
from the client. Command-Tab, Command-Space and Mission Control never reach an
app, so they stay with the iMac. The Mac needs the Accessibility permission for
any of this.

**Send this Mac's audio** (off by default). The Mac's sound plays on the iMac,
uncompressed: 48 kHz stereo, about 1.5 Mb/s. Volume and a delay slider sit
beside it. The delay runs from −50 to +250 ms, and negative is the useful
direction: the iMac's buffers make sound arrive late rather than early.

**Brightness** sets the iMac's own panel from the Mac, and is put back to what
it was when the client quits.

How each of these was built and tested is in
[docs/NOTES.md](docs/NOTES.md#the-imacs-keyboard-and-mouse-drive-the-mac).

## 6. Power: staying awake, and waking up

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

## 7. Tuning

The defaults are what this was tuned to on the 21.5-inch iMac: 1920×1080 at 60
fps, High profile, 25 Mb/s, with the near-lossless still refresh on.

**The bitrate decides how smoothly things move on the iMac.** OS X 10.9 decodes
on the iMac's CPU, and the cost follows the bitrate. The host never sends more
frames than the iMac reports decoding, so a higher bitrate means bigger frames
and fewer of them:

| Bitrate | Frames a second the iMac can decode, roughly |
|---|---|
| 15 Mb/s | 44 |
| 25 Mb/s (default) | 36 |
| 49 Mb/s | 17 |

25 is the setting to use. Higher is sharper in motion and visibly less smooth;
lower is the reverse. Either way the picture is refreshed at near-lossless
quality once it stops changing.

**Video mode** is one switch in the panel that swaps in a second, higher
bitrate (60 Mb/s unless you change it) and back, for moving pictures where
detail matters more than smoothness. On this iMac that means fewer frames a
second, for the reason above.

| Symptom | Change |
|---|---|
| Motion is jerky | Lower the bitrate, or turn Video mode off |
| Blocky while moving, fine once still | Raise the bitrate, if the frame rate allows |
| **Quality drops when you stop moving the cursor** | "Keep this Mac at full performance" in the panel. See below |
| `packets lost` climbing | Check the cable; raise `kern.ipc.maxsockbuf` (section 1); lower the bitrate |
| Tearing | Press `V` for vsync, costs ~1 refresh |
| Small, brightly coloured icons look stepped | That is the stream carrying colour at half resolution (4:2:0), which is what 10.9's decoder takes. The iMac cannot put it back |
| Above 1080p | Don't. More pixels is more for the CPU to decode |

A screen that is not changing sends nothing at all, so leaving the iMac on a
still screen costs neither machine anything.

### Quality drops when you stop touching the MacBook

macOS App Naps an app that is not frontmost on a system with no keyboard or
trackpad activity: it lowers the process's quality of service and coalesces its
timers. For a video encoder that shows up as an uneven frame rate and a softer
picture — and it recovers the moment you move the cursor, because that counts
as user activity.

The host now declares itself busy for as long as it is streaming
(`ProcessInfo.beginActivity` with `.userInitiated` and `.latencyCritical`, the
latter being what turns off timer coalescing). The toggle is in the Power
section and is on by default; the window tells you whether the assertion is
actually held.

When capturing an existing display rather than a virtual one, it additionally
keeps that display awake, because a display that has gone to sleep stops
producing frames to capture.

If the picture still degrades with that on, watch **Encoded fps** and **Sending
Mb/s** in the host window while you stop moving the cursor:

| What you see | What it means |
|---|---|
| Both drop | Something is still throttling. Check the toggle is asserted |
| fps drops, Mb/s holds | The source stopped producing frames — a browser throttling a background window, for instance. Not something this can fix |
| fps holds, Mb/s drops | The encoder is hitting its bitrate ceiling. Raise the bitrate |
| Both hold, but the iMac looks worse | The iMac is dropping frames. Check `dropped` in its overlay (`S`) |

## 8. Testing without the iMac

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

It builds its client into a temporary directory, so the real 10.9 binary in
`build/` is left alone.

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

### Every test

All of these run on the Mac, without the iMac.

| Script | What it checks |
|---|---|
| `run_loopback_test.sh` | Unit tests, then a real encode, UDP send and decode, with the latency distribution |
| `run_render_test.sh` | The OpenGL path, numerically |
| `run_colour_test.sh` | Twelve mid-tone patches end to end, to within 4 code values, four ways |
| `run_cursor_test.sh` | The pointer lands on the right pixel, and an update never waits on a draw |
| `run_input_test.sh` | Keyboard and mouse forwarding, both ends |
| `run_audio_test.sh` | PCM from the host's packetiser to the client's parser, sample for sample |
| `run_still_test.sh` | The near-lossless still refresh: when it happens, and that it works |
| `run_decoder_drop_test.sh` | Falling behind never puts a damaged frame on screen |
| `run_client_soak_test.sh` | Twelve hours of frames, and the RTP timestamp wrap |
| `run_mtu_test.sh` | The packet size follows what the link can carry |
| `run_bitrate_switch_test.sh` | Video mode's bitrate reaches the encoder |
| `run_settings_audit.sh` | Every control changes the stream or says it does not |
| `run_overlay_cost_test.sh` | What the statistics overlay costs the render path |
| `run_nap_check.sh` | Whether an app with no window gets throttled |
| `run_client_compat_check.sh` | The client uses nothing newer than OS X 10.9. Run it before building on the iMac |
| `run_windows_core_test.sh` | The Windows client's shared core, on real streams |
| `run_windows_build_test.sh` | The Windows build, and whether Windows 7 would load it |

## 9. Troubleshooting

**About a second of delay when testing with VLC** — That is VLC's own
`--network-caching`, which defaults to 1000 ms. Run it with
`--network-caching=0`, or better, use the real client (section 8).

**Motion is jerky, or the picture trails behind** — The iMac decodes on its
CPU, so the bitrate sets how many frames a second it can show: lower it
(section 7). Make sure the client is as new as the host, too. An older one does
not say when it has decoded each frame, so the host has to estimate, and if
*Keyframe requests* in the host window climbs while things move, the estimate
is losing.

**Black on the iMac after updating or rebuilding the host** — macOS's Local
Network check forgets a changed app and can refuse every packet its first
launch sends. The host notices and relaunches itself once, so wait ten seconds.
If it stays black, the panel says so: check System Settings ▸ Privacy &
Security ▸ Local Network.

**It asks for Screen Recording or Accessibility after every rebuild** — The
build is signed ad-hoc. Make an Apple Development certificate (section 2) and
rebuild once more.

**The iMac's keyboard and mouse do nothing on the Mac** — Accessibility. The
panel says "Needs Accessibility permission." and has an Allow button. After an
update or an ad-hoc rebuild it has to be granted again.

**Blocky, blotchy corruption when the picture gets busy** — zooming a photo,
scrolling fast, playing video. Almost always packet loss on a burst rather than
anything to do with encoding quality. A 1080p keyframe is around 490 KB, or some
360 packets back to back, and if the client's receive buffer cannot absorb that
while the decode thread is busy the tail is dropped.

Check the client's overlay (`S`) for the `recv buffer` line. Under a megabyte is
too small. Then raise the ceiling on the iMac:

```bash
sudo sysctl -w kern.ipc.maxsockbuf=8388608
```

Add `kern.ipc.maxsockbuf=8388608` to `/etc/sysctl.conf` to make it stick. Also
watch **Packets lost** in the host window: if it climbs during busy pictures
that confirms it, and if it stays at zero the problem is elsewhere.

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
streaming. Press Start streaming in the panel, or launch the host with
`open -a LanScreenHost --args --autostart` so it starts by itself.

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
complete frame yet"*, packets are arriving but frames are not completing. Set
both machines back to MTU 1500: the host fits its packets to the link it
finds, and the panel says when it has had to.

**Client: "Could not create a decode session"** — The stream uses something this
machine cannot decode. Switch the host to Baseline profile and drop to 1080p or
below.

**Green blocks or smearing that never clears** — Should be impossible; the
client refuses to decode anything until a clean IDR arrives. If you see it, the
back-channel is not getting through. Check that the host's control port is
reachable and watch the *Keyframe requests* counter in the host UI.

**The picture freezes** — A still screen sends nothing, on purpose, and the
client knows the host is there from the control channel's ping. If the Mac's
screen is changing and the iMac's is not, look at Sending and Encoded in the
panel. Zero there means capture has stopped: Screen Recording, or the Mac slept
(the stream resumes after it wakes). Moving there means the packets are not
arriving. The client also logs a line a second if it is decoding frames it
cannot draw.

**Host shows "Encoder hints declined"** — Harmless. The Apple silicon encoder
rejects some settings outright, and nothing depends on them.

**Keeping a record** — Quit the host and start it with
`open --env LS_LOG=1 -a LanScreenHost`, and it logs a line a second of
throughput, latency, loss and keyframes. Read it with
`/usr/bin/log show --predicate 'subsystem == "com.lanscreen.host"' --last 15m`.
The full path matters: in zsh, `log` is a built-in, and `log show` prints
nothing.

## 10. What this does not do

- **No wake from a powered-off iMac.** Wake-on-LAN wakes a sleeping machine, not
  a shut down one.
- **No full-resolution colour.** H.264 as 10.9 decodes it carries colour at half
  resolution, so thin coloured lines and small saturated icons are softer than
  on the Mac.
- **No encryption.** Plain RTP on a direct cable between two machines you own.
  Do not run this across a network you do not control.
- **IPv4 only**, one client at a time.

## 11. Windows 7 on the same iMac

The same iMac can boot 64-bit Windows 7, and `Client/windows/` has a client for
it, cross-built on the Mac (`brew install nasm mingw-w64` first):

```bash
./Client/windows/build.sh
```

It is phase 0: it decodes through DXVA2, shows the picture fullscreen, and
reports back to the host's panel, so it can answer whether Windows on this
hardware decodes the stream fast enough. It does not yet draw its own pointer,
play sound or send the keyboard and mouse. It is built against `msvcrt.dll`, so
Windows 7 needs nothing installed, but it has not yet been run end to end on
the iMac. Windows 7 gets no security fixes any more: keep it on the cable to the
Mac. [The notes](docs/NOTES.md#windows-7-on-the-same-imac-phase-0) cover
getting it across, the firewall rule it needs, and how it is put together.

## 12. Making a release

```bash
./Tools/make_release.sh v2.1.0
```

builds the host from the current commit, refusing if anything is uncommitted,
and takes the client the iMac built from `build/`, refusing it if it is older
than the last change to its source. The host is signed **ad-hoc**, not with
your certificate, because the certificate's name is usually your Apple ID email
and codesign writes it into the app. Its debug map is stripped too, because the
linker leaves the full path of every object file in it, home directory
included.

Then both apps, and both zips as they will be downloaded, are searched for this
Mac's git email, the name on every signing certificate in the keychain, and the
home directory. Any of them stops the release. None of them is written down in
the repository: the script reads them from the Mac it runs on. It prints the
checksums for the release notes and the `gh release create` command, and
publishes nothing itself.

The repository is public, so commit with GitHub's noreply address rather than
your own:

```bash
git config user.email <id>+<username>@users.noreply.github.com
```

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
Common/                    the wire format, compiled into both ends
  include/rtp_protocol.h
  rtp_protocol.c
Host/                      Swift + SwiftUI, macOS 13+
  build_app.sh             builds and signs LanScreenHost.app
  Sources/
    LanScreenHostApp.swift   menu bar scene, settings window, activation policy
    MenuBarPanel.swift       the panel behind the status item
    SettingsView.swift       the Settings window: what you set once
    AeroStyle.swift          the Aero look: glass, gloss, bevels, meters
    StreamSettings.swift     every setting, saved in UserDefaults
    StreamPlan.swift         settings -> pipeline, in one place, with what it ignored
    StreamController.swift   pipeline wiring, pacing, heartbeat, stats
    CaptureEngine.swift      ScreenCaptureKit
    VideoEncoder.swift       VideoToolbox H.264
    StillRefinement.swift    when to resend a still picture at near-lossless quality
    RTPPacketizer.swift      AVCC -> RFC 6184
    ControlChannel.swift     back-channel, host side
    CursorTracker.swift      the pointer, sent beside the video rather than in it
    InputInjector.swift      the iMac's keyboard and mouse, as events on this Mac
    AudioSender.swift        system audio -> fixed PCM packets
    WakeOnLAN.swift          magic packets, bound to the direct link
    UDPSocket.swift          POSIX sockets
    UISnapshot.swift         --render-ui, draws every view to PNG and exits
    UnattendedRun.swift      --autostart/--quit-after/--with-window, for measuring
  VirtualDisplay/
    LSVirtualDisplay.m       private CGVirtualDisplay, looked up at runtime
Client/                    Objective-C, OS X 10.9 SDK
  build.sh                 builds LanScreenClient.app, on the iMac
  src/
    LSAppDelegate.m          window, overlay, keys
    LSReceiver.m             bound socket, receive thread
    LSDepacketizer.m         FU-A reassembly, loss detection
    LSDecodeQueue.m          never decodes a frame whose predecessor was dropped
    LSDecoder.m              VideoToolbox decode thread, "frame decoded"
    LSGLView.m               IOSurface -> OpenGL, zero copy, render thread
    LSControlClient.m        back-channel, client side
    LSInputForwarder.m       the iMac's keyboard and mouse, sent to the Mac
    LSAudioReceiver.m        the audio socket and its receive loop
    LSAudioPlayer.m          AudioQueue, and the delay line in front of it
    LSPowerManager.m         keeps the iMac awake while a stream is showing
    LSBrightness.m           the iMac's panel, driven from the other machine
  core/                    portable C, shared by the Windows client, tested here
    ls_depacketizer.c        RTP -> Annex B access units, wait for a keyframe after loss
    ls_decode_queue.c        the same rules as LSDecodeQueue
    ls_decoder.c             FFmpeg H.264, hardware when given a device
  windows/                 Windows 7 x64 client, phase 0
    setup_toolchain.sh       a compiler for msvcrt.dll, assembled from llvm-mingw
    build_ffmpeg.sh          FFmpeg 7.1.5, H.264 + DXVA2 only, pinned by SHA-256
    build.sh                 the program and its zip
    main.c, network.c, decode.c, display.c
    run.cmd, README.txt      what goes in the zip beside it
Tools/
  serve_to_imac.sh         packages the client source and serves it to the iMac
  fetch_from_imac.sh       brings the built client back the other way
  make_release.sh          release zips, signed ad-hoc and checked for anything identifying
Tests/                     run_*.sh are listed in section 8; the rest are what they run
docs/
  NOTES.md                 what was measured, what it bought, and what was rejected
```

## How it got here

Every choice in this project was measured before it was kept, and
[docs/NOTES.md](docs/NOTES.md) says what was measured and what was rejected.
Some of what is in there:

- [Why the pointer is drawn by the iMac](docs/NOTES.md#the-pointer-is-drawn-by-the-client),
  not sent in the video.
- [Two encoder settings that cost 5 ms each](docs/NOTES.md#capturing-in-420-and-two-settings-that-were-costing-5-ms-each),
  on since the beginning, which hid each other.
- [Moshing](docs/NOTES.md#moshing-decoding-a-frame-whose-predecessor-was-thrown-away):
  why the iMac never decodes a frame whose predecessor was thrown away.
- [The iMac decodes on its CPU](docs/NOTES.md#the-imac-decodes-on-its-cpu-so-the-host-sends-what-it-can-decode),
  and how the host paces to it.
- [Colour, measured rather than assumed](docs/NOTES.md#colour-measured-rather-than-assumed),
  and why the iMac converts with its own shader.
- [Black after a rebuild](docs/NOTES.md#black-after-a-rebuild-or-an-update-macoss-local-network-check):
  macOS's Local Network check.
