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

@implementation LSGLView {
    GLuint _texture;
    CVPixelBufferRef _currentBuffer;
    NSLock *_lock;
    BOOL _contextReady;
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
        _lock = [[NSLock alloc] init];
        mach_timebase_info(&_timebase);
        _loggedUnsupportedFormat = 0;
        _vsyncEnabled = NO;
    }
    return self;
}

- (void)dealloc {
    if (_currentBuffer) CVBufferRelease(_currentBuffer);
}

- (BOOL)isOpaque { return YES; }

#pragma mark - context setup

- (void)prepareOpenGL {
    [super prepareOpenGL];
    [self applyContextSettings];
    _contextReady = YES;
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
    [_lock lock];
    CGLContextObj cgl = [[self openGLContext] CGLContextObj];
    CGLLockContext(cgl);
    GLint interval = enabled ? 1 : 0;
    [[self openGLContext] setValues:&interval forParameter:NSOpenGLCPSwapInterval];
    CGLUnlockContext(cgl);
    [_lock unlock];
}

// -update and -reshape arrive on the main thread while the render thread may
// be mid-draw, so both take the same lock the renderer uses. Doing the context
// update here rather than deferring it means a resize is correct even if no
// new frame ever arrives.
- (void)update {
    if (!_contextReady) { [super update]; return; }
    [_lock lock];
    CGLContextObj cgl = [[self openGLContext] CGLContextObj];
    CGLLockContext(cgl);
    [super update];
    CGLUnlockContext(cgl);
    [_lock unlock];
}

- (void)reshape {
    [super reshape];
    if (_contextReady) [self renderNow];
}

#pragma mark - presentation

- (void)presentPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;

    [_lock lock];
    if (_currentBuffer) CVBufferRelease(_currentBuffer);
    _currentBuffer = pixelBuffer;          // ownership transferred in
    [_lock unlock];

    if (!_contextReady || ![self window]) {
        // Context not up yet; the next drawRect: on the main thread will pick
        // the buffer up.
        [self performSelectorOnMainThread:@selector(setNeedsDisplayYes)
                               withObject:nil waitUntilDone:NO];
        return;
    }
    [self renderNow];
}

- (void)setNeedsDisplayYes { [self setNeedsDisplay:YES]; }

- (void)clear {
    [_lock lock];
    if (_currentBuffer) { CVBufferRelease(_currentBuffer); _currentBuffer = NULL; }
    [_lock unlock];
    if (_contextReady) [self renderNow];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self renderNow];
}

- (void)renderNow {
    uint64_t begin = mach_absolute_time();

    [_lock lock];
    NSOpenGLContext *context = [self openGLContext];
    CGLContextObj cgl = [context CGLContextObj];
    CGLLockContext(cgl);
    CGLSetCurrentContext(cgl);

    NSRect bounds = [self bounds];
    GLsizei viewWidth  = (GLsizei)NSWidth(bounds);
    GLsizei viewHeight = (GLsizei)NSHeight(bounds);
    glViewport(0, 0, viewWidth, viewHeight);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, viewWidth, 0, viewHeight, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    glClear(GL_COLOR_BUFFER_BIT);

    if (_currentBuffer) {
        [self drawBuffer:_currentBuffer intoViewWidth:viewWidth height:viewHeight cgl:cgl];
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
    [_lock unlock];

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

- (BOOL)writeSnapshotToPath:(NSString *)path {
    if (!_contextReady) return NO;
    [_lock lock];
    _pendingSnapshotPath = [path copy];
    _snapshotSucceeded = NO;
    [_lock unlock];
    [self renderNow];          // draws, then reads back before the swap
    [_lock lock];
    BOOL ok = _snapshotSucceeded;
    [_lock unlock];
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
