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

/// The Glass HUD design tokens for the macOS host (mirrors the iOS client's `Glass`; the two apps
/// are separate targets so the language is duplicated rather than shared through the SwiftPM core).
enum Glass {
    static let signal = Color(hex: 0x7FE9D0)
    static let signalDeep = Color(hex: 0x5FD9BE)
    static let signalInk = Color(hex: 0x0C1512)
    static let degraded = Color(hex: 0xF2B14F)
    static let danger = Color(hex: 0xFF6470)
    static let dangerText = Color(hex: 0xFF8A93)

    static let text1 = Color(hex: 0xEEF2F1)
    static let text1Bright = Color(hex: 0xF4F7F6)
    static let text2 = Color(hex: 0x8A968F)
    static let text3 = Color(hex: 0x6E7880)

    static let card: CGFloat = 14
    static let well: CGFloat = 10

    static let accentFill = LinearGradient(
        colors: [signal, signalDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Font {
    static func grotesk(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Canvas + bloom

struct GlassCanvas<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x16323A), location: 0),
                    .init(color: Color(hex: 0x102229), location: 0.45),
                    .init(color: Color(hex: 0x0C0F14), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [Glass.signal.opacity(0.18), .clear]),
                    center: .center, startRadius: 0, endRadius: 140))
                .frame(width: 280, height: 280)
                .offset(x: -40, y: -60)
                .allowsHitTesting(false)
            content
        }
    }
}

// MARK: - Glass surfaces

private struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var accent: Bool
    var accentGradientFill: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(accent ? Glass.signal.opacity(0.24) : Color.white.opacity(0.10), lineWidth: 1)
            }
    }

    private var fill: AnyShapeStyle {
        accentGradientFill
            ? AnyShapeStyle(LinearGradient(colors: [Glass.signal.opacity(0.12), Color.white.opacity(0.03)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(Color.white.opacity(0.04))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = Glass.card, accent: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, accent: accent, accentGradientFill: accent))
    }
    func telemetryWell(cornerRadius: CGFloat = Glass.well) -> some View {
        background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
    }
    func eyebrow(_ size: CGFloat = 9) -> some View {
        font(.mono(size, .semibold)).textCase(.uppercase).tracking(size * 0.08)
    }
}

// MARK: - Status dot

struct StatusDot: View {
    enum Kind { case signal, amber, offline }
    let kind: Kind
    var size: CGFloat = 8
    @State private var expand = false

    private var color: Color {
        switch kind {
        case .signal: Glass.signal
        case .amber: Glass.degraded
        case .offline: Glass.text3
        }
    }
    private var pulses: Bool { kind == .signal }

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: pulses ? color.opacity(0.8) : .clear, radius: pulses ? 6 : 0)
            .overlay {
                if pulses {
                    Circle().stroke(color, lineWidth: 1.5)
                        .scaleEffect(expand ? 2.6 : 1).opacity(expand ? 0 : 0.6)
                }
            }
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: false)) { expand = true }
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
            .font(.mono(9, .semibold)).tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                if style == .amber {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
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
        case .amber, .neutral: .clear
        }
    }
}

// MARK: - Button styles (compact macOS chrome)

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.grotesk(14, .semibold)).foregroundStyle(Glass.signalInk)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Glass.accentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Glass.signal.opacity(0.35), radius: 11, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct NeutralButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.grotesk(14, .semibold)).foregroundStyle(Glass.text1)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Outline button in a token color (amber "Open Settings", danger "Disconnect").
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.grotesk(12.5, .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
