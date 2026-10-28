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
//  How faithfully the client reconstructs colour at sharp colour edges -- the
//  part of the picture 4:2:0 chroma takes away first, and what makes small app
//  icons look stepped. Reads one row of the client's snapshot of the "stripes"
//  pattern from Tests/LoopSend and reports the mean error against what was sent.
//  The colour list and the band rule have to match the ones there.
//
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static const int kStripes[6][3] = {
    {220, 40, 40}, {40, 180, 60}, {50, 80, 220}, {230, 200, 40}, {200, 60, 200}, {40, 190, 200},
};

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: checkchroma <png>\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
        const uint8_t *src = CFDataGetBytePtr(data);
        size_t stride = CGImageGetBytesPerRow(image), bpp = CGImageGetBitsPerPixel(image) / 8;
        BOOL bgr = (CGImageGetBitmapInfo(image) & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;

        // The middle rows, away from the edges of the picture; every column but
        // the first and last 64.
        double sum = 0; long n = 0; int worst = 0;
        for (size_t y = height / 2 - 8; y < height / 2 + 8; y++) {
            for (size_t x = 64; x < width - 64; x++) {
                const uint8_t *p = src + y * stride + x * bpp;
                int rgb[3] = { bgr ? p[2] : p[0], p[1], bgr ? p[0] : p[2] };
                const int *want = kStripes[(x / 3) % 6];
                for (int c = 0; c < 3; c++) {
                    int e = abs(rgb[c] - want[c]);
                    sum += e; n++;
                    if (e > worst) worst = e;
                }
            }
        }
        CFRelease(data);
        CGImageRelease(image);
        printf("mean error %.2f code values per channel, worst %d, over %ld samples\n",
               sum / (double)n, worst, n);
        return 0;
    }
}
