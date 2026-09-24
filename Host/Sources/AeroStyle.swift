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

// The 2000s Aero look, rebuilt from its three actual ingredients: a cold blue
// glass, a hard gloss across the top half of everything, and a 1px white inner
// bevel that fakes a lit edge. Nothing here is a system material — Aero predates
// them and they look nothing alike.
//
// Everything is drawn light. Aero never had a dark mode, and a half-dark version
// of it reads as a bug rather than as a style, so the panel pins its own colour
// scheme rather than following the system.
enum Aero {

    // MARK: - Palette

    static let glassTop    = Color(red: 0.91, green: 0.96, blue: 1.00)
    static let glassMid    = Color(red: 0.78, green: 0.89, blue: 0.98)
    static let glassBottom = Color(red: 0.62, green: 0.79, blue: 0.93)

    static let chromeTop    = Color(red: 0.36, green: 0.62, blue: 0.86)
    static let chromeBottom = Color(red: 0.16, green: 0.38, blue: 0.68)

    static let ink      = Color(red: 0.06, green: 0.15, blue: 0.28)
    static let inkFaint = Color(red: 0.24, green: 0.36, blue: 0.50)

    static let blue   = Color(red: 0.24, green: 0.56, blue: 0.88)
    static let green  = Color(red: 0.42, green: 0.78, blue: 0.20)
    static let amber  = Color(red: 0.98, green: 0.71, blue: 0.10)
    static let red    = Color(red: 0.86, green: 0.22, blue: 0.16)
    static let violet = Color(red: 0.52, green: 0.38, blue: 0.82)

    static let hairline = Color(red: 0.24, green: 0.42, blue: 0.62)

    // MARK: - Building blocks

    /// The hard gloss that sits across the top half of every Aero surface. The
    /// abrupt edge halfway down is the whole point — a soft fade reads as a
    /// modern gradient, not as glass.
    struct Gloss: View {
        var cornerRadius: CGFloat = 5
        var strength: Double = 0.70

        var body: some View {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.white.opacity(strength), .white.opacity(strength * 0.28)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(height: geo.size.height * 0.5)
                    // Below the waist Aero put a faint upward bounce of light
                    // rather than leaving it flat.
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(strength * 0.22)],
                            startPoint: .top, endPoint: .bottom))
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .allowsHitTesting(false)
        }
    }

    /// The 1px lit edge just inside the border, plus the darker border itself.
    struct Bevel: View {
        var cornerRadius: CGFloat = 5
        var edge: Color = .white.opacity(0.85)
        var border: Color = Aero.hairline.opacity(0.75)

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 1)
                    .strokeBorder(edge, lineWidth: 1)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }

    /// The panel background: blue glass with a broad specular smear near the top
    /// left, the way a lit sheet of glass actually behaves.
    struct GlassBackground: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [glassTop, glassMid, glassBottom],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [.white.opacity(0.75), .white.opacity(0)],
                               center: UnitPoint(x: 0.22, y: -0.12),
                               startRadius: 0, endRadius: 320)
                RadialGradient(colors: [violet.opacity(0.16), .clear],
                               center: UnitPoint(x: 1.05, y: 1.1),
                               startRadius: 0, endRadius: 260)
            }
            .ignoresSafeArea()
        }
    }

    /// A glossy LED. Aero's status lights were spheres, so this is a radial fill
    /// with an off-centre specular dot and a bloom around the outside.
    struct Orb: View {
        var colour: Color
        var diameter: CGFloat = 13
        var lit: Bool = true

        var body: some View {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [colour.opacity(lit ? 0.55 : 0), .clear],
                        center: .center, startRadius: diameter * 0.35,
                        endRadius: diameter * 1.15))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                // Lit from the upper left: white at the highlight, the colour
                // itself across the middle, and a darkened rim. Fading the
                // alpha instead would just wash the whole thing out against
                // light glass, which is what the first version of this did.
                Circle()
                    .fill(RadialGradient(
                        colors: [colour.blended(with: .white, amount: lit ? 0.62 : 0.45),
                                 colour.blended(with: .white, amount: lit ? 0.10 : 0.30),
                                 colour.blended(with: .black, amount: lit ? 0.32 : 0.10)],
                        center: UnitPoint(x: 0.34, y: 0.26),
                        startRadius: 0, endRadius: diameter * 0.80))
                    .overlay(Circle().strokeBorder(
                        colour.blended(with: .black, amount: 0.55).opacity(0.7), lineWidth: 0.75))
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: diameter * 0.44, height: diameter * 0.26)
                    .offset(x: -diameter * 0.07, y: -diameter * 0.27)
            }
            .frame(width: diameter, height: diameter)
        }
    }

    // MARK: - Meters

    /// Vista's progress bar: a recessed trough with a glossy bar in it. The
    /// bar is capped at full rather than overflowing, and the caller decides
    /// what "full" means.
    struct Meter: View {
        var label: String
        var value: String
        var fraction: Double
        var colour: Color = Aero.green
        var live: Bool = true

        var body: some View {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Aero.inkFaint)
                    .frame(width: 74, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Recessed: dark at the top where the lip casts into
                        // it, lighter at the bottom.
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(white: 0.66), Color(white: 0.90)],
                                startPoint: .top, endPoint: .bottom))
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Aero.hairline.opacity(0.5), lineWidth: 1))

                        let w = max(0, min(1, fraction)) * geo.size.width
                        if w > 1 {
                            ZStack {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [colour.blended(with: .white, amount: 0.30),
                                                 colour,
                                                 colour.blended(with: .black, amount: 0.18)],
                                        startPoint: .top, endPoint: .bottom))
                                Gloss(cornerRadius: 3, strength: 0.50)
                                Bevel(cornerRadius: 3,
                                      edge: .white.opacity(0.55),
                                      border: colour.blended(with: .black, amount: 0.40))
                            }
                            .frame(width: w)
                            .shadow(color: colour.opacity(live ? 0.45 : 0), radius: 3, y: 0)
                        }
                    }
                }
                .frame(height: 11)
                .opacity(live ? 1 : 0.5)

                Text(value)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Aero.ink)
                    .frame(width: 62, alignment: .trailing)
            }
            .animation(.easeOut(duration: 0.28), value: fraction)
        }
    }

    // MARK: - Panels

    /// A titled glass sub-panel — Aero's group box, which was a lighter sheet
    /// laid on the window glass rather than an outlined box.
    struct Group<Content: View>: View {
        var title: String
        var accent: Color = Aero.blue
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Capsule().fill(accent).frame(width: 3, height: 10)
                    Text(title.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(accent.blended(with: .black, amount: 0.38))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.top, 6)
                .padding(.bottom, 5)

                content()
                    .padding(.horizontal, 9)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.88), .white.opacity(0.42)],
                                             startPoint: .top, endPoint: .bottom))
                    Bevel(cornerRadius: 6,
                          edge: .white.opacity(0.9),
                          border: Aero.hairline.opacity(0.45))
                }
                .compositingGroup()
                .shadow(color: Aero.hairline.opacity(0.22), radius: 2, y: 1)
            )
        }
    }
}

// MARK: - Controls

/// The glossy Aero button: gradient body, hard gloss on the top half, lit inner
/// edge, and a coloured bloom on hover that Vista used to show focus.
struct AeroButtonStyle: ButtonStyle {
    enum Kind { case primary, stop, plain }

    var kind: Kind = .plain
    var big: Bool = false

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    private var base: Color {
        switch kind {
        case .primary: return Aero.green
        case .stop:    return Aero.red
        // Not a neutral grey: Aero's ordinary buttons were tinted the same
        // blue as the glass they sat on.
        case .plain:   return Color(red: 0.72, green: 0.82, blue: 0.92)
        }
    }

    private var label: Color {
        kind == .plain ? Aero.ink : .white
    }

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = big ? 6 : 5
        let pressed = configuration.isPressed

        configuration.label
            .font(.system(size: big ? 13 : 11, weight: big ? .bold : .semibold))
            .foregroundStyle(enabled ? label : label.opacity(0.4))
            .shadow(color: kind == .plain ? .white.opacity(0.8) : .black.opacity(0.35),
                    radius: 0.8, y: kind == .plain ? 0.5 : 0.5)
            .padding(.horizontal, big ? 16 : 10)
            .padding(.vertical, big ? 8 : 4)
            .frame(maxWidth: big ? .infinity : nil)
            .background(
                ZStack {
                    // Lighter at the top, darker at the bottom, and inverted
                    // while held down. Shading by lightness rather than by
                    // alpha is what makes this read as a lit surface instead of
                    // a flat tint.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(
                            colors: pressed
                                ? [base.blended(with: .black, amount: 0.22),
                                   base.blended(with: .black, amount: 0.06)]
                                : [base.blended(with: .white, amount: kind == .plain ? 0.38 : 0.28),
                                   base.blended(with: .black, amount: kind == .plain ? 0.06 : 0.16)],
                            startPoint: .top, endPoint: .bottom))
                    Aero.Gloss(cornerRadius: radius, strength: pressed ? 0.22 : 0.58)
                    Aero.Bevel(cornerRadius: radius,
                               edge: .white.opacity(pressed ? 0.35 : 0.8),
                               border: base.blended(with: .black,
                                                    amount: kind == .plain ? 0.45 : 0.38))
                }
                .compositingGroup()
                .shadow(color: .black.opacity(pressed ? 0.05 : 0.18),
                        radius: pressed ? 1 : 2, y: pressed ? 0 : 1)
                .shadow(color: (kind == .plain ? Aero.blue : base)
                            .opacity(hovering && enabled && !pressed ? 0.5 : 0),
                        radius: 6)
            )
            .opacity(enabled ? 1 : 0.55)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A glass rocker switch. Aero didn't have a switch control, so this is the
/// nearest honest thing: a recessed slot with a glossy knob in it, coloured
/// when on.
struct AeroToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        // Deliberately not a Button. A disabled Button dims its own label, and
        // that dimming lands on top of whatever the style does, which left a
        // switched-on-but-disabled row looking switched off. Doing the hit
        // testing by hand means the greying is mine alone: the switch keeps
        // almost all of its contrast and only the text recedes.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switchBody(on: configuration.isOn)
                .alignmentGuide(.firstTextBaseline) { $0.height - 3 }
                .opacity(enabled ? 1 : 0.88)
            configuration.label
                .font(.system(size: 11))
                .foregroundStyle(enabled ? Aero.ink : Aero.inkFaint.opacity(0.75))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { configuration.isOn.toggle() } }
    }

    private func switchBody(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            // Off is a recessed grey slot; on fills it with lit green. Both
            // keep their contrast when the row is disabled, so a greyed-out
            // switch still reads as on or off.
            Capsule()
                .fill(LinearGradient(
                    colors: on ? [Aero.green.blended(with: .black, amount: 0.12),
                                  Aero.green.blended(with: .white, amount: 0.18)]
                               : [Color(white: 0.60), Color(white: 0.84)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(
                    on ? Aero.green.blended(with: .black, amount: 0.45)
                       : Aero.hairline.opacity(0.65), lineWidth: 1))
                .frame(width: 30, height: 15)
            ZStack {
                Circle().fill(LinearGradient(colors: [.white, Color(white: 0.84)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(Aero.hairline.opacity(0.55), lineWidth: 0.75)
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 7, height: 4).offset(y: -2.5)
            }
            .frame(width: 13, height: 13)
            .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
            .padding(.horizontal, 1)
        }
        .frame(width: 30, height: 15)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: on)
    }
}

/// Restyles every `GroupBox` in the settings window without touching the call
/// sites, which is why the window could be reskinned without rewriting it. The
/// caller's own label is drawn rather than being read back out of it, so a
/// GroupBox titled with anything other than a plain string still works.
struct AeroGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Capsule().fill(Aero.blue).frame(width: 3, height: 10)
                configuration.label
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Aero.blue.blended(with: .black, amount: 0.38))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            configuration.content
                .font(.system(size: 11))
                .foregroundStyle(Aero.ink)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0.24)],
                                         startPoint: .top, endPoint: .bottom))
                Aero.Bevel(cornerRadius: 6,
                           edge: .white.opacity(0.8),
                           border: Aero.hairline.opacity(0.35))
            }
        )
    }
}

extension Color {
    /// Mixes two colours in sRGB. Used for border shades that need to track a
    /// tint rather than being hand-picked for each one.
    func blended(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = max(0, min(1, amount))
        return Color(red:   Double(a.redComponent)   * (1 - t) + Double(b.redComponent)   * t,
                     green: Double(a.greenComponent) * (1 - t) + Double(b.greenComponent) * t,
                     blue:  Double(a.blueComponent)  * (1 - t) + Double(b.blueComponent)  * t)
    }
}
