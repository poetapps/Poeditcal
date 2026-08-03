import AppKit
import SwiftUI

enum PoetTheme {
    static let background = Color(hex: 0x0B0C0B)
    static let card = Color(hex: 0x131513)
    static let elevated = Color(hex: 0x1C1F1C)
    static let elevatedHover = Color(hex: 0x242824)
    static let cream = Color(hex: 0xF2EDE1)
    static let muted = Color(hex: 0x97958D)
    static let faint = Color(hex: 0x5F625D)
    static let sage = Color(hex: 0x8EA786)
    static let sageDark = Color(hex: 0x283228)
    static let amber = Color(hex: 0xD98B35)
    static let amberDark = Color(hex: 0x382719)
    static let error = Color(hex: 0xD96E66)
    static let divider = Color.white.opacity(0.065)

    static func editorial(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        liberationSans(size, weight: weight)
    }

    static func utility(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        liberationSans(size, weight: weight)
    }

    private static func liberationSans(_ size: CGFloat, weight: Font.Weight) -> Font {
        let face = weight == .bold || weight == .semibold || weight == .heavy ? "Liberation Sans Bold" : "Liberation Sans"
        if NSFont(name: face, size: size) != nil { return .custom(face, size: size) }
        return .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

struct PoetCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(PoetTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoetTheme.utility(compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(PoetTheme.background)
            .padding(.horizontal, compact ? 16 : 22)
            .frame(height: compact ? 38 : 46)
            .background(PoetTheme.sage.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoetTheme.utility(14, weight: .semibold))
            .foregroundStyle(PoetTheme.cream)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(configuration.isPressed ? PoetTheme.elevatedHover : PoetTheme.elevated)
            .clipShape(Capsule())
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(PoetTheme.utility(11, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(PoetTheme.sage)
    }
}

struct MagneticStepSlider: View {
    let stepCount: Int
    @Binding var selectedIndex: Int
    @State private var draggedProgress: CGFloat?

    private var selectedProgress: CGFloat {
        guard stepCount > 1 else { return 0 }
        return CGFloat(selectedIndex) / CGFloat(stepCount - 1)
    }

    private var displayedProgress: CGFloat { draggedProgress ?? selectedProgress }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                Capsule()
                    .fill(PoetTheme.elevated)
                    .frame(height: 7)

                HStack(spacing: 0) {
                    Capsule()
                        .fill(PoetTheme.sage.opacity(0.66))
                        .frame(width: max(7, width * displayedProgress), height: 7)
                    Spacer(minLength: 0)
                }

                ForEach(0..<stepCount, id: \.self) { index in
                    let progress = CGFloat(index) / CGFloat(max(stepCount - 1, 1))
                    Circle()
                        .fill(index <= nearestDisplayedIndex ? PoetTheme.sage : PoetTheme.elevatedHover)
                        .frame(width: 12, height: 12)
                        .position(x: width * progress, y: geometry.size.height / 2)
                }

                Circle()
                    .fill(PoetTheme.sage)
                    .frame(width: 25, height: 25)
                    .shadow(color: PoetTheme.sage.opacity(0.2), radius: 8)
                    .position(x: width * displayedProgress, y: geometry.size.height / 2)
                    .animation(.spring(response: 0.3, dampingFraction: 0.72), value: displayedProgress)
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let raw = min(max(value.location.x / max(width, 1), 0), 1)
                        draggedProgress = magnetized(raw)
                    }
                    .onEnded { value in
                        let raw = min(max(value.location.x / max(width, 1), 0), 1)
                        let nearest = Int((raw * CGFloat(stepCount - 1)).rounded())
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
                            selectedIndex = min(max(nearest, 0), stepCount - 1)
                            draggedProgress = nil
                        }
                    }
            )
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel("Choice slider")
        .accessibilityValue("Option \(selectedIndex + 1) of \(stepCount)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selectedIndex = min(selectedIndex + 1, stepCount - 1)
            case .decrement: selectedIndex = max(selectedIndex - 1, 0)
            @unknown default: break
            }
        }
    }

    private var nearestDisplayedIndex: Int {
        min(max(Int((displayedProgress * CGFloat(max(stepCount - 1, 1))).rounded()), 0), stepCount - 1)
    }

    private func magnetized(_ progress: CGFloat) -> CGFloat {
        let interval = 1 / CGFloat(max(stepCount - 1, 1))
        let nearest = (progress / interval).rounded() * interval
        return abs(progress - nearest) < interval * 0.13 ? nearest : progress
    }
}
