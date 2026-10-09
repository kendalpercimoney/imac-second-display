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
//  Verifies the colour round trip end to end: BGRA -> H.264 -> 2vuy ->
//  GL_YCBCR_422_APPLE -> screen. Reads the PNG the client wrote and checks the
//  four quadrants came out the colours they went in as.
//
//  A wrong YUV->RGB matrix, a video-range vs full-range mismatch, or a flipped
//  image all show up here rather than as "the colours look a bit off" once the
//  code is on a machine in another room.
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

typedef struct { const char *name; double fx, fy; int r, g, b; } Expectation;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: checkpattern <png> [tolerance] [--at x y r g b]\n");
            return 2;
        }
        int tolerance = argc > 2 ? atoi(argv[2]) : 32;
        int pointMode = 0, px = 0, py = 0, pr = 0, pg = 0, pb = 0;
        for (int i = 3; i + 5 < argc; i++) {
            if (strcmp(argv[i], "--at") == 0) {
                pointMode = 1;
                px = atoi(argv[i+1]); py = atoi(argv[i+2]);
                pr = atoi(argv[i+3]); pg = atoi(argv[i+4]); pb = atoi(argv[i+5]);
            }
        }

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) { fprintf(stderr, "FAIL: cannot open %s\n", argv[1]); return 2; }
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) { fprintf(stderr, "FAIL: cannot decode image\n"); return 2; }

        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        size_t stride = width * 4;
        uint8_t *pixels = calloc(stride, height);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, stride, space,
                                                     (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(space);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
        CGImageRelease(image);

        printf("image %zux%zu, tolerance +/-%d\n", width, height, tolerance);

        if (pointMode) {
            uint8_t *p = pixels + (size_t)py * stride + (size_t)px * 4;
            int dr = abs((int)p[0] - pr), dg = abs((int)p[1] - pg), db = abs((int)p[2] - pb);
            BOOL ok = (dr <= tolerance && dg <= tolerance && db <= tolerance);
            printf("  point (%4d,%4d): got (%3u,%3u,%3u) want (%3d,%3d,%3d)  %s\n",
                   px, py, p[0], p[1], p[2], pr, pg, pb, ok ? "ok" : "OUT OF RANGE");
            free(pixels);
            printf("\n%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
            return ok ? 0 : 1;
        }

        Expectation expectations[] = {
            { "top-left  red  ", 0.25, 0.25, 255,   0,   0 },
            { "top-right green", 0.75, 0.25,   0, 255,   0 },
            { "bot-left  blue ", 0.25, 0.75,   0,   0, 255 },
            { "bot-right white", 0.75, 0.75, 255, 255, 255 },
        };

        int failures = 0;
        for (int i = 0; i < 4; i++) {
            Expectation e = expectations[i];
            size_t x = (size_t)(e.fx * width), y = (size_t)(e.fy * height);
            uint8_t *p = pixels + y * stride + x * 4;
            int dr = abs((int)p[0] - e.r), dg = abs((int)p[1] - e.g), db = abs((int)p[2] - e.b);
            BOOL ok = (dr <= tolerance && dg <= tolerance && db <= tolerance);
            printf("  %s at (%4zu,%4zu): got (%3u,%3u,%3u) want (%3d,%3d,%3d)  delta (%3d,%3d,%3d)  %s\n",
                   e.name, x, y, p[0], p[1], p[2], e.r, e.g, e.b, dr, dg, db,
                   ok ? "ok" : "OUT OF RANGE");
            if (!ok) failures++;
        }
        free(pixels);

        printf("\n%s\n", failures == 0 ? "RESULT: PASS" : "RESULT: FAIL");
        return failures == 0 ? 0 : 1;
    }
}
