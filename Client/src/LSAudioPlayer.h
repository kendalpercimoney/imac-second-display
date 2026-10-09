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
//  LSAudioPlayer.h
//  Plays the host's system audio through an AudioQueue.
//
//  Between the network and the speaker sits a ring buffer, because packets
//  arrive in bursts and the audio hardware wants a steady trickle. It is kept
//  deliberately shallow: every millisecond of buffering is a millisecond of
//  delay, and the whole point of this project is not having any.
//
#import <Foundation/Foundation.h>

@interface LSAudioPlayer : NSObject

- (id)initWithSampleRate:(uint32_t)sampleRate channels:(uint32_t)channels;

- (BOOL)start:(NSError **)error;
- (void)stop;

/// Interleaved 16-bit samples straight off the wire. Safe to call from the
/// receive thread; never blocks on the audio hardware.
- (void)enqueueSamples:(const int16_t *)samples frames:(uint32_t)frames;

/// How much audio the ring holds back at all times, which is the delay every
/// sample goes through. Zero plays each packet the instant it arrives.
- (void)setTargetBufferMilliseconds:(double)milliseconds;
- (double)targetBufferMilliseconds;

/// What the audio queue holds on top of that, and therefore the floor: audio
/// already given to the hardware cannot be pulled back.
+ (double)hardwareFloorMilliseconds;

/// Takes up to `wanted` samples out of the ring, padding with silence if there
/// are not enough. Called by the audio callback; exposed so the buffering can
/// be tested without audio hardware, which a headless test has none of.
- (void)drainInto:(int16_t *)out samples:(uint32_t)wanted;

/// 0 to 1. Applied by the audio queue, so it costs nothing and does not touch
/// the samples themselves.
@property (nonatomic, assign) float volume;

/// Pauses the audio queue when nothing has arrived for this long, and it
/// resumes on its own when audio returns. An audio queue asks for a buffer a
/// hundred times a second whether or not there is anything to put in it.
- (void)pauseIfIdleFor:(NSTimeInterval)seconds;
@property (nonatomic, readonly) BOOL isPlaying;

@property (nonatomic, readonly) uint32_t framesPlayed;
/// Times the queue asked for audio and there was none: the number that says
/// whether the buffer is deep enough.
@property (nonatomic, readonly) uint32_t underruns;
/// Single frames trimmed to keep the buffer near its target as the two
/// machines' clocks drift apart. These are inaudible; the counter is here so it
/// is obvious that drift is being handled rather than accumulating.
@property (nonatomic, readonly) uint32_t driftTrims;
/// Frames thrown away because the buffer was full, which means the host is
/// running faster than this machine's clock.
@property (nonatomic, readonly) uint32_t overruns;
/// How much audio is waiting, in milliseconds. This is the latency the buffer
/// is costing right now.
@property (nonatomic, readonly) double bufferedMilliseconds;

@end
