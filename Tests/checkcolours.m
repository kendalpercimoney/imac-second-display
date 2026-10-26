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
//  Checks the colours that came out of the client against the ones that went
//  in, patch by patch, in code values.
//
//  The patches are the "patches" pattern from Tests/LoopSend: mid-tones,
//  because a wrong colour matrix moves those and leaves saturated primaries
//  alone. The table below has to match the one there.
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

typedef struct { const char *name; int r, g, b; } Patch;

static const Patch kPatches[12] = {
    {"skin",   200, 120,  80}, {"leaf",    80, 160,  80},
    {"sky",     90, 150, 210}, {"grey",   128, 128, 128},
    {"shadow",  30,  30,  30}, {"paper",  230, 230, 230},
    {"red",    200,  40,  40}, {"teal",    40, 160, 160},
    {"yellow", 220, 200,  60}, {"purple", 120,  60, 160},
    {"orange", 230, 140,  40}, {"brown",  110,  80,  50},
};

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: checkcolours <png> [tolerance]\n");
            return 2;
        }
        int tolerance = argc > 2 ? atoi(argv[2]) : 4;

        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) { fprintf(stderr, "FAIL: cannot open %s\n", argv[1]); return 2; }
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) { fprintf(stderr, "FAIL: cannot decode image\n"); return 2; }

        // Read the values as stored, with no colour conversion of our own: the
        // question is what the client put in its framebuffer.
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        size_t stride = width * 4;
        uint8_t *pixels = calloc(stride, height);
        CGDataProviderRef provider = CGImageGetDataProvider(image);
        CFDataRef data = CGDataProviderCopyData(provider);
        size_t srcStride = CGImageGetBytesPerRow(image);
        CGBitmapInfo info = CGImageGetBitmapInfo(image);
        size_t bpp = CGImageGetBitsPerPixel(image) / 8;
        BOOL bgr = (info & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;
        const uint8_t *src = CFDataGetBytePtr(data);
        for (size_t y = 0; y < height; y++) {
            for (size_t x = 0; x < width; x++) {
                const uint8_t *s = src + y * srcStride + x * bpp;
                uint8_t *d = pixels + y * stride + x * 4;
                if (bgr) { d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; }
                else     { d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; }
            }
        }
        CFRelease(data);
        CGImageRelease(image);

        printf("image %zux%zu, tolerance +/-%d code values per channel\n\n", width, height, tolerance);
        printf("  %-7s  %-15s  %-15s  %s\n", "patch", "sent", "shown", "error");
        int worst = 0, failures = 0;
        for (int i = 0; i < 12; i++) {
            // The centre of each patch, averaged over a small square so the
            // odd compression ripple does not decide the result.
            int col = i % 4, row = i / 4;
            int cx = (int)((col + 0.5) * width / 4.0);
            int cy = (int)((row + 0.5) * height / 3.0);
            double sr = 0, sg = 0, sb = 0; int n = 0;
            for (int dy = -6; dy <= 6; dy++) for (int dx = -6; dx <= 6; dx++) {
                const uint8_t *p = pixels + (size_t)(cy + dy) * stride + (size_t)(cx + dx) * 4;
                sr += p[0]; sg += p[1]; sb += p[2]; n++;
            }
            int r = (int)lround(sr / n), g = (int)lround(sg / n), b = (int)lround(sb / n);
            int er = r - kPatches[i].r, eg = g - kPatches[i].g, eb = b - kPatches[i].b;
            int e = abs(er) > abs(eg) ? abs(er) : abs(eg);
            if (abs(eb) > e) e = abs(eb);
            if (e > worst) worst = e;
            BOOL ok = e <= tolerance;
            if (!ok) failures++;
            printf("  %-7s  (%3d,%3d,%3d)    (%3d,%3d,%3d)    %+4d %+4d %+4d  %s\n",
                   kPatches[i].name, kPatches[i].r, kPatches[i].g, kPatches[i].b,
                   r, g, b, er, eg, eb, ok ? "ok" : "FAIL");
        }
        free(pixels);
        printf("\nworst channel error: %d code values\n", worst);
        printf("RESULT: %s\n", failures == 0 ? "PASS" : "FAIL");
        return failures == 0 ? 0 : 1;
    }
}
