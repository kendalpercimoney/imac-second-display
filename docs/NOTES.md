# LanScreen: what was measured, and what it bought

The engineering notes behind [the README](../README.md), in the order the work
was done. Everything here was measured before it was kept. Several suggestions
that sounded reasonable were measured and dropped, and two settings that had
been on since the beginning turned out to be the largest single cost in the
pipeline.

Later sections sometimes overturn earlier ones. The biggest: the iMac was
believed to decode in hardware until it was measured decoding on its CPU
([below](#the-imac-decodes-on-its-cpu-so-the-host-sends-what-it-can-decode)).
Where an earlier section rests on a belief that turned out wrong, it says so
there.

## A still screen sends nothing

Measured on a static 1920×1080 desktop, encoding with the real settings:

| Change | Effect |
|---|---|
| **A still screen now sends nothing** | Was 4.03 Mb/s and a full IDR decode every second. Now zero. Free — already done |
| **Keyframe interval 2s → 10s** | 73% less data on a nearly-still screen, and that many fewer decode spikes. Default is 5s |
| **1080p → 720p** | Roughly half the pixels to decode. The single biggest lever if the iMac is struggling |
| **60 → 30 fps** | Halves both encode and decode work |
| **Lower bitrate** | Less to parse, less to decode, fewer packets |

The first one is worth understanding because it changes what silence means. A
still screen used to be re-encoded as a forced keyframe once a second so that a
client joining mid-session would still get a picture. But a client that joins
sends HELLO, and a client that loses a packet asks for a keyframe, and both
already trigger one on demand — so the periodic version was paying 4 Mb/s and a
decode spike every second to re-send a picture nobody needed.

The client now takes "the host is still there" from the control channel's
once-a-second ping instead of from video traffic, which is why it can sit
happily on a completely silent video socket.

If the iMac is still struggling, look at `decode` in its statistics overlay
(press `S`). Above about 15 ms per frame at 60 fps it cannot keep up, and the
shallow decode queue will start dropping frames rather than accumulating
latency — visible as `dropped` climbing in the same overlay.

**Later:** on the iMac, the bitrate turned out to be the lever rather than the
resolution, because 10.9 decodes on the CPU at a cost that follows the bitrate;
and the host now sends only as many frames as the iMac reports decoding, so the
queue no longer has to drop them. See
[the iMac decodes on its CPU](#the-imac-decodes-on-its-cpu-so-the-host-sends-what-it-can-decode).

## The pointer is drawn by the client

`showsCursor` is off, and the pointer is sent as its own small UDP message a
hundred and twenty times a second. The client draws it over the last decoded
frame.

A pointer inside the video is exactly as old as the video: encoded, sent,
decoded, displayed. Sent separately it arrives in well under a millisecond and
is drawn on the next refresh. Since the pointer is what your eye tracks, this is
the change you actually feel. VNC has done it for the same reason for decades.

**The trade-off is real and you will see it:** the pointer now runs slightly
ahead of a window you are dragging, because the window moves with the video and
the pointer does not.

## Capturing in 4:2:0, and two settings that were costing 5 ms each

`ScreenCaptureKit` hands over `420v` instead of BGRA, so the encoder is never
converting a frame before it can start. That part was always right.

The other two were not, and both had been on since the beginning: VideoToolbox's
`EnableLowLatencyRateControl`, and `kVTCompressionPropertyKey_RealTime`. Between
them they were costing **5.4 ms of the 13.5 ms** this pipeline took.

They hid behind each other. The low-latency rate controller is in charge of
timing when it is on, so `RealTime` makes no difference while it is enabled —
and measuring the two together, which is what had always been done, shows
neither. Four hundred frames through the loopback harness, interleaved, three
rounds, mean capture-to-decoded-frame:

| | mean | median | p95 | min |
|---|---|---|---|---|
| **4:2:0, neither** | **8.04–8.13 ms** | 7.7–7.9 | 11.3–12.4 | **5.1** |
| BGRA, neither | 8.70–8.82 ms | 8.4–8.6 | 12.3–12.8 | 5.8 |
| 4:2:0 + real time | 13.00–13.43 ms | 12.7–13.1 | 16.9–17.4 | 10.3 |
| 4:2:0 + low latency | 13.46–13.55 ms | 13.3–13.5 | 16.8–17.3 | 10.2 |
| BGRA + low latency | 14.15–14.39 ms | 14.0–14.2 | 18.2–18.5 | 11.2 |

No overlap in any statistic in any round, including the minimum, which has no
noise in it at all. 4:2:0 is worth about 0.7 ms on top.

`RealTime = true` does not make the encoder hurry; it appears to make
VideoToolbox pace delivery to the frame duration. The signature is that with it
on, the median hold (17.9 ms) is *higher* than the mean (14.9) — a queue being
fed out on a clock rather than emptied.

**`Tests/EncoderLatency` says the opposite about the low-latency rate
controller**, and that is where the original belief came from: 9.4 ms of hold
time against 14.5. It measures submit-to-callback on a batch fed as fast as it
will go, which turns out not to be the same quantity as latency. The loopback
harness times the real pipeline and disagrees by 5 ms. Where they conflict, the
one that measures the whole path wins.

Turning the low-latency rate controller off also gets the full requested bitrate
back (it was undershooting ~1%), restores Baseline in place of Constrained
Baseline, and returns 0.2 dB of mean PSNR. It was better at exactly one thing:
the single worst frame, 33.6 dB against 32.1.

## What a zoom costs

Zooming a photograph is the worst thing this pipeline is asked to carry: every
pixel moves and none of it moves in a straight line, so inter prediction has
almost nothing to work with. "It goes blocky when I zoom" has no answer that is
not a number, so here is the number, 1080p60, mean and worst-frame PSNR over 400
frames:

| bitrate | mean | worst frame |
|---|---|---|
| 25 Mb/s | 40.24 dB | **32.05 dB** |
| 49 Mb/s | 42.89 dB | **34.82 dB** |
| 80 Mb/s | 44.35 dB | 37.32 dB |
| 120 Mb/s | 45.57 dB | 38.92 dB |

Below about 35 dB is visibly soft and below 30 is blocky, and it is the worst
frames that get noticed — so a zoom at 49 Mb/s sits right on that line and a
zoom at 120 does not. This is what Video mode is for.

**The burst cap has nothing to do with it**, which is worth writing down because
it keeps being the next suggestion. During a sustained zoom at 49 Mb/s, from 2x
to 16x to removing it entirely: 42.87, 42.89, 42.90, 42.91, 42.87 dB. That is
the same number five times.

## Above 50 Mb/s is a different stream

An H.264 level is a promise about how hard a stream is to decode, and VideoToolbox
picks it for itself from the resolution, frame rate and bitrate. 1080p at 60 fps
already needs Level 4.2, whose bitrate ceiling is 50 Mb/s. Measured on this
encoder:

| bitrate | level |
|---|---|
| 25, 40, 49, 50 Mb/s | 4.2 |
| 55, 80, 120 Mb/s | **5.0** |

That matters because a hardware decoder that does not support a level does not
refuse the stream. VideoToolbox decodes it in software instead, with no error.
Asking for hardware decode (which the client always has) is a request, not a
guarantee.

So the client now asks the session which decoder it actually got, logs it with
the level when the session comes up —

    decode session up, pixel format 2vuy, H.264 level 4.2, HARDWARE decode

— and reports it to the host, which shows it in the Link group. If it says
software while the stream is above 50 Mb/s, the panel says that is the likely
reason and to try 50 or less. If it says software *below* 50, the level is not
the explanation and the panel does not offer it as one.

Whether a 2010 iMac's decoder takes Level 5.0 is exactly the thing that could
not be checked from here, which is why this is a report and not a cap.

**Later, on the iMac:** OS X 10.9 does not answer the question. The client
logs `decoder unknown` there, and the iMac turned out to decode on its CPU at
every level and bitrate — see
[the iMac decodes on its CPU](#the-imac-decodes-on-its-cpu-so-the-host-sends-what-it-can-decode).

## Sharper, and the right colours

Nothing here sharpens anything. A sharpening filter makes a picture look crisper
by changing its pixels, which is the opposite of what you want when you are
editing photos on it. This is about losing less of the picture on the way.

**The geometry was already exact.** The 21.5-inch iMac is 1920x1080, the same
as the stream, so every pixel lands on exactly one pixel of the panel, and the
client samples the centre of each one. Nothing is scaled or blended. What was
left was compression and colour.

### A still picture is refreshed at near-lossless quality

When you stop moving, the picture on the iMac used to stay at whatever quality
its last moving frame got, because nothing is sent until the screen changes
again. On a zoom into a photograph with fine grain, that last frame measured
33.5 dB at 25 Mb/s and 36.1 dB at 49 — visibly soft. Re-sending it does very
little: the encoder decides the picture is good enough for its bitrate and sends
265-byte frames saying nothing changed. Raising its quality on the fly is
ignored, the same way raising its bitrate is.

So once the screen has been still for 0.3 seconds, the host sends the picture
again as a single keyframe from a second encoder running at constant quality.
It measures **50.4 dB**, past the point anyone can see a difference, for about
1.3 MB, which is 10 ms on a gigabit cable. It is matched to the level of the
stream it joins, so it carries identical parameter sets and the iMac's decoder
carries on without rebuilding. The motion encoder's next frame is then a
keyframe too, because the picture the iMac predicts from has changed under it.

Not every pause earns one. Typing sends small frames and a caret blinks twice a
second; a refresh after each would be a megabyte per blink. It is earned by real
change — 300 KB of moving frames since the last refresh — and the keyframes it
forces do not count towards the next. If it ever misbehaves:

```bash
defaults write com.lanscreen.host ls.refineStill -bool false
```

### High profile, which keeps more detail for the same bitrate

| profile, same bitrate | mean, 25 / 49 Mb/s | worst frame, 25 / 49 Mb/s |
|---|---|---|
| Baseline | 40.22 / 42.83 dB | 32.11 / 34.82 dB |
| **High** | **41.32 / 43.51 dB** | **32.86 / 35.91 dB** |

Worth about a quarter more bitrate, for nothing; almost all of it is CABAC, the
more efficient entropy coder. The Profile setting offered Main as well, with
CABAC switched off on the theory that it was too much work for a 2010 decoder.
Main without CABAC is bit-for-bit identical to Baseline, so that option never did
anything; it is gone, and a saved "Main" comes back as High. High is the default
for new installs. That was on the belief that the iMac decodes H.264 in
hardware, where CABAC costs nothing. It does not: under 10.9 it decodes on its
CPU, where CABAC is not free. High against Baseline has not been measured there.

High also keeps the stream at Level 4.2 up to 62 Mb/s rather than 50, so Video
mode can go further before the iMac might fall back to software decoding.

### Colour, measured rather than assumed

The host captures with ScreenCaptureKit, which converts to YCbCr with the BT.709
matrix — measured against an RGB capture of the same screen, 0.11 code values
out against 2.70 for the older BT.601 one. The client has to convert back with
the same matrix, or every colour that is not grey or fully saturated shifts. But
the stream carried no colour information at all, so the iMac had to guess.

On a current Mac the built-in conversion follows a tag on each decoded frame,
and falls back to BT.601 when there is none: 14 code values too green on a leaf,
17 at worst end to end. Whether 10.9 tags its frames, and whether a 2010
graphics driver reads the tag, could not be checked from here. So now:

- The stream says what it is: BT.709 matrix and primaries, video range. Not its
  transfer curve: OS X 10.9's decoder refuses every frame of a stream tagged
  with sRGB's (`transfer_characteristics` 13) as bad data, error -8969, which on
  the iMac was a black screen. The client never used that tag anyway.
- The client **checks itself** on the first frame: it draws four mid-tones
  through its own conversion, with the real frame's tags, reads the pixels back
  and compares them with what BT.709 says they should be. If the built-in
  conversion is off, it switches to a small shader that does the BT.709 maths
  itself. It logs what it found, and the panel says so only if neither could be
  made right.

On the iMac itself it measured both: 10.9's built-in conversion is 14 code
values off, so it does not follow the tags, and the shader is within 1. So the
iMac converts with the shader, and this check is what made its colours right.

`./Tests/run_colour_test.sh` checks twelve mid-tone patches end to end, to
within 4 code values, four ways: tagged frames, the shader forced, untagged
frames with the built-in conversion forced — which must get them wrong, or the
test proves nothing — and untagged frames left to decide, which must switch to
the shader and get them right. The render test's quadrants are pure primaries
with ±40 of tolerance and could never have caught any of this.

### For accurate colour on the iMac

The stream carries sRGB, and the iMac shows those values as they are. So the
picture is as accurate as the iMac's panel is to sRGB. To make it accurate,
**calibrate the iMac itself to sRGB** (D65 white, sRGB tone curve) on the iMac,
with a colorimeter if you have one. A calibration's tone curves are applied by
the iMac's graphics card to everything it shows, LanScreen's picture included.

Capturing in the LanScreen display's own colour space, and giving that display
the iMac's profile on the Mac, would in principle let macOS colour-manage for the
iMac directly. It was measured and not done: left without a colour space,
ScreenCaptureKit does not simply pass the display's values through — on a
display whose profile converts to sRGB unchanged, it altered 14% of the picture
by up to 95 code values, against none between two captures with the same
setting — and what it does instead could not be pinned down.

### Not done

- **4:4:4 colour.** Colour detail is half resolution each way in H.264 as the
  iMac's decoder takes it. Thin coloured lines and small coloured text show it;
  photographs mostly do not. Measured
  [further down](#stepped-edges-on-small-colourful-icons-420-not-the-client).
- **Rendering at twice the resolution and scaling down.** Text would be
  smoother, but photos would be resampled rather than shown pixel for pixel.

## Windows 7 on the same iMac: phase 0

The same iMac can boot 64-bit Windows 7, and there is a client for it in
`Client/windows/`. This first phase answers one question before anything else
is built on it: does Windows on this hardware decode the host's stream in
hardware, quickly enough? So it receives the stream from the unchanged host,
decodes it through DXVA2, shows it fullscreen, and reports back; the host's
panel shows Decoder, Decode, Render and glass to glass for it exactly as it
does for the OS X client. It does not yet draw its own pointer, play sound or
send the iMac's keyboard and mouse. Its HELLO says so, and the host puts the
pointer into the video instead.

Windows 7 gets no security fixes any more. Keep it on the cable to the Mac.

Build it on the Mac (`brew install nasm mingw-w64` first; mingw-w64 is only
used by the build test, to read the program's import table):

```bash
./Client/windows/build.sh
```

The first time, that fetches the compiler and cross-builds FFmpeg 7.1.5 —
only the H.264 decoder and DXVA2 — both checked against pinned SHA-256s, and
makes
`build/windows/LanScreen-Windows.zip`. To get it across the cable, serve that
folder from the Mac and open `http://10.0.0.1:8000/` in the iMac's browser:

```bash
python3 -m http.server 8000 --bind 10.0.0.1 --directory build/windows
```

Then `run.cmd` in the zip. The `README.txt` beside it covers the two things
Windows needs once: the address 10.0.0.2 on the Ethernet adapter, and one
firewall rule, which `run.cmd` asks permission to add. That rule allows UDP port 5000, from 10.0.0.1
only, for `lanscreen.exe` only. It has to exist beforehand, because otherwise
Windows asks behind the fullscreen picture, where nobody can see the question.

How it is put together, and why:

- **FFmpeg with DXVA2, not Media Foundation.** Media Foundation's low-latency
  decoding mode arrived in Windows 8. FFmpeg's decoder is told to output each
  picture as soon as it is decoded and is given a single thread. Measured on
  the Mac with the same code in software: automatic threading without that
  setting holds back eight frames, 133 ms at 60 fps, before the first picture.
- **The reassembly and the moshing rules are shared C**, in `Client/core/`:
  a port of the OS X client's depacketizer and decode queue, which emits
  Annex B for FFmpeg instead of AVCC. They are tested on the Mac, rule by
  rule, and then with real streams from the host's encoder in both profiles:
  every access unit gives its picture at once, and the colour patches come
  through within 3 code values.
- **Direct3D 9Ex, exclusive fullscreen**, so the picture skips the desktop
  compositor and its frame of latency, with a frame latency of one so
  Direct3D does not queue three frames ahead. The decoder writes into DXVA2
  surfaces on the same device, and the video processor converts them into the
  back buffer, so a picture never leaves the graphics card.
- **The colour conversion is told it is BT.709, then checked.** Before the
  first picture, the twelve test colours go through the same video processor
  and are read back. The worst error goes to the host in STATS, which warns
  above 4 code values, as it does for the Mac client.
- **An 8 MB receive buffer.** Winsock's default on Windows 7 is 8 KB, less
  than one keyframe, which arrives as hundreds of packets inside a millisecond.

What phase 0 cannot know until it runs on the iMac: whether the graphics
driver decodes the host's stream (High profile at Level 4.2 by default) in
hardware or quietly falls back to software, what decoding and presenting cost,
and whether the driver converts as BT.709 when asked. `lanscreen.log` beside
the program records all of it, along with the graphics card and driver.

The first build, made with Homebrew's mingw-w64, would not start on the iMac:
"api-ms-win-crt-convert-l1-1-0.dll is missing". Homebrew's compiler only
targets the Universal C Runtime, which Windows 7 has only once a particular
update is installed. The program is now built against msvcrt.dll, which every
Windows has, so it needs nothing installed. The compiler for that is
llvm-mingw, which publishes an msvcrt build only for Linux and a macOS build
only for the UCRT; both come from one release with one compiler, so
`Client/windows/setup_toolchain.sh` puts the Linux build's Windows libraries
under the macOS compiler.

`./Tests/run_windows_build_test.sh` reads the import table and fails on any
DLL Windows 7 lacks, a C runtime other than msvcrt.dll, any function from
Windows 8 or later, or a header asking for a newer Windows to load it. Nothing
on this Mac can run the program, so that is checked rather than tried.

## Video mode

One switch in the panel, meant to be reached for mid-stream: it swaps the
everyday bitrate for a higher one kept separately, so turning it off puts the
desktop back exactly as it was. 25 to 60 Mb/s is +3.3 dB at 1080p on hard
content. The bitrate is settable on a live compression session and does not
change the SPS, so it takes effect on the next frame and the iMac never notices
anything happened.

**Changing it replaces the compression session** rather than setting a property
on the running one, because setting the property does not work.
`kVTCompressionPropertyKey_AverageBitRate` on a live session returns `noErr` and
changes nothing: asked to go from 25 to 60 Mb/s mid-stream on content that
wanted every bit of it, the encoder carried on at 25.8 Mb/s. The first version
of Video mode did exactly that and the report back was "video mode doesn't
change the stats", which is precisely what it was doing.
`./Tests/run_bitrate_switch_test.sh` measures both ways and requires that the
one the app uses works (25.8 → 61.4 Mb/s) and that the one it used to use still
does not — if a future macOS fixes the property, that assertion fails and says
so.

Replacing the session costs a keyframe and a few tens of milliseconds. The old
session is stopped *before* the new one starts: VideoToolbox serialises output
callbacks within a session but not between two of them, and both would be
writing into the packetizer's single packet buffer.

**It costs no latency**, which is not what was intended. It was going to spend
some: let the encoder hold frames to look ahead, loosen the burst cap so a cut
is not rationed out over the following second. Neither survived measurement.
`MaxFrameDelayCount` does nothing whatsoever on this encoder — 4 measures
14.98 ms against 14.93 for 0 — and loosening the burst cap from 4x to 16x bought
0.05 dB on the worst frame while spending 4% more bitrate for it. There was no
latency here worth buying anything with.

B-frames are the one real lever left, and they are refused deliberately: the
client decodes synchronously and draws whatever comes out, so it has no way to
put decode order back into display order.

On the 2010 iMac, which decodes on its CPU, a higher bitrate also means fewer
frames a second, so there Video mode trades smoothness for detail
([below](#the-imac-decodes-on-its-cpu-so-the-host-sends-what-it-can-decode)).

## The iMac's keyboard and mouse drive the Mac

While the client's window is in front, the iMac's own keyboard and mouse
control the Mac it is a display for. The pointer moves **across both displays**
— off the edge of the virtual display and on to the Mac's own screen, the way a
second monitor works — because motion is sent as deltas, not as a position on
the iMac's screen. A position could only ever land somewhere on the virtual
display; a delta can carry the pointer off it.

- **Taking over** happens when the window becomes the front window, or when you
  click the picture. That click is not sent on: landing on whatever is under
  the Mac's pointer would be a surprise.
- **Giving back** is Control-Option-Escape. Not Command-Option-Escape, which is
  Force Quit and best left alone. Switching away from the window gives it back
  too.
- While it is taken, everything that reaches the app goes to the Mac, including
  Command-Q and Escape, which used to quit the client. What never reaches an app
  — Command-Tab, Command-Space, Mission Control — stays with the iMac.

The iMac's pointer is parked in the middle of the window and frozen there
(`CGAssociateMouseAndMouseCursorPosition`), so it never reaches the iMac's own
screen edges. What you see is the Mac's pointer, drawn by the client as before.

**The Mac needs the Accessibility permission**, without which posted events go
nowhere — no error, no event. The panel says when it is missing and has an
Allow button. Like Screen Recording, the grant is tied to the app's code
signature, so a rebuild of the host means granting it again.

**Only the client that said HELLO is listened to.** The host otherwise follows
whoever sent it a well-formed datagram last, which is fine for knowing where to
send pings and not fine for deciding who may type on this Mac. Matched by IP,
because the client's source port changes when it has to replace its socket.

**Nothing is left held down.** UDP loses the odd datagram, and a lost key-up is
a key held on the Mac forever. So the client sends everything it holds four
times a second while forwarding, and the host lets go of anything it thinks is
held that the client does not list. The reverse is deliberately not repaired:
that is a lost key-down, and typing it late would be worse. A client that goes
quiet with something held has it released after a second and a half, and
stopping the stream releases everything before anything else is torn down.

Smaller things that each had to be right: a drag is a drag event, not a move
with a button down, or nothing can be dragged; the iMac's click count is carried
across, or nothing opens on double-click; key repeat is the iMac's own, forwarded
as it happens; motion is scaled to the size the picture is drawn at; and
fractions of a point are carried rather than rounded away, or a slow hand never
moves the pointer at all.

`./Tests/run_input_test.sh` checks both ends — the client's forwarder through to
the bytes it sends, and the host's injector with every event recorded instead of
posted, so it needs no permission and moves nothing. Mutation-checked: without
the drag mapping, the edge clamping, the stuck-key reconciliation, the fraction
carrying, the refusal to engage, or the exact release shortcut, it fails.

## Audio, uncompressed and on its own socket

The Mac's system audio goes to the iMac as raw PCM: 48 kHz, stereo, 16-bit,
straight from ScreenCaptureKit. There is a switch for it and a volume slider,
both in the menu bar panel.

**Not compressed.** That is 1.5 Mb/s against 25 to 50 for the video, on a link
with a gigabit spare. An AAC round trip would add more algorithmic latency than
the entire rest of the pipeline costs, to save bandwidth that is not scarce.

**Not on the video socket.** A lost audio packet is concealed and forgotten; it
must never do what a lost video packet does and ask for a keyframe. And audio
must not queue behind the several hundred packets a keyframe arrives as.

**The volume slider is on the host and the speakers are not**, so the value goes
over the control channel as thousandths and the client hands it to its audio
queue, which applies it for free. The samples on the wire are never touched.
It is repeated every two seconds, because the control channel is UDP and a lost
one would otherwise leave the iMac at a volume nobody asked for.

Packets are 256 frames — 5.33 ms, 1024 bytes of payload, which fits inside a
standard MTU with room to spare, so audio never fragments even when the video
has to be cut down to fit.

Between the socket and the speaker is a 200 ms ring buffer that starts playing
at 25 ms. That is headroom, not a target: 25 ms is about where a network hiccup
stops being audible, and every millisecond beyond it is a millisecond of lag
against the picture. When it overflows the *oldest* audio is dropped, because
what just arrived is what the screen is showing now.

The header is network byte order like everything else here. The samples are
deliberately not: they are little-endian because both machines are, and
byte-swapping ninety-six thousand samples a second on a 2010 CPU would buy
nothing. The format field says so explicitly rather than leaving it an unwritten
exception.

**The client must be rebuilt again.** It gained an audio socket and a player,
and it advertises the capability in its HELLO — a host will not send audio to a
client that has not said it can play it, rather than pouring 1.5 Mb/s into a
socket nobody is listening to.

### What was checked

`./Tests/run_audio_test.sh` pushes 20,000 frames of a ramp through the real
packetiser in deliberately awkward chunks — 100 frames, then 333, then 1, then
1024 — and checks what comes out of the parser at the other end of a real
socket. The seam being tested is that ScreenCaptureKit delivers audio in
whatever sized pieces it likes while the wire wants whole frames: getting it
wrong swaps the channels permanently, or loses a few samples per callback, and
neither fails loudly. Every sample arrived identical and in order, packets
numbered contiguously, timestamps advancing by exactly the frames sent.

The ring buffer is covered in the unit tests: that it stays silent before it has
primed, returns what went in, counts an underrun and pads with silence when it
runs dry, and on overflow drops the oldest audio rather than the newest.

Both were confirmed by breaking them. With the packetiser throwing away the
remainder between callbacks, 7,079 of 20,000 frames arrive. With the ring
dropping the newest audio instead of the oldest, the ordering check fails.

## Audio delay, and why negative is the direction that matters

Audio takes a much shorter path than video — capture, one hop, play — while
video goes through an encoder, the network and a decoder. You would expect sound
to arrive early and need holding back. In practice it does not, because the far
end puts it in a jitter buffer and then in an audio queue, and those cost more
than the whole video pipeline saves. So the useful direction is usually
*negative*: pull the sound earlier.

The slider runs from −50 ms to +250 ms and is remembered between runs like every
other setting. It is sent over the control channel and applied by the client,
which is where the sound actually comes out.

What it changes is how much audio the client's ring holds back at all times.
That is what makes the ring a delay line rather than just somewhere packets
land: keep 25 ms behind permanently and every sample waits 25 ms. Zero plays
each packet the instant it arrives.

**There is a floor, and the app is honest about it.** Underneath the ring sits
the audio queue's own buffers, and audio already handed to the hardware cannot
be pulled back. Those were three buffers of 10 ms; they are now three of 5,
which halves the floor to 15 ms specifically so the negative end of the slider
has somewhere to go. Below that, pulling audio earlier would mean delaying the
video, which is the one thing this project exists not to do.

The client's overlay shows all three numbers — what is buffered, what is being
held deliberately, and the hardware floor — so the slider can be set by reading
rather than by guessing.

The unit tests cover it: that a 10 ms target holds exactly 10 ms back, that the
next millisecond to arrive releases exactly one millisecond, and that what comes
out is the oldest audio rather than the newest. Confirmed by breaking it both
ways — ignoring the target, and making the setter do nothing. The signed wire
value has its own test, because a negative number travelling through an unsigned
field is precisely the kind of thing that works for positive values and silently
does not for negative ones; that one was confirmed by masking the sign bit off.

## Checking 10.9 compatibility without walking to the iMac

The client is built on the iMac against the 10.9 SDK, but it is written on a
current Mac against a current SDK, where anything Apple has added in the last
decade compiles perfectly happily. `clock_gettime` went in exactly that way:
fine here, `use of undeclared identifier CLOCK_REALTIME` over there, and the
only way to find out was to go and build it on the other machine.

    ./Tests/run_client_compat_check.sh

compiles every client source against the current SDK with a 10.9 deployment
target and `-Werror=unguarded-availability`, which reports anything newer than
the target. It reproduces that exact error, and it is the last line of the
suite that matters before handing a build over.

Note the flag has no `-new` suffix. `-Wunguarded-availability-new` sounds like
the stricter one and is the opposite: it only warns about things newer than the
SDK's own baseline, and it lets `clock_gettime` through silently. That was worth
checking rather than assuming, because a compatibility check that passes
everything is worse than none.

The wait in the render loop now uses `pthread_cond_timedwait_relative_np`, which
has been in macOS since 10.4 and needs no wall clock at all.

## The client asks for no permissions, and says what it can do

OS X 10.9 has no permission prompts for anything the client does: playing audio,
reading and setting display brightness, and opening UDP sockets all just work or
just do not. So there is nothing to grant, and nothing to have forgotten to
grant. What there *was* is silent failure, which looks the same from the outside.

It now prints one line at startup saying exactly what it managed:

    [LanScreen] capabilities: audio yes, brightness NO (no display exposes it), pointer yes

and it tells the host the same thing in its HELLO. The host greys the brightness
slider out and says why, rather than moving a control that does nothing at the
far end — the same treatment the pointer and audio controls already get.

## Why the iMac was getting hot

Two things, both measured on the client under a fixed video load by reading the
process's own CPU time rather than by watching a fan.

**An idle audio queue is not idle.** It asks for a buffer a hundred times a
second whether or not anything is arriving, and fills each one with silence. On
an M1 that measured 0.24 seconds of CPU per 10 seconds — 2.4 per cent of a core,
continuously, to play nothing — and a 2010 core is several times slower. The
queue now pauses after two seconds of quiet and resumes the moment a packet
arrives. Idle cost dropped to 0.05 s per 10 s, five times less.

**Drawing faster than the panel can show.** The pointer arrives 120 times a
second and every arrival marks the view dirty, so on a 60 Hz iMac half of every
full-screen redraw was of a frame nobody would ever see. Moving the pointer cost
+76 per cent CPU on top of the video; capping draws at the panel's refresh rate
takes 20 per cent of that back.

The render thread now waits out the rest of the refresh interval before drawing,
on the condition variable rather than in a sleep, so everything arriving during
the wait folds into the same draw and the newest state is still what gets drawn.
It also made the pointer *more* responsive, not less — the slowest handover
across four runs went from 3531 µs to 1000 µs, because the render thread spends
more of its time with the lock released and less of it drawing while holding one.

    ./Tests/run_cursor_test.sh                # uses the panel's real rate
    MAXDRAWS=60 ./Tests/run_cursor_test.sh    # what the iMac does
    MAXDRAWS=1000 ./Tests/run_cursor_test.sh  # effectively uncapped

The override exists because this is developed on a 120 Hz panel and runs on a
60 Hz one, so without it the saving is invisible on the machine doing the
measuring.

### Measured and left alone

**No memory leaks.** Resident size is flat across repeated bursts, and `leaks`
finds nothing rooted in any LanScreen code — the 417 it reports are AppIntents
and XPC allocations the frameworks make at launch.

**The ring buffer costs 0.078 per cent of a core**, 16 ns a frame, despite
copying sample by sample with a modulo each time. `Tests/AudioBench` measures it.
Rewriting it as two memcpys would be faster and would save nothing anyone could
notice.

**Packet size makes no measurable difference to the client.** Cutting frames
into six times as many packets, which is what a 1500-byte link forces, cost
2.02 s against 2.01 s for jumbo frames. That overturns the obvious guess, and it
is worth saying plainly: syscall overhead on a 2010 machine is higher than on
the one this was measured on, so this is the least transferable of these
numbers — but a six-fold change in packet count producing half a per cent here
does not suggest it dominates there.

## Why it popped, which was three separate things

A click is a discontinuity. There were three places producing one.

**Halving the audio queue buffers.** They went from three of 10 ms to three of
5 to give the delay slider more negative range. A 5 ms buffer has to be refilled
two hundred times a second by a 2010 machine that is also decoding 1080p H.264,
and every callback it is late for is a gap. They are back to 10 ms, and the
floor is 30 ms again. The extra 15 ms is worth not hearing.

**Filling gaps with a memset.** When the ring ran dry the shortfall was zeroed,
which steps from wherever the waveform was straight to zero, and then steps back
when audio resumes. Two clicks per gap. It now fades out over about a
millisecond and fades back in, so a gap is a brief dip instead of a crack.

**Letting clock drift accumulate.** The two machines sample at 48 kHz on their
own crystals, which differ by tens of parts per million, so the buffer creeps
one way or the other forever. Left alone it eventually hit the end of the ring
and a whole block was dropped at once — plainly audible, and on a regular
cycle. A single frame is now trimmed when it drifts past its slack, which at
48 kHz is twenty microseconds and inaudible.

The trim rate follows the excess rather than being one frame a packet. One a
packet clears real drift fifty times over, but recovering from an actual
excursion — the audio device stalling, a burst from the host — would then take
a quarter of a minute, and all of that time is lag you hear against the picture.
It is capped at 16 frames, a third of a millisecond.

The test measures the thing itself: the largest jump between consecutive samples
either side of a gap. Stepping to zero from a signal at 20,000 gives a jump of
20,000; the fade gives about 400. Confirmed by putting the memset back, which
reports a step of exactly 20,000 — the click, reproduced as a number.

The client now reports its audio underruns, dropped frames and buffer depth in
its once-a-second statistics, so the host logs them and the panel shows them.
The next time something is audibly wrong there will be numbers rather than
guesses. Older clients send the shorter message and still parse, with the audio
counters simply absent.

## The iMac's screen brightness

A slider on the host, applied on the iMac through `IODisplaySetFloatParameter`.
That is the old IODisplayConnect interface, which is exactly why it works here:
a 2010 panel exposes brightness through it where a current Mac does not. A
display that refuses is not an error — the client says so in its overlay rather
than the host pretending it worked.

It is put back to whatever it was when the client quits. Leaving someone's
screen dark because an app exited would be rude, and on a machine being used as
a second display it would not be obvious what had done it.

The value is repeated every two seconds along with the volume and the audio
delay, for the same reason: the control channel is UDP, and a lost message would
otherwise leave the iMac at a setting nobody chose.

## Sleep, and coming back from it

ScreenCaptureKit stops when the Mac sleeps. "Stop streaming when this Mac
sleeps" decides whether BYE is sent first — so the iMac drops its keep-awake
assertion and sleeps too rather than sitting lit up all night on a frozen frame
— but it does not decide whether the capture survives. Nothing does. The capture
ends either way, which is why turning that setting off did not avoid any of
this.

So the usual way this stream ended was `onStreamStopped`, and that called
`stop()` and left it there. The iMac went on showing the last frame it had been
sent, which from in front of it is indistinguishable from a freeze: the picture
stops and nothing says why. Pressing Start afterwards then met "No capturable
display found", because `SCShareableContent` returns an empty list for a second
or two after wake while the window server republishes displays, and it was asked
exactly once.

A stop the app performs is now recorded as distinct from a stop the user asked
for, only the first is owed back, and the display lookup is retried for five
seconds. The resume waits for the teardown to finish rather than assuming it
has — `stop()` tears down inside a Task, so a lid closed and opened straight
away finds the old stream still shutting down.

Bounded, because retrying is right for a capture that stopped because the Mac
slept and wrong for one that stops immediately every time. Four short-lived
restarts in a row and it gives up and says to check Screen Recording, which is
what that failure actually looks like.

## It says where it went

Launching an accessory app looks exactly like launching nothing: no Dock icon,
no window, and on a laptop with a notch the status item may be behind it or
pushed out of the menu bar altogether. So the host opens with a box carrying the
icon itself, drawn six times menu-bar size, because "look for the little screen"
is not much help when you cannot find it. It has a "Don't show this again"
checkbox, and `--with-window` skips it.

## The panel is not in a ScrollView

A `MenuBarExtra` popover takes its size from its content, and a `ScrollView` has
no height of its own to give it — it fills what it is handed, which in a popover
is nothing. Wrapping the body in one, to stop a 718-point panel running off the
bottom of a laptop screen, made the panel stop appearing at all. The way to make
it fit is for it to be shorter.

## Moshing: decoding a frame whose predecessor was thrown away

Every frame after a keyframe is a set of changes to the one before it. The
decode queue kept latency down by throwing away its oldest waiting frame when
decoding fell behind — and then decoding the next frame anyway, applying its
changes to a picture they were never meant for. The damage is copied forward
into every frame until the next keyframe, up to five seconds later: blocks
smeared and dragged across the picture. Decoding falls behind on exactly the
frames scrolling and zooming produce, which is when it was seen.

Measured with real frames really decoded, each scored against what it should
have been (`./Tests/run_decoder_drop_test.sh`, a scrolling 1280x720 page):

| | worst frame shown | damaged frames shown |
|---|---|---|
| decode everything | 38.9 dB | 0 |
| drop one frame, carry on (as it was) | **16.7 dB** | **49**, until the keyframe |
| drop one frame, wait for a keyframe (now) | 38.9 dB | 0 |

The rule now is that a frame is never decoded unless the one before it was.
When the queue is full, the newest frame is refused rather than the oldest, so
the frames already waiting — a complete chain — still decode correctly, and
nothing after the gap is decoded until a keyframe arrives. The client asks for
one at once, and again for every frame refused until it comes, because a lost
request would otherwise mean waiting for the host's own schedule. A frame the
decoder rejects is treated the same way. A keyframe also overtakes anything
still waiting ahead of it, which could only put the picture further behind.

The cost is the picture holding still for a round trip instead of being wrong
for seconds. In the panel, Dropped counts the frames this refuses. If it climbs
while scrolling, the iMac cannot decode the stream fast enough — and on a
client that can tell, the Decoder readout says whether it has fallen back to
software. 10.9 cannot tell, and the iMac's answer turned out to be the CPU
regardless, which is what the pacing further down is for.

The loopback harness now answers keyframe requests the way the host does, so it
exercises that recovery instead of waiting for a scheduled keyframe that a
short run never reaches. It counts how often decoding fell behind rather than
how many frames that cost, since one overflow now refuses a run of them.

## Looking for a twelve-hour freeze

The client stopped after about twelve hours, with no crash and nothing in the
log. Twelve hours is close enough to the RTP timestamp's 13h15m wrap — 32 bits
at 90 kHz — to be worth ruling in or out rather than reasoning about, so both
halves were measured.

`./Tests/run_client_soak_test.sh` pushes twelve hours of frames, 2.59 million of
them and some fifty million packets, through the depacketizer in about ten
seconds while watching its own resident memory, and walks the timestamp across
the wrap on the way. Resident size moves by 16 KB over the whole run and is flat
after the first few hundred thousand frames: one allocator bump, not a leak. The
threshold was confirmed by breaking it — leaking four bytes per frame turns into
65 bytes per frame of real growth and the run fails.

The second half replays real encoded frames through `LSDecoder` with timestamps
walking up to the wrap, across it, and out the other side. 279 frames out
before, 301 after, nothing stuck in the queue. **So the wrap is not it**, and
neither is anything that accumulates per frame or per packet.

What that search did turn up is a different way to stop forever. Both receive
loops gave up permanently after 500 consecutive errors, or on `EBADF` — one log
line, the thread exits, and the app goes on running with a still picture. For
the control socket that is worse than it sounds: no pings means the client
decides the host has gone and blanks, and saying hello is what that same socket
is for, so it could never hear it come back. Both now replace the socket instead
of abandoning it.

And because none of this reproduced the actual freeze, the client now says when
it is stuck: frames decoding while none are drawn means the render thread has
stopped, and that gets a line a second rather than a still screen and no
explanation. Sockets being replaced gets one too.

## Measured and rejected

- **`ExpectedFrameRate` of 120 while feeding 60.** Takes the encoder's hold
  time from 14.5 ms to 10.3, but leaves the p95 at 18–19 ms rather than the 12
  that simply turning `RealTime` off gives. Nothing to prefer about it.
- **Letting the encoder hold frames to look ahead**, the textbook way to spend
  latency on picture. `MaxFrameDelayCount` changes nothing measurable in either
  direction on this hardware.
- **A 120 Hz virtual display.** The claim that feeding faster reduces latency
  does not survive direct measurement: the encoder's hold time is ~10 ms whether
  fed at 60 or 120. The original README said otherwise, and it was wrong —
  that conclusion came from the loopback test, where the shallow decode queue
  drops the oldest frames, so at a higher feed rate the surviving samples are
  biased towards the quick ones. It would also double the iMac's decode work for
  nothing.
- **"Low-latency mode stops periodic keyframes."** It does not. 400 frames at a
  two-second interval produced four keyframes either way, so no timer is needed
  to force them.

## Not attempted

- **Sending changed regions uncompressed.** Real, and it would make text sharper,
  but it means rewriting both ends around a second codec path.
- **Converting the panel to a monitor.** Out of scope for software, and it stops
  the iMac being a computer.

## Nothing that receives data may draw

The pointer arrives on the control thread. Drawing it there seems natural and is
wrong: with vsync on, a draw waits for the next vertical blank, so on a 60 Hz
screen the thread can service at most sixty updates a second while a hundred and
twenty arrive. The rest queue in the socket buffer and are drawn later, stale,
one refresh apart — latency that grows for as long as the pointer keeps moving.
It reads as the pointer wading through syrup, and only with vsync on.

So the client has a render thread. Producers — the decoder, the pointer, a
resize — update state and signal it; it draws the newest state once per wake,
coalescing whatever arrived in between. Two locks, not one: the GL lock is held
for a whole draw, while the state lock is held only long enough to hand a frame
or a position over.

Both parts were necessary. Moving the draw to its own thread but leaving the one
shared lock still made updates queue behind the current draw, and the client
still only got through a third of them. The AppKit accessors mattered too:
`-window` and `-bounds` are not safe from a background thread and can wait on
AppKit's own lock, which was worth milliseconds on its own. They are cached by
the main thread now.

`run_cursor_test.sh` asserts the invariant directly — handing over a pointer
update must not wait on a draw — because inferring it from throughput only works
when the display is slower than the send rate. It is not on every machine, which
is how the first version of this test passed against the broken code.

| | slowest pointer update |
|---|---|
| drawing on the control thread | 38,891 µs |
| render thread, split locks, cached accessors | 366 µs |

## It lives in the menu bar now, and it looks like 2006

The host has no Dock icon and no window on launch. There is a small monitor in
the menu bar, blue with a green lamp while it is streaming, grey while it is
not, and amber while it is sending to a client that has not answered. Clicking
it drops a panel with the start button, three live meters, the link numbers and
the three switches that actually change how the stream feels. Everything you
set once — ports, resolution, bitrate, Wake-on-LAN — is behind **Settings…**, in
the old window.

The style is Aero, on purpose and fairly literally. Three things make it work,
and the first one is the one that is easy to get wrong:

- **Shading is by lightness, not by alpha.** A tint at 80% opacity over pale
  blue glass comes out *lighter*, so a gradient built from opacity steps shades
  a surface the wrong way round and everything ends up looking flat and washed.
  Every gradient here blends toward white or toward black instead.
- **The gloss has a hard edge halfway down.** A soft fade reads as a modern
  gradient. The abrupt break is what reads as glass.
- **A 1px white bevel just inside a darker border**, which is what fakes a lit
  edge.

The app runs as an accessory, so it has no menu bar of its own — and therefore
no Edit menu, and therefore no Paste. That matters, because the Power section
asks you to paste in the output of `arp`. So it becomes a regular app for
exactly as long as the settings window is open, and drops back to an accessory
when you close it.

`LanScreenHost --render-ui <dir>` draws the panel in both states, the settings
window and the status item glyph straight to PNG and exits, without opening
anything. The look was checked that way rather than by asking someone to click
the status item and describe what they saw.

## Jumbo frames that are not there any more

A packet size is a setting in this app but a property of the cable, the adapter
and both machines. A manually raised MTU does not survive a reboot. So a setting
that was right yesterday can be wrong today with nothing to show for it, and the
failure is silent by construction: an oversized datagram is not rejected, it is
split into IP fragments and delivered. Losing any one fragment destroys the
whole packet, so a link dropping a fraction of a percent of fragments drops
several percent of packets — and the kernel's reassembly queues fill as it goes,
which is why it degrades over minutes instead of failing outright.

This was found by reading `netstat -s -p ip` on a machine where it was
happening: 921,196 fragments created from 153,943 datagrams, almost exactly the
six-way split an 8900 B payload takes on a 1500 B link, and zero while idle.

The host now asks the interface that routes to the client what it can carry, and
uses the smaller of that and the configured size. The 8900-byte option has
since been removed altogether: neither the iMac's port nor a USB adapter on
Apple silicon can carry jumbo frames.

Start the host with `LS_LOG=1` and it also writes a line a second of throughput,
latency, loss and keyframe counts, because nothing else keeps a history and by
the time you notice a degradation the numbers that would explain it are gone:

    open --env LS_LOG=1 -a LanScreenHost     # quit it first; open passes no other environment
    /usr/bin/log show --predicate 'subsystem == "com.lanscreen.host"' --last 15m

Off by default, and not because it was expensive: that line, with all fifteen of
its interpolations, measures 2.16 µs, which once a second is 0.0002% of one
core. It is off because a stream that is behaving does not need a diary. Errors
are written down either way.

Those lines are logged at `notice`, not `info`, which took a second attempt to
get right. Info-level messages live in a memory ring buffer and are evicted, so
the first version had already lost the opening ninety seconds of a stream — the
part that says what packet size was chosen — before anyone came to read it, and
the `log show` command written here returned nothing at all.

On the client, the two log lines that sit on a per-frame path — a failed decode
and a failed texture upload — print the first occurrence and then one per 300.
`NSLog` sixty times a second on a 2010 iMac is a second fault on top of the
first one.

**One thing still fragments, and it is fine.** The packet-size clamp applies to
the video. Cursor bitmaps go over the control channel as a single datagram of up
to 64x64 RGBA, which is three or four IP fragments on a 1500 B link. Unlike a
video packet, losing one costs a single cursor update and it is re-sent within
five seconds, so it is not worth a protocol change to fix. If `netstat -s -p ip`
shows a handful of fragmented datagrams while streaming and the video shows no
loss, this is what they are.

## Measured and rejected: App Nap

Moving the host into the menu bar changed one thing about how the OS sees the
process — it no longer has a window, which is one of the conditions App Nap
looks for, and App Nap does not apply immediately. That is a good enough story
that it was worth eight minutes to find out it is wrong.

`./Tests/run_nap_check.sh` runs three real signed .app bundles at once, each
with a 120 Hz timer on a user-interactive queue and a fixed slice of arithmetic:
an accessory with no window and no activity assertion, an accessory with the
assertion (the app as it now ships), and a regular app with a visible window and
the assertion (the app as it was). Over eight minutes all three held a 8.33 ms
median with no drift, and the accessory build missed fewer deadlines than the
windowed one, not more.

The first version of that test calibrated its workload per process, so each of
the three picked a different amount of arithmetic and their work times could not
be compared with each other — which was the entire point of measuring them.

## Controls that did nothing

Three of them, found by asking the question directly rather than by reading the
code and believing it.

**HiDPI is gone.** The toggle asked `CGVirtualDisplaySettings` for a Retina
backing store. What came back, measured by reading the mode the window server
actually settled on, was an ordinary 1:1 display:

    virtual display 20 settled: 1920x1080 points / 1920x1080 pixels (hiDPI=1)

Identical to the same thing with the toggle off. Three descriptor variants were
tried — doubling `maxPixelsWide`/`maxPixelsHigh`, giving the mode in pixels
rather than points, and both together — and every one produced the same 1:1
mode. It never made a HiDPI display, it did make the picture come apart, and it
would have been of no use on a 1080p 2010 panel if it had worked. A switch that
does nothing except break things is worse than no switch.

The geometry the window server settles on is now read back and logged, and it
has to be read *after* the display is published: `CGDisplayCopyDisplayMode`
returns nothing for one created a moment ago, which reads as 0x0 and looks like
a failure rather than a race.

**The Profile picker did nothing** whenever the low-latency encoder was on,
which was the default. VideoToolbox's low-latency rate controller only offers
Constrained Baseline, so asking for Main did not fail — it was simply not what
you got. That one has since fixed itself: the low-latency rate controller is
gone, measured as costing 5 ms, and the picker means what it says again.

**Include mouse cursor does nothing** whenever the pointer is being sent
separately, which is the default, because the pointer must not be in the video
as well as beside it.

**The everyday Bitrate slider does nothing** while Video mode is on, which was
caught by this machinery within minutes of Video mode existing rather than by
someone dragging a slider and wondering.

These are still overridden, because the overrides are correct. What changed is
that the overriding happens in one place, `StreamPlan`, which records what it
ignored and why — and the window greys those controls out and says so, instead
of presenting a live-looking control and quietly discarding it.

`./Tests/run_settings_audit.sh` flips every control in turn and requires that it
either changes the plan the pipeline is built from, or is named as inert. A
control may be ignored; it may not be ignored quietly. Both halves were
confirmed by breaking them: with a setting wired to a constant, and with an
override applied but not declared, the audit fails in each case.

## The iMac decodes on its CPU, so the host sends what it can decode

On OS X 10.9 the iMac's H.264 decoding runs on the CPU, one frame at a time,
and its cost follows the bitrate: about 18 ms a frame plus about 14 ms a
megabit. That makes roughly 17 frames a second sustainable at 49 Mb/s, 36 at
25, 44 at 15. Zooming or scrolling is captured at 45 to 60.

Before this, every frame the iMac could not take broke the chain -- each is
built on the one before -- so it had to wait for a keyframe, the slowest frame
of all to decode, and fell further behind. Measured with the same 25-second
zoom, the host paced to nothing:

| | decode | dropped | keyframes requested |
|---|---|---|---|
| 49 Mb/s, still refresh on | 27 ms | 173 | 69 |
| 49 Mb/s, still refresh off | 32 ms | 373 | 111 |
| 49 Mb/s, no colour tags | 31 ms | 372 | 110 |
| 25 Mb/s | 19 ms | 205 | 72 |

Not the refresh and not the tags: the decoder. That was the lag, and the 130
Mb/s bursts, nine keyframes a second answering nine requests.

The host now sends no more frames than the client's own decode time allows,
with 15% to spare; a frame that is too soon waits, and the newest goes when the
pace allows, so the last frame of a movement is never lost. Keyframes answer
requests at most every 300 ms. With the same zoom:

| paced | frames a second while zooming | dropped | keyframes requested |
|---|---|---|---|
| 49 Mb/s | 11-17 | 12 | 6 |
| 25 Mb/s, refresh off | 20-30 | 11 | 4 |
| 25 Mb/s, refresh on | 13-17 | 0 | 0 |

So on this iMac 49 Mb/s cannot be smooth however it is paced, and 25 is the
setting to use, with the still refresh for detail. The refresh keyframes take
the iMac 100-200 ms each and inflate the decode time the pace follows, which is
why the last row is slower.

A client that says when it has finished each frame no longer needs the average.
It sends DECODED with the frame's RTP timestamp after every decode, and the host
keeps exactly one frame in flight: the next goes the moment the last is
reported, so a big frame holds the next back for as long as it really takes and
a small one for no longer. One rather than two, because a second would only wait
in the client's queue. A frame that is never reported -- lost, or refused while
the client waits for a keyframe -- holds things up for at most 250 ms.

Tested on this Mac first, against a client slowed to the iMac's measured cost
(`-decodeDelayMs 18 -decodeDelayPerMbitMs 14`): no frames dropped, no keyframes
requested, with the refresh on. It did not raise the frame rate, though, and that
is the useful finding: at a fixed bitrate, fewer frames means bigger ones, and a
CPU decoder takes longer over bigger frames. The pacing stops the storms; only
the bitrate decides how many frames a second this iMac can show.

## Stepped edges on small colourful icons: 4:2:0, not the client

The stream carries colour at half the resolution of brightness, in both
directions. Photos and plain icons hide that; a small, saturated app icon is
where it shows. Measured with three-pixel bands of saturated colour (`stripes`
in Tests/LoopSend, scored by Tests/checkchroma.m), mean error per channel:

| reconstruction | mean | worst |
|---|---|---|
| the driver's built-in conversion | 20.93 | 148 |
| the BT.709 shader | 20.93 | 148 |
| the shader, blending each pixel pair's colour with the next | 20.69 | 198 |

The two conversions are identical, so neither was losing anything; blending
bought one percent on average and made the worst pixel worse, so it was not
kept. The colour is gone before the iMac sees it, and 4:4:4 is not something
10.9's decoder takes.

## Black after a rebuild or an update: macOS's Local Network check

The first launch of a changed host -- every rebuild, and presumably every update
-- sometimes had every packet it sent to the iMac refused with EPIPE, for the
whole run, while capture and encoding carried on normally: 136 frames captured
in the first three seconds, 69 KB sent in ten. macOS's Local Network privacy
check keys on the binary itself. It forgets a changed one and re-learns it a
few seconds after launch ("Local network allowed by preference ... but received
prompt. Clearing cached UUIDs and restarting session"), and what it re-learns
applies to processes started afterwards. Fresh sockets in the same process
stayed refused through three stream restarts over twenty seconds; the next
launch always worked.

So a stream that has never got a packet out and is being refused with EPIPE
relaunches the app once, and carries on streaming about ten seconds later. If
the relaunched copy is refused too, Local Network really is off, and the panel
says to check it rather than relaunching for ever.

Two other suspects were ruled out on the way. Screen Recording was granted every
time (tccd: authValue 2), and capture attached to the right display every time.
Finding this took one more thing worth knowing: in zsh, `log` is a built-in, so
`log show` there runs the wrong program and prints nothing. Use `/usr/bin/log`.

## Verifying it

`./Tests/run_cursor_test.sh` sends a solid magenta pointer to a known position
over a red part of the test pattern and checks that pixel in the client's own
framebuffer. Nothing else in the pipeline can catch a mistake in the coordinate
mapping or the hotspot: it would simply appear in the wrong place on the iMac.

`./Tests/run_mtu_test.sh` checks that the host finds the MTU of the interface
that actually routes to the client — not merely that it finds *an* MTU, which
passes when the lookup returns the wrong interface — and that it cuts the
payload to fit. Both halves were confirmed by breaking them: with the clamp
disabled and with the interface lookup taking the first interface it sees, the
test fails in each case.

`./Tests/run_bitrate_switch_test.sh` checks that Video mode's bitrate reaches
the encoder, in about 25 seconds. It is a characterisation test of VideoToolbox
rather than of this app's code: it measures what the two ways of changing a
bitrate actually do, which is the fact the app is built on.

`./Tests/QualityCheck` produced the picture-quality numbers above, and
`./Tests/run_loopback_test.sh` the latency ones. It takes `PIPELINE=` to pick
what the encoder is configured with: `shipping` (the default), `greedy` for what
this used to do, or `lowlatency` and `plain` to isolate the halves.

`./Tests/EncoderLatency` measures the encoder on its own. Treat it as a hint,
not as a verdict — it is where the belief that the low-latency rate controller
was fast came from, and it was wrong by 5 ms. Both it and `QualityCheck` default
to 400 frames now, because at 150 the encoder has not reached steady state and
the answer is not a noisier version of the real one, it is a different one: over
150 frames every configuration measures about 9.5 ms and the low-latency rate
controller looks like it does nothing at all.
