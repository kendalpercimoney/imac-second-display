# LanScreen Greedy

A variant of [LanScreen](https://github.com/kendalpercimoney/imac-second-display)
tuned hard for responsiveness, at some cost in picture quality and one visible
behavioural trade-off.

**The client must be rebuilt.** The wire protocol gained pointer messages and a
capability flag, and an older client paired with this host would show no pointer
at all. The host warns you if that happens rather than leaving you to notice.

## What is different, and what it bought

Everything below was measured on an M1 Pro before being kept. Two suggestions
that sounded reasonable were measured and dropped.

### The pointer is drawn by the client

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

### Low-latency rate control, and capturing in 4:2:0

VideoToolbox's `EnableLowLatencyRateControl` with `ScreenCaptureKit` handing over
`420v` instead of BGRA, so the encoder is never converting a frame before it can
start.

Measured as how long the encoder holds a frame, 1080p, 400 frames, three rounds:

| | mean hold | p95 |
|---|---|---|
| as the original ships | ~16 ms | 21–36 ms |
| 4:2:0 alone | ~15 ms | 19–23 ms |
| low-latency alone | ~9.9 ms | 13–15 ms |
| **both together** | **~9.2 ms** | **9.9–13.2 ms** |

4:2:0 on its own does nothing. It only pays off combined with the low-latency
rate controller.

End to end over the loopback harness, four interleaved pairs of 300 frames:

| | median | p95 | mean |
|---|---|---|---|
| original pipeline | ~12.1 ms | **~40 ms** | ~17.1 ms |
| greedy pipeline | ~10.4 ms | **~20 ms** | ~11.8 ms |

The median barely moves. **The tail halves**, and the tail is what reads as
stutter.

Costs about half a decibel of PSNR on hard content (39.9 dB against 40.5 dB on a
1080p zoom), though the worst single frame is slightly better. It forces
Constrained Baseline, a subset of the Baseline the iMac already decodes.

### Audio, uncompressed and on its own socket

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

#### What was checked

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

### Audio delay, and why negative is the direction that matters

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

### Why the iMac was getting hot

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

#### Measured and left alone

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

### Why it popped, which was three separate things

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

### The iMac's screen brightness

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

### Measured and rejected

- **`ExpectedFrameRate` of 120 while feeding 60.** Improves the mean about as
  much as low-latency mode does, but leaves the p95 at 18–20 ms rather than
  13–15. No reason to prefer it, and no benefit stacking it.
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

### Not attempted

- **Sending changed regions uncompressed.** Real, and it would make text sharper,
  but it means rewriting both ends around a second codec path.
- **Converting the panel to a monitor.** Out of scope for software, and it stops
  the iMac being a computer.

### Nothing that receives data may draw

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

### It lives in the menu bar now, and it looks like 2006

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

### Jumbo frames that are not there any more

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
uses the smaller of that and the configured size. It says so in the panel and in
the log rather than changing the saved setting, so restoring MTU 9000 on both
ends brings jumbo frames back on its own.

    log show --predicate 'subsystem == "com.lanscreen.host"' --last 15m

is also where a line a second of throughput, latency, loss and keyframe counts
now goes, because nothing kept a history and by the time you notice a
degradation the numbers that would explain it are gone.

Those lines are logged at `notice`, not `info`, which took a second attempt to
get right. Info-level messages live in a memory ring buffer and are evicted, so
the first version had already lost the opening ninety seconds of a stream — the
part that says what packet size was chosen — before anyone came to read it, and
the `log show` command written here returned nothing at all.

**One thing still fragments, and it is fine.** The packet-size clamp applies to
the video. Cursor bitmaps go over the control channel as a single datagram of up
to 64x64 RGBA, which is three or four IP fragments on a 1500 B link. Unlike a
video packet, losing one costs a single cursor update and it is re-sent within
five seconds, so it is not worth a protocol change to fix. If `netstat -s -p ip`
shows a handful of fragmented datagrams while streaming and the video shows no
loss, this is what they are.

### Measured and rejected: App Nap

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

### Controls that did nothing

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
which is the default. VideoToolbox's low-latency rate controller only offers
Constrained Baseline, so asking for Main did not fail — it was simply not what
you got.

**Include mouse cursor did nothing** whenever the pointer was being sent
separately, which is also the default, because the pointer must not be in the
video as well as beside it.

Both are still overridden, because both overrides are correct. What changed is
that the overriding now happens in one place, `StreamPlan`, which records what
it ignored and why — and the window greys those controls out and says so,
instead of presenting a live-looking control and quietly discarding it.

`./Tests/run_settings_audit.sh` flips every control in turn and requires that it
either changes the plan the pipeline is built from, or is named as inert. A
control may be ignored; it may not be ignored quietly. Both halves were
confirmed by breaking them: with a setting wired to a constant, and with an
override applied but not declared, the audit fails in each case.

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

`./Tests/EncoderLatency` and `./Tests/QualityCheck` produced the numbers above,
and `./Tests/run_loopback_test.sh` takes `PIPELINE=plain` to measure the
original path for comparison.

---

Everything below describes LanScreen generally and applies to both.

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

## Tested devices

| Role | Machine | OS | Status |
|---|---|---|---|
| Host | MacBook Pro (M1 Pro) | macOS 27.0 | Working |
| Client | iMac 21.5-inch, Mid 2010 | OS X 10.9.5, Xcode 6.2 | Working |

Confirmed on that pair: the client builds under Xcode 6.2 against the 10.9 SDK,
decodes in hardware, and displays the MacBook's screen over a direct Gigabit
cable.

The 21.5-inch panel is 1920×1080, which happens to be exactly the resolution
this is tuned for — the stream maps 1:1 with no scaling at either end.

Not tested, in rough order of how likely they are to work:

- **iMac 27-inch, Mid 2010.** Same vintage, but its panel is 2560×1440. That is
  above what a 2010 GPU decodes comfortably; stream 1080p to it and let the iMac
  scale, rather than matching its native resolution.
- **Other macOS versions on the host.** Needs 12.3+ for ScreenCaptureKit; the
  virtual display uses private API that could change in any release.
- **Anything between OS X 10.10 and macOS 12** as a client. The client only
  needs 10.9 APIs, so it should be fine, but nobody has run it.

## Prebuilt binaries

`build/` holds both apps, if you would rather not compile anything:

| App | Architecture | Minimum OS | Signing |
|---|---|---|---|
| `LanScreenHost.app` | arm64 | macOS 13 | Ad-hoc |
| `LanScreenClient.app` | x86_64 | OS X 10.9 | Unsigned |


The client was built on the iMac itself with Xcode 6.2, because no current
toolchain can target 10.9 (see section 3).

Neither is notarised, so macOS will quarantine them after download and refuse
to open them. Clear that with:

```bash
xattr -dr com.apple.quarantine LanScreenHost.app
```

On OS X 10.9, right-click the app and choose Open instead.

Screen Recording permission is tied to the code signature, so a downloaded copy
of the host will ask for it separately from one you built yourself. Building
from source is still the better path; these are here for convenience.

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
| **Quality drops when you stop moving the cursor** | Turn on "Keep this Mac at full performance while streaming" in Power. See below |
| Client stutters, `decode` over ~15 ms | Drop resolution, or 60 → 30 fps |
| Blocky during motion | Raise bitrate |
| `packets lost` climbing | Lower bitrate; check the cable; raise `kern.ipc.maxsockbuf` |
| Tearing | Press `V` for vsync, costs ~1 refresh |
| Above 1080p | Don't. The old GPU falls back to software decode |

Baseline profile is the default and the right choice: no CABAC, no B-frames,
and it is what the 2010-era hardware decoder handles best. Main profile is
offered for a few percent better quality per bit, and uses CAVLC entropy coding
even then for the same reason.

### Reducing load on both machines

Measured on a static 1920×1080 desktop, encoding with the real settings:

| Change | Effect |
|---|---|
| **A still screen now sends nothing** | Was 4.03 Mb/s and a full IDR decode every second. Now zero. Free — already done |
| **Keyframe interval 2s → 10s** | 73% less data on a nearly-still screen, and that many fewer decode spikes. Default is 5s |
| **Jumbo frames** | At 25 Mb/s, 1400-byte packets mean ~2,250 `recv` calls and interrupts per second on the iMac. 8900-byte packets cut that to ~350 |
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

### Quality drops when you stop touching the MacBook

macOS App Naps an app that is not frontmost on a system with no keyboard or
trackbad activity: it lowers the process's quality of service and coalesces its
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

### Host and client versions have to match

The change above is not backward compatible. An **older client paired with a
newer host** will blank every few seconds on a still screen: it is still waiting
for video traffic that no longer comes. If you update one, update both.

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

## 8. Troubleshooting

**About a second of delay when testing with VLC** — That is VLC's own
`--network-caching`, which defaults to 1000 ms. Run it with
`--network-caching=0`, or better, use the real client (section 7).

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
    LanScreenHostApp.swift   menu bar scene, settings window, activation policy
    MenuBarPanel.swift       the panel behind the status item
    AeroStyle.swift          the Aero look: glass, gloss, bevels, meters
    UISnapshot.swift         --render-ui, draws every view to PNG and exits
    UnattendedRun.swift      --autostart/--quit-after/--with-window, for measuring
    StreamPlan.swift         settings -> pipeline, in one place, with what it ignored
    AudioSender.swift        system audio -> fixed PCM packets
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
  LSAudioPlayer.m        AudioQueue, and the delay line in front of it
  LSAudioReceiver.m      the audio socket and its receive loop
  LSBrightness.m         the iMac's panel, driven from the other machine
Tools/
  serve_to_imac.sh       packages the client source and serves it to the iMac
  fetch_from_imac.sh     brings the built client back the other way
Tests/
  depacketizer_test.m    unit tests
  loopreceive.m          loopback receiver + latency measurement
  LoopSend/main.swift    loopback sender
  checkpattern.m         colour round-trip verification
  WakeCheck/main.swift   Wake-on-LAN interface selection and delivery
  IdleCost/main.swift    measures what an idle screen costs to stream
  run_loopback_test.sh   headless: unit tests + encode/decode round trip
  run_render_test.sh     the OpenGL path, checked numerically
  PathMTU/main.swift     link MTU discovery and the payload clamp
  AudioLoop/main.swift   PCM from the host packetiser to the client parser
  AudioBench/main.m      what the ring buffer costs per second of audio
  SettingsAudit/main.swift  every control either does something or says it does not
  NapCheck/main.swift    whether an app with no window gets throttled
```
