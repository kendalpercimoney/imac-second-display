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
import LSProtocol

@main
struct LanScreenHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = StreamSettings()
    @StateObject private var controller: StreamController

    init() {
        let settings = StreamSettings()
        _settings = StateObject(wrappedValue: settings)
        let controller = StreamController(settings: settings)
        _controller = StateObject(wrappedValue: controller)
        UnattendedRun.begin(settings: settings, controller: controller)
    }

    var body: some Scene {
        // The menu bar is the app. There is no window scene at all, because a
        // SwiftUI `Window` opens itself at launch and this is not a thing you
        // want a window for — the settings window is built on demand instead.
        MenuBarExtra {
            MenuBarPanel(settings: settings, controller: controller)
                .task { await controller.refreshDisplays() }
        } label: {
            Image(nsImage: Aero.menuBarIcon(
                running: controller.isRunning,
                attention: controller.lastError != nil
                    || (controller.isRunning && !controller.client.hasSaidHello)))
                .renderingMode(.original)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Runs as an accessory: no Dock icon, no menu bar of its own, just the status
/// item. It becomes a regular app for as long as the settings window is open,
/// so that window gets a real Edit menu — without one there is no Paste, and
/// the MAC address field exists specifically to have something pasted into it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UISnapshot.runIfRequested() { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(UnattendedRun.wantsWindow ? .regular : .accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The settings window, built by hand rather than as a SwiftUI scene so that it
/// exists only once it is asked for.
enum HostWindows {
    private static var settings: NSWindow?
    private static var observer: NSObjectProtocol?

    static func showSettings(settings streamSettings: StreamSettings,
                             controller: StreamController) {
        if settings == nil {
            let view = ContentView(settings: streamSettings, controller: controller)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "LanScreen Host"
            window.contentView = NSHostingView(rootView: view)
            window.contentMinSize = NSSize(width: 560, height: 480)
            window.isReleasedWhenClosed = false
            // Aero has no dark mode, so the window is pinned light and the
            // titlebar is left to blend into the glass behind it.
            window.appearance = NSAppearance(named: .aqua)
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 0.91, green: 0.96, blue: 1.0, alpha: 1)
            window.center()
            settings = window

            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    // Back to an accessory once it is gone, or the Dock icon
                    // outlives the only window that justified it. Except under
                    // --with-window, where staying a regular app is the point.
                    if !UnattendedRun.wantsWindow { NSApp.setActivationPolicy(.accessory) }
                }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

struct ContentView: View {
    @ObservedObject var settings: StreamSettings
    @ObservedObject var controller: StreamController

    /// What the pipeline would be configured with right now. Used to grey out
    /// controls that would have no effect, rather than presenting them as live
    /// and quietly ignoring them.
    private var plan: StreamPlan {
        StreamPlan(settings: settings,
                   linkMTU: controller.linkMTUBytes > 0 ? controller.linkMTUBytes : nil)
    }

    /// The note under a control that is not currently being honoured.
    @ViewBuilder
    private func inertNote(_ control: String) -> some View {
        if let note = plan.inertFor(control) {
            Label("Not in effect: \(note.reason).", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                sourceSection
                destinationSection
                videoSection
                networkSection
                latencySection
                powerSection
                statsSection
                if let error = controller.lastError { errorBox(error) }
                if !controller.warnings.isEmpty { warningBox(controller.warnings) }
            }
            .padding(18)
        }
        .background(Aero.GlassBackground())
        // Set once here rather than at four hundred call sites: every GroupBox,
        // Button and Toggle below picks these up through the environment, which
        // is the only reason the window could be reskinned without rewriting it.
        .groupBoxStyle(AeroGroupBoxStyle())
        .buttonStyle(AeroButtonStyle())
        .toggleStyle(AeroToggleStyle())
        .tint(Aero.blue)
        .foregroundStyle(Aero.ink)
        .environment(\.colorScheme, .light)
        .task { await controller.refreshDisplays() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Aero.Orb(colour: controller.isRunning ? Aero.green : Color(white: 0.55),
                     diameter: 14, lit: controller.isRunning)
                .padding(.leading, 3)
            VStack(alignment: .leading, spacing: 0) {
                Text("LanScreen Greedy")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                Text(controller.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.88))
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            }
            Spacer()
            Button(controller.isRunning ? "Stop" : "Start") {
                controller.isRunning ? controller.stop() : controller.start()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(AeroButtonStyle(kind: controller.isRunning ? .stop : .primary))
            .frame(width: 96)
            .padding(.trailing, 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Aero.chromeTop, Aero.chromeBottom],
                                         startPoint: .top, endPoint: .bottom))
                Aero.Gloss(cornerRadius: 7, strength: 0.42)
                Aero.Bevel(cornerRadius: 7,
                           edge: .white.opacity(0.45),
                           border: Aero.chromeBottom.blended(with: .black, amount: 0.3))
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        )
    }

    private var destinationSection: some View {
        GroupBox("Destination") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Client IP")
                    TextField("10.0.0.2", text: $settings.clientAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("Video port")
                    TextField("", value: $settings.videoPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("Control")
                    TextField("", value: $settings.controlPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            .padding(6)
            .disabled(controller.isRunning)
        }
    }

    private var sourceSection: some View {
        GroupBox("Source") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $settings.source) {
                    ForEach(StreamSettings.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(controller.isRunning || !controller.virtualDisplaySupported)

                if settings.source == .virtualDisplay {
                    Label("Creates a headless display so the iMac becomes a real second "
                          + "monitor instead of a mirror. Arrange it in System Settings ▸ "
                          + "Displays once it appears.",
                          systemImage: "display.2")
                        .font(.caption).foregroundStyle(.secondary)

                    if !controller.virtualDisplaySupported {
                        Label("This macOS does not expose CGVirtualDisplay. Use a hardware "
                              + "HDMI dummy plug and capture it as an existing display.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if controller.client.screenWidth > 0 {
                        HStack {
                            Text("Client reports \(controller.client.screenWidth)×\(controller.client.screenHeight)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Match") {
                                settings.width = controller.client.screenWidth
                                settings.height = controller.client.screenHeight
                            }
                            .controlSize(.small)
                            .disabled(controller.isRunning)
                        }
                    }
                } else {
                    Picker("Display", selection: $settings.displayID) {
                        ForEach(controller.displays) { display in
                            Text(display.label).tag(display.id)
                        }
                    }
                    .disabled(controller.isRunning)
                }

                if !controller.activeSourceDescription.isEmpty {
                    Text(controller.activeSourceDescription)
                        .font(.caption.monospaced()).foregroundStyle(.green)
                }
            }
            .padding(6)
        }
    }

    private var videoSection: some View {
        GroupBox("Video") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(settings.source == .virtualDisplay ? "Display size" : "Resolution")
                    TextField("", value: $settings.width, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("×")
                    TextField("", value: $settings.height, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("Frame rate")
                    TextField("", value: $settings.frameRate, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
                GridRow {
                    Text("Bitrate")
                    HStack {
                        Slider(value: $settings.bitrateMbps, in: 5...80, step: 1)
                        Text("\(Int(settings.bitrateMbps)) Mb/s").monospacedDigit().frame(width: 80)
                    }
                    .gridCellColumns(5)
                }
                GridRow {
                    Text("Profile")
                    Picker("", selection: $settings.profile) {
                        ForEach(StreamSettings.Profile.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 170)
                    .disabled(plan.inertFor("Profile") != nil)
                    Text("Keyframe")
                    HStack(spacing: 4) {
                        TextField("", value: $settings.keyframeSeconds, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 50)
                        Text("s")
                    }
                    .gridCellColumns(3)
                }
                GridRow {
                    Text("")
                    Toggle("Include mouse cursor", isOn: $settings.showsCursor)
                        .disabled(plan.inertFor("Include mouse cursor") != nil)
                        .gridCellColumns(5)
                }
            }
            .padding(6)
            .disabled(controller.isRunning)

            VStack(alignment: .leading, spacing: 4) {
                inertNote("Profile")
                inertNote("Include mouse cursor")
            }
            .padding(.horizontal, 6)

            if settings.height > 1080 {
                Label("Above 1080p the 2010 iMac will likely fall back to software decoding and stutter.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 6)
            }
        }
    }

    private var networkSection: some View {
        GroupBox("Network") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Packet size", selection: $settings.mtuPayload) {
                    Text("1400 B — standard 1500 MTU").tag(Int(LS_DEFAULT_MTU_PAYLOAD))
                    Text("8900 B — jumbo frames (MTU 9000 on both ends)").tag(Int(LS_JUMBO_MTU_PAYLOAD))
                }
                .disabled(controller.isRunning)

                if controller.linkMTUBytes > 0 { linkMTUNote }
                inertNote("Packet size")

                HStack {
                    Button("Force keyframe") { controller.requestKeyframeNow() }
                        .disabled(!controller.isRunning)
                    if let path = controller.sdpPath {
                        Button("Reveal test .sdp") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        Text("open with VLC to verify the stream locally")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    /// Split out of the Network section because the type checker gave up on it
    /// inline.
    private var linkMTUNote: some View {
        let mtu = controller.linkMTUBytes
        let fits = controller.effectiveMTUPayload == settings.mtuPayload
        let text = "The link to \(settings.clientAddress) reports an MTU of \(mtu) B, so the "
            + "largest packet that does not get split into IP fragments carries "
            + "\(mtu - lsIPv4UDPOverhead) B."
        return Text(text)
            .font(.caption)
            .foregroundStyle(fits ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var latencySection: some View {
        GroupBox("Latency") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Low-latency encoder and 4:2:0 capture", isOn: Binding(
                    get: { settings.lowLatencyEncoder && settings.captureYUV420 },
                    set: { settings.lowLatencyEncoder = $0; settings.captureYUV420 = $0 }))
                    .disabled(controller.isRunning)
                Text("Measured together as the encoder's hold time dropping from about "
                     + "16 ms to about 9 ms, with the p95 roughly halved. Costs about half "
                     + "a decibel of PSNR on hard content, and forces Constrained Baseline.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Send the pointer separately", isOn: $settings.forwardCursor)
                    .disabled(controller.isRunning)
                Text("The pointer is drawn by the client instead of being encoded into "
                     + "the video, so it lags by about a screen refresh rather than by the "
                     + "whole round trip. It will run slightly ahead of a window you drag.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.forwardCursor && controller.client.hasSaidHello
                    && !controller.client.drawsCursor {
                    Label("The connected client is too old to draw the pointer, so there "
                          + "will be no pointer on screen at all. Rebuild it, or turn this off.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    private var powerSection: some View {
        GroupBox("Power") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Wake the client when streaming starts and when this Mac wakes",
                       isOn: $settings.wakeClientAutomatically)
                Toggle("Keep this Mac at full performance while streaming",
                       isOn: $settings.preventAppNap)
                    .help("Opts out of App Nap and timer coalescing. Without it the "
                          + "picture degrades when you stop moving the cursor, because "
                          + "macOS treats an unfocused app on an idle system as "
                          + "something it can throttle.")
                if controller.isRunning {
                    Text(controller.fullPerformanceHeld
                         ? "Full performance asserted — macOS will not throttle this app"
                         : "Not asserted — macOS may throttle this app when you stop typing")
                        .font(.caption)
                        .foregroundStyle(controller.fullPerformanceHeld ? .green : .orange)
                }

                Toggle("Stop streaming when this Mac sleeps", isOn: $settings.stopOnSleep)
                    .help("Lets the client drop its keep-awake assertion so the iMac "
                          + "can sleep too, instead of sitting lit up showing a frozen frame.")

                HStack {
                    Text("Client MAC")
                    TextField("c4:2c:03:07:35:10", text: $settings.clientMACAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                    Button("Wake now") { controller.wakeClient(reason: "Manual") }
                        .disabled(settings.clientMACAddress.isEmpty)
                }

                Label("Filled in automatically the first time the client connects. "
                      + "macOS hides hardware addresses from apps, so this Mac cannot "
                      + "look it up on its own — to set it before the first connection, "
                      + "run `arp -n \(settings.clientAddress)` in Terminal and paste the result.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)

                Label("On the iMac, tick Energy Saver ▸ \"Wake for network access\", or the "
                      + "magic packet will be ignored.",
                      systemImage: "bolt")
                    .font(.caption).foregroundStyle(.secondary)

                if !controller.wakeStatus.isEmpty {
                    Text(controller.wakeStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    private var statsSection: some View {
        GroupBox("Live") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    stat("Sending", String(format: "%.1f Mb/s", controller.outgoingMbps))
                    stat("Encoded", String(format: "%.0f fps", controller.encodedFPS))
                    stat("Capture → wire", String(format: "%.1f ms", controller.hostPipelineMilliseconds))
                }
                GridRow {
                    stat("Client", controller.client.address)
                    stat("RTT", controller.client.rttMilliseconds > 0
                         ? String(format: "%.2f ms", controller.client.rttMilliseconds) : "—")
                    stat("Keyframe requests", "\(controller.keyframeRequests)")
                }
                GridRow {
                    stat("Client decode", controller.client.stats.decode_us > 0
                         ? String(format: "%.2f ms", Double(controller.client.stats.decode_us) / 1000) : "—")
                    stat("Client render", controller.client.stats.render_us > 0
                         ? String(format: "%.2f ms", Double(controller.client.stats.render_us) / 1000) : "—")
                    stat("Packets lost", "\(controller.client.stats.packets_lost)")
                }
                GridRow {
                    stat("Frames decoded", "\(controller.client.stats.frames_decoded)")
                    stat("Frames dropped", "\(controller.client.stats.frames_dropped)")
                    stat("Frames corrupt", "\(controller.client.stats.frames_corrupt)")
                }
            }
            .padding(6)

            if controller.isRunning && controller.client.stats.decode_us > 0 {
                Divider()
                HStack {
                    Text("Estimated glass-to-glass")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "≈ %.0f ms", controller.estimatedGlassToGlassMilliseconds))
                        .font(.system(.body, design: .monospaced).bold())
                    Text("capture→wire + RTT/2 + decode + render, plus one frame of capture")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
        .frame(minWidth: 130, alignment: .leading)
    }

    private func errorBox(_ text: String) -> some View {
        Label(text, systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningBox(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Encoder hints the hardware declined (stream still works):")
                .font(.caption).bold()
            ForEach(items, id: \.self) { Text($0).font(.caption.monospaced()) }
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
