import SwiftUI

// MARK: - Color from hex

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

// MARK: - Glass HUD design tokens

/// The locked "Glass HUD" visual language (see the design handoff README). Colors, radii, motion,
/// and reusable glass surfaces live here so every screen stays consistent.
enum Glass {
    // Core
    static let signal = Color(hex: 0x7FE9D0)
    static let signalDeep = Color(hex: 0x5FD9BE)
    static let signalInk = Color(hex: 0x0C1512)
    static let degraded = Color(hex: 0xF2B14F)
    static let danger = Color(hex: 0xFF6470)
    static let dangerText = Color(hex: 0xFF8A93)
    static let savedDot = Color(hex: 0xF2B14F)
    static let offlineDot = Color(hex: 0x46504E)

    // Text
    static let text1 = Color(hex: 0xEEF2F1)
    static let text1Bright = Color(hex: 0xF4F7F6)
    static let text2 = Color(hex: 0x8A968F)
    static let text3 = Color(hex: 0x6E7880)

    // Radii
    static let sheet: CGFloat = 18
    static let card: CGFloat = 16
    static let rail: CGFloat = 11
    static let button: CGFloat = 12

    // Motion
    /// The live pan/zoom cursor follow — critically damped, no overshoot. This is the real app value.
    static let cursorFollow = Animation.spring(response: 0.1, dampingFraction: 1.0)
    /// Quick, critically-damped panel/state transitions (no bounce).
    static let panel = Animation.spring(response: 0.3, dampingFraction: 1.0)

    static let accentFill = LinearGradient(
        colors: [signal, signalDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Fonts

extension Font {
    /// UI grotesque (System / SF — a neo-grotesque, per the README's blessed equivalent).
    static func grotesk(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Monospace for every numeric readout / label (SF Mono).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Canvas backgrounds

struct GlassCanvas<Content: View>: View {
    enum Style { case deck, live }
    let style: Style
    var bloom: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            background.ignoresSafeArea()
            if bloom {
                BloomGlow()
                    .offset(x: -40, y: -50)
                    .allowsHitTesting(false)
            }
            content
        }
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .deck:
            ZStack {
                Color(hex: 0x0C0F14)
                RadialGradient(
                    gradient: Gradient(colors: [Color(hex: 0x142028), .clear]),
                    center: UnitPoint(x: 0.2, y: 0), startRadius: 0, endRadius: 780)
            }
        case .live:
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x16323A), location: 0),
                    .init(color: Color(hex: 0x102229), location: 0.45),
                    .init(color: Color(hex: 0x0C0F14), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Soft accent glow, top-left of screens.
struct BloomGlow: View {
    var diameter: CGFloat = 260
    var body: some View {
        Circle()
            .fill(RadialGradient(
                gradient: Gradient(colors: [Glass.signal.opacity(0.18), .clear]),
                center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - Status dot (live pulse / saved / offline)

struct StatusDot: View {
    enum Kind { case live, onNetwork, degraded, saved, offline }
    let kind: Kind
    var size: CGFloat = 9
    @State private var expand = false

    private var color: Color {
        switch kind {
        case .live, .onNetwork: Glass.signal
        case .degraded: Glass.degraded
        case .saved: Glass.savedDot
        case .offline: Glass.offlineDot
        }
    }
    private var pulses: Bool { kind == .live || kind == .onNetwork || kind == .degraded }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: pulses ? color.opacity(0.8) : .clear, radius: pulses ? 6 : 0)
            .overlay {
                if pulses {
                    Circle()
                        .stroke(color, lineWidth: 1.5)
                        .scaleEffect(expand ? 2.6 : 1)
                        .opacity(expand ? 0 : 0.6)
                }
            }
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: false)) {
                    expand = true
                }
            }
    }
}

// MARK: - Pill badge

struct PillBadge: View {
    enum Style { case accent, amber, neutral }
    let text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.mono(9, .semibold))
            .tracking(0.9)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if style == .amber {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Glass.degraded.opacity(0.5), lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .accent: Glass.signalInk
        case .amber: Glass.degraded
        case .neutral: Glass.text3
        }
    }
    private var background: Color {
        switch style {
        case .accent: Glass.signal
        case .amber: Glass.degraded.opacity(0.0)
        case .neutral: .clear
        }
    }
}

// MARK: - Glass surfaces (Material-backed)

private struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tintOpacity: Double
    var borderAccent: Bool
    var accentGradientFill: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(fillStyle)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        borderAccent ? Glass.signal.opacity(0.28) : Color.white.opacity(0.12),
                        lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // Subtle inset top highlight.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
    }

    private var fillStyle: AnyShapeStyle {
        if accentGradientFill {
            return AnyShapeStyle(LinearGradient(
                colors: [Glass.signal.opacity(0.14), Color.white.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(Color(hex: 0x0E161A, opacity: tintOpacity))
    }
}

extension View {
    /// A floating control panel / sheet / toast (heavier dark glass).
    func glassPanel(cornerRadius: CGFloat = Glass.sheet, accent: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tintOpacity: 0.66,
                              borderAccent: accent, accentGradientFill: false))
    }

    /// A list tile / control button surface (lighter glass). `accent` gives the live-tile gradient.
    func glassCard(cornerRadius: CGFloat = Glass.card, accent: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tintOpacity: 0.30,
                              borderAccent: accent, accentGradientFill: accent))
    }

    /// A dark telemetry / activity well.
    func telemetryWell(cornerRadius: CGFloat = 10) -> some View {
        background(Color.black.opacity(0.22),
                   in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
    }

    /// Mono uppercase label / eyebrow.
    func eyebrow(_ size: CGFloat = 10) -> some View {
        font(.mono(size, .semibold)).textCase(.uppercase).tracking(size * 0.12)
    }
}

// MARK: - Button styles

struct AccentButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Glass.sheet
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.grotesk(15, .bold))
            .foregroundStyle(Glass.signalInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Glass.accentFill,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Glass.signal.opacity(0.4), radius: 16, y: 9)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}
