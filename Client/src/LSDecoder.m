#import "LSDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include "rtp_protocol.h"
#include <pthread.h>
#include <mach/mach_time.h>

// These two keys are spelled out rather than referenced by symbol. Their values
// are stable, and writing them literally means the client links against any
// 10.8/10.9 SDK variant without us having to guess which point release first
// exported the constant.
#define LS_KEY_ENABLE_HW_DECODER  CFSTR("EnableHardwareAcceleratedVideoDecoder")
#define LS_KEY_REALTIME           CFSTR("RealTime")

@interface LSAccessUnit : NSObject
@property (nonatomic, strong) NSData *avcc;
@property (nonatomic, strong) NSData *sps;
@property (nonatomic, strong) NSData *pps;
@property (nonatomic, assign) uint32_t timestamp;
@end

@implementation LSAccessUnit
@end


static void lsDecoderOutputCallback(void *decompressionOutputRefCon,
                                    void *sourceFrameRefCon,
                                    OSStatus status,
                                    VTDecodeInfoFlags infoFlags,
                                    CVImageBufferRef imageBuffer,
                                    CMTime presentationTimeStamp,
                                    CMTime presentationDuration);

@interface LSDecoder ()
- (void)emitFrame:(CVImageBufferRef)imageBuffer presentationTime:(CMTime)presentationTime;
@end


@implementation LSDecoder {
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _formatDescription;
    NSData *_activeSPS;
    NSData *_activePPS;

    NSMutableArray *_queue;
    pthread_mutex_t _mutex;
    pthread_cond_t  _cond;
    NSThread *_thread;
    BOOL _running;

    double _decodeMicrosAverage;
    mach_timebase_info_data_t _timebase;
}

- (id)init {
    self = [super init];
    if (self) {
        _queue = [[NSMutableArray alloc] init];
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_cond, NULL);
        mach_timebase_info(&_timebase);
    }
    return self;
}

- (void)dealloc {
    [self stop];
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
}

#pragma mark - lifecycle

- (void)start {
    if (_running) return;
    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(decodeLoop) object:nil];
    [_thread setName:@"com.lanscreen.decode"];
    [_thread setThreadPriority:0.9];
    [_thread start];
}

- (void)stop {
    pthread_mutex_lock(&_mutex);
    _running = NO;
    pthread_cond_broadcast(&_cond);
    pthread_mutex_unlock(&_mutex);

    while (_thread && ![_thread isFinished]) {
        usleep(1000);
    }
    _thread = nil;
    [self teardownSession];
}

- (void)teardownSession {
    if (_session) {
        VTDecompressionSessionWaitForAsynchronousFrames(_session);
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    _activeSPS = nil;
    _activePPS = nil;
}

#pragma mark - submission

- (void)submitAccessUnit:(NSData *)avcc
                     sps:(NSData *)sps
                     pps:(NSData *)pps
               timestamp:(uint32_t)timestamp
{
    LSAccessUnit *unit = [[LSAccessUnit alloc] init];
    unit.avcc = avcc;
    unit.sps = sps;
    unit.pps = pps;
    unit.timestamp = timestamp;

    pthread_mutex_lock(&_mutex);
    // Depth 2. Anything deeper is latency we would have to pay back later.
    while ([_queue count] >= 2) {
        [_queue removeObjectAtIndex:0];
        _framesDropped++;
    }
    [_queue addObject:unit];
    _queueDepth = (uint32_t)[_queue count];
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

#pragma mark - decode thread

- (void)decodeLoop {
    while (YES) {
        LSAccessUnit *unit = nil;

        pthread_mutex_lock(&_mutex);
        while (_running && [_queue count] == 0) {
            pthread_cond_wait(&_cond, &_mutex);
        }
        if (!_running) { pthread_mutex_unlock(&_mutex); break; }
        unit = [_queue objectAtIndex:0];
        [_queue removeObjectAtIndex:0];
        _queueDepth = (uint32_t)[_queue count];
        pthread_mutex_unlock(&_mutex);

        @autoreleasepool {
            [self decodeUnit:unit];
        }
    }
}

- (BOOL)ensureSessionForSPS:(NSData *)sps pps:(NSData *)pps {
    if (_session && _activeSPS && _activePPS &&
        [_activeSPS isEqualToData:sps] && [_activePPS isEqualToData:pps]) {
        return YES;
    }

    [self teardownSession];

    const uint8_t * const parameterSets[2] = {
        (const uint8_t *)[sps bytes],
        (const uint8_t *)[pps bytes]
    };
    const size_t parameterSetSizes[2] = { [sps length], [pps length] };

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, parameterSets, parameterSetSizes, 4, &_formatDescription);
    if (status != noErr) {
        _statusMessage = [NSString stringWithFormat:
            @"Could not build format description from SPS/PPS (%d)", (int)status];
        return NO;
    }

    // Try 2vuy first. The 2010 iMac's hardware decoder emits it natively, and
    // it maps straight onto GL_YCBCR_422_APPLE so the texture unit does the
    // colour conversion for free. BGRA is the fallback for anything that
    // refuses 2vuy; it always works but the decoder has to convert.
    //
    // Override with  -pixelFormat bgra  on the command line, or
    // LS_PIXEL_FORMAT=bgra in the environment, if 2vuy turns out to be slow on
    // a particular machine. Measure before deciding: on some Macs asking for
    // 2vuy triggers a software colour conversion that costs more than it saves.
    OSType formats[2] = { kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_32BGRA };
    int attemptCount = 2;

    NSString *preference = nil;
    const char *fromEnvironment = getenv("LS_PIXEL_FORMAT");
    if (fromEnvironment) {
        preference = [NSString stringWithUTF8String:fromEnvironment];
    } else {
        preference = [[NSUserDefaults standardUserDefaults] stringForKey:@"pixelFormat"];
    }
    if ([[preference lowercaseString] isEqualToString:@"bgra"]) {
        formats[0] = kCVPixelFormatType_32BGRA;
        attemptCount = 1;
    } else if ([[preference lowercaseString] isEqualToString:@"2vuy"]) {
        attemptCount = 1;
    }

    for (int attempt = 0; attempt < attemptCount; attempt++) {
        NSDictionary *destinationAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(formats[attempt]),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (id)kCVPixelBufferOpenGLCompatibilityKey : @YES
        };
        NSDictionary *decoderSpec = @{
            (__bridge id)LS_KEY_ENABLE_HW_DECODER : @YES
        };

        VTDecompressionOutputCallbackRecord callback;
        callback.decompressionOutputCallback = lsDecoderOutputCallback;
        callback.decompressionOutputRefCon = (__bridge void *)self;

        status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                              _formatDescription,
                                              (__bridge CFDictionaryRef)decoderSpec,
                                              (__bridge CFDictionaryRef)destinationAttributes,
                                              &callback,
                                              &_session);
        if (status == noErr && _session) {
            // Best effort. A decoder that rejects the hint still decodes.
            VTSessionSetProperty(_session, LS_KEY_REALTIME, kCFBooleanTrue);
            _activeSPS = [sps copy];
            _activePPS = [pps copy];
            _statusMessage = nil;
            NSLog(@"[LanScreen] decode session up, pixel format %@",
                  [self nameForPixelFormat:formats[attempt]]);
            return YES;
        }
        NSLog(@"[LanScreen] VTDecompressionSessionCreate failed for %@ (%d)",
              [self nameForPixelFormat:formats[attempt]], (int)status);
    }

    _statusMessage = [NSString stringWithFormat:
        @"Could not create a decode session (%d). The stream may use a profile "
        @"this machine cannot decode -- try Baseline on the host.", (int)status];
    if (_formatDescription) { CFRelease(_formatDescription); _formatDescription = NULL; }
    return NO;
}

- (NSString *)nameForPixelFormat:(OSType)format {
    char tag[5] = {0};
    tag[0] = (char)((format >> 24) & 0xFF); tag[1] = (char)((format >> 16) & 0xFF);
    tag[2] = (char)((format >> 8) & 0xFF);  tag[3] = (char)(format & 0xFF);
    return [NSString stringWithUTF8String:tag];
}

- (void)decodeUnit:(LSAccessUnit *)unit {
    if (![self ensureSessionForSPS:unit.sps pps:unit.pps]) return;

    CMBlockBufferRef blockBuffer = NULL;
    // kCFAllocatorNull for the data: the NSData outlives this call because the
    // decode below is synchronous, so there is no reason to copy a megabyte.
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        (void *)[unit.avcc bytes],
        [unit.avcc length],
        kCFAllocatorNull,
        NULL, 0, [unit.avcc length],
        0, &blockBuffer);
    if (status != kCMBlockBufferNoErr) return;

    CMSampleTimingInfo timing;
    timing.duration = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake((int64_t)unit.timestamp, (int32_t)LS_RTP_CLOCK_HZ);
    timing.decodeTimeStamp = kCMTimeInvalid;

    size_t sampleSize = [unit.avcc length];
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true,
                                  NULL, NULL, _formatDescription,
                                  1, 1, &timing, 1, &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    if (status != noErr || !sampleBuffer) return;

    uint64_t begin = mach_absolute_time();

    // Synchronous decode. Asynchronous would let the decoder pipeline frames,
    // which is exactly the latency we are trying not to have.
    VTDecodeInfoFlags infoFlags = 0;
    status = VTDecompressionSessionDecodeFrame(_session, sampleBuffer,
                                               0, NULL, &infoFlags);
    CFRelease(sampleBuffer);

    uint64_t elapsed = mach_absolute_time() - begin;
    double micros = (double)elapsed * (double)_timebase.numer
                  / (double)_timebase.denom / 1000.0;
    _decodeMicrosAverage = (_decodeMicrosAverage == 0.0)
        ? micros : (_decodeMicrosAverage * 0.85 + micros * 0.15);
    _decodeMicroseconds = (uint32_t)_decodeMicrosAverage;
    _decodeMicrosecondsLast = (uint32_t)micros;
    if ((uint32_t)micros > _decodeMicrosecondsPeak) _decodeMicrosecondsPeak = (uint32_t)micros;

    if (status != noErr) {
        NSLog(@"[LanScreen] decode failed (%d)", (int)status);
        // A decoder that has lost its reference state needs a clean restart.
        if (status == kVTInvalidSessionErr) {
            [self teardownSession];
        }
    }
}

- (void)emitFrame:(CVImageBufferRef)imageBuffer presentationTime:(CMTime)presentationTime {
    if (!imageBuffer) return;
    _framesDecoded++;
    _hasDecodedFrame = YES;
    if (self.frameHandler) {
        CVPixelBufferRef retained = (CVPixelBufferRef)CVBufferRetain(imageBuffer);
        self.frameHandler(retained, presentationTime);
    }
}

@end


static void lsDecoderOutputCallback(void *decompressionOutputRefCon,
                                    void *sourceFrameRefCon,
                                    OSStatus status,
                                    VTDecodeInfoFlags infoFlags,
                                    CVImageBufferRef imageBuffer,
                                    CMTime presentationTimeStamp,
                                    CMTime presentationDuration)
{
    if (status != noErr || imageBuffer == NULL) return;
    if (infoFlags & kVTDecodeInfo_FrameDropped) return;
    LSDecoder *decoder = (__bridge LSDecoder *)decompressionOutputRefCon;
    [decoder emitFrame:imageBuffer presentationTime:presentationTimeStamp];
}
