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

/// Where to draw the pointer, in streamed video pixels with a top-left origin.
/// Safe to call from any thread; redraws immediately so the pointer keeps
/// moving even while the picture underneath is perfectly still.
- (void)setCursorX:(int)x y:(int)y visible:(BOOL)visible;

/// Premultiplied RGBA, uploaded on the next draw. Safe to call from any thread.
- (void)setCursorImage:(NSData *)rgba
                 width:(int)width height:(int)height
              hotspotX:(int)hotspotX hotspotY:(int)hotspotY;

/// Never draw more often than this. The pointer arrives at 120 Hz and marks
/// the view dirty each time; on a 60 Hz panel half of those draws are of a
/// frame nobody sees. Zero removes the limit.
- (void)setMaximumDrawsPerSecond:(double)rate;

/// 0 = present as soon as the frame is ready (tearing, lowest latency).
/// 1 = wait for vertical blank (clean, adds up to one refresh of latency).
@property (nonatomic, assign) BOOL vsyncEnabled;

@property (nonatomic, readonly) uint32_t renderMicroseconds;   // rolling average

/// The longest a single pointer update has taken to hand over.
///
/// This is the invariant that matters for how the pointer feels: a thread
/// receiving network data must never wait on the display. If this creeps up to
/// milliseconds, something in the update path is blocking on a draw -- which on
/// a 60 Hz screen means only half the updates can be serviced and the rest
/// queue, one refresh apart, for as long as the pointer keeps moving.
@property (nonatomic, readonly) uint32_t cursorUpdateMaxMicroseconds;

/// Reads the framebuffer back and writes a PNG. Used by the test harness to
/// prove the render path works without anyone having to look at a screen.
/// Call from the main thread; returns NO if nothing has been drawn yet.
- (BOOL)writeSnapshotToPath:(NSString *)path;

@end
