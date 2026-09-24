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
    private var forceKeyframeFlag = false
    private var sdpWritten = false
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
            guard self.settings.wakeClientAutomatically else { return }
            // The Ethernet link has to renegotiate after wake, which takes a
            // moment; a packet sent immediately goes nowhere. Retrying for a
            // while covers both that and an iMac that is slow to come up.
            self.wakeClient(reason: "this Mac woke")
            self.startWakeRetries()
        })

        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.settings.stopOnSleep, self.isRunning else { return }
            // Stopping sends BYE, which makes the client drop its keep-awake
            // assertion so the iMac can sleep too instead of sitting lit up all
            // night showing a frozen frame.
            self.stop()
        })
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
                    StreamController.statsLog.info(
                        "stream started \(self.settings.width, privacy: .public)x\(self.settings.height, privacy: .public) @ \(self.settings.frameRate, privacy: .public), \(self.settings.bitrateMbps, format: .fixed(precision: 0), privacy: .public) Mb/s")
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

    func stop() {
        guard isRunning else { return }
        onMain { self.statusText = "Stopping…" }
        Task {
            await teardown()
            onMain {
                StreamController.statsLog.info(
                    "stream stopped after \(Int(Date().timeIntervalSince(self.startedAt ?? Date())), privacy: .public)s")
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
        // adapter and both machines. A manually raised MTU does not survive a
        // reboot, so a setting that was right yesterday can be wrong today with
        // nothing to show for it except a stream that slowly falls apart. Check
        // rather than assume, and carry on with what the link can actually take.
        let requestedPayload = settings.mtuPayload
        var effectivePayload = requestedPayload
        var pathWarnings: [String] = []
        let linkMTU = sender.linkMTU
        effectivePayload = lsEffectiveMTUPayload(requested: requestedPayload,
                                                 linkMTU: linkMTU,
                                                 headerSize: Int(LS_RTP_HEADER_SIZE))
        if let mtu = linkMTU, effectivePayload != requestedPayload {
            pathWarnings.append(
                "Packet size set to \(requestedPayload) B but the link to "
                + "\(settings.clientAddress) has an MTU of \(mtu). Every packet would be "
                + "split into \(Int(ceil(Double(requestedPayload + lsIPv4UDPOverhead) / Double(mtu)))) "
                + "IP fragments and one lost fragment destroys the whole packet, so "
                + "\(effectivePayload) B is being used instead. To get jumbo frames back, set "
                + "MTU 9000 on this Mac and the client — it is not persistent across a reboot.")
        }
        onMain {
            self.linkMTUBytes = linkMTU ?? 0
            self.effectiveMTUPayload = effectivePayload
            // Published here rather than with the encoder's warnings at the end
            // of this function: if anything between the two throws, this is
            // exactly the warning you still want to have seen.
            self.warnings = pathWarnings
        }
        if let mtu = linkMTU {
            StreamController.statsLog.info(
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

        let encoderConfig = VideoEncoder.Configuration(
            width: settings.width,
            height: settings.height,
            frameRate: settings.frameRate,
            bitrate: settings.bitrateBitsPerSecond,
            profileIsBaseline: settings.profile == .baseline,
            keyframeInterval: settings.keyframeSeconds,
            lowLatencyRateControl: settings.lowLatencyEncoder)

        let encoder = VideoEncoder(config: encoderConfig) { [weak self] sampleBuffer in
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

        try await capture.start(displayID: captureDisplayID,
                                width: settings.width,
                                height: settings.height,
                                frameRate: settings.frameRate,
                                showsCursor: settings.showsCursor && !settings.forwardCursor,
                                useYUV420: settings.captureYUV420)

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
                                           hiDPI: settings.hiDPI,
                                           name: "LanScreen")
        virtualDisplay = display
        activeSourceDescription =
            "Virtual display \(display.displayID) — \(display.width)×\(display.height)"

        // The window server needs a moment to publish the new display before
        // SCShareableContent will list it.
        try? await Task.sleep(nanoseconds: 500_000_000)
        return display.displayID
    }

    private func teardown() async {
        endFullPerformance()
        cursorTracker?.stop(); cursorTracker = nil
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
        let bytes = encodeQueue.sync { self.packetizer?.bytesSent ?? 0 }

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
    ///     log show --predicate 'subsystem == "com.lanscreen.host"' --last 15m
    ///     log stream --predicate 'subsystem == "com.lanscreen.host"'
    private func logStatsLine() {
        guard isRunning else { return }
        let uptime = Int(Date().timeIntervalSince(startedAt ?? Date()))
        StreamController.statsLog.info("""
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
            fullperf=\(self.fullPerformanceHeld, privacy: .public)
            """)
    }

    static let statsLog = Logger(subsystem: "com.lanscreen.host", category: "stats")

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
