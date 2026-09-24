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

import Foundation
import LSProtocol

/// User-tunable knobs. Persisted in UserDefaults so the app comes back the
/// way you left it.
final class StreamSettings: ObservableObject {

    /// Where the pixels come from.
    enum Source: String, CaseIterable, Identifiable {
        /// Create a headless display. This is what makes the iMac a genuine
        /// second monitor rather than a mirror of the MacBook's screen.
        case virtualDisplay = "Virtual display"
        /// Capture a display that already exists -- the built-in screen, or a
        /// real monitor, or a hardware HDMI dummy plug.
        case existingDisplay = "Existing display"
        var id: String { rawValue }
    }

    enum Profile: String, CaseIterable, Identifiable {
        /// Baseline is the safe default: no CABAC, no B-frames, and it is what
        /// the 2010 iMac's hardware decoder is happiest with.
        case baseline = "Baseline"
        /// Slightly better quality per bit, but CABAC costs the old GPU more.
        case main = "Main"
        var id: String { rawValue }
    }

    @Published var clientAddress: String { didSet { save(clientAddress, "clientAddress") } }
    @Published var videoPort: Int       { didSet { save(videoPort, "videoPort") } }
    @Published var controlPort: Int     { didSet { save(controlPort, "controlPort") } }
    @Published var width: Int           { didSet { save(width, "width") } }
    @Published var height: Int          { didSet { save(height, "height") } }
    @Published var frameRate: Int       { didSet { save(frameRate, "frameRate") } }
    @Published var bitrateMbps: Double  { didSet { save(bitrateMbps, "bitrateMbps") } }
    @Published var profile: Profile     { didSet { save(profile.rawValue, "profile") } }
    @Published var mtuPayload: Int      { didSet { save(mtuPayload, "mtuPayload") } }
    @Published var showsCursor: Bool    { didSet { save(showsCursor, "showsCursor") } }
    @Published var displayID: UInt32    { didSet { save(Int(displayID), "displayID") } }
    @Published var source: Source       { didSet { save(source.rawValue, "source") } }
    /// Seconds between unforced IDRs.
    ///
    /// A keyframe is several times the size of an inter frame and far more
    /// expensive for a 2010 GPU to decode. On a nearly-still screen, going from
    /// one every 2 seconds to one every 10 measured as 73% less data and that
    /// many fewer decode spikes.
    ///
    /// The only thing short intervals buy is recovery from packet loss without
    /// the control channel -- and the client asks for a keyframe the moment it
    /// sees a sequence gap, so that path is already covered. 5 seconds keeps a
    /// bounded worst case if the back-channel ever fails. Raise it if the iMac
    /// is struggling; drop it to 2 if the control channel cannot get through.
    @Published var keyframeSeconds: Double { didSet { save(keyframeSeconds, "keyframeSeconds") } }

    /// Send a Wake-on-LAN magic packet when streaming starts, and again when
    /// this Mac wakes from sleep.
    @Published var wakeClientAutomatically: Bool { didSet { save(wakeClientAutomatically, "wakeClientAutomatically") } }
    /// The client's hardware address. Learned from its HELLO, or typed in.
    @Published var clientMACAddress: String { didSet { save(clientMACAddress, "clientMACAddress") } }
    /// Stop streaming when this Mac sleeps, so the iMac releases its
    /// keep-awake assertion and can sleep too.
    @Published var stopOnSleep: Bool { didSet { save(stopOnSleep, "stopOnSleep") } }

    /// Tell macOS this Mac is busy for as long as we are streaming.
    ///
    /// Without it, an app that is not frontmost with no keyboard or trackpad
    /// activity is a candidate for App Nap: lowered quality of service and
    /// coalesced timers. Which is why the picture degrades when you stop
    /// moving the cursor and recovers when you move it again -- moving it
    /// counts as user activity and suppresses the throttling.
    @Published var preventAppNap: Bool { didSet { save(preventAppNap, "preventAppNap") } }

    /// VideoToolbox's low-latency rate controller, plus capturing in 4:2:0 so
    /// the encoder is handed the format it wants. Measured together as the
    /// encoder's hold time dropping from about 16 ms to about 9 ms, with the
    /// p95 roughly halved. Costs about half a decibel of PSNR on hard content,
    /// and forces Constrained Baseline -- a subset of the Baseline the iMac
    /// already decodes.
    @Published var lowLatencyEncoder: Bool { didSet { save(lowLatencyEncoder, "lowLatencyEncoder") } }
    @Published var captureYUV420: Bool { didSet { save(captureYUV420, "captureYUV420") } }

    /// Send the pointer separately and let the client draw it, rather than
    /// letting ScreenCaptureKit burn it into the video. The pointer then lags by
    /// about a screen refresh instead of by the whole encode-send-decode round
    /// trip, at the cost of it running slightly ahead of a window being dragged.
    @Published var forwardCursor: Bool { didSet { save(forwardCursor, "forwardCursor") } }

    /// Send the Mac's system audio to the client, which plays it. Raw PCM, so
    /// it costs 1.5 Mb/s and adds no encode or decode delay of its own.
    @Published var audioEnabled: Bool { didSet { save(audioEnabled, "audioEnabled") } }
    /// Playback volume at the client, 0 to 1. The slider is here; the speakers
    /// are not, so this is sent over the control channel rather than applied to
    /// the samples.
    @Published var audioVolume: Double { didSet { save(audioVolume, "audioVolume") } }
    @Published var audioPort: Int { didSet { save(audioPort, "audioPort") } }
    /// Milliseconds to hold audio at the client before playing it, relative to
    /// its default hold. Negative pulls the sound earlier, which is the
    /// direction that usually matters: audio takes a shorter path than video
    /// but sits in a jitter buffer and an audio queue at the far end.
    @Published var audioDelayMilliseconds: Double {
        didSet { save(audioDelayMilliseconds, "audioDelayMilliseconds") }
    }
    /// The iMac's panel brightness, 0 to 1.
    @Published var clientBrightness: Double {
        didSet { save(clientBrightness, "clientBrightness") }
    }

    private let defaults = UserDefaults.standard
    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: "ls." + key) }

    init() {
        let d = UserDefaults.standard
        func int(_ k: String, _ fallback: Int) -> Int {
            d.object(forKey: "ls." + k) as? Int ?? fallback
        }
        func dbl(_ k: String, _ fallback: Double) -> Double {
            d.object(forKey: "ls." + k) as? Double ?? fallback
        }
        clientAddress   = d.string(forKey: "ls.clientAddress") ?? "10.0.0.2"
        videoPort       = int("videoPort", Int(LS_DEFAULT_VIDEO_PORT))
        controlPort     = int("controlPort", Int(LS_DEFAULT_CONTROL_PORT))
        width           = int("width", 1920)
        height          = int("height", 1080)
        frameRate       = int("frameRate", 60)
        bitrateMbps     = dbl("bitrateMbps", 25)
        profile         = Profile(rawValue: d.string(forKey: "ls.profile") ?? "") ?? .baseline
        mtuPayload      = int("mtuPayload", Int(LS_DEFAULT_MTU_PAYLOAD))
        showsCursor     = d.object(forKey: "ls.showsCursor") as? Bool ?? true
        displayID       = UInt32(int("displayID", 0))
        source          = Source(rawValue: d.string(forKey: "ls.source") ?? "") ?? .virtualDisplay
        keyframeSeconds = dbl("keyframeSeconds", 5.0)
        wakeClientAutomatically = d.object(forKey: "ls.wakeClientAutomatically") as? Bool ?? true
        clientMACAddress = d.string(forKey: "ls.clientMACAddress") ?? ""
        stopOnSleep = d.object(forKey: "ls.stopOnSleep") as? Bool ?? true
        preventAppNap = d.object(forKey: "ls.preventAppNap") as? Bool ?? true
        lowLatencyEncoder = d.object(forKey: "ls.lowLatencyEncoder") as? Bool ?? true
        captureYUV420 = d.object(forKey: "ls.captureYUV420") as? Bool ?? true
        forwardCursor = d.object(forKey: "ls.forwardCursor") as? Bool ?? true
        audioEnabled = d.object(forKey: "ls.audioEnabled") as? Bool ?? false
        audioVolume = d.object(forKey: "ls.audioVolume") as? Double ?? 0.8
        audioPort = int("audioPort", Int(LS_DEFAULT_AUDIO_PORT))
        audioDelayMilliseconds = dbl("audioDelayMilliseconds", 0)
        clientBrightness = dbl("clientBrightness", 1.0)
    }

    var bitrateBitsPerSecond: Int { Int(bitrateMbps * 1_000_000) }

    /// The volume as the wire carries it: thousandths, clamped to unity.
    var audioVolumeThousandths: UInt16 {
        UInt16(max(0, min(1, audioVolume)) * Double(LS_VOLUME_SCALE))
    }

    var audioDelayWireValue: Int16 {
        Int16(max(Double(LS_AUDIO_DELAY_MIN_MS),
                  min(Double(LS_AUDIO_DELAY_MAX_MS), audioDelayMilliseconds.rounded())))
    }

    var clientBrightnessThousandths: UInt16 {
        UInt16(max(0, min(1, clientBrightness)) * Double(LS_BRIGHTNESS_SCALE))
    }
}
