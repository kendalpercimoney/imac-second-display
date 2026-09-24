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
// Three buffers of 10 ms. This was briefly 5, to let the delay control go
// further negative, and that is when the sound started popping: a 5 ms buffer
// has to be refilled two hundred times a second by a 2010 machine that is also
// decoding 1080p H.264, and every callback it is late for is a gap. The extra
// 15 ms of floor is worth not hearing.
#define LS_AQ_BUFFERS        3
#define LS_AQ_BUFFER_MS      10
// About a millisecond at 48 kHz. Long enough to remove the step, short enough
// that it is not itself audible as a swell.
#define LS_FADE_FRAMES       48
// How far the buffer may drift past the target before a single frame is
// trimmed. Two machines' 48 kHz clocks differ by tens of parts per million, so
// the buffer creeps one way or the other no matter what; the question is only
// whether the correction is one inaudible frame or an audible lump.
#define LS_DRIFT_SLACK_MS    40
// The most frames one packet may trim: 16 is a third of a millisecond.
#define LS_MAX_TRIM_FRAMES   16
#define LS_RING_MS           400
// The ring holds this much back at all times, which is what makes it a delay
// line rather than just somewhere packets land. Below about 20 ms every network
// hiccup is audible; above it you start hearing the lag against the picture.
#define LS_DEFAULT_TARGET_MS 25

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
    /// How much audio the ring keeps behind at all times. Each sample waits
    /// this long before it is played, so this *is* the delay.
    uint32_t _targetSamples;

    /// The last real sample played on each channel, so a gap can be faded into
    /// rather than stepped into. Jumping straight to zero is a discontinuity,
    /// and a discontinuity is exactly what a click is.
    int16_t  _lastSample[8];
    BOOL     _inSilence;

    /// An audio queue does not idle. It asks for a buffer a hundred times a
    /// second whether or not anything is arriving, and filling those with
    /// silence measured at a few per cent of a core, continuously, for nothing.
    /// So it is paused when the host goes quiet and resumed when audio returns.
    BOOL             _queueRunning;
    NSTimeInterval   _lastArrival;
}

- (id)initWithSampleRate:(uint32_t)sampleRate channels:(uint32_t)channels {
    if (!(self = [super init])) return nil;
    _sampleRate = sampleRate ?: 48000;
    _channels = channels ?: 2;
    _volume = 1.0f;
    pthread_mutex_init(&_lock, NULL);

    _ringSamples = (uint32_t)((uint64_t)_sampleRate * _channels * LS_RING_MS / 1000);
    _ring = (int16_t *)calloc(_ringSamples, sizeof(int16_t));
    [self setTargetBufferMilliseconds:LS_DEFAULT_TARGET_MS];
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
    _queueRunning = YES;
    _lastArrival = [NSDate timeIntervalSinceReferenceDate];
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
    pthread_mutex_unlock(&_lock);
}

#pragma mark - the ring

- (void)enqueueSamples:(const int16_t *)samples frames:(uint32_t)frames {
    if (!samples || frames == 0 || !_ring) return;
    uint32_t count = frames * _channels;

    _lastArrival = [NSDate timeIntervalSinceReferenceDate];
    if (_running && !_queueRunning && _queue) {
        // Audio is back. Safe from the receive thread; AudioQueueStart does not
        // require the thread that created the queue.
        if (AudioQueueStart(_queue, NULL) == noErr) _queueRunning = YES;
    }

    pthread_mutex_lock(&_lock);

    // Clock drift, corrected one frame at a time. The host samples on its clock
    // and this machine plays on its own; they are never exactly equal, so the
    // buffer creeps. Left alone it eventually hits the end of the ring and a
    // whole block gets dropped at once, which is plainly audible. Trimming a
    // single frame when it has crept far enough is not: one frame at 48 kHz is
    // twenty microseconds.
    uint32_t slack = (uint32_t)((uint64_t)_sampleRate * _channels * LS_DRIFT_SLACK_MS / 1000);
    if (_fill > _targetSamples + slack) {
        // How much to take is proportional to how far past the line it is. One
        // frame a packet is ample for clock drift, but recovering from a real
        // excursion -- the audio device stalling for a moment, a burst from the
        // host -- would then take tens of seconds, and all of that time is
        // latency you can hear against the picture. The cap is 16 frames, which
        // is a third of a millisecond: still far too short to be audible as a
        // splice, and it brings a tenth of a second back in a couple of seconds.
        uint32_t excessFrames = (_fill - (_targetSamples + slack)) / _channels;
        // One frame a packet clears clock drift many times over, but on its own
        // it takes a quarter of a minute to walk back a tenth of a second, and
        // every millisecond of that is lag against the picture. So the rate
        // follows the excess: deep excursions come back in a second or two,
        // and the last few frames of drift still go one at a time.
        uint32_t trimFrames = 1 + excessFrames / 128;
        if (trimFrames > LS_MAX_TRIM_FRAMES) trimFrames = LS_MAX_TRIM_FRAMES;
        uint32_t trimSamples = trimFrames * _channels;
        if (trimSamples > _fill) trimSamples = _fill;
        _readIndex = (_readIndex + trimSamples) % _ringSamples;
        _fill -= trimSamples;
        _driftTrims += trimSamples / _channels;
    }

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
    pthread_mutex_unlock(&_lock);
}

/// Fills `out` with up to `wanted` samples, padding with silence. Returns
/// nothing: a short read is silence, not an error.
- (void)drainInto:(int16_t *)out samples:(uint32_t)wanted {
    pthread_mutex_lock(&_lock);
    // Only what is in excess of the target may be played. Holding that much
    // back at all times is what delays every sample by the same amount, and it
    // is also what absorbs a late packet without a gap. A target of zero plays
    // audio the instant it arrives.
    uint32_t playable = (_fill > _targetSamples) ? (_fill - _targetSamples) : 0;
    uint32_t take = playable < wanted ? playable : wanted;
    for (uint32_t i = 0; i < take; i++) {
        out[i] = _ring[_readIndex];
        _readIndex = (_readIndex + 1) % _ringSamples;
    }
    _fill -= take;

    if (take > 0) {
        // Coming back from a gap, ramp up rather than stepping up.
        if (_inSilence) {
            uint32_t fade = LS_FADE_FRAMES * _channels;
            if (fade > take) fade = take;
            for (uint32_t i = 0; i < fade; i++) {
                out[i] = (int16_t)((int32_t)out[i] * (int32_t)i / (int32_t)fade);
            }
            _inSilence = NO;
        }
        for (uint32_t channel = 0; channel < _channels && channel < 8; channel++) {
            _lastSample[channel] = out[take - _channels + channel];
        }
    }

    if (take < wanted) {
        // Ramp down to silence from wherever the signal actually was. A memset
        // here is a step discontinuity, and two of them per gap -- one leaving,
        // one returning -- is what a run of underruns sounds like.
        uint32_t gap = wanted - take;
        uint32_t fade = LS_FADE_FRAMES * _channels;
        if (fade > gap) fade = gap;
        for (uint32_t i = 0; i < fade; i += _channels) {
            for (uint32_t channel = 0; channel < _channels; channel++) {
                int32_t value = (channel < 8) ? _lastSample[channel] : 0;
                out[take + i + channel] =
                    (int16_t)(value * (int32_t)(fade - i) / (int32_t)fade);
            }
        }
        if (gap > fade) memset(out + take + fade, 0, (gap - fade) * sizeof(int16_t));
        _underruns++;
        _inSilence = YES;
    }
    _framesPlayed += take / _channels;
    pthread_mutex_unlock(&_lock);
}

- (void)setTargetBufferMilliseconds:(double)milliseconds {
    if (milliseconds < 0) milliseconds = 0;
    // It has to fit, with room to actually hold audio in front of it.
    double ceiling = (double)LS_RING_MS * 0.75;
    if (milliseconds > ceiling) milliseconds = ceiling;
    uint32_t samples = (uint32_t)(milliseconds / 1000.0 * (double)_sampleRate * (double)_channels);
    pthread_mutex_lock(&_lock);
    _targetSamples = samples;
    pthread_mutex_unlock(&_lock);
}

- (double)targetBufferMilliseconds {
    pthread_mutex_lock(&_lock);
    uint32_t samples = _targetSamples;
    pthread_mutex_unlock(&_lock);
    if (_sampleRate == 0 || _channels == 0) return 0;
    return (double)samples / (double)_channels / (double)_sampleRate * 1000.0;
}

/// What the audio queue itself holds, which is the floor the delay control
/// cannot get under: audio already handed to the hardware cannot be un-handed.
+ (double)hardwareFloorMilliseconds {
    return LS_AQ_BUFFERS * LS_AQ_BUFFER_MS;
}

/// Called once a second by the app. Pauses the queue when the host has gone
/// quiet, which is most of the time on a desktop that is not playing anything.
- (void)pauseIfIdleFor:(NSTimeInterval)seconds {
    if (!_running || !_queueRunning || !_queue) return;
    if ([NSDate timeIntervalSinceReferenceDate] - _lastArrival < seconds) return;

    AudioQueuePause(_queue);
    _queueRunning = NO;
    // Whatever is left is older than the silence that followed it, so playing
    // it when audio resumes would be playing the past.
    pthread_mutex_lock(&_lock);
    _readIndex = _writeIndex = _fill = 0;
    _inSilence = YES;
    memset(_lastSample, 0, sizeof(_lastSample));
    pthread_mutex_unlock(&_lock);
}

- (BOOL)isPlaying { return _queueRunning; }

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
