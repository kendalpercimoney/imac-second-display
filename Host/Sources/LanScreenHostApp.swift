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
    @StateObject private var settings = StreamSettings()
    @StateObject private var controller: StreamController

    init() {
        let settings = StreamSettings()
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: StreamController(settings: settings))
    }

    var body: some Scene {
        Window("LanScreen Host", id: "main") {
            ContentView(settings: settings, controller: controller)
                .frame(minWidth: 560, minHeight: 620)
                .task { await controller.refreshDisplays() }
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @ObservedObject var settings: StreamSettings
    @ObservedObject var controller: StreamController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                sourceSection
                destinationSection
                videoSection
                networkSection
                powerSection
                Divider()
                statsSection
                if let error = controller.lastError { errorBox(error) }
                if !controller.warnings.isEmpty { warningBox(controller.warnings) }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            Text(controller.statusText).font(.headline)
            Spacer()
            Button(controller.isRunning ? "Stop" : "Start") {
                controller.isRunning ? controller.stop() : controller.start()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
        }
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
                    Label("A real second monitor, not a mirror. Arrange it in "
                          + "System Settings ▸ Displays.",
                          systemImage: "display.2")
                        .font(.caption).foregroundStyle(.secondary)

                    if !controller.virtualDisplaySupported {
                        Label("No CGVirtualDisplay on this macOS. Use an HDMI dummy "
                              + "plug and capture it as an existing display.",
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
                        .gridCellColumns(5)
                }
            }
            .padding(6)
            .disabled(controller.isRunning)

            if settings.height > 1080 {
                Label("Above 1080p the 2010 iMac falls back to software decoding.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 6)
            }
        }
    }

    /// Split out of the Network section because the type checker gave up on it
    /// inline.
    private var linkMTUNote: some View {
        let mtu = controller.linkMTUBytes
        let fits = controller.effectiveMTUPayload == settings.mtuPayload
        let text = "Link MTU \(mtu) B — up to \(mtu - lsIPv4UDPOverhead) B per packet "
            + "without IP fragmentation."
        return Text(text)
            .font(.caption)
            .foregroundStyle(fits ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .fixedSize(horizontal: false, vertical: true)
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

                HStack {
                    Button("Force keyframe") { controller.requestKeyframeNow() }
                        .disabled(!controller.isRunning)
                    if let path = controller.sdpPath {
                        Button("Reveal test .sdp") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        Text("for VLC")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    private var powerSection: some View {
        GroupBox("Power") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Wake the client on start, and when this Mac wakes",
                       isOn: $settings.wakeClientAutomatically)
                Toggle("Keep this Mac at full performance", isOn: $settings.preventAppNap)
                    .help("Opts out of App Nap and timer coalescing, which otherwise "
                          + "degrade the picture when you stop moving the cursor.")
                if controller.isRunning {
                    Text(controller.fullPerformanceHeld
                         ? "Full performance asserted — macOS will not throttle this app"
                         : "Not asserted — macOS may throttle this app when you stop typing")
                        .font(.caption)
                        .foregroundStyle(controller.fullPerformanceHeld ? .green : .orange)
                }

                Toggle("Stop streaming when this Mac sleeps", isOn: $settings.stopOnSleep)
                    .help("Lets the iMac sleep too, rather than sitting lit up on a "
                          + "frozen frame.")

                HStack {
                    Text("Client MAC")
                    TextField("c4:2c:03:07:35:10", text: $settings.clientMACAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                    Button("Wake now") { controller.wakeClient(reason: "Manual") }
                        .disabled(settings.clientMACAddress.isEmpty)
                }

                Label("Learned when the client first connects. macOS hides hardware "
                      + "addresses from apps, so to set it sooner run "
                      + "`arp -n \(settings.clientAddress)` and paste the result.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)

                Label("The iMac needs Energy Saver ▸ \"Wake for network access\".",
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
                    Text(String(format: "≈ %.0f ms", latencyEstimate))
                        .font(.system(.body, design: .monospaced).bold())
                    Text("capture→wire + RTT/2 + decode + render")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
            }
        }
    }

    private var latencyEstimate: Double {
        // Host side is measured directly. Network is half the round trip. The
        // client reports its own decode and render times.
        controller.hostPipelineMilliseconds
            + controller.client.rttMilliseconds / 2.0
            + Double(controller.client.stats.decode_us) / 1000.0
            + Double(controller.client.stats.render_us) / 1000.0
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
            Text("Encoder hints declined:")
                .font(.caption).bold()
            ForEach(items, id: \.self) { Text($0).font(.caption.monospaced()) }
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
