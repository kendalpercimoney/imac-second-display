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

// What the ring buffer costs per second of audio.
//
// The iMac is a 2010 machine doing 1080p H.264 at the same time, so anything
// per-sample matters. This pushes a fixed number of seconds of 48 kHz stereo
// through enqueue and drain in the same sizes the real thing uses -- 256-frame
// packets in, 480-frame audio queue buffers out -- and reports what fraction of
// real time that took.

#import <Foundation/Foundation.h>
#import "LSAudioPlayer.h"
#import <mach/mach_time.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        const int seconds = (argc > 1) ? atoi(argv[1]) : 60;
        const int rate = 48000, channels = 2;
        const int packetFrames = 256;      // what the wire delivers
        const int drainFrames = 480;       // what a 10 ms audio queue buffer wants

        LSAudioPlayer *player = [[LSAudioPlayer alloc] initWithSampleRate:rate
                                                                channels:channels];
        [player setTargetBufferMilliseconds:25];

        int16_t *packet = calloc(packetFrames * channels, sizeof(int16_t));
        int16_t *out = calloc(drainFrames * channels, sizeof(int16_t));
        for (int i = 0; i < packetFrames * channels; i++) packet[i] = (int16_t)(i * 37);

        const long totalFrames = (long)rate * seconds;
        long enqueued = 0, drained = 0;

        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        uint64_t start = mach_absolute_time();

        while (enqueued < totalFrames) {
            [player enqueueSamples:packet frames:packetFrames];
            enqueued += packetFrames;
            // Keep the drain roughly in step with the source, as it is in life.
            while (drained + drainFrames <= enqueued) {
                [player drainInto:out samples:drainFrames * channels];
                drained += drainFrames;
            }
        }

        uint64_t elapsed = mach_absolute_time() - start;
        double nanos = (double)elapsed * timebase.numer / timebase.denom;
        double cpuSeconds = nanos / 1e9;

        printf("%d seconds of 48 kHz stereo through the ring\n", seconds);
        printf("  took %.4f s of CPU\n", cpuSeconds);
        printf("  which is %.4f%% of one core\n", cpuSeconds / seconds * 100.0);
        printf("  %.1f ns per frame\n", nanos / (double)totalFrames);

        free(packet);
        free(out);
        return 0;
    }
}
