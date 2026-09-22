//
//  LSGLView.h
//  Zero-copy CVPixelBuffer -> OpenGL rendering for OS X 10.9.
//
//  The decoder hands us IOSurface-backed pixel buffers. CGLTexImageIOSurface2D
//  binds that surface directly as a texture with no CPU copy and no upload, and
//  for 2vuy the GL_YCBCR_422_APPLE format makes the texture unit do the
//  YUV->RGB conversion for free. On a 2010 GPU that is the difference between
//  comfortable and unwatchable.
//
#import <Cocoa/Cocoa.h>
#import <CoreVideo/CoreVideo.h>

@interface LSGLView : NSOpenGLView

/// Safe to call from any thread. Takes ownership of the passed-in buffer.
///
/// Draws immediately on the calling thread rather than bouncing to the main
/// run loop. On a busy 2010 iMac that hop is worth several milliseconds, and
/// the CGL context lock makes the direct path safe.
- (void)presentPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// Clears to black and forgets the last frame.
- (void)clear;

/// 0 = present as soon as the frame is ready (tearing, lowest latency).
/// 1 = wait for vertical blank (clean, adds up to one refresh of latency).
@property (nonatomic, assign) BOOL vsyncEnabled;

@property (nonatomic, readonly) uint32_t renderMicroseconds;   // rolling average

/// Reads the framebuffer back and writes a PNG. Used by the test harness to
/// prove the render path works without anyone having to look at a screen.
/// Call from the main thread; returns NO if nothing has been drawn yet.
- (BOOL)writeSnapshotToPath:(NSString *)path;

@end
