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

import SwiftUI
import AppKit

// The menu bar is now the app. Everything you touch while streaming — start,
// stop, the live numbers, the three switches that actually change how it feels —
// is here. The settings window still exists for the things you set once.

extension StreamController {
    /// Capture to wire is measured on this side, the network is half the round
    /// trip, and the client reports its own decode and render. Shared by the
    /// panel and the settings window so the two cannot disagree.
    var estimatedGlassToGlassMilliseconds: Double {
        hostPipelineMilliseconds
            + client.rttMilliseconds / 2.0
            + Double(client.stats.decode_us) / 1000.0
            + Double(client.stats.render_us) / 1000.0
    }
}

struct MenuBarPanel: View {
    @ObservedObject var settings: StreamSettings
    @ObservedObject var controller: StreamController

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            VStack(spacing: 9) {
                startButton
                meters
                linkGroup
                switchesGroup
                if let error = controller.lastError { notice(error, colour: Aero.red) }
                if !controller.warnings.isEmpty {
                    notice("Encoder hints the hardware declined: "
                           + controller.warnings.joined(separator: ", "),
                           colour: Aero.amber)
                }
                footer
            }
            .padding(.horizontal, 11)
            .padding(.top, 10)
            .padding(.bottom, 11)
        }
        .frame(width: 372)
        .background(Aero.GlassBackground())
        .toggleStyle(AeroToggleStyle())
        .environment(\.colorScheme, .light)
    }

    // MARK: - Title bar

    /// The deep blue caption bar off the top of an Aero window, complete with
    /// the gloss break halfway down and a lit bottom edge.
    private var titleBar: some View {
        HStack(spacing: 9) {
            Aero.Orb(colour: orbColour, diameter: 12, lit: controller.isRunning)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("LanScreen")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                    Text("GREEDY")
                        .font(.system(size: 7.5, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [Aero.amber, Aero.amber.blended(with: .red, amount: 0.35)],
                                startPoint: .top, endPoint: .bottom))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.75))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                }
                Text(controller.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.88))
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Aero.chromeTop, Aero.chromeBottom],
                               startPoint: .top, endPoint: .bottom)
                Aero.Gloss(cornerRadius: 0, strength: 0.42)
                RadialGradient(colors: [.white.opacity(0.32), .clear],
                               center: UnitPoint(x: 0.12, y: 0),
                               startRadius: 0, endRadius: 190)
                // The reflection every Aero caption bar had: a wide, shallow
                // ellipse of light hanging off the top edge.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 520, height: 44)
                    .offset(x: -30, y: -20)
                    .blur(radius: 5)
                    .allowsHitTesting(false)
                Rectangle().fill(.white.opacity(0.55)).frame(height: 1)
            }
        )
    }

    private var orbColour: Color {
        if controller.lastError != nil { return Aero.red }
        if !controller.isRunning { return Color(white: 0.55) }
        return controller.client.hasSaidHello ? Aero.green : Aero.amber
    }

    // MARK: - The one button that matters

    private var startButton: some View {
        HStack(spacing: 8) {
            Button {
                controller.isRunning ? controller.stop() : controller.start()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: controller.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(controller.isRunning ? "Stop streaming" : "Start streaming")
                }
            }
            .buttonStyle(AeroButtonStyle(kind: controller.isRunning ? .stop : .primary, big: true))
            .keyboardShortcut(.return, modifiers: [])

            Button {
                controller.requestKeyframeNow()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(AeroButtonStyle(big: true))
            .frame(width: 38)
            .disabled(!controller.isRunning)
            .help("Force a keyframe")
        }
    }

    // MARK: - Meters

    private var meters: some View {
        Aero.Group(title: "Throughput", accent: Aero.green) {
            VStack(spacing: 5) {
                Aero.Meter(label: "Sending",
                           value: String(format: "%.1f Mb/s", controller.outgoingMbps),
                           fraction: controller.outgoingMbps / max(settings.bitrateMbps, 1),
                           colour: Aero.green, live: controller.isRunning)
                Aero.Meter(label: "Encoding",
                           value: String(format: "%.0f fps", controller.encodedFPS),
                           fraction: controller.encodedFPS / Double(max(settings.frameRate, 1)),
                           colour: Aero.blue, live: controller.isRunning)
                Aero.Meter(label: "Glass to glass",
                           value: latencyReady ? String(format: "%.0f ms", latency) : "—",
                           // Half the bar is 25 ms, which is about where the
                           // pointer stops feeling attached to your hand.
                           fraction: latencyReady ? latency / 50 : 0,
                           colour: latencyColour, live: controller.isRunning && latencyReady)
            }
        }
    }

    private var latency: Double { controller.estimatedGlassToGlassMilliseconds }
    private var latencyReady: Bool { controller.isRunning && controller.client.stats.decode_us > 0 }
    private var latencyColour: Color {
        latency < 20 ? Aero.green : (latency < 35 ? Aero.amber : Aero.red)
    }

    // MARK: - Link

    private var linkGroup: some View {
        Aero.Group(title: "Link", accent: Aero.violet) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    // ClientState starts at an em dash rather than at "", so
                    // fall back on anything that is not an actual address.
                    readout("Client", controller.client.hasSaidHello
                            ? controller.client.address : settings.clientAddress)
                    readout("RTT", controller.client.rttMilliseconds > 0
                            ? String(format: "%.2f ms", controller.client.rttMilliseconds) : "—")
                    readout("Lost", "\(controller.client.stats.packets_lost)",
                            alarm: controller.client.stats.packets_lost > 0)
                }
                GridRow {
                    readout("Decode", controller.client.stats.decode_us > 0
                            ? String(format: "%.2f ms", Double(controller.client.stats.decode_us) / 1000) : "—")
                    readout("Render", controller.client.stats.render_us > 0
                            ? String(format: "%.2f ms", Double(controller.client.stats.render_us) / 1000) : "—")
                    readout("Dropped", "\(controller.client.stats.frames_dropped)",
                            alarm: controller.client.stats.frames_dropped > 0)
                }
                GridRow {
                    readout("Link MTU", controller.linkMTUBytes > 0
                            ? "\(controller.linkMTUBytes) B" : "—")
                    // Red when it is not what was asked for: that means the
                    // link could not carry the configured size.
                    readout("Packet", controller.effectiveMTUPayload > 0
                            ? "\(controller.effectiveMTUPayload) B" : "—",
                            alarm: controller.effectiveMTUPayload > 0
                                && controller.effectiveMTUPayload != settings.mtuPayload)
                    readout("Keyframes", "\(controller.keyframeRequests)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if settings.forwardCursor && controller.client.hasSaidHello
                && !controller.client.drawsCursor {
                Text("This client cannot draw the pointer. Rebuild it, or turn the "
                     + "pointer switch off.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Aero.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func readout(_ label: String, _ value: String, alarm: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Aero.inkFaint)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(alarm ? Aero.red : Aero.ink)
                .lineLimit(1)
        }
        .frame(width: 104, alignment: .leading)
    }

    // MARK: - The three switches worth reaching for

    private var switchesGroup: some View {
        Aero.Group(title: "Responsiveness", accent: Aero.amber) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Low-latency encoder, 4:2:0 capture", isOn: Binding(
                    get: { settings.lowLatencyEncoder && settings.captureYUV420 },
                    set: { settings.lowLatencyEncoder = $0; settings.captureYUV420 = $0 }))
                    .disabled(controller.isRunning)
                Toggle("Send the pointer separately", isOn: $settings.forwardCursor)
                    .disabled(controller.isRunning)
                Toggle("Keep this Mac at full performance", isOn: $settings.preventAppNap)

                if controller.isRunning {
                    HStack(spacing: 5) {
                        Aero.Orb(colour: controller.fullPerformanceHeld ? Aero.green : Aero.amber,
                                 diameter: 7)
                        Text(controller.fullPerformanceHeld
                             ? "Full performance asserted"
                             : "Not asserted — macOS may throttle this app")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Aero.inkFaint)
                    }
                    .padding(.leading, 2)
                }
                if controller.isRunning {
                    Text("Greyed switches are read when the stream starts.")
                        .font(.system(size: 9))
                        .foregroundStyle(Aero.inkFaint.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Settings…") {
                HostWindows.showSettings(settings: settings, controller: controller)
            }
            .buttonStyle(AeroButtonStyle())

            Button("Wake iMac") { controller.wakeClient(reason: "Manual") }
                .buttonStyle(AeroButtonStyle())
                .disabled(settings.clientMACAddress.isEmpty)

            Spacer(minLength: 0)

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(AeroButtonStyle())
                .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func notice(_ text: String, colour: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: colour == Aero.red
                  ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(colour)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(Aero.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colour.opacity(0.14))
                Aero.Bevel(cornerRadius: 5,
                           edge: .white.opacity(0.5), border: colour.opacity(0.55))
            }
        )
    }
}

// MARK: - The menu bar icon

extension Aero {
    /// Drawn rather than shipped as an asset, so it can carry the running state
    /// in colour. Menu bar icons are normally templates; this one deliberately
    /// is not, because the point of it is the green light.
    static func menuBarIcon(running: Bool, attention: Bool) -> NSImage {
        let size = NSSize(width: 19, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 1.5, y: 3.5, width: 16, height: 11)
            let screen = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)

            let top    = running ? NSColor(srgbRed: 0.42, green: 0.70, blue: 0.95, alpha: 1)
                                 : NSColor(srgbRed: 0.62, green: 0.65, blue: 0.70, alpha: 1)
            let bottom = running ? NSColor(srgbRed: 0.10, green: 0.34, blue: 0.68, alpha: 1)
                                 : NSColor(srgbRed: 0.34, green: 0.37, blue: 0.42, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: screen, angle: -90)

            // Gloss across the top half, clipped to the screen.
            NSGraphicsContext.saveGraphicsState()
            screen.addClip()
            let gloss = NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)
            NSGradient(starting: NSColor(white: 1, alpha: 0.55),
                       ending: NSColor(white: 1, alpha: 0.12))?.draw(in: gloss, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            NSColor(white: 0, alpha: 0.55).setStroke()
            screen.lineWidth = 1
            screen.stroke()

            // Stand.
            let stand = NSBezierPath(rect: NSRect(x: 7.5, y: 1.0, width: 4, height: 2.5))
            NSColor(white: 0.35, alpha: 0.85).setFill()
            stand.fill()
            let foot = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 0, width: 10, height: 1.8),
                                    xRadius: 0.9, yRadius: 0.9)
            foot.fill()

            // The light.
            let dot = NSRect(x: 12.0, y: 5.4, width: 4, height: 4)
            let lamp = running ? (attention
                                  ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.10, alpha: 1)
                                  : NSColor(srgbRed: 0.45, green: 0.92, blue: 0.25, alpha: 1))
                               : NSColor(white: 1, alpha: 0.35)
            lamp.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if running {
                NSColor(white: 1, alpha: 0.75).setFill()
                NSBezierPath(ovalIn: NSRect(x: dot.minX + 0.9, y: dot.minY + 2.0,
                                            width: 1.5, height: 1.2)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
