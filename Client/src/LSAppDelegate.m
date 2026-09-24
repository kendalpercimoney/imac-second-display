// This file is part of LanScreen.
// Copyright (C) 2026 Kendal Percimoney
//
// LanScreen is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// LanScreen is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with
// this program. If not, see <https://www.gnu.org/licenses/>.

#import "LSAppDelegate.h"
#import "LSGLView.h"
#import "LSReceiver.h"
#import "LSDecoder.h"
#import "LSDepacketizer.h"
#import "LSControlClient.h"
#import "LSPowerManager.h"
#import "LSAudioPlayer.h"
#import "LSAudioReceiver.h"
#import "LSBrightness.h"

@implementation LSWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)keyDown:(NSEvent *)event {
    if ([_keyTarget respondsToSelector:@selector(handleKeyDown:)]) {
        [_keyTarget performSelector:@selector(handleKeyDown:) withObject:event];
    } else {
        [super keyDown:event];
    }
}
@end


@interface LSAppDelegate () <LSDepacketizerDelegate>
- (void)handleKeyDown:(NSEvent *)event;
@end


@implementation LSAppDelegate {
    LSWindow        *_window;
    LSGLView        *_glView;
    NSWindow        *_overlayWindow;
    NSTextField     *_overlayField;

    LSReceiver      *_receiver;
    LSDecoder       *_decoder;
    LSDepacketizer  *_depacketizer;
    LSControlClient *_control;
    LSPowerManager  *_power;

    NSString *_hostAddress;
    uint16_t  _videoPort;
    uint16_t  _controlPort;
    uint16_t  _audioPort;
    BOOL      _audioEnabled;
    LSAudioPlayer   *_audioPlayer;
    LSAudioReceiver *_audioReceiver;
    LSBrightness    *_brightness;
    BOOL      _fullscreen;
    BOOL      _statsVisible;

    NSString *_snapshotPath;
    uint32_t  _snapshotAfter;
    NSTimer  *_snapshotTimer;
    NSTimer  *_tickTimer;
    uint64_t  _bytesAtLastTick;
    double    _incomingMbps;
    BOOL      _sawFirstFrame;
    NSString *_fatalMessage;
}

#pragma mark - launch

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self readConfiguration];
    [self buildMenu];
    [self buildWindow];
    [self startPipeline];

    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(tick:)
                                                userInfo:nil
                                                 repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_tickTimer forMode:NSRunLoopCommonModes];

    if (_snapshotPath) {
        _snapshotTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                          target:self
                                                        selector:@selector(checkSnapshot:)
                                                        userInfo:nil
                                                         repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_snapshotTimer forMode:NSRunLoopCommonModes];
    }

    [NSApp activateIgnoringOtherApps:YES];
    [self updateOverlay];
}

- (void)readConfiguration {
    // NSUserDefaults folds "-host 10.0.0.1" style arguments into the argument
    // domain automatically, so the same keys work three ways:
    //   ./LanScreenClient -host 10.0.0.1 -videoPort 5000
    //   defaults write com.lanscreen.client host 10.0.0.1
    //   (falling back to the defaults below)
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{
        @"host"        : @"10.0.0.1",
        @"videoPort"   : @(LS_DEFAULT_VIDEO_PORT),
        @"controlPort" : @(LS_DEFAULT_CONTROL_PORT),
        @"audioPort"   : @(LS_DEFAULT_AUDIO_PORT),
        @"audio"       : @YES,
        @"maxDraws"    : @0,
        @"windowed"    : @NO,
        @"vsync"       : @NO,
        @"stats"       : @NO,
        @"snapshotAfter" : @40
    }];

    _hostAddress  = [defaults stringForKey:@"host"];
    _videoPort    = (uint16_t)[defaults integerForKey:@"videoPort"];
    _controlPort  = (uint16_t)[defaults integerForKey:@"controlPort"];
    _audioPort    = (uint16_t)[defaults integerForKey:@"audioPort"];
    _audioEnabled = [defaults boolForKey:@"audio"];
    _fullscreen   = ![defaults boolForKey:@"windowed"];
    _statsVisible = [defaults boolForKey:@"stats"];
    // Test hook: render N frames, write a PNG, quit. Lets the render path be
    // verified without anyone having to look at a screen.
    _snapshotPath = [defaults stringForKey:@"snapshot"];
    _snapshotAfter = (uint32_t)[defaults integerForKey:@"snapshotAfter"];

    NSLog(@"[LanScreen] host=%@ video=%u control=%u fullscreen=%d",
          _hostAddress, (unsigned)_videoPort, (unsigned)_controlPort, (int)_fullscreen);
}

- (void)buildMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];

    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit LanScreen" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [NSApp setMainMenu:mainMenu];
}

- (void)buildWindow {
    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = _fullscreen ? [screen frame] : NSMakeRect(100, 100, 1280, 720);
    NSUInteger style = _fullscreen
        ? NSBorderlessWindowMask
        : (NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask);

    _window = [[LSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:screen];
    _window.keyTarget = self;
    [_window setTitle:@"LanScreen"];
    [_window setBackgroundColor:[NSColor blackColor]];
    [_window setAcceptsMouseMovedEvents:NO];
    if (_fullscreen) {
        [_window setLevel:NSMainMenuWindowLevel + 1];
        [NSApp setPresentationOptions:(NSApplicationPresentationHideDock |
                                       NSApplicationPresentationHideMenuBar)];
    }

    _glView = [[LSGLView alloc] initWithFrame:[[_window contentView] bounds]];
    [_glView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    // Cap drawing at what the panel can actually show. The pointer arrives at
    // 120 Hz and every arrival marks the view dirty, so without this the client
    // redraws 1080p twice as often as a 60 Hz iMac can display it.
    // -maxDraws overrides the detected rate. It exists because the machine this
    // is developed on is a 120 Hz panel and the machine it runs on is 60, so
    // the saving is invisible here without it.
    double cap = (double)[[NSUserDefaults standardUserDefaults] integerForKey:@"maxDraws"];
    if (cap <= 0) cap = [self displayRefreshRate];
    [_glView setMaximumDrawsPerSecond:cap];
    NSLog(@"[LanScreen] drawing capped at %.0f per second", cap);
    _glView.vsyncEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"vsync"];
    [[_window contentView] addSubview:_glView];

    [self buildOverlay];

    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_window];
}

/// What the screen the window is on actually refreshes at. Falls back to 60,
/// which is what the panel this was written for does, and which is a safe floor
/// for anything else: a faster screen just gets its cap raised by whatever this
/// returns instead.
- (double)displayRefreshRate {
    NSScreen *screen = [_window screen] ?: [NSScreen mainScreen];
    NSNumber *number = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
    if (number) {
        CGDirectDisplayID display = (CGDirectDisplayID)[number unsignedIntValue];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
        if (mode) {
            double rate = CGDisplayModeGetRefreshRate(mode);
            CGDisplayModeRelease(mode);
            // A built-in panel often reports zero rather than its real rate.
            if (rate > 1.0) return rate;
        }
    }
    return 60.0;
}

- (void)buildOverlay {
    // A child window rather than a sibling view: on 10.9 an NSView layered over
    // an NSOpenGLView flickers or simply does not composite. A separate window
    // ordered above the main one always works.
    NSRect frame = NSMakeRect(0, 0, 520, 120);
    _overlayWindow = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSBorderlessWindowMask
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    [_overlayWindow setOpaque:NO];
    [_overlayWindow setBackgroundColor:[NSColor colorWithCalibratedWhite:0.0 alpha:0.62]];
    [_overlayWindow setIgnoresMouseEvents:YES];
    [_overlayWindow setHasShadow:NO];

    _overlayField = [[NSTextField alloc] initWithFrame:NSInsetRect(frame, 10, 8)];
    [_overlayField setEditable:NO];
    [_overlayField setSelectable:NO];
    [_overlayField setBordered:NO];
    [_overlayField setDrawsBackground:NO];
    [_overlayField setTextColor:[NSColor whiteColor]];
    [_overlayField setFont:[NSFont fontWithName:@"Menlo" size:11]
     ?: [NSFont userFixedPitchFontOfSize:11]];
    [_overlayField setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [[_overlayWindow contentView] addSubview:_overlayField];

    [_window addChildWindow:_overlayWindow ordered:NSWindowAbove];
    [self positionOverlay];
}

- (void)positionOverlay {
    NSRect windowFrame = [_window frame];
    NSRect overlayFrame = [_overlayWindow frame];
    [_overlayWindow setFrameOrigin:NSMakePoint(NSMinX(windowFrame) + 24,
                                               NSMaxY(windowFrame) - NSHeight(overlayFrame) - 24)];
}

#pragma mark - pipeline

- (void)startPipeline {
    _power = [[LSPowerManager alloc] init];
    _depacketizer = [[LSDepacketizer alloc] init];
    _depacketizer.delegate = self;

    _decoder = [[LSDecoder alloc] init];
    LSGLView *view = _glView;
    _decoder.frameHandler = ^(CVPixelBufferRef pixelBuffer, CMTime presentationTime) {
        // Ownership moves into the view, which releases it when it is replaced.
        [view presentPixelBuffer:pixelBuffer];
    };
    [_decoder start];

    NSError *error = nil;
    _receiver = [[LSReceiver alloc] initWithPort:_videoPort depacketizer:_depacketizer];
    if (![_receiver start:&error]) {
        _fatalMessage = [error localizedDescription];
        NSLog(@"[LanScreen] %@", _fatalMessage);
        return;
    }

    if (_audioEnabled) {
        _audioPlayer = [[LSAudioPlayer alloc] initWithSampleRate:LS_AUDIO_SAMPLE_RATE
                                                        channels:LS_AUDIO_CHANNELS];
        NSError *audioError = nil;
        if (![_audioPlayer start:&audioError]) {
            // Not fatal. No sound is worse than sound, but far better than no
            // picture, and the host keeps sending either way.
            NSLog(@"[LanScreen] audio unavailable: %@", [audioError localizedDescription]);
            _audioPlayer = nil;
        } else {
            _audioReceiver = [[LSAudioReceiver alloc] initWithPort:_audioPort
                                                            player:_audioPlayer];
            if (![_audioReceiver start:&audioError]) {
                NSLog(@"[LanScreen] audio socket unavailable: %@",
                      [audioError localizedDescription]);
                [_audioPlayer stop];
                _audioPlayer = nil;
                _audioReceiver = nil;
            }
        }
    }

    _control = [[LSControlClient alloc] initWithHost:_hostAddress port:_controlPort];
    if (![_control start:&error]) {
        // Not fatal: without the back-channel we still display video, we just
        // cannot ask for keyframes or report statistics.
        NSLog(@"[LanScreen] control channel unavailable: %@", [error localizedDescription]);
        _control = nil;
    } else {
        __unsafe_unretained LSAppDelegate *weakSelf = self;
        _brightness = [[LSBrightness alloc] init];
        if (!_brightness.available) {
            NSLog(@"[LanScreen] brightness control unavailable: %@", _brightness.statusMessage);
        }
        _control.canSetBrightness = _brightness.available;
        LSBrightness *brightness = _brightness;
        _control.brightnessChanged = ^(float value) {
            [brightness setBrightness:value];
        };

        LSAudioPlayer *player = _audioPlayer;
        _control.audioDelayChanged = ^(int delayMilliseconds) {
            // The host's slider is relative to the default hold, so a negative
            // value shortens it. It cannot go below zero -- the audio queue's
            // own buffers are the floor beneath that.
            double target = 25.0 + (double)delayMilliseconds;
            [player setTargetBufferMilliseconds:target < 0 ? 0 : target];
        };
        _control.volumeChanged = ^(float volume) {
            // Arrives on the control thread. AudioQueueSetParameter is safe
            // there, so this does not need a hop to main.
            [player setVolume:volume];
        };
        _control.hostSaidGoodbye = ^{
            // Arrives on the control thread; the UI work has to hop to main.
            [weakSelf performSelectorOnMainThread:@selector(handleHostDisconnected)
                                       withObject:nil
                                    waitUntilDone:NO];
        };
        LSGLView *view = _glView;
        _control.cursorMoved = ^(uint16_t x, uint16_t y, BOOL visible, uint16_t imageID) {
            [view setCursorX:x y:y visible:visible];
        };
        _control.cursorImageChanged = ^(uint16_t imageID, uint16_t width, uint16_t height,
                                        uint16_t hotspotX, uint16_t hotspotY, NSData *rgba) {
            [view setCursorImage:rgba width:width height:height
                        hotspotX:hotspotX hotspotY:hotspotY];
        };

        // One line saying exactly what this build can and cannot do. OS X 10.9 has
    // no permission prompts for any of it, so if something is not working the
    // reason is here rather than in a dialog that never appeared.
    NSLog(@"[LanScreen] capabilities: audio %@, brightness %@, pointer yes",
          _audioPlayer ? @"yes" : (_audioEnabled ? @"NO (see above)" : @"off"),
          _brightness.available ? @"yes" : @"NO (no display exposes it)");
    [self sendHello];
    }
}

/// The host stopped streaming. Blank the screen rather than leaving the last
/// frame frozen on it, and go back to advertising ourselves so we reconnect
/// automatically when the host comes back.
- (void)handleHostDisconnected {
    if (!_sawFirstFrame) return;
    NSLog(@"[LanScreen] host went quiet -- blanking and waiting for it to come back");
    _sawFirstFrame = NO;
    // Stop holding the machine awake: with nothing to show, the iMac should be
    // free to sleep on its own schedule.
    [_power endKeepingAwake];
    // The audio queue and its socket deliberately stay up. Tearing them down
    // here would mean no sound at all after the host comes back, and an idle
    // queue simply plays the silence the ring drains to.
    [_depacketizer reset];
    [_glView clear];
    [self updateOverlay];
}

- (void)sendHello {
    NSRect screen = [[NSScreen mainScreen] frame];
    [_control sendHelloWithWidth:(uint16_t)NSWidth(screen)
                          height:(uint16_t)NSHeight(screen)
                       videoPort:_videoPort];
}

#pragma mark - LSDepacketizerDelegate (called on the receive thread)

- (void)depacketizer:(LSDepacketizer *)depacketizer
 didCompleteAccessUnit:(NSData *)avcc
                   sps:(NSData *)sps
                   pps:(NSData *)pps
             timestamp:(uint32_t)timestamp
            isKeyframe:(BOOL)isKeyframe
{
    if (!_sawFirstFrame) {
        _sawFirstFrame = YES;
        // On the receive thread; power management belongs on main.
        [self performSelectorOnMainThread:@selector(handleStreamStarted)
                               withObject:nil waitUntilDone:NO];
    }
    [_decoder submitAccessUnit:avcc sps:sps pps:pps timestamp:timestamp];
}

/// A stream just started arriving. Light the screen if it has already slept,
/// and hold it awake for as long as the stream lasts.
- (void)handleStreamStarted {
    [_power wakeDisplayNow];
    [_power beginKeepingAwake];
    [self updateOverlay];
}

- (void)depacketizerNeedsKeyframe:(LSDepacketizer *)depacketizer {
    [_control requestKeyframe];
}

#pragma mark - periodic

- (void)tick:(NSTimer *)timer {
    // Two seconds of quiet is well past any gap in real audio, and the queue
    // comes back on its own the moment a packet arrives.
    [_audioPlayer pauseIfIdleFor:2.0];
    uint64_t bytes = [_receiver bytesReceived];
    uint64_t delta = bytes >= _bytesAtLastTick ? bytes - _bytesAtLastTick : 0;
    _bytesAtLastTick = bytes;
    _incomingMbps = (double)delta * 8.0 / 1000000.0;

    // A frame that never finished arriving.
    //
    // Losing a packet mid-stream is self-correcting: the next packet reveals
    // the sequence gap and we ask for a keyframe. But if the loss takes the
    // tail of the last frame before the screen goes still, no further packet
    // ever arrives to reveal it -- so the part-built frame just sits there and
    // the iMac shows the previous one indefinitely. Asking for a keyframe
    // repairs it. Only reads state here; the depacketizer itself is left for
    // the receive thread to reset through its normal path when the new frame
    // arrives with a different timestamp.
    NSTimeInterval partialSince = [_depacketizer partialFrameStartedAt];
    if (_sawFirstFrame && partialSince > 0 &&
        [NSDate timeIntervalSinceReferenceDate] - partialSince > 0.5) {
        [_control requestKeyframe];
    }

    // Is the host still there?
    //
    // Silence on the video socket used to be the test, but a still screen now
    // sends no video at all -- that is the point of the change, since forcing a
    // keyframe every second cost 4 Mb/s and a full IDR decode to show a picture
    // that had not changed. So video silence no longer means anything is wrong.
    //
    // The control channel pings once a second whether or not anything is being
    // encoded, so that is the signal. Where there is no control channel we fall
    // back to the old behaviour: less correct, but better than a frozen frame
    // that never clears.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval lastContact;
    if (_control) {
        NSTimeInterval video = [_receiver lastPacketTime];
        NSTimeInterval control = [_control lastHostContact];
        lastContact = video > control ? video : control;
    } else {
        lastContact = [_receiver lastPacketTime];
    }
    // Four seconds is three missed pings. Blanking a working screen because one
    // UDP packet went missing would be far more annoying than noticing a real
    // disconnect a second later.
    if (_sawFirstFrame && lastContact > 0 && now - lastContact > 4.0) {
        [self handleHostDisconnected];
    }

    if (_control) {
        ls_stats stats;
        memset(&stats, 0, sizeof(stats));
        stats.frames_decoded   = [_decoder framesDecoded];
        stats.frames_dropped   = [_decoder framesDropped];
        stats.frames_corrupt   = [_depacketizer framesCorrupt];
        stats.packets_received = [_depacketizer packetsReceived];
        stats.packets_lost     = [_depacketizer packetsLost];
        stats.decode_us        = [_decoder decodeMicroseconds];
        stats.render_us        = [_glView renderMicroseconds];
        stats.queue_depth      = [_decoder queueDepth];
        if (_audioPlayer) {
            stats.audio_underruns   = [_audioPlayer underruns];
            stats.audio_overruns    = [_audioPlayer overruns];
            stats.audio_buffered_us = (uint32_t)([_audioPlayer bufferedMilliseconds] * 1000.0);
        }
        [_control sendStats:&stats];

        // Until video shows up, keep saying hello. The host resends its
        // parameter sets and forces an IDR every time it hears one, so a client
        // started before the host still gets a picture the moment the host
        // comes up.
        if (!_sawFirstFrame) [self sendHello];
    }

    [self updateOverlay];
}

- (void)checkSnapshot:(NSTimer *)timer {
    if ([_decoder framesDecoded] < _snapshotAfter) return;
    [_snapshotTimer invalidate];
    _snapshotTimer = nil;

    // Hide the overlay first so it does not land in the image.
    [_overlayWindow orderOut:nil];
    BOOL ok = [_glView writeSnapshotToPath:_snapshotPath];
    fprintf(stdout, "snapshot %s after %u frames: %s\n",
            ok ? "written" : "FAILED", [_decoder framesDecoded],
            [_snapshotPath UTF8String]);
    fprintf(stdout, "cursor positions processed: %u\n",
            [_control cursorMessagesReceived]);
    fprintf(stdout, "slowest pointer update: %u us\n",
            [_glView cursorUpdateMaxMicroseconds]);
    fprintf(stdout, "render time: %.2f ms (vsync %s)\n",
            [_glView renderMicroseconds] / 1000.0,
            _glView.vsyncEnabled ? "on" : "off");
    fflush(stdout);
    [NSApp terminate:nil];
}

- (void)updateOverlay {
    NSMutableString *text = [NSMutableString string];

    if (_fatalMessage) {
        [text appendFormat:@"LanScreen could not start\n\n%@\n", _fatalMessage];
    } else if (!_sawFirstFrame) {
        [text appendFormat:@"Waiting for %@…\n", _hostAddress];
        [text appendFormat:@"listening on UDP %u, control %u\n",
            (unsigned)_videoPort, (unsigned)_controlPort];
        if ([_receiver bytesReceived] > 0) {
            [text appendString:@"receiving packets but no complete frame yet\n"];
        }
        NSString *status = [_decoder statusMessage];
        if (status) [text appendFormat:@"%@\n", status];
    } else if (_statsVisible) {
        [text appendFormat:@"host %@   video :%u   control :%u\n",
            _hostAddress, (unsigned)_videoPort, (unsigned)_controlPort];
        [text appendFormat:@"in  %6.2f Mb/s   packets %u   lost %u\n",
            _incomingMbps, [_depacketizer packetsReceived], [_depacketizer packetsLost]];
        [text appendFormat:@"frames %u   dropped %u   corrupt %u   queue %u\n",
            [_decoder framesDecoded], [_decoder framesDropped],
            [_depacketizer framesCorrupt], [_decoder queueDepth]];
        [text appendFormat:@"decode %6.2f ms   render %6.2f ms   vsync %@\n",
            [_decoder decodeMicroseconds] / 1000.0,
            [_glView renderMicroseconds] / 1000.0,
            _glView.vsyncEnabled ? @"on" : @"off"];
        [text appendFormat:@"pointer updates %u\n", [_control cursorMessagesReceived]];
        if (_audioPlayer) {
            [text appendFormat:@"audio %5.1f ms buffered (hold %4.1f + %4.1f hw)   "
                               @"under %u   over %u   vol %3.0f%%\n",
                [_audioPlayer bufferedMilliseconds], [_audioPlayer targetBufferMilliseconds],
                [LSAudioPlayer hardwareFloorMilliseconds],
                [_audioPlayer underruns], [_audioPlayer overruns],
                [_audioPlayer volume] * 100.0f];
            if (_brightness) {
                [text appendFormat:@"brightness %@\n",
                    _brightness.available
                        ? [NSString stringWithFormat:@"%3.0f%%", [_brightness currentBrightness] * 100.0f]
                        : _brightness.statusMessage];
            }
        } else if (_audioEnabled) {
            [text appendString:@"audio: not available\n"];
        }
        [text appendFormat:@"recv buffer %d KB%@\n",
            [_receiver receiveBufferBytes] / 1024,
            [_receiver receiveBufferBytes] < 1024 * 1024 ? @"   TOO SMALL" : @""];
        [text appendFormat:@"awake assertion %@   mac %@\n",
            _power.isKeepingAwake ? @"held" : @"released",
            _control.localMACString ?: @"unknown"];
        if (_power.statusMessage) [text appendFormat:@"%@\n", _power.statusMessage];
    }

    if ([text length] == 0) {
        [_overlayWindow orderOut:nil];
        return;
    }

    [text appendString:@"\n[S] stats   [V] vsync   [K] keyframe   [F] window   [Q] quit"];
    [_overlayField setStringValue:text];

    NSSize size = [[_overlayField cell] cellSizeForBounds:NSMakeRect(0, 0, 900, 400)];
    NSRect frame = [_overlayWindow frame];
    frame.size = NSMakeSize(size.width + 24, size.height + 20);
    [_overlayWindow setFrame:frame display:YES];
    [self positionOverlay];

    if (![_overlayWindow isVisible]) {
        [_window addChildWindow:_overlayWindow ordered:NSWindowAbove];
    }
}

#pragma mark - keys

- (void)handleKeyDown:(NSEvent *)event {
    NSString *characters = [[event charactersIgnoringModifiers] lowercaseString];
    if ([characters length] == 0) return;
    unichar key = [characters characterAtIndex:0];

    switch (key) {
        case 's':
            _statsVisible = !_statsVisible;
            [self updateOverlay];
            break;
        case 'v':
            _glView.vsyncEnabled = !_glView.vsyncEnabled;
            [self updateOverlay];
            break;
        case 'k':
            [_control requestKeyframe];
            break;
        case 'f':
            [self toggleFullscreen];
            break;
        case 'q':
        case 27:    // Escape
            [NSApp terminate:nil];
            break;
        default:
            break;
    }
}

- (void)toggleFullscreen {
    _fullscreen = !_fullscreen;
    // Rebuilding the window is heavier than restyling it, but restyling a
    // borderless window in place on 10.9 loses the OpenGL surface often enough
    // that it is not worth the cleverness.
    [_window removeChildWindow:_overlayWindow];
    [_overlayWindow orderOut:nil];
    [_glView removeFromSuperview];
    [_window orderOut:nil];
    _window = nil;

    if (!_fullscreen) {
        [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    }

    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = _fullscreen ? [screen frame] : NSMakeRect(100, 100, 1280, 720);
    NSUInteger style = _fullscreen
        ? NSBorderlessWindowMask
        : (NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask);

    _window = [[LSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO
                                             screen:screen];
    _window.keyTarget = self;
    [_window setTitle:@"LanScreen"];
    [_window setBackgroundColor:[NSColor blackColor]];
    if (_fullscreen) {
        [_window setLevel:NSMainMenuWindowLevel + 1];
        [NSApp setPresentationOptions:(NSApplicationPresentationHideDock |
                                       NSApplicationPresentationHideMenuBar)];
    }

    [_glView setFrame:[[_window contentView] bounds]];
    [[_window contentView] addSubview:_glView];
    [_window addChildWindow:_overlayWindow ordered:NSWindowAbove];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_window];
    [self positionOverlay];
}

#pragma mark - shutdown

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_tickTimer invalidate];
    _tickTimer = nil;
    [_power endKeepingAwake];
    [_receiver stop];
    [_audioReceiver stop];
    [_audioPlayer stop];
    [_brightness restoreOriginal];
    [_control stop];
    [_decoder stop];
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
