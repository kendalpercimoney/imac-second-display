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
        if (argc < 2) { fprintf(stderr, "usage: checkpattern <png> [tolerance]\n"); return 2; }
        int tolerance = argc > 2 ? atoi(argv[2]) : 32;

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
