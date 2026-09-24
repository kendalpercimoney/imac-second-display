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

#import "LSAudioPlayer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>

// Three buffers of 10 ms. Fewer and the queue runs dry between callbacks on a
// machine this old; more and you are just adding delay. The ring behind them
// holds 200 ms, which is not a target depth -- it is headroom so a burst is
// absorbed rather than dropped.
#define LS_AQ_BUFFERS        3
#define LS_AQ_BUFFER_MS      10
#define LS_RING_MS           200
// Start playing once this much has arrived. Below about 20 ms every hiccup in
// the network is audible; much above it and you can hear the lag against the
// picture.
#define LS_PRIME_MS          25

@implementation LSAudioPlayer {
    AudioQueueRef       _queue;
    AudioQueueBufferRef _buffers[LS_AQ_BUFFERS];
    AudioStreamBasicDescription _format;

    uint32_t _sampleRate;
    uint32_t _channels;

    // The ring. Guarded by _lock, which is held only for memcpy-length
    // stretches: the receive thread must never wait on the audio thread.
    int16_t        *_ring;
    uint32_t        _ringSamples;      // capacity, in samples not frames
    uint32_t        _readIndex;
    uint32_t        _writeIndex;
    uint32_t        _fill;             // samples currently held
    pthread_mutex_t _lock;

    BOOL     _running;
    BOOL     _primed;
    uint32_t _primeSamples;
}

- (id)initWithSampleRate:(uint32_t)sampleRate channels:(uint32_t)channels {
    if (!(self = [super init])) return nil;
    _sampleRate = sampleRate ?: 48000;
    _channels = channels ?: 2;
    _volume = 1.0f;
    pthread_mutex_init(&_lock, NULL);

    _ringSamples = (uint32_t)((uint64_t)_sampleRate * _channels * LS_RING_MS / 1000);
    _ring = (int16_t *)calloc(_ringSamples, sizeof(int16_t));
    _primeSamples = (uint32_t)((uint64_t)_sampleRate * _channels * LS_PRIME_MS / 1000);
    return self;
}

- (void)dealloc {
    [self stop];
    pthread_mutex_destroy(&_lock);
    free(_ring);
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

#pragma mark - lifecycle

static void LSAudioCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer);

- (BOOL)start:(NSError **)error {
    if (_running) return YES;
    if (!_ring) {
        if (error) *error = [NSError errorWithDomain:@"LanScreen.Audio" code:1 userInfo:
                             @{NSLocalizedDescriptionKey: @"Could not allocate the audio ring."}];
        return NO;
    }

    memset(&_format, 0, sizeof(_format));
    _format.mSampleRate       = _sampleRate;
    _format.mFormatID         = kAudioFormatLinearPCM;
    _format.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    _format.mFramesPerPacket  = 1;
    _format.mChannelsPerFrame = _channels;
    _format.mBitsPerChannel   = 16;
    _format.mBytesPerFrame    = (UInt32)(_channels * sizeof(int16_t));
    _format.mBytesPerPacket   = _format.mBytesPerFrame;

    OSStatus status = AudioQueueNewOutput(&_format, LSAudioCallback,
                                          (__bridge void *)self,
                                          NULL, kCFRunLoopCommonModes, 0, &_queue);
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:@"LanScreen.Audio" code:status userInfo:
                             @{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"AudioQueueNewOutput failed (%d).",
                                (int)status]}];
        return NO;
    }

    AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, _volume);

    UInt32 bytesPerBuffer = (UInt32)((uint64_t)_sampleRate * LS_AQ_BUFFER_MS / 1000)
                          * _format.mBytesPerFrame;
    for (int i = 0; i < LS_AQ_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(_queue, bytesPerBuffer, &_buffers[i]);
        if (status != noErr) {
            if (error) *error = [NSError errorWithDomain:@"LanScreen.Audio" code:status userInfo:
                                 @{NSLocalizedDescriptionKey: @"Could not allocate audio buffers."}];
            AudioQueueDispose(_queue, true);
            _queue = NULL;
            return NO;
        }
        // Prime each buffer with silence and enqueue it, which is what gets the
        // callback cycle turning. Starting a queue with nothing in it just
        // stops it again.
        _buffers[i]->mAudioDataByteSize = bytesPerBuffer;
        memset(_buffers[i]->mAudioData, 0, bytesPerBuffer);
        AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
    }

    _running = YES;
    status = AudioQueueStart(_queue, NULL);
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:@"LanScreen.Audio" code:status userInfo:
                             @{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"AudioQueueStart failed (%d).",
                                (int)status]}];
        _running = NO;
        AudioQueueDispose(_queue, true);
        _queue = NULL;
        return NO;
    }
    NSLog(@"[LanScreen] audio out: %u Hz, %u channels", _sampleRate, _channels);
    return YES;
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_queue) {
        AudioQueueStop(_queue, true);
        AudioQueueDispose(_queue, true);
        _queue = NULL;
    }
    pthread_mutex_lock(&_lock);
    _readIndex = _writeIndex = _fill = 0;
    _primed = NO;
    pthread_mutex_unlock(&_lock);
}

#pragma mark - the ring

- (void)enqueueSamples:(const int16_t *)samples frames:(uint32_t)frames {
    if (!samples || frames == 0 || !_ring) return;
    uint32_t count = frames * _channels;

    pthread_mutex_lock(&_lock);
    uint32_t space = _ringSamples - _fill;
    if (count > space) {
        // The host is producing faster than this machine consumes, or the
        // speaker stalled. Drop the oldest audio rather than the newest: what
        // is arriving now is what the picture on screen is doing now.
        uint32_t excess = count - space;
        _readIndex = (_readIndex + excess) % _ringSamples;
        _fill -= excess;
        _overruns += excess / _channels;
    }
    for (uint32_t i = 0; i < count; i++) {
        _ring[_writeIndex] = samples[i];
        _writeIndex = (_writeIndex + 1) % _ringSamples;
    }
    _fill += count;
    if (!_primed && _fill >= _primeSamples) _primed = YES;
    pthread_mutex_unlock(&_lock);
}

/// Fills `out` with up to `wanted` samples, padding with silence. Returns
/// nothing: a short read is silence, not an error.
- (void)drainInto:(int16_t *)out samples:(uint32_t)wanted {
    pthread_mutex_lock(&_lock);
    uint32_t available = _primed ? _fill : 0;
    uint32_t take = available < wanted ? available : wanted;
    for (uint32_t i = 0; i < take; i++) {
        out[i] = _ring[_readIndex];
        _readIndex = (_readIndex + 1) % _ringSamples;
    }
    _fill -= take;
    if (take < wanted) {
        memset(out + take, 0, (wanted - take) * sizeof(int16_t));
        // Running dry means re-priming, otherwise every subsequent callback
        // stutters against a buffer that never gets a chance to refill.
        if (_primed) { _underruns++; _primed = NO; }
    }
    _framesPlayed += take / _channels;
    pthread_mutex_unlock(&_lock);
}

- (double)bufferedMilliseconds {
    pthread_mutex_lock(&_lock);
    uint32_t fill = _fill;
    pthread_mutex_unlock(&_lock);
    if (_sampleRate == 0 || _channels == 0) return 0;
    return (double)fill / (double)_channels / (double)_sampleRate * 1000.0;
}

- (void)setVolume:(float)volume {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    _volume = volume;
    if (_queue) AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, volume);
}

static void LSAudioCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    LSAudioPlayer *player = (__bridge LSAudioPlayer *)userData;
    uint32_t wanted = buffer->mAudioDataBytesCapacity / sizeof(int16_t);
    [player drainInto:(int16_t *)buffer->mAudioData samples:wanted];
    buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

@end
