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

/// Everything the pipeline is about to be configured with, derived from the
/// settings in exactly one place.
///
/// This exists because two of the controls in the window turned out to do
/// nothing: the Profile picker, which the low-latency rate controller silently
/// overrides with Constrained Baseline, and Include mouse cursor, which is
/// ignored whenever the pointer is being sent separately. Both were being
/// overridden deep inside the pipeline where nothing could see it, and the UI
/// went on presenting them as live controls.
///
/// So the overriding happens here instead, it is recorded in `overrides` as it
/// happens, and the UI greys out a control it knows is not being honoured. A
/// test walks every setting, flips it, and requires that it either changes the
/// plan or is named in `overrides` — a control may be ignored, but not silently.
struct StreamPlan: Equatable {

    enum Profile: String, Equatable {
        case constrainedBaseline = "Constrained Baseline"
        case baseline = "Baseline"
        case main = "Main"
    }

    /// A control the plan did not honour, and why.
    struct Override: Equatable {
        var control: String
        var reason: String
    }

    // capture
    var width: Int
    var height: Int
    var frameRate: Int
    var capturesCursor: Bool
    var capturesYUV420: Bool

    // encode
    var bitrateBitsPerSecond: Int
    var profile: Profile
    var keyframeSeconds: Double
    var lowLatencyRateControl: Bool

    // send
    var mtuPayload: Int
    var videoPort: Int
    var controlPort: Int
    var clientAddress: String

    // pointer
    var forwardsCursorSeparately: Bool

    // audio
    var sendsAudio: Bool
    var audioPort: Int
    var audioVolumeThousandths: UInt16

    // power
    var wakesClient: Bool
    var holdsFullPerformance: Bool
    var stopsOnSleep: Bool

    /// Controls that have no effect in this configuration, whatever they are
    /// set to. The UI greys these out — a control that cannot do anything
    /// should not look like it can.
    var inert: [Override] = []
    /// The subset of `inert` where the setting's current value differs from
    /// what is actually being used, so something was really lost. These are
    /// worth a warning; the rest are not.
    var overrides: [Override] = []

    /// - Parameters:
    ///   - linkMTU: what the interface that routes to the client says it can
    ///     carry, or nil if it could not be determined.
    ///   - clientPlaysAudio: nil until a client has said hello. Audio is only
    ///     sent to a client that says it can play it — otherwise it is 1.5 Mb/s
    ///     into a socket nothing is listening to.
    init(settings: StreamSettings, linkMTU: Int? = nil, clientPlaysAudio: Bool? = nil) {
        width = settings.width
        height = settings.height
        frameRate = settings.frameRate
        capturesYUV420 = settings.captureYUV420
        bitrateBitsPerSecond = settings.bitrateBitsPerSecond
        keyframeSeconds = settings.keyframeSeconds
        lowLatencyRateControl = settings.lowLatencyEncoder
        videoPort = settings.videoPort
        controlPort = settings.controlPort
        clientAddress = settings.clientAddress
        forwardsCursorSeparately = settings.forwardCursor
        wakesClient = settings.wakeClientAutomatically
        holdsFullPerformance = settings.preventAppNap
        stopsOnSleep = settings.stopOnSleep

        audioPort = settings.audioPort
        audioVolumeThousandths = settings.audioVolumeThousandths
        if settings.audioEnabled, clientPlaysAudio == false {
            sendsAudio = false
            inert.append(Override(control: "Send audio",
                                  reason: "this client cannot play it"))
            overrides.append(Override(control: "Send audio",
                                      reason: "this client cannot play it"))
        } else {
            sendsAudio = settings.audioEnabled
        }
        if !sendsAudio {
            inert.append(Override(control: "Volume", reason: "audio is off"))
        }

        // The pointer must not be in the video as well as being sent beside it,
        // or there are two of them, one lagging the other.
        if settings.forwardCursor {
            capturesCursor = false
            let note = Override(
                control: "Include mouse cursor",
                reason: "the pointer is sent separately")
            inert.append(note)
            if settings.showsCursor { overrides.append(note) }
        } else {
            capturesCursor = settings.showsCursor
        }

        // VideoToolbox's low-latency rate controller only offers Constrained
        // Baseline. Asking for Main alongside it does not fail, it is just not
        // what you get.
        if settings.lowLatencyEncoder {
            profile = .constrainedBaseline
            let note = Override(
                control: "Profile",
                reason: "low latency forces Constrained Baseline")
            inert.append(note)
            if settings.profile == .main { overrides.append(note) }
        } else {
            profile = settings.profile == .baseline ? .baseline : .main
        }

        // A payload the link cannot carry is split into IP fragments, and one
        // lost fragment destroys the whole packet.
        mtuPayload = lsEffectiveMTUPayload(requested: settings.mtuPayload,
                                           linkMTU: linkMTU,
                                           headerSize: Int(LS_RTP_HEADER_SIZE))
        if mtuPayload != settings.mtuPayload, let mtu = linkMTU {
            let note = Override(
                control: "Packet size",
                reason: "the link MTU is \(mtu)")
            inert.append(note)
            overrides.append(note)
        }
    }

    /// Whether a named control has any effect right now, for greying it out.
    func inertFor(_ control: String) -> Override? {
        inert.first { $0.control == control }
    }

    /// Whether a named control's value was actually contradicted, for warning.
    func overrideFor(_ control: String) -> Override? {
        overrides.first { $0.control == control }
    }
}
