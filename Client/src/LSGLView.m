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

#include <dlfcn.h>
#import "LSGLView.h"
#include "rtp_protocol.h"
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurfaceAPI.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#include <mach/mach_time.h>
#include <pthread.h>

// BT.709, video range, written out rather than left to GL_YCBCR_422_APPLE.
//
// The host captures with ScreenCaptureKit, which converts to YCbCr with the
// BT.709 matrix -- measured, and tagged so on its buffers. The built-in
// conversion is a fixed matrix inside the driver, and which one depends on the
// driver: on a current Mac it comes out within 2 code values of BT.709, but
// what a 2010 Radeon under 10.9 does could not be checked from here. If it is
// the older BT.601 one, foliage comes out 14 code values too green and skin
// tones shift with it. So the client measures the built-in conversion when it
// starts, and only if that is off does it use this instead.
//
// GL_RGB_422_APPLE hands over the 2vuy samples unconverted: luma in green,
// Cb in blue, Cr in red. No #version line: GLSL 1.10, which every Mac that
// runs 10.9 has.
static const char *kColourShaderSource =
    "#extension GL_ARB_texture_rectangle : enable\n"
    "uniform sampler2DRect frame;\n"
    "void main() {\n"
    "    vec3 s = texture2DRect(frame, gl_TexCoord[0].st).rgb;\n"
    "    float y  = (s.g - 16.0 / 255.0) * (255.0 / 219.0);\n"
    "    float cb = (s.b - 128.0 / 255.0) * (255.0 / 224.0);\n"
    "    float cr = (s.r - 128.0 / 255.0) * (255.0 / 224.0);\n"
    "    gl_FragColor = vec4(y + 1.5748 * cr,\n"
    "                        y - 0.1873 * cb - 0.4681 * cr,\n"
    "                        y + 1.8556 * cb, 1.0);\n"
    "}\n";

// The colours the check draws: mid-tones, because a wrong matrix moves those
// and leaves greys and saturated primaries alone.
static const int kColourCheckPatches[4][3] = {
    { 80, 160,  80},    // leaf
    {200, 120,  80},    // skin
    { 90, 150, 210},    // sky
    {128, 128, 128},    // grey
};
#define LS_COLOUR_PATCH_WIDTH 16
#define LS_COLOUR_CHECK_HEIGHT 8
// Within this many code values per channel counts as right. Rounding to
// 8-bit YCbCr and back costs one or two on its own.
#define LS_COLOUR_TOLERANCE 4

@implementation LSGLView {
    GLuint _texture;
    CVPixelBufferRef _currentBuffer;
    // Two locks, deliberately. _glLock is held for the whole of a draw, which
    // can be many milliseconds. _stateLock is held only long enough to hand
    // over a pointer or a frame, so the threads producing those never wait on
    // the display. Sharing one lock meant every pointer update queued behind
    // the current draw, which is most of what made vsync feel like syrup.
    NSLock *_glLock;
    NSLock *_stateLock;
    BOOL _contextReady;
    // Rendering happens on its own thread, woken by whoever changed something.
    // Nothing that receives data may draw: with vsync on, a draw blocks until
    // the next vertical blank, and the control thread receives pointer updates
    // at twice the refresh rate. Drawing inline there meant it could only
    // service half of them, so the rest queued in the socket buffer and were
    // drawn later, stale, one refresh apart -- latency that grew for as long as
    // the pointer kept moving.
    NSThread *_renderThread;
    pthread_mutex_t _renderMutex;
    pthread_cond_t _renderCond;
    BOOL _renderDirty;
    /// Drawing more often than the panel refreshes is work nobody can see.
    uint64_t _minimumDrawInterval;
    uint64_t _lastDrawTime;
    volatile BOOL _renderRunning;
    // AppKit accessors like -window and -bounds are not safe to call from a
    // background thread, and can wait on AppKit's own lock while the main
    // thread is busy -- which showed up as pointer updates occasionally taking
    // milliseconds even once the drawing had been moved off that thread.
    // Both are cached here by the main thread instead.
    volatile BOOL _hasWindow;
    GLsizei _cachedWidth, _cachedHeight;
    /// Every completed draw. Watched from the once-a-second tick: frames
    /// arriving and decoding while this stands still is a render thread that
    /// has stopped, which is what a frozen picture looks like from the inside
    /// and used to leave no trace at all.
    uint32_t _framesDrawn;

    // How 2vuy frames are turned into RGB, decided once by measuring.
    GLuint _colourProgram;          // the BT.709 shader, 0 if it could not be built
    GLint  _colourSampler;
    GLuint _colourCheckTexture;
    CVPixelBufferRef _colourCheckBuffer;
    BOOL   _colourChecked;
    BOOL   _useColourShader;
    int    _colourError;            // worst channel error of the path in use
    BOOL   _stripColourTags;        // test only: see -colourStripTags
    double _hostPointsPerViewPoint;
    GLuint _cursorTexture;
    NSData *_pendingCursorImage;
    int _cursorImageWidth, _cursorImageHeight;
    int _cursorHotspotX, _cursorHotspotY;
    BOOL _haveCursorImage;
    int _cursorX, _cursorY;
    BOOL _cursorVisible;
    NSString *_pendingSnapshotPath;
    BOOL _snapshotSucceeded;
    OSType _loggedUnsupportedFormat;
    /// Failures here repeat every frame, so the log is throttled rather than
    /// silenced: the first one, then one line per 300 after it. A fault that
    /// prints sixty times a second on a 2010 iMac is a second fault.
    uint32_t _texImageFailures;
    uint64_t _lastDiagnosis;
    double _renderMicrosAverage;
    mach_timebase_info_data_t _timebase;
}

+ (NSOpenGLPixelFormat *)defaultPixelFormat {
    // Legacy profile on purpose: the 2010 iMac's GPU drivers are far better
    // exercised on the fixed-function path, and a textured quad needs nothing
    // that a core profile would give us.
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADepthSize, 0,
        NSOpenGLPFANoRecovery,
        0
    };
    return [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
}

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame pixelFormat:[LSGLView defaultPixelFormat]];
    if (self) {
        _glLock = [[NSLock alloc] init];
        _stateLock = [[NSLock alloc] init];
        mach_timebase_info(&_timebase);
        _loggedUnsupportedFormat = 0;
        _texImageFailures = 0;
        _hostPointsPerViewPoint = 1.0;
        _colourError = -1;
        // Test only. Strips the colour tags off every decoded frame, which is
        // what a decoder that does not tag its output would hand over -- and
        // on a current Mac makes the built-in conversion fall back to BT.601.
        // It is how the shader fallback is tested without a Mac that needs it.
        _stripColourTags = [[NSUserDefaults standardUserDefaults] boolForKey:@"colourStripTags"];
        _vsyncEnabled = NO;
        pthread_mutex_init(&_renderMutex, NULL);
        pthread_cond_init(&_renderCond, NULL);
    }
    return self;
}

- (void)dealloc {
    [self stopRendering];
    pthread_mutex_destroy(&_renderMutex);
    pthread_cond_destroy(&_renderCond);
    if (_currentBuffer) CVBufferRelease(_currentBuffer);
    if (_colourCheckBuffer) CVBufferRelease(_colourCheckBuffer);
}

#pragma mark - render thread

/// Coalescing is the point: several updates between two blanks produce one
/// draw, of the newest state, rather than a queue of old ones.
- (void)markDirty {
    pthread_mutex_lock(&_renderMutex);
    _renderDirty = YES;
    pthread_cond_signal(&_renderCond);
    pthread_mutex_unlock(&_renderMutex);
}

- (void)startRendering {
    if (_renderThread) return;
    _renderRunning = YES;
    _renderThread = [[NSThread alloc] initWithTarget:self
                                            selector:@selector(renderLoop)
                                              object:nil];
    [_renderThread setName:@"com.lanscreen.render"];
    [_renderThread setThreadPriority:0.9];
    [_renderThread start];
}

- (void)stopRendering {
    if (!_renderThread) return;
    pthread_mutex_lock(&_renderMutex);
    _renderRunning = NO;
    pthread_cond_broadcast(&_renderCond);
    pthread_mutex_unlock(&_renderMutex);
    while (![_renderThread isFinished]) usleep(1000);
    _renderThread = nil;
}

- (void)renderLoop {
    while (_renderRunning) {
        pthread_mutex_lock(&_renderMutex);
        while (!_renderDirty && _renderRunning) {
            pthread_cond_wait(&_renderCond, &_renderMutex);
        }

        // Something wants drawing. Before drawing it, wait out whatever is left
        // of this refresh interval, and let every other update that arrives
        // meanwhile fold into the same draw.
        //
        // The pointer arrives a hundred and twenty times a second and each
        // arrival marks the view dirty. On a sixty hertz panel half of those
        // draws are of a frame nobody will ever see, and a full-screen redraw
        // on a 2010 GPU is not cheap: moving the pointer measured at +76% CPU
        // over the video alone, and a quarter of that was these invisible
        // draws. Coalescing costs nothing visible -- the newest state is still
        // what gets drawn -- and the wait is on the condition variable, so a
        // frame arriving during it is absorbed rather than delayed past it.
        if (_minimumDrawInterval > 0) {
            uint64_t now = mach_absolute_time();
            uint64_t sinceLast = now - _lastDrawTime;
            if (_lastDrawTime != 0 && sinceLast < _minimumDrawInterval) {
                uint64_t remaining = _minimumDrawInterval - sinceLast;
                double remainingNanos = (double)remaining * (double)_timebase.numer
                                      / (double)_timebase.denom;
                struct timespec wait;
                wait.tv_sec = (time_t)(remainingNanos / 1e9);
                wait.tv_nsec = (long)(remainingNanos - (double)wait.tv_sec * 1e9);
                // Relative rather than absolute: clock_gettime does not exist
                // before 10.12, and this Mac's SDK compiles it happily while
                // the iMac's does not. The _np call has been in macOS since
                // 10.4 and needs no wall clock at all.
                pthread_cond_timedwait_relative_np(&_renderCond, &_renderMutex, &wait);
            }
        }

        _renderDirty = NO;
        pthread_mutex_unlock(&_renderMutex);
        if (!_renderRunning) break;
        _lastDrawTime = mach_absolute_time();
        @autoreleasepool { [self renderNow]; }
    }
}

/// Draws no more often than this. Zero removes the limit.
- (void)setMaximumDrawsPerSecond:(double)rate {
    if (rate <= 0) { _minimumDrawInterval = 0; return; }
    double nanos = 1e9 / rate;
    _minimumDrawInterval = (uint64_t)(nanos * (double)_timebase.denom
                                            / (double)_timebase.numer);
}

- (BOOL)isOpaque { return YES; }

#pragma mark - context setup

- (void)prepareOpenGL {
    [super prepareOpenGL];
    [self applyContextSettings];
    NSRect bounds = [self bounds];
    _cachedWidth = (GLsizei)NSWidth(bounds);
    _cachedHeight = (GLsizei)NSHeight(bounds);
    _hasWindow = ([self window] != nil);
    _contextReady = YES;
    [self startRendering];
}

- (void)applyContextSettings {
    CGLContextObj cgl = [[self openGLContext] CGLContextObj];
    CGLSetCurrentContext(cgl);

    GLint swapInterval = _vsyncEnabled ? 1 : 0;
    [[self openGLContext] setValues:&swapInterval forParameter:NSOpenGLCPSwapInterval];

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_DITHER);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

    if (_texture == 0) {
        glGenTextures(1, &_texture);
    }
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _texture);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

- (void)setVsyncEnabled:(BOOL)enabled {
    _vsyncEnabled = enabled;
    if (!_contextReady) return;
    [_glLock lock];
    CGLContextObj cgl = [[self openGLContext] CGLContextObj];
    CGLLockContext(cgl);
    GLint interval = enabled ? 1 : 0;
    [[self openGLContext] setValues:&interval forParameter:NSOpenGLCPSwapInterval];
    CGLUnlockContext(cgl);
    [_glLock unlock];
}

// -update and -reshape arrive on the main thread while the render thread may
// be mid-draw, so both take the same lock the renderer uses. Doing the context
// update here rather than deferring it means a resize is correct even if no
// new frame ever arrives.
- (void)update {
    if (!_contextReady) { [super update]; return; }
    [_glLock lock];
    CGLContextObj cgl = [[self openGLContext] CGLContextObj];
    CGLLockContext(cgl);
    [super update];
    CGLUnlockContext(cgl);
    [_glLock unlock];
}

- (void)reshape {
    [super reshape];
    NSRect bounds = [self bounds];
    _cachedWidth = (GLsizei)NSWidth(bounds);
    _cachedHeight = (GLsizei)NSHeight(bounds);
    if (_contextReady) [self markDirty];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    _hasWindow = ([self window] != nil);
    NSRect bounds = [self bounds];
    _cachedWidth = (GLsizei)NSWidth(bounds);
    _cachedHeight = (GLsizei)NSHeight(bounds);
    if (_hasWindow && _contextReady) [self markDirty];
}

#pragma mark - presentation

- (void)presentPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;
    if (_stripColourTags) {
        CVBufferRemoveAllAttachments(pixelBuffer);
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
        // Not in the 10.9 SDK, so looked up rather than linked: this is a
        // test mode, and the function does not exist on the iMac.
        static void (*removeAll)(IOSurfaceRef);
        if (!removeAll) removeAll = (void (*)(IOSurfaceRef))dlsym(RTLD_DEFAULT, "IOSurfaceRemoveAllValues");
        if (surface && removeAll) removeAll(surface);
    }

    [_stateLock lock];
    if (_currentBuffer) CVBufferRelease(_currentBuffer);
    _currentBuffer = pixelBuffer;          // ownership transferred in
    [_stateLock unlock];

    if (!_contextReady || !_hasWindow) {
        // Context not up yet; the next drawRect: on the main thread will pick
        // the buffer up.
        [self performSelectorOnMainThread:@selector(setNeedsDisplayYes)
                               withObject:nil waitUntilDone:NO];
        return;
    }
    [self markDirty];
}

- (void)setNeedsDisplayYes { [self setNeedsDisplay:YES]; }

#pragma mark - pointer

- (void)setCursorX:(int)x y:(int)y visible:(BOOL)visible {
    uint64_t begin = mach_absolute_time();
    [_stateLock lock];
    BOOL changed = (x != _cursorX || y != _cursorY || visible != _cursorVisible);
    _cursorX = x; _cursorY = y; _cursorVisible = visible;
    [_stateLock unlock];
    // Redraw on movement alone. This is the entire point of sending the pointer
    // separately: it keeps moving at its own rate over a picture that may not
    // have changed for minutes.
    if (changed && _contextReady && _hasWindow) [self markDirty];

    uint64_t elapsed = mach_absolute_time() - begin;
    uint32_t micros = (uint32_t)((double)elapsed * (double)_timebase.numer
                                 / (double)_timebase.denom / 1000.0);
    if (micros > _cursorUpdateMaxMicroseconds) _cursorUpdateMaxMicroseconds = micros;
}

- (void)setCursorImage:(NSData *)rgba
                 width:(int)width height:(int)height
              hotspotX:(int)hotspotX hotspotY:(int)hotspotY {
    if ([rgba length] != (NSUInteger)(width * height * 4)) return;
    [_stateLock lock];
    _pendingCursorImage = [rgba copy];
    _cursorImageWidth = width; _cursorImageHeight = height;
    _cursorHotspotX = hotspotX; _cursorHotspotY = hotspotY;
    [_stateLock unlock];
}

- (void)clear {
    [_stateLock lock];
    if (_currentBuffer) { CVBufferRelease(_currentBuffer); _currentBuffer = NULL; }
    [_stateLock unlock];
    if (_contextReady) [self markDirty];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self renderNow];
}

- (void)renderNow {
    if (!_hasWindow) return;
    uint64_t begin = mach_absolute_time();

    // Copy what is being drawn, briefly, so producers are never blocked by the
    // draw that follows.
    [_stateLock lock];
    CVPixelBufferRef buffer = _currentBuffer ? (CVPixelBufferRef)CVBufferRetain(_currentBuffer) : NULL;
    [_stateLock unlock];

    [_glLock lock];
    NSOpenGLContext *context = [self openGLContext];
    CGLContextObj cgl = [context CGLContextObj];
    CGLLockContext(cgl);
    CGLSetCurrentContext(cgl);

    GLsizei viewWidth = _cachedWidth;
    GLsizei viewHeight = _cachedHeight;
    if (viewWidth <= 0 || viewHeight <= 0) { CGLUnlockContext(cgl); [_glLock unlock];
                                             if (buffer) CVBufferRelease(buffer); return; }
    glViewport(0, 0, viewWidth, viewHeight);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, viewWidth, 0, viewHeight, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    // Once, before the first 2vuy frame, with the context that will draw it.
    // Ahead of the clear, so the check's corner is wiped before anything shows.
    if (buffer && CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_422YpCbCr8) {
        [self checkColourIfNeeded:cgl like:buffer];
    }

    glClear(GL_COLOR_BUFFER_BIT);

    if (buffer) {
        [self drawBuffer:buffer intoViewWidth:viewWidth height:viewHeight cgl:cgl];
        [self drawCursorIntoViewWidth:viewWidth height:viewHeight forBuffer:buffer];
    }

    if (_diagnose && buffer) [self diagnose:buffer viewWidth:viewWidth height:viewHeight];

    if (_pendingSnapshotPath) {
        // Has to happen before the swap: after flushBuffer the back buffer
        // holds whatever was there previously, not what we just drew.
        _snapshotSucceeded = [self readBackTo:_pendingSnapshotPath
                                        width:viewWidth height:viewHeight];
        _pendingSnapshotPath = nil;
    }

    [context flushBuffer];
    CGLUnlockContext(cgl);
    [_glLock unlock];
    if (buffer) CVBufferRelease(buffer);

    uint64_t elapsed = mach_absolute_time() - begin;
    double micros = (double)elapsed * (double)_timebase.numer / (double)_timebase.denom / 1000.0;
    _renderMicrosAverage = (_renderMicrosAverage == 0.0)
        ? micros : (_renderMicrosAverage * 0.85 + micros * 0.15);
    _renderMicroseconds = (uint32_t)_renderMicrosAverage;
    _framesDrawn++;
}

#pragma mark - colour

/// Builds the BT.709 shader, if this driver can hand over 4:2:2 samples
/// unconverted at all. Returns whether it is usable.
- (BOOL)prepareColourShader {
    if (_colourProgram) return YES;
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    if (!extensions || !strstr(extensions, "GL_APPLE_rgb_422")) return NO;

    GLuint shader = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(shader, 1, &kColourShaderSource, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512] = {0};
        glGetShaderInfoLog(shader, sizeof(log) - 1, NULL, log);
        NSLog(@"[LanScreen] colour shader did not compile: %s", log);
        glDeleteShader(shader);
        return NO;
    }
    GLuint program = glCreateProgram();
    glAttachShader(program, shader);
    glLinkProgram(program);
    glDeleteShader(shader);
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { glDeleteProgram(program); return NO; }
    _colourProgram = program;
    _colourSampler = glGetUniformLocation(program, "frame");
    return YES;
}

/// A small 2vuy picture of the check patches, encoded with BT.709 at video
/// range -- exactly what the host's capture produces.
- (CVPixelBufferRef)colourCheckBuffer {
    if (_colourCheckBuffer) return _colourCheckBuffer;
    size_t width = 4 * LS_COLOUR_PATCH_WIDTH, height = LS_COLOUR_CHECK_HEIGHT;
    NSDictionary *attributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_422YpCbCr8,
                            (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x += 2) {
            const int *c = kColourCheckPatches[x / LS_COLOUR_PATCH_WIDTH];
            double r = c[0] / 255.0, g = c[1] / 255.0, b = c[2] / 255.0;
            double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            uint8_t Y  = (uint8_t)lround(16.0 + 219.0 * luma);
            uint8_t Cb = (uint8_t)lround(128.0 + 224.0 * (b - luma) / 1.8556);
            uint8_t Cr = (uint8_t)lround(128.0 + 224.0 * (r - luma) / 1.5748);
            uint8_t *p = base + y * stride + x * 2;      // Cb Y0 Cr Y1
            p[0] = Cb; p[1] = Y; p[2] = Cr; p[3] = Y;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    _colourCheckBuffer = buffer;
    return buffer;
}

/// Draws the check patches through one conversion into the corner of the
/// back buffer, reads them back, and returns the worst channel error in code
/// values -- 255 if it could not be measured at all. The frame drawn straight
/// afterwards clears the corner, and nothing is shown until then.
- (int)measureColour:(BOOL)withShader cgl:(CGLContextObj)cgl {
    CVPixelBufferRef buffer = [self colourCheckBuffer];
    IOSurfaceRef surface = buffer ? CVPixelBufferGetIOSurface(buffer) : NULL;
    if (!surface) return 255;
    GLsizei width = (GLsizei)IOSurfaceGetWidth(surface), height = (GLsizei)IOSurfaceGetHeight(surface);

    if (!_colourCheckTexture) glGenTextures(1, &_colourCheckTexture);
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _colourCheckTexture);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    CGLError err = CGLTexImageIOSurface2D(cgl, GL_TEXTURE_RECTANGLE_ARB, GL_RGB, width, height,
                                          withShader ? GL_RGB_422_APPLE : GL_YCBCR_422_APPLE,
                                          GL_UNSIGNED_SHORT_8_8_APPLE, surface, 0);
    if (err != kCGLNoError) {
        glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
        return 255;
    }
    if (withShader) {
        glUseProgram(_colourProgram);
        glUniform1i(_colourSampler, 0);
    }
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glBegin(GL_QUADS);
        glTexCoord2f(0, 0);                          glVertex2d(0, 0);
        glTexCoord2f((GLfloat)width, 0);             glVertex2d(width, 0);
        glTexCoord2f((GLfloat)width, (GLfloat)height); glVertex2d(width, height);
        glTexCoord2f(0, (GLfloat)height);            glVertex2d(0, height);
    glEnd();
    if (withShader) glUseProgram(0);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);

    int worst = 0;
    for (int i = 0; i < 4; i++) {
        uint8_t pixel[4] = {0};
        glReadPixels(i * LS_COLOUR_PATCH_WIDTH + LS_COLOUR_PATCH_WIDTH / 2,
                     LS_COLOUR_CHECK_HEIGHT / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        for (int c = 0; c < 3; c++) {
            int e = abs((int)pixel[c] - kColourCheckPatches[i][c]);
            if (e > worst) worst = e;
        }
    }
    return worst;
}

/// Decides, once, how 2vuy frames are converted to RGB: the driver's built-in
/// conversion if it measures right, the BT.709 shader if it does not.
///
/// The built-in conversion follows the colour tags on each frame: on a current
/// Mac an untagged 2vuy picture is converted with BT.601 -- 14 code values out
/// on foliage -- and one tagged BT.709 comes out right. Real frames arrive
/// tagged by the decoder, so the check copies the first real frame's tags onto
/// its own picture before measuring. Otherwise it measures a picture no real
/// frame looks like, and reports the built-in conversion wrong when it is not.
/// Whether 10.9's decoder tags its frames, and whether a 2010 driver reads the
/// tags, is exactly what cannot be known from here; this way it does not have
/// to be.
///
/// `-colourPath builtin` or `-colourPath shader` forces one, for testing.
/// `-colourCheck NO` skips the check and uses the built-in conversion, as
/// every client before the check did.
///
/// Each step is logged before it runs. The check has only ever run on current
/// Macs; if a 2010 driver stops dead in one of these calls, the last line in
/// system.log says which.
- (void)checkColourIfNeeded:(CGLContextObj)cgl like:(CVPixelBufferRef)frame {
    if (_colourChecked) return;
    _colourChecked = YES;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"colourCheck"] && ![defaults boolForKey:@"colourCheck"]) {
        _useColourShader = NO;
        NSLog(@"[LanScreen] colour check: skipped, as asked; using the built-in conversion");
        return;
    }

    NSLog(@"[LanScreen] colour check: copying the first frame's colour tags");
    CVPixelBufferRef check = [self colourCheckBuffer];
    if (check && frame) {
        CVBufferRemoveAllAttachments(check);
        CVBufferPropagateAttachments(frame, check);
    }

    NSString *forced = [[defaults stringForKey:@"colourPath"] lowercaseString];
    NSLog(@"[LanScreen] colour check: building the BT.709 shader");
    BOOL shaderUsable = [self prepareColourShader];
    NSLog(@"[LanScreen] colour check: measuring the built-in conversion");
    int builtIn = [self measureColour:NO cgl:cgl];
    NSLog(@"[LanScreen] colour check: measuring the shader%@", shaderUsable ? @"" : @" (not available)");
    int shader = shaderUsable ? [self measureColour:YES cgl:cgl] : 255;

    if ([forced isEqualToString:@"shader"] && shaderUsable) {
        _useColourShader = YES;
    } else if ([forced isEqualToString:@"builtin"]) {
        _useColourShader = NO;
    } else {
        _useColourShader = builtIn > LS_COLOUR_TOLERANCE && shader < builtIn;
    }
    _colourError = _useColourShader ? shader : builtIn;

    BOOL wasForced = [forced isEqualToString:@"shader"] || [forced isEqualToString:@"builtin"];
    if (wasForced) {
        NSLog(@"[LanScreen] colour check: built-in conversion within %d of BT.709, shader "
              @"within %d; using the %@, as forced", builtIn, shader,
              _useColourShader ? @"shader" : @"built-in conversion");
    } else if (!_useColourShader) {
        NSLog(@"[LanScreen] colour check: the built-in conversion is within %d of BT.709, "
              @"so it is used", builtIn);
    } else {
        NSLog(@"[LanScreen] colour check: the built-in conversion is off by up to %d code "
              @"values, so a BT.709 shader is used instead, within %d", builtIn, shader);
    }
    if (_colourError > LS_COLOUR_TOLERANCE && !wasForced) {
        NSLog(@"[LanScreen] colour check: colours are up to %d code values off and "
              @"nothing here could do better (the shader is %@)", _colourError,
              shaderUsable ? @"no closer" : @"not available on this driver");
    }
}

/// Reads the decoded frame's centre on the CPU and the back buffer's centre
/// with glReadPixels, before the swap, and logs both. At most every five
/// seconds: locking a decoded surface and reading back stall the GPU.
- (void)diagnose:(CVPixelBufferRef)buffer viewWidth:(GLsizei)viewWidth height:(GLsizei)viewHeight {
    uint64_t now = mach_absolute_time();
    double sinceLast = (double)(now - _lastDiagnosis) * (double)_timebase.numer / (double)_timebase.denom;
    if (_lastDiagnosis != 0 && sinceLast < 5e9) return;
    _lastDiagnosis = now;

    NSString *decoded = @"not readable";
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    size_t width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer);
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        if (base && format == kCVPixelFormatType_422YpCbCr8) {
            const uint8_t *p = base + (height / 2) * stride + ((width / 2) & ~(size_t)1) * 2;
            decoded = [NSString stringWithFormat:@"Cb %u Y %u Cr %u", p[0], p[1], p[2]];
        } else if (base && format == kCVPixelFormatType_32BGRA) {
            const uint8_t *p = base + (height / 2) * stride + (width / 2) * 4;
            decoded = [NSString stringWithFormat:@"RGB %u %u %u", p[2], p[1], p[0]];
        }
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    }
    uint8_t drawn[4] = {0};
    glReadPixels(viewWidth / 2, viewHeight / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, drawn);
    GLenum glError = glGetError();
    NSLog(@"[LanScreen] diagnose: frame %zux%zu, centre decoded %@, drawn RGB %u %u %u; "
          @"view %dx%d, %@, texture failures %u, frames drawn %u, GL error 0x%x",
          width, height, decoded, drawn[0], drawn[1], drawn[2], viewWidth, viewHeight,
          _useColourShader ? @"BT.709 shader" : @"built-in conversion",
          _texImageFailures, _framesDrawn, glError);
}

- (uint32_t)colourFlags {
    if (!_colourChecked || _colourError < 0) return 0;
    uint32_t flags = LS_DECODER_COLOUR_CHECKED;
    if (_useColourShader) flags |= LS_DECODER_COLOUR_SHADER;
    flags |= (uint32_t)(_colourError > 255 ? 255 : _colourError) << LS_DECODER_COLOUR_ERROR_SHIFT;
    return flags;
}

- (void)drawBuffer:(CVPixelBufferRef)buffer
     intoViewWidth:(GLsizei)viewWidth
            height:(GLsizei)viewHeight
               cgl:(CGLContextObj)cgl
{
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    if (!surface) return;

    GLsizei imageWidth  = (GLsizei)IOSurfaceGetWidth(surface);
    GLsizei imageHeight = (GLsizei)IOSurfaceGetHeight(surface);
    if (imageWidth <= 0 || imageHeight <= 0) return;

    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    GLenum internalFormat, glFormat, glType;

    if (format == kCVPixelFormatType_422YpCbCr8) {
        // '2vuy' is UYVY = Cb Y Cr Y, which is what GL_UNSIGNED_SHORT_8_8_APPLE
        // describes. GL_YCBCR_422_APPLE (as opposed to GL_RGB_422_APPLE) is the
        // variant that performs the colour conversion for us.
        internalFormat = GL_RGB;
        glFormat = _useColourShader ? GL_RGB_422_APPLE : GL_YCBCR_422_APPLE;
        glType = GL_UNSIGNED_SHORT_8_8_APPLE;
    } else if (format == kCVPixelFormatType_32BGRA) {
        internalFormat = GL_RGBA;
        glFormat = GL_BGRA;
        glType = GL_UNSIGNED_INT_8_8_8_8_REV;
    } else {
        if (_loggedUnsupportedFormat != format) {
            _loggedUnsupportedFormat = format;
            NSLog(@"[LanScreen] unsupported pixel format '%c%c%c%c' from the decoder",
                  (char)((format >> 24) & 0xFF), (char)((format >> 16) & 0xFF),
                  (char)((format >> 8) & 0xFF), (char)(format & 0xFF));
        }
        return;
    }

    glEnable(GL_TEXTURE_RECTANGLE_ARB);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _texture);

    CGLError err = CGLTexImageIOSurface2D(cgl, GL_TEXTURE_RECTANGLE_ARB,
                                          internalFormat,
                                          imageWidth, imageHeight,
                                          glFormat, glType, surface, 0);
    if (err != kCGLNoError) {
        if (_texImageFailures++ % 300 == 0) {
            NSLog(@"[LanScreen] CGLTexImageIOSurface2D failed: %d (%u so far)",
                  (int)err, _texImageFailures);
        }
        return;
    }

    // Aspect-fit letterbox.
    double scale = fmin((double)viewWidth / (double)imageWidth,
                        (double)viewHeight / (double)imageHeight);
    double drawWidth  = (double)imageWidth * scale;
    double drawHeight = (double)imageHeight * scale;
    // Stream pixels are host points, and the view is in points, so this is
    // how far the host's pointer has to move for each point a hand moves it
    // across the picture.
    if (scale > 0) _hostPointsPerViewPoint = 1.0 / scale;
    double originX = ((double)viewWidth - drawWidth) * 0.5;
    double originY = ((double)viewHeight - drawHeight) * 0.5;

    BOOL shading = _useColourShader && format == kCVPixelFormatType_422YpCbCr8;
    if (shading) {
        glUseProgram(_colourProgram);
        glUniform1i(_colourSampler, 0);
    }

    // Texture rectangle coordinates are in texels, and the image is top-down
    // while GL is bottom-up, hence the flipped T coordinates.
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glBegin(GL_QUADS);
        glTexCoord2f(0.0f, (GLfloat)imageHeight);
        glVertex2d(originX, originY);

        glTexCoord2f((GLfloat)imageWidth, (GLfloat)imageHeight);
        glVertex2d(originX + drawWidth, originY);

        glTexCoord2f((GLfloat)imageWidth, 0.0f);
        glVertex2d(originX + drawWidth, originY + drawHeight);

        glTexCoord2f(0.0f, 0.0f);
        glVertex2d(originX, originY + drawHeight);
    glEnd();

    // Back to fixed function before the pointer is drawn: it is RGBA, and
    // running it through the YCbCr shader would turn it into nonsense.
    if (shading) glUseProgram(0);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
}

/// Draws the pointer over the video, in the same letterboxed rectangle the
/// video occupies, so it lands where it would on the host's screen.
- (void)drawCursorIntoViewWidth:(GLsizei)viewWidth height:(GLsizei)viewHeight
                      forBuffer:(CVPixelBufferRef)buffer {
    [_stateLock lock];
    NSData *pendingImage = _pendingCursorImage;
    _pendingCursorImage = nil;
    int imageWidthPx = _cursorImageWidth, imageHeightPx = _cursorImageHeight;
    int hotspotX = _cursorHotspotX, hotspotY = _cursorHotspotY;
    int cursorX = _cursorX, cursorY = _cursorY;
    BOOL visible = _cursorVisible;
    [_stateLock unlock];

    if (pendingImage) {
        if (_cursorTexture == 0) glGenTextures(1, &_cursorTexture);
        glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _cursorTexture);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA,
                     imageWidthPx, imageHeightPx, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, [pendingImage bytes]);
        _haveCursorImage = YES;
    }
    if (!_haveCursorImage || !visible || !buffer) return;

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    if (!surface) return;
    double imageWidth = (double)IOSurfaceGetWidth(surface);
    double imageHeight = (double)IOSurfaceGetHeight(surface);
    if (imageWidth <= 0 || imageHeight <= 0) return;

    double scale = fmin((double)viewWidth / imageWidth, (double)viewHeight / imageHeight);
    double drawWidth = imageWidth * scale, drawHeight = imageHeight * scale;
    double originX = ((double)viewWidth - drawWidth) * 0.5;
    double originY = ((double)viewHeight - drawHeight) * 0.5;

    // Video coordinates run downwards, GL upwards.
    double left = originX + ((double)cursorX - hotspotX) * scale;
    double top = originY + drawHeight - ((double)cursorY - hotspotY) * scale;
    double w = imageWidthPx * scale, h = imageHeightPx * scale;

    glEnable(GL_BLEND);
    // The bitmap is premultiplied, so source alpha is already folded in.
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_TEXTURE_RECTANGLE_ARB);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _cursorTexture);
    glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
    glBegin(GL_QUADS);
        glTexCoord2f(0.0f, (GLfloat)imageHeightPx); glVertex2d(left, top - h);
        glTexCoord2f((GLfloat)imageWidthPx, (GLfloat)imageHeightPx); glVertex2d(left + w, top - h);
        glTexCoord2f((GLfloat)imageWidthPx, 0.0f); glVertex2d(left + w, top);
        glTexCoord2f(0.0f, 0.0f); glVertex2d(left, top);
    glEnd();
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
    glDisable(GL_BLEND);
}

- (BOOL)writeSnapshotToPath:(NSString *)path {
    if (!_contextReady) return NO;
    [_glLock lock];
    _pendingSnapshotPath = [path copy];
    _snapshotSucceeded = NO;
    [_glLock unlock];
    [self renderNow];          // draws, then reads back before the swap
    [_glLock lock];
    BOOL ok = _snapshotSucceeded;
    [_glLock unlock];
    return ok;
}

/// Called from inside renderNow with the context current and locked.
- (BOOL)readBackTo:(NSString *)path width:(GLsizei)width height:(GLsizei)height {
    if (width <= 0 || height <= 0) return NO;
    size_t stride = (size_t)width * 4;

    uint8_t *pixels = malloc(stride * (size_t)height);
    if (!pixels) return NO;
    glReadBuffer(GL_BACK);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);

    // OpenGL hands back rows bottom-up; CGImage wants them top-down.
    uint8_t *flipped = malloc(stride * (size_t)height);
    if (!flipped) { free(pixels); return NO; }
    for (GLsizei y = 0; y < height; y++) {
        memcpy(flipped + (size_t)y * stride,
               pixels + (size_t)(height - 1 - y) * stride, stride);
    }
    free(pixels);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(flipped, (size_t)width, (size_t)height,
                                                 8, stride, space,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);
    if (!context) { free(flipped); return NO; }

    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(flipped);
    if (!image) return NO;

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, kUTTypePNG, 1, NULL);
    BOOL ok = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    return ok;
}

@end
