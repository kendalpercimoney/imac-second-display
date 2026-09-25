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
import os
import CoreMedia
import CoreVideo
import LSProtocol
import LSVirtualDisplay
import AppKit

/// Wires capture -> encode -> packetize -> socket together, and owns the policy
/// that keeps the stream alive: idle heartbeat, keyframe on demand, stats.
///
/// Deliberately not a @MainActor type. Frames arrive on ScreenCaptureKit's
/// queue, encoded output arrives on a VideoToolbox thread, and control messages
/// arrive on a POSIX receive thread; pinning all of that to the main actor
/// would add hops exactly where we are trying to remove them. Instead the
/// pipeline lives on `encodeQueue` and only @Published updates hop to main.
final class StreamController: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var lastError: String?
    @Published private(set) var warnings: [String] = []

    @Published private(set) var outgoingMbps: Double = 0
    /// Packets this Mac could not hand to the network at all. Distinct from
    /// the client's `packets_lost`, which counts packets that were sent and
    /// did not arrive; these never left.
    @Published private(set) var packetsNotSent: UInt64 = 0
    @Published private(set) var encodedFPS: Double = 0
    @Published private(set) var encodeMilliseconds: Double = 0
    /// Capture timestamp to bytes-on-the-wire. This is the whole host-side
    /// contribution to glass-to-glass latency.
    @Published private(set) var hostPipelineMilliseconds: Double = 0
    @Published private(set) var client = ControlChannel.ClientState()
    @Published private(set) var keyframeRequests: Int = 0
    @Published private(set) var sdpPath: String?
    /// What the outgoing interface says it can carry, and what we settled on
    /// sending. Both 0 until a stream has started.
    @Published private(set) var linkMTUBytes: Int = 0
    @Published private(set) var effectiveMTUPayload: Int = 0
    /// The interface that routes to the client, for naming it in the panel's
    /// instruction for raising the MTU.
    @Published private(set) var linkInterfaceName: String = ""
    /// What the running stream was actually configured with, including any
    /// control whose value was not honoured. Nil until a stream has started.
    @Published private(set) var plan: StreamPlan?
    @Published private(set) var activeSourceDescription: String = ""
    @Published private(set) var wakeStatus: String = ""
    @Published private(set) var fullPerformanceHeld = false
    @Published var displays: [DisplayInfo] = []

    var virtualDisplaySupported: Bool { LSVirtualDisplay.isSupported() }

    private let settings: StreamSettings

    // Owned by encodeQueue once running.
    private var capture: CaptureEngine?
    private var encoder: VideoEncoder?
    private var packetizer: RTPPacketizer?
    private var sender: UDPSender?
    private var control: ControlChannel?
    /// Held for as long as we stream: releasing it removes the display.
    private var virtualDisplay: LSVirtualDisplay?
    private var cursorTracker: CursorTracker?
    private var audioSender: AudioSender?
    /// Resent periodically, because a lost volume message would otherwise leave
    /// the iMac at whatever it was last told until something else changed it.
    private var volumeTimer: DispatchSourceTimer?

    private let encodeQueue = DispatchQueue(label: "com.lanscreen.encode", qos: .userInteractive)

    private var idleTimer: DispatchSourceTimer?
    private var statsTimer: Timer?
    private var wakeRetryTimer: DispatchSourceTimer?
    private var activityToken: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []

    /// The most recent captured frame, retained rather than copied, so an
    /// on-demand keyframe always re-encodes what is actually on screen.
    private var lastCapturedBuffer: CVPixelBuffer?
    private var lastEncodeSubmitTime: TimeInterval = 0
    /// What the outgoing interface reported when the stream started, kept so a
    /// plan can be rebuilt mid-stream without asking the socket again.
    private var startedWithLinkMTU: Int?
    private var forceKeyframeFlag = false
    private var sdpWritten = false
    /// Whether the stream we stopped was stopped because this Mac slept, and so
    /// is owed back on wake.
    private var stoppedBySleep = false
    /// When the current stream started, so the log lines carry an elapsed time
    /// rather than only a wall clock.
    private var startedAt: Date?

    // Stats counters, touched from several threads behind statsLock.
    private let statsLock = NSLock()
    private var framesThisPeriod = 0
    private var encodeMillisThisPeriod: Double = 0
    private var pipelineMillisThisPeriod: Double = 0
    private var pipelineSamplesThisPeriod = 0
    private var bytesAtPeriodStart: UInt64 = 0

    init(settings: StreamSettings) {
        self.settings = settings
        installSleepWakeObservers()
    }

    deinit {
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - App Nap

    /// Declares the process busy so macOS leaves it alone while streaming.
    ///
    /// `.latencyCritical` is the part that matters most here: it turns off
    /// timer coalescing, which the OS otherwise applies to an idle system and
    /// which shows up as an uneven frame rate. `.userInitiated` keeps the
    /// system from idle-sleeping mid-stream and opts out of App Nap.
    private func beginFullPerformance() {
        guard settings.preventAppNap, activityToken == nil else { return }

        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical]
        if settings.source == .existingDisplay {
            // A display that has gone to sleep stops producing frames to
            // capture. A virtual display has no such problem, so we only pay
            // the power cost of a lit screen when capturing a real one.
            options.insert(.idleDisplaySleepDisabled)
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: options, reason: "Streaming this screen to another Mac")
        onMain { self.fullPerformanceHeld = true }
    }

    private func endFullPerformance() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
        onMain { self.fullPerformanceHeld = false }
    }

    // MARK: - sleep and wake

    /// The iMac should follow this Mac: wake with it, and be allowed to sleep
    /// when it sleeps.
    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.settings.wakeClientAutomatically {
                // The Ethernet link has to renegotiate after wake, which takes
                // a moment; a packet sent immediately goes nowhere. Retrying
                // for a while covers both that and an iMac that is slow to
                // come up.
                self.wakeClient(reason: "this Mac woke")
                self.startWakeRetries()
            }
            self.resumeAfterWakeIfNeeded()
        })

        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.stopOnSleep, self.isRunning else { return }
            // Stopping sends BYE, which makes the client drop its keep-awake
            // assertion so the iMac can sleep too instead of sitting lit up all
            // night showing a frozen frame.
            //
            // Remembered, because a stream this app stopped by itself is one it
            // owes the user back. Without this the iMac simply stayed dark
            // after every lid close, which is indistinguishable from a freeze:
            // the screen you are looking at stops updating and nothing says
            // why.
            self.stop(becauseOfSleep: true)
        })
    }

    /// Put the stream back after the Mac wakes, if sleep is what took it away.
    ///
    /// Not immediately. The Ethernet link renegotiates, the window server
    /// republishes displays, and `SCShareableContent` returns an empty list for
    /// a second or two after wake -- which is the "No capturable display found"
    /// that greeted every wake. `startStreaming` retries that lookup, and this
    /// gives the machine a moment before the first attempt regardless.
    private func resumeAfterWakeIfNeeded() {
        guard stoppedBySleep else { return }
        onMain { self.statusText = "Resuming after wake…" }
        scheduleWakeResume(after: 2.0, attemptsLeft: 12)
    }

    /// The flag is cleared when the stream is actually handed back, not when
    /// the wake notification arrives.
    ///
    /// `stop()` tears down inside a Task, so `isRunning` is still true for a
    /// moment afterwards. A wake that arrives promptly -- closing and opening
    /// the lid, which is the common case -- would otherwise find the old stream
    /// still shutting down, conclude there was nothing to resume, and leave the
    /// iMac dark with the flag already cleared.
    private func scheduleWakeResume(after delay: TimeInterval, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.stoppedBySleep else { return }
            guard !self.isRunning else {
                guard attemptsLeft > 0 else {
                    self.stoppedBySleep = false
                    return
                }
                self.scheduleWakeResume(after: 0.5, attemptsLeft: attemptsLeft - 1)
                return
            }
            self.stoppedBySleep = false
            self.start()
        }
    }

    /// Sends a magic packet, if we know where to send it.
    @discardableResult
    func wakeClient(reason: String) -> Bool {
        let mac = settings.clientMACAddress.trimmingCharacters(in: .whitespaces)
        guard !mac.isEmpty else {
            onMain { self.wakeStatus = "No MAC address for the client yet, so it cannot be woken." }
            return false
        }
        let result = WakeOnLAN.wake(macAddress: mac, clientAddress: settings.clientAddress)
        onMain { self.wakeStatus = "\(reason): \(result.summary)" }
        return result.error == nil
    }

    /// Keeps knocking until the client says hello, or we give up.
    private func startWakeRetries() {
        wakeRetryTimer?.cancel()
        guard settings.wakeClientAutomatically,
              !settings.clientMACAddress.isEmpty else { return }

        var attemptsLeft = 10          // 10 tries, 3s apart, ~30 seconds
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Stop as soon as the client is talking to us again.
            let seen = self.client.lastSeen.map { Date().timeIntervalSince($0) < 5 } ?? false
            attemptsLeft -= 1
            if seen || attemptsLeft <= 0 {
                self.wakeRetryTimer?.cancel()
                self.wakeRetryTimer = nil
                if seen { self.onMain { self.wakeStatus = "Client is awake and connected." } }
                return
            }
            _ = self.wakeClient(reason: "Waking the client (\(attemptsLeft) tries left)")
        }
        timer.resume()
        wakeRetryTimer = timer
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - lifecycle

    @MainActor
    func refreshDisplays() async {
        do {
            let list = try await CaptureEngine.availableDisplays()
            displays = list
            if settings.displayID == 0 || !list.contains(where: { $0.id == settings.displayID }) {
                if let first = list.first { settings.displayID = first.id }
            }
        } catch {
            lastError = "Could not list displays: \(error.localizedDescription)\n" +
                        "Grant Screen Recording in System Settings ▸ Privacy & Security, then relaunch."
        }
    }

    func start() {
        guard !isRunning else { return }
        onMain {
            self.lastError = nil
            self.warnings = []
            self.keyframeRequests = 0
            self.statusText = "Starting…"
        }
        sdpWritten = false

        // Knock before we start: if the iMac is asleep there is no point
        // streaming into the void.
        if settings.wakeClientAutomatically && !settings.clientMACAddress.isEmpty {
            wakeClient(reason: "Starting")
            startWakeRetries()
        }

        Task {
            do {
                try await startPipeline()
                onMain {
                    self.startedAt = Date()
                    self.isRunning = true
                    self.statusText = "Streaming to \(self.settings.clientAddress):\(self.settings.videoPort)"
                    if StreamController.logsProgress {
                        StreamController.statsLog.notice(
                            "stream started \(self.settings.width, privacy: .public)x\(self.settings.height, privacy: .public) @ \(self.settings.frameRate, privacy: .public), \(self.activeBitrateMbps, format: .fixed(precision: 0), privacy: .public) Mb/s")
                    }
                }
            } catch {
                await teardown()
                onMain {
                    StreamController.statsLog.error(
                        "stream failed to start: \(error.localizedDescription, privacy: .public)")
                    self.lastError = error.localizedDescription
                    self.statusText = "Failed"
                    self.isRunning = false
                }
            }
        }
    }

    /// A stop the user asked for. Anything the app stops by itself says so,
    /// because only one of the two is owed back afterwards.
    func stop() { stop(becauseOfSleep: false) }

    private func stop(becauseOfSleep: Bool) {
        guard isRunning else { return }
        stoppedBySleep = becauseOfSleep
        onMain { self.statusText = "Stopping…" }
        Task {
            await teardown()
            onMain {
                if StreamController.logsProgress {
                    StreamController.statsLog.notice(
                        "stream stopped after \(Int(Date().timeIntervalSince(self.startedAt ?? Date())), privacy: .public)s")
                }
                self.startedAt = nil
                self.isRunning = false
                self.statusText = "Idle"
                self.outgoingMbps = 0
                self.encodedFPS = 0
                self.client = ControlChannel.ClientState()
            }
        }
    }

    func requestKeyframeNow() {
        encodeQueue.async { self.forceKeyframeFlag = true }
    }

    private func startPipeline() async throws {
        // Decide what we are capturing before anything else: a virtual display
        // has to exist and be published to the window server before
        // ScreenCaptureKit will enumerate it.
        let captureDisplayID = try await resolveCaptureDisplay()
        beginFullPerformance()

        let sender = try UDPSender(host: settings.clientAddress,
                                   port: UInt16(settings.videoPort))

        // Jumbo frames are a setting here but a property of the cable, the
        // adapter and both machines, and a manually raised MTU does not outlive
        // a reboot. So a setting that was right yesterday can be wrong today
        // with nothing to show for it but a stream that slowly falls apart.
        // Check rather than assume, and carry on with what the link can take.
        let requestedPayload = settings.mtuPayload
        let linkMTU = sender.linkMTU
        let plan = StreamPlan(settings: settings, linkMTU: linkMTU,
                              clientPlaysAudio: client.hasSaidHello ? client.playsAudio : nil,
                              clientSetsBrightness: client.hasSaidHello
                                  ? client.setsBrightness : nil)
        let effectivePayload = plan.mtuPayload
        var pathWarnings: [String] = []
        if let mtu = linkMTU, effectivePayload != requestedPayload {
            pathWarnings.append(
                "Packet size \(requestedPayload) B needs MTU "
                + "\(requestedPayload + lsIPv4UDPOverhead); the link is \(mtu). "
                + "Using \(effectivePayload) B.")
        }
        startedWithLinkMTU = linkMTU
        onMain {
            self.plan = plan
            self.linkMTUBytes = linkMTU ?? 0
            self.effectiveMTUPayload = effectivePayload
            self.linkInterfaceName = sender.linkInterfaceName ?? ""
            // Published here rather than with the encoder's warnings at the end
            // of this function: if anything between the two throws, this is
            // exactly the warning you still want to have seen.
            self.warnings = pathWarnings
        }
        if let mtu = linkMTU, StreamController.logsProgress {
            StreamController.statsLog.notice(
                "link mtu=\(mtu, privacy: .public) requested payload=\(requestedPayload, privacy: .public) using=\(effectivePayload, privacy: .public)")
        }

        let packetizer = RTPPacketizer(sender: sender, mtuPayload: effectivePayload)

        let control = ControlChannel()
        control.onKeyframeRequested = { [weak self] in
            guard let self else { return }
            self.encodeQueue.async { self.forceKeyframeFlag = true }
            self.onMain { self.keyframeRequests += 1 }
        }
        control.onClientMAC = { [weak self] mac in
            guard let self else { return }
            self.onMain {
                if self.settings.clientMACAddress.caseInsensitiveCompare(mac) != .orderedSame {
                    self.settings.clientMACAddress = mac
                    self.wakeStatus = "Learned the client's MAC address: \(mac)"
                }
            }
        }
        control.onClientHello = { [weak self] in
            guard let self else { return }
            // A client that just appeared has no SPS/PPS yet, so resend the
            // parameter sets and make the next IDR happen right now.
            self.encodeQueue.async {
                self.packetizer?.invalidateParameterSetCache()
                self.forceKeyframeFlag = true
            }
        }
        control.onStateChanged = { [weak self] state in
            self?.onMain { self?.client = state }
        }
        try control.start(port: UInt16(settings.controlPort))

        let encoder = makeEncoder(for: plan)
        try encoder.start()
        let encoderWarnings = encoder.warnings

        let capture = CaptureEngine()
        capture.onFrame = { [weak self] pixelBuffer, time in
            self?.handleCapturedFrame(pixelBuffer, time)
        }
        capture.onStreamStopped = { [weak self] error in
            guard let self else { return }
            self.onMain { self.lastError = "Capture stopped: \(error.localizedDescription)" }
            self.stop()
        }

        encodeQueue.sync {
            self.sender = sender
            self.packetizer = packetizer
            self.control = control
            self.encoder = encoder
            self.capture = capture
            self.lastEncodeSubmitTime = CFAbsoluteTimeGetCurrent()
        }

        if plan.sendsAudio {
            let audio = try AudioSender(host: settings.clientAddress,
                                        port: UInt16(plan.audioPort))
            audioSender = audio
            capture.onAudio = { [weak audio] samples, frames, channels in
                audio?.send(samples, frames: frames, channels: channels)
            }
        }

        try await capture.start(displayID: captureDisplayID,
                                width: plan.width,
                                height: plan.height,
                                frameRate: plan.frameRate,
                                showsCursor: plan.capturesCursor,
                                useYUV420: plan.capturesYUV420,
                                capturesAudio: plan.sendsAudio)

        startClientSettingsUpdates(control: control)

        // The pointer is drawn by the client, so it must not also be in the
        // video -- otherwise there are two of them, one lagging the other.
        if settings.forwardCursor {
            let tracker = CursorTracker()
            var positionBuffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
            var imageBuffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_PACKET))

            tracker.onPosition = { [weak control] x, y, visible, imageID in
                let n = ls_ctrl_build_cursor(&positionBuffer, positionBuffer.count,
                                             x, y, visible ? 1 : 0, imageID)
                if n > 0 { control?.send(positionBuffer, count: Int(n)) }
            }
            tracker.onImage = { [weak control] imageID, width, height, hotX, hotY, pixels in
                let n = pixels.withUnsafeBytes { raw -> size_t in
                    guard let base = raw.baseAddress else { return 0 }
                    return ls_ctrl_build_cursor_image(
                        &imageBuffer, imageBuffer.count, imageID,
                        UInt16(width), UInt16(height), UInt16(hotX), UInt16(hotY),
                        base.assumingMemoryBound(to: UInt8.self), UInt32(raw.count))
                }
                if n > 0 { control?.send(imageBuffer, count: Int(n)) }
            }
            tracker.start(displayID: captureDisplayID,
                          streamWidth: settings.width, streamHeight: settings.height)
            cursorTracker = tracker
        }

        onMain { self.warnings = pathWarnings + encoderWarnings }
        startIdleHeartbeat()
        await MainActor.run { self.startStatsTimer() }
    }

    /// One place the encoder is built, so the mode switch can rebuild it
    /// identically to the way the stream started it.
    private func makeEncoder(for plan: StreamPlan) -> VideoEncoder {
        let config = VideoEncoder.Configuration(
            width: plan.width,
            height: plan.height,
            frameRate: plan.frameRate,
            bitrate: plan.bitrateBitsPerSecond,
            profileIsBaseline: plan.profile != .main,
            keyframeInterval: plan.keyframeSeconds)
        return VideoEncoder(config: config) { [weak self] sampleBuffer in
            // VideoToolbox serializes output callbacks per session, so the
            // packetizer is only ever entered by one thread at a time.
            guard let self, let packetizer = self.packetizer else { return }
            packetizer.packetize(sampleBuffer: sampleBuffer)

            // Measured against the same clock the frame was stamped with, so
            // this is capture-to-wire for real, not an estimate.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let age = CMTimeGetSeconds(CMTimeSubtract(now, pts)) * 1000.0

            self.statsLock.lock()
            self.framesThisPeriod += 1
            if age >= 0 && age < 1000 {   // ignore anything absurd
                self.pipelineMillisThisPeriod += age
                self.pipelineSamplesThisPeriod += 1
            }
            self.statsLock.unlock()
            self.maybeWriteSDP()
        }
    }

    /// Returns the CGDirectDisplayID to capture, creating a virtual display
    /// first if that is the selected source.
    @MainActor
    private func resolveCaptureDisplay() async throws -> UInt32 {
        guard settings.source == .virtualDisplay else {
            virtualDisplay = nil
            let label = displays.first(where: { $0.id == settings.displayID })?.label
                     ?? "display \(settings.displayID)"
            activeSourceDescription = "Capturing \(label)"
            return settings.displayID
        }

        // Swift imports the ObjC `error:` initialiser as a throwing one, so a
        // failure here surfaces with LSVirtualDisplay's own message.
        let display = try LSVirtualDisplay(width: UInt(settings.width),
                                           height: UInt(settings.height),
                                           refreshRate: Double(settings.frameRate),
                                           name: "LanScreen")
        virtualDisplay = display
        activeSourceDescription =
            "Virtual display \(display.displayID) — \(display.width)×\(display.height)"

        // The window server needs a moment to publish the new display before
        // SCShareableContent will list it.
        try? await Task.sleep(nanoseconds: 500_000_000)
        display.refreshModeGeometry()
        activeSourceDescription =
            "Virtual display \(display.displayID) — \(display.modePointsWide)×\(display.modePointsHigh)"
            + (display.modePixelsWide != display.modePointsWide
               ? " (\(display.modePixelsWide)×\(display.modePixelsHigh) pixels)" : "")
        return display.displayID
    }

    private func teardown() async {
        endFullPerformance()
        cursorTracker?.stop(); cursorTracker = nil
        volumeTimer?.cancel(); volumeTimer = nil
        audioSender?.flush(); audioSender = nil
        idleTimer?.cancel(); idleTimer = nil
        wakeRetryTimer?.cancel(); wakeRetryTimer = nil
        await MainActor.run { self.statsTimer?.invalidate(); self.statsTimer = nil }

        let captureRef = encodeQueue.sync { self.capture }
        await captureRef?.stop()

        let controlRef = encodeQueue.sync { self.control }
        controlRef?.stop()

        encodeQueue.sync {
            // stop() runs CompleteFrames + Invalidate, which guarantees no
            // further output callbacks, so it is safe to drop the packetizer
            // immediately afterwards.
            self.encoder?.stop()
            self.encoder = nil
            self.packetizer = nil
            self.sender = nil
            self.control = nil
            self.capture = nil
            self.lastCapturedBuffer = nil
        }

        // Last, so the display does not vanish out from under a capture that
        // is still shutting down.
        await MainActor.run {
            self.virtualDisplay = nil
            self.activeSourceDescription = ""
        }
    }

    // MARK: - frame path

    private func handleCapturedFrame(_ pixelBuffer: CVPixelBuffer, _ time: CMTime) {
        encodeQueue.async {
            guard let encoder = self.encoder else { return }

            let force = self.forceKeyframeFlag
            self.forceKeyframeFlag = false

            let start = CFAbsoluteTimeGetCurrent()
            encoder.encode(pixelBuffer: pixelBuffer, presentationTime: time, forceKeyframe: force)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

            self.lastEncodeSubmitTime = CFAbsoluteTimeGetCurrent()
            self.statsLock.lock()
            self.encodeMillisThisPeriod += elapsed
            self.statsLock.unlock()

            // Retain, do not copy. The previous version memcpy'd the whole
            // frame four times a second in case the screen went quiet -- 33 MB/s
            // at 1080p -- and could still hand the heartbeat a frame up to a
            // quarter second out of date, which showed up as the iMac reverting
            // to a stale picture. Holding a reference is free and always current.
            self.lastCapturedBuffer = pixelBuffer
        }
    }

    /// Re-encodes the last captured frame when someone asks for a keyframe and
    /// no new frames are arriving.
    ///
    /// This used to fire once a second unconditionally, on the theory that a
    /// late-joining client needs a picture even if the screen is static. It
    /// does -- but a client that joins says HELLO, and a client that loses a
    /// packet asks for a keyframe, and both already set the flag below. The
    /// unconditional version was measured at 491 KB per frame on a static
    /// 1080p desktop: 4 Mb/s of bandwidth and a full IDR decode on the 2010
    /// GPU every second, to show a screen that had not changed.
    ///
    /// So an idle screen now costs nothing on the video channel. The client
    /// tells the host is still alive from the control channel's ping instead.
    ///
    /// The timer ticks four times a second rather than once: it does nothing
    /// unless a keyframe was asked for, and when one is asked for, waiting up
    /// to a second to answer was the slowest part of recovering from a lost
    /// packet on an otherwise still screen.
    /// Sends everything the client is told rather than asked -- volume, audio
    /// delay, screen brightness -- now and every two seconds after. The control
    /// channel is UDP, so a single message can go missing; repeating costs
    /// nothing and means the iMac is never left at a setting nobody chose.
    private func startClientSettingsUpdates(control: ControlChannel) {
        volumeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self, weak control] in
            guard let self, let control else { return }
            self.pushClientSettings(control)
        }
        timer.resume()
        volumeTimer = timer
    }

    private func pushClientSettings(_ control: ControlChannel) {
        var buffer = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
        if sendsAudioNow {
            var n = ls_ctrl_build_volume(&buffer, buffer.count,
                                         settings.audioVolumeThousandths)
            if n > 0 { control.send(buffer, count: Int(n)) }
            n = ls_ctrl_build_audio_delay(&buffer, buffer.count, settings.audioDelayWireValue)
            if n > 0 { control.send(buffer, count: Int(n)) }
        }
        let n = ls_ctrl_build_brightness(&buffer, buffer.count,
                                         settings.clientBrightnessThousandths)
        if n > 0 { control.send(buffer, count: Int(n)) }
    }

    /// Whether audio is actually going out, so the audio-only messages are not
    /// sent to a client that is not playing any.
    private var sendsAudioNow: Bool { audioSender != nil }

    /// Pushes a change straight out rather than waiting for the next repeat, so
    /// dragging a slider is heard, or seen, as you drag it.
    func sendClientSettingsNow() {
        guard isRunning else { return }
        encodeQueue.async { [weak self] in
            guard let self, let control = self.control else { return }
            self.pushClientSettings(control)
        }
    }

    /// Kept for the volume slider's own call site.
    func sendVolumeNow() { sendClientSettingsNow() }

    /// Retune the running encoder for the current mode.
    ///
    /// This replaces the compression session rather than setting a property on
    /// it, because setting the property does not work. `AverageBitRate` on a
    /// live session returns `noErr` and changes nothing: asked to go from 25 to
    /// 60 Mb/s mid-stream on content that wanted every bit of it, the encoder
    /// carried on emitting 24.6, 24.8, 24.6, 30.1, 23.9 Mb/s. That is what
    /// "Video mode does not change the stats" was. A fresh session at 60 Mb/s
    /// delivers 60.3.
    ///
    /// Rebuilding costs a keyframe and a few tens of milliseconds. The SPS may
    /// change with it, so the parameter set cache is dropped and the next frame
    /// forced to an IDR -- the client rebuilds its decode session when the SPS
    /// changes, which it already does for a client that reconnects.
    ///
    /// The plan is rebuilt rather than patched, so the mode goes through the
    /// same one place every other setting does and the UI's greying stays
    /// truthful.
    func applyEncoderModeNow() {
        guard isRunning else { return }
        let rebuilt = StreamPlan(settings: settings,
                                 linkMTU: startedWithLinkMTU,
                                 clientPlaysAudio: client.hasSaidHello ? client.playsAudio : nil,
                                 clientSetsBrightness: client.hasSaidHello
                                     ? client.setsBrightness : nil)
        onMain { self.plan = rebuilt }
        encodeQueue.async { [weak self] in
            guard let self, let outgoing = self.encoder else { return }

            // The old session is stopped before the new one starts, and the
            // order matters. VideoToolbox serialises output callbacks within a
            // session but not between two of them, and both would be calling
            // the same packetizer, which owns one packet buffer. Overlapping
            // them for even a few milliseconds would interleave two frames'
            // bytes into the same datagram. `stop()` runs CompleteFrames and
            // Invalidate, so when it returns no further callbacks can arrive.
            outgoing.stop()
            self.encoder = nil

            let replacement = self.makeEncoder(for: rebuilt)
            do {
                try replacement.start()
            } catch {
                // There is no encoder left to fall back to, so say so plainly
                // rather than leaving a stream that is running and silent.
                self.onMain {
                    self.lastError = "Could not switch mode: \(error.localizedDescription)"
                    self.stop()
                }
                return
            }
            self.encoder = replacement
            // The profile can differ across the switch, so the client needs the
            // new parameter sets and an IDR to start from.
            self.packetizer?.invalidateParameterSetCache()
            self.forceKeyframeFlag = true
            let warnings = replacement.warnings
            self.onMain { self.warnings = warnings }
        }
    }

    /// The bitrate the running stream is actually using, for the meter to
    /// scale against. Falls back to what the settings would produce before a
    /// stream exists.
    var activeBitrateMbps: Double {
        Double(plan?.bitrateBitsPerSecond
               ?? (settings.videoMode ? settings.videoBitrateBitsPerSecond
                                      : settings.bitrateBitsPerSecond)) / 1_000_000
    }

    private func startIdleHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let encoder = self.encoder else { return }
            guard self.forceKeyframeFlag else { return }

            // If frames are still arriving, the capture path will pick the flag
            // up on its own and encode something current. Only step in when it
            // has gone quiet.
            let idleFor = CFAbsoluteTimeGetCurrent() - self.lastEncodeSubmitTime
            guard idleFor > 0.2 else { return }
            guard let latest = self.lastCapturedBuffer else { return }

            self.forceKeyframeFlag = false
            // Host time clock, same as ScreenCaptureKit stamps its frames with.
            // Using CFAbsoluteTime here would put these frames on a completely
            // different epoch from captured ones, which throws the RTP
            // timestamps and the latency measurement off.
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            encoder.encode(pixelBuffer: latest, presentationTime: pts, forceKeyframe: true)
            self.lastEncodeSubmitTime = CFAbsoluteTimeGetCurrent()
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: - stats

    @MainActor
    private func startStatsTimer() {
        statsLock.lock(); bytesAtPeriodStart = 0; statsLock.unlock()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func tickStats() {
        let (bytes, drops) = encodeQueue.sync {
            (self.packetizer?.bytesSent ?? 0, self.sender?.dropped ?? 0)
        }

        statsLock.lock()
        let frames = framesThisPeriod
        let millis = encodeMillisThisPeriod
        let pipelineMillis = pipelineMillisThisPeriod
        let pipelineSamples = pipelineSamplesThisPeriod
        let delta = bytes >= bytesAtPeriodStart ? bytes - bytesAtPeriodStart : 0
        bytesAtPeriodStart = bytes
        framesThisPeriod = 0
        encodeMillisThisPeriod = 0
        pipelineMillisThisPeriod = 0
        pipelineSamplesThisPeriod = 0
        statsLock.unlock()

        onMain {
            self.outgoingMbps = Double(delta) * 8.0 / 1_000_000.0
            self.packetsNotSent = drops
            self.encodedFPS = Double(frames)
            self.encodeMilliseconds = frames > 0 ? millis / Double(frames) : 0
            if pipelineSamples > 0 {
                self.hostPipelineMilliseconds = pipelineMillis / Double(pipelineSamples)
            }
            self.logStatsLine()
        }
    }

    /// A line a second to the system log, so "it got slower after a few
    /// minutes" leaves something behind that can be read afterwards. Nothing in
    /// the app keeps a history otherwise, and by the time you notice a
    /// degradation the numbers that would explain it are gone.
    ///
    ///     LS_LOG=1 open -a LanScreenHost
    ///     log stream --predicate 'subsystem == "com.lanscreen.host"'
    ///     log show --predicate 'subsystem == "com.lanscreen.host"' --last 15m
    ///
    /// Off unless `LS_LOG` is set. Not because it was expensive -- this exact
    /// line with all fifteen of its interpolations measured 2.16 us, which once
    /// a second is 0.0002% of one core, and the whole running commentary is not
    /// detectable in any number this app reports. It is off because a stream
    /// that is behaving does not need a diary, and turning it on is one word on
    /// the command line when one is wanted.
    ///
    /// At `notice`, not `info`. Info-level messages live in a memory ring
    /// buffer and are evicted, so the first version of this had already lost
    /// the opening ninety seconds of a stream — including the line saying what
    /// packet size was chosen — by the time anyone came to read it. Which is
    /// the one thing a record of what happened must not do.
    private func logStatsLine() {
        guard isRunning, StreamController.logsProgress else { return }
        let uptime = Int(Date().timeIntervalSince(startedAt ?? Date()))
        StreamController.statsLog.notice("""
            t=\(uptime, privacy: .public)s \
            mbps=\(self.outgoingMbps, format: .fixed(precision: 1), privacy: .public) \
            fps=\(self.encodedFPS, format: .fixed(precision: 0), privacy: .public) \
            encode=\(self.encodeMilliseconds, format: .fixed(precision: 2), privacy: .public)ms \
            pipeline=\(self.hostPipelineMilliseconds, format: .fixed(precision: 2), privacy: .public)ms \
            rtt=\(self.client.rttMilliseconds, format: .fixed(precision: 2), privacy: .public)ms \
            decode=\(Double(self.client.stats.decode_us) / 1000, format: .fixed(precision: 2), privacy: .public)ms \
            render=\(Double(self.client.stats.render_us) / 1000, format: .fixed(precision: 2), privacy: .public)ms \
            lost=\(self.client.stats.packets_lost, privacy: .public) \
            dropped=\(self.client.stats.frames_dropped, privacy: .public) \
            corrupt=\(self.client.stats.frames_corrupt, privacy: .public) \
            keyframes=\(self.keyframeRequests, privacy: .public) \
            audio_under=\(self.client.stats.audio_underruns, privacy: .public) \
            audio_over=\(self.client.stats.audio_overruns, privacy: .public) \
            audio_buf=\(Double(self.client.stats.audio_buffered_us) / 1000, format: .fixed(precision: 1), privacy: .public)ms \
            fullperf=\(self.fullPerformanceHeld, privacy: .public)
            """)
    }

    static let statsLog = Logger(subsystem: "com.lanscreen.host", category: "stats")

    /// Whether to keep a running commentary. Read once: an environment
    /// variable cannot change under a running process, and this is consulted
    /// on a path that runs every second.
    ///
    /// Errors are not covered by this. A failure that is never written down is
    /// a failure nobody can explain afterwards, and those cost nothing because
    /// they do not happen.
    static let logsProgress = ProcessInfo.processInfo.environment["LS_LOG"] != nil

    // MARK: - SDP, for testing with VLC/ffplay before touching the iMac

    private func maybeWriteSDP() {
        guard !sdpWritten,
              let sets = packetizer?.sdpParameterSets else { return }
        sdpWritten = true   // only ever set from the VideoToolbox output thread

        let sdp = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=LanScreen
        c=IN IP4 127.0.0.1
        t=0 0
        a=tool:LanScreen
        m=video \(settings.videoPort) RTP/AVP \(LS_RTP_PAYLOAD_TYPE)
        a=rtpmap:\(LS_RTP_PAYLOAD_TYPE) H264/\(LS_RTP_CLOCK_HZ)
        a=fmtp:\(LS_RTP_PAYLOAD_TYPE) packetization-mode=1;sprop-parameter-sets=\(sets.sps),\(sets.pps)

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lanscreen.sdp")
        try? sdp.write(to: url, atomically: true, encoding: .utf8)
        onMain { self.sdpPath = url.path }
    }
}

// Lives here rather than beside the snapshot code because these setters are
// private on purpose: nothing outside this file gets to invent stream state.
extension StreamController {
    /// Plausible mid-stream numbers, for `--render-ui` only. Nothing in the app
    /// calls this.
    func applyPreviewState() {
        isRunning = true
        statusText = "Streaming to 10.0.0.2:5004"
        outgoingMbps = 23.4
        encodedFPS = 59
        hostPipelineMilliseconds = 9.4
        keyframeRequests = 3
        fullPerformanceHeld = true
        activeSourceDescription = "Virtual display 1920×1080 @ 60"
        // A clamped packet size, so the snapshot exercises the jumbo-frame
        // hint. The preview is the only thing that looks at this panel without
        // a stream running, so anything it does not set is never seen.
        linkMTUBytes = 1500
        effectiveMTUPayload = 1472
        linkInterfaceName = "en7"
        packetsNotSent = 0
        var state = ControlChannel.ClientState()
        state.address = "10.0.0.2"
        state.hasSaidHello = true
        state.drawsCursor = true
        state.rttMilliseconds = 0.31
        state.stats.decode_us = 4200
        state.stats.render_us = 1900
        state.stats.frames_decoded = 18422
        state.stats.frames_dropped = 2
        state.stats.packets_lost = 0
        client = state
    }
}
