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

#import "LSGLView.h"
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurfaceAPI.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#include <mach/mach_time.h>
#include <pthread.h>

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
                struct timespec deadline;
                clock_gettime(CLOCK_REALTIME, &deadline);
                deadline.tv_nsec += (long)remainingNanos;
                deadline.tv_sec += deadline.tv_nsec / 1000000000L;
                deadline.tv_nsec %= 1000000000L;
                // A timed wait rather than a sleep: it releases the mutex, so
                // producers never block on the render thread napping.
                pthread_cond_timedwait(&_renderCond, &_renderMutex, &deadline);
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

    glClear(GL_COLOR_BUFFER_BIT);

    if (buffer) {
        [self drawBuffer:buffer intoViewWidth:viewWidth height:viewHeight cgl:cgl];
        [self drawCursorIntoViewWidth:viewWidth height:viewHeight forBuffer:buffer];
    }

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
        glFormat = GL_YCBCR_422_APPLE;
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
        NSLog(@"[LanScreen] CGLTexImageIOSurface2D failed: %d", (int)err);
        return;
    }

    // Aspect-fit letterbox.
    double scale = fmin((double)viewWidth / (double)imageWidth,
                        (double)viewHeight / (double)imageHeight);
    double drawWidth  = (double)imageWidth * scale;
    double drawHeight = (double)imageHeight * scale;
    double originX = ((double)viewWidth - drawWidth) * 0.5;
    double originY = ((double)viewHeight - drawHeight) * 0.5;

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
