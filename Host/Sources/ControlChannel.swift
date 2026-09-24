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
import Darwin
import LSProtocol

/// The UDP back-channel, host side.
///
/// Gemini's original design was one-way RTP, which means a single lost packet
/// corrupts the picture until the next scheduled IDR. This channel is what
/// makes that recoverable: the client asks for a keyframe the instant it sees a
/// sequence gap, and we oblige. It also carries RTT probes and the client's
/// decode statistics so you can actually see where latency is going.
final class ControlChannel {

    struct ClientState {
        var address: String = "—"
        var screenWidth: Int = 0
        var screenHeight: Int = 0
        /// Reported by the client so we can wake it later, or "" if it could
        /// not determine its own hardware address.
        var macAddress: String = ""
        /// Whether the client told us it can draw the pointer itself.
        var drawsCursor = false
        /// Whether the client told us it can play the audio stream.
        var playsAudio = false
        /// Whether the client's display took a brightness reading.
        var setsBrightness = false
        var hasSaidHello = false
        var lastSeen: Date?
        var rttMilliseconds: Double = 0
        var stats = ls_stats()
    }

    private var socket: UDPBoundSocket?
    private var thread: Thread?
    private var pingTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var clientAddress: sockaddr_in?
    private var running = false

    /// Fired on the receive thread. Keep the handler cheap.
    var onKeyframeRequested: (() -> Void)?
    /// Fired on the receive thread when a client introduces itself.
    var onClientHello: (() -> Void)?
    /// Fired on the receive thread when a client reports a usable MAC address.
    var onClientMAC: ((String) -> Void)?
    /// Fired on the main queue whenever client state changes.
    var onStateChanged: ((ClientState) -> Void)?

    private var state = ClientState()

    func start(port: UInt16) throws {
        let sock = try UDPBoundSocket(port: port)
        socket = sock
        running = true

        let thread = Thread { [weak self] in self?.receiveLoop(sock) }
        thread.name = "com.lanscreen.control"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.sendPing() }
        timer.resume()
        pingTimer = timer
    }

    func stop() {
        running = false
        pingTimer?.cancel()
        pingTimer = nil
        // Best effort goodbye so the client blanks instead of freezing on the
        // last frame it happened to receive.
        if let addr = currentClientAddress(), let sock = socket {
            var buf = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
            let n = ls_ctrl_build_bye(&buf, buf.count)
            if n > 0 { sock.send(buf, Int(n), to: addr) }
        }
        socket?.shutdownAndClose()
        socket = nil
        lock.lock(); clientAddress = nil; lock.unlock()
    }

    private func currentClientAddress() -> sockaddr_in? {
        lock.lock(); defer { lock.unlock() }
        return clientAddress
    }

    private func receiveLoop(_ sock: UDPBoundSocket) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var consecutiveErrors = 0

        while running {
            var from = sockaddr_in()
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return sock.receive(into: base, capacity: raw.count, from: &from)
            }
            if n <= 0 {
                if !running { break }
                let code = errno
                if code == EINTR { continue }

                // Anything else used to end the loop, which quietly killed the
                // control channel for the rest of the session: no more pings,
                // so the client would time out and blank with no indication
                // why. No confirmed case of that happening -- the obvious
                // candidate, an ICMP unreachable from a restarted client, does
                // not surface here -- but a channel that can disappear for the
                // rest of a session without a word is not worth keeping.
                //
                // Only a socket that is genuinely gone is fatal.
                if code == EBADF || code == ENOTSOCK {
                    NSLog("[LanScreen] control socket closed (%s)",
                          String(cString: strerror(code)))
                    break
                }

                consecutiveErrors += 1
                if consecutiveErrors == 1 || consecutiveErrors % 50 == 0 {
                    NSLog("[LanScreen] control receive error, continuing (%s, %d in a row)",
                          String(cString: strerror(code)), consecutiveErrors)
                }
                if consecutiveErrors > 500 {
                    NSLog("[LanScreen] control socket is not recovering, giving up")
                    break
                }
                usleep(2000)
                continue
            }
            consecutiveErrors = 0

            var message = ls_ctrl_message()
            let ok = buffer.withUnsafeBufferPointer { p -> Bool in
                ls_ctrl_parse(p.baseAddress!, n, &message) == 0
            }
            guard ok else { continue }   // stray or malformed: ignore silently

            lock.lock()
            clientAddress = from
            state.address = addressString(from)
            state.lastSeen = Date()
            lock.unlock()

            handle(message, from: from, socket: sock)
        }
    }

    private func handle(_ message: ls_ctrl_message, from: sockaddr_in, socket: UDPBoundSocket) {
        switch Int(message.type) {
        case LS_MSG_HELLO:
            var reportedMAC = ""
            if message.has_mac != 0 {
                var bytes = message.mac
                var text = [CChar](repeating: 0, count: 18)
                _ = withUnsafePointer(to: &bytes) { macPointer in
                    macPointer.withMemoryRebound(to: UInt8.self, capacity: 6) {
                        ls_format_mac(&text, text.count, $0)
                    }
                }
                reportedMAC = String(cString: text)
            }
            lock.lock()
            state.screenWidth = Int(message.screen_width)
            state.screenHeight = Int(message.screen_height)
            state.drawsCursor = (message.flags & UInt16(LS_CLIENT_FLAG_DRAWS_CURSOR)) != 0
            state.playsAudio = (message.flags & UInt16(LS_CLIENT_FLAG_PLAYS_AUDIO)) != 0
            state.setsBrightness = (message.flags & UInt16(LS_CLIENT_FLAG_SETS_BRIGHTNESS)) != 0
            state.hasSaidHello = true
            if !reportedMAC.isEmpty { state.macAddress = reportedMAC }
            lock.unlock()
            onClientHello?()
            if !reportedMAC.isEmpty { onClientMAC?(reportedMAC) }
            publishState()

        case LS_MSG_KEYFRAME_REQ:
            onKeyframeRequested?()

        case LS_MSG_STATS:
            lock.lock()
            state.stats = message.stats
            lock.unlock()
            publishState()

        case LS_MSG_PONG:
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if message.token != 0, now > message.token {
                let rtt = Double(now - message.token) / 1_000_000.0
                lock.lock()
                // Light smoothing; raw RTT on a quiet link jitters enough to be
                // unreadable in a live UI.
                state.rttMilliseconds = state.rttMilliseconds == 0
                    ? rtt : (state.rttMilliseconds * 0.7 + rtt * 0.3)
                lock.unlock()
            }
            publishState()

        case LS_MSG_BYE:
            lock.lock()
            clientAddress = nil
            state.lastSeen = nil
            lock.unlock()
            publishState()

        default:
            break
        }
    }

    /// Sends a prebuilt message to whatever address the client last spoke from.
    /// Silently does nothing before the client has said hello, which is correct:
    /// there is nowhere to send it yet.
    func send(_ bytes: [UInt8], count: Int) {
        guard let sock = socket, let addr = currentClientAddress(), count > 0 else { return }
        sock.send(bytes, count, to: addr)
    }

    private func sendPing() {
        guard let sock = socket, let addr = currentClientAddress() else { return }
        var buf = [UInt8](repeating: 0, count: Int(LS_CTRL_MAX_SIZE))
        let token = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let n = ls_ctrl_build_ping(&buf, buf.count, token)
        if n > 0 { sock.send(buf, Int(n), to: addr) }
    }

    private func publishState() {
        lock.lock(); let snapshot = state; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(snapshot) }
    }
}
