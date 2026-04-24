import SwiftUI

extension Color {
    /// Pure dark background: #080808
    static let clayBackground = Color(red: 0.031, green: 0.031, blue: 0.031)
    static let clayCanvas = Color.clayBackground

    /// Warm cream text: #EDE8DF
    static let clayText = Color(red: 0.930, green: 0.910, blue: 0.874)

    /// Secondary text: warm cream at 55% opacity
    static let clayTextMuted = Color.clayText.opacity(0.55)
    static let clayTextDim = Color.clayTextMuted

    /// Clay surface: white at 3% opacity
    static let claySurface = Color.white.opacity(0.03)

    /// Active/selected state: warm cream at 8% fill
    static let clayActive = Color.clayText.opacity(0.08)

    /// Border color: warm cream at 14% opacity
    static let clayBorder = Color.clayText.opacity(0.14)
    static let clayDivider = Color.clayBorder

    /// Highlight color for borders
    static let clayHighlight = Color.white.opacity(0.06)

    /// Hover state: white at 5%
    static let clayHover = Color.white.opacity(0.05)

    /// Ghost number color: warm cream at 10% opacity
    static let ghostNumber = Color.clayText.opacity(0.10)

    /// Decorative element color: warm cream at 12% opacity
    static let clayDecorative = Color.clayText.opacity(0.12)

    /// Agent running status: desaturated green #7FB069
    static let agentRunning = Color(red: 0.498, green: 0.690, blue: 0.412)
    static let clayRunning = Color.agentRunning

    /// Agent idle status: gray #555
    static let agentIdle = Color(red: 0.333, green: 0.333, blue: 0.333)
    static let clayIdle = Color.agentIdle
}

/// Typography constants
enum ClayFont {
    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let tiny = Font.system(size: 11)
    static let ghost = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let sectionLabel = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

/// Clay card modifier with inset highlight
struct ClayCard: ViewModifier {
    let isActive: Bool
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Base surface: white at 3% opacity
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.claySurface)

                    // Top inset highlight: 1px at white 6%
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.clayHighlight, lineWidth: 1)
                        .mask(
                            VStack(spacing: 0) {
                                Rectangle().frame(height: 1)
                                Spacer()
                            }
                        )
                }
            )
            .overlay(
                Group {
                    // Active state: warm cream at 8% fill, 1px border at 14%
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.clayActive)
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.clayBorder, lineWidth: 1)
                }
                .opacity(isActive ? 1 : 0)
            )
    }
}

extension View {
    func clayCard(isActive: Bool = false, radius: CGFloat = 10) -> some View {
        self.modifier(ClayCard(isActive: isActive, radius: radius))
    }
}

/// Ghost step number for section enumeration (01, 02, 03...)
/// Always call as GhostNumber(x) — positional only.
struct GhostNumber: View {
    let n: Int

    init(_ n: Int) { self.n = n }

    var body: some View {
        Text(String(format: "%02d", n))
            .font(ClayFont.ghost)
            .monospacedDigit()
            .foregroundStyle(Color.ghostNumber)
            .kerning(1)
    }
}

/// Blueprint-style decorative SVG line art (1px strokes, no fills, cream color)
struct BlueprintMark: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 20, y: 0))
                path.addLine(to: CGPoint(x: 20, y: 4))
                path.move(to: CGPoint(x: 0, y: 8))
                path.addLine(to: CGPoint(x: 12, y: 8))
                path.addLine(to: CGPoint(x: 12, y: 12))
            }
            .stroke(Color.clayText, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 20, height: 12)
    }
}

/// Reticle mark (alternative decorative element)
struct ReticleMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.clayText, lineWidth: 1)
                .frame(width: size, height: size)
            Circle()
                .stroke(Color.clayText, lineWidth: 1)
                .frame(width: size * 0.4, height: size * 0.4)
            Rectangle()
                .fill(Color.clayText)
                .frame(width: size, height: 1)
            Rectangle()
                .fill(Color.clayText)
                .frame(width: 1, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// Orbit diagram for empty state
struct OrbitDiagram: View {
    var size: CGFloat = 200

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.clayDecorative, lineWidth: 1)
                .frame(width: size, height: size)
            Circle()
                .stroke(Color.clayDecorative, lineWidth: 1)
                .frame(width: size * 0.6, height: size * 0.6)
            Circle()
                .stroke(Color.clayDecorative, lineWidth: 1)
                .frame(width: size * 0.3, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}
