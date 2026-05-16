import AppKit
import SwiftUI

enum DesignTokens {
    static let background = neutral950InDark(light: .white)
    static let sidebarBackground = neutral900InDark(light: nsColor(250, 250, 250))
    static let panel = neutral800InDark(light: nsColor(245, 245, 245))
    static let text = neutral100InDark(light: nsColor(23, 23, 23))
    static let secondaryText = neutral400InDark(light: nsColor(82, 82, 82))
    static let tertiaryText = neutral500InDark(light: nsColor(115, 115, 115))
    static let separator = neutral800InDark(light: nsColor(229, 229, 229))
    static let accent = Color(nsColor: nsColor(37, 99, 235))

    static let neutral50 = neutral900InDark(light: nsColor(250, 250, 250))
    static let neutral100 = neutral800InDark(light: nsColor(245, 245, 245))
    static let neutral200 = neutral700InDark(light: nsColor(229, 229, 229))
    static let neutral300 = neutral600InDark(light: nsColor(212, 212, 212))
    static let neutral400 = neutral500InDark(light: nsColor(163, 163, 163))
    static let neutral500 = neutral400InDark(light: nsColor(115, 115, 115))
    static let neutral600 = neutral300InDark(light: nsColor(82, 82, 82))
    static let neutral700 = neutral200InDark(light: nsColor(64, 64, 64))
    static let neutral800 = neutral100InDark(light: nsColor(38, 38, 38))
    static let neutral900 = neutral50InDark(light: nsColor(23, 23, 23))

    static let danger = Color(nsColor: nsColor(239, 68, 68))
    static let success = Color(nsColor: nsColor(34, 197, 94))
    static let warning = Color(nsColor: nsColor(245, 158, 11))
    static let radius: CGFloat = 8
    static let smallRadius: CGFloat = 6
    static let largeRadius: CGFloat = 12
    static let userBubbleRadius: CGFloat = 22
    static let headerHeight: CGFloat = 48

    static let sidebarMinWidth: CGFloat = 200
    static let sidebarDefaultWidth: CGFloat = 248
    static let sidebarMaxWidth: CGFloat = 480
    static let sidebarHeaderHeight: CGFloat = 64
    static let sidebarSegmentHeight: CGFloat = 28
    static let sidebarProjectRowHeight: CGFloat = 32
    static let sidebarFooterHeight: CGFloat = 54

    static let composerMaxWidth: CGFloat = 720
    static let composerTextMinHeight: CGFloat = 48
    static let filesChatDefaultWidth: CGFloat = 460
    static let filesChatMinWidth: CGFloat = 320
    static let filesPaneMinWidth: CGFloat = 280

    static func selectedRowFill() -> Color {
        neutral200.opacity(0.70)
    }

    static func hoverFill() -> Color {
        neutral100
    }

    private static func neutral950InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(10, 10, 10))
    }

    private static func neutral900InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(23, 23, 23))
    }

    private static func neutral800InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(38, 38, 38))
    }

    private static func neutral700InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(64, 64, 64))
    }

    private static func neutral600InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(82, 82, 82))
    }

    private static func neutral500InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(115, 115, 115))
    }

    private static func neutral400InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(163, 163, 163))
    }

    private static func neutral300InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(212, 212, 212))
    }

    private static func neutral200InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(229, 229, 229))
    }

    private static func neutral100InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(245, 245, 245))
    }

    private static func neutral50InDark(light: NSColor) -> Color {
        adaptive(light: light, dark: nsColor(250, 250, 250))
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        })
    }

    private static func nsColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            red: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }
}

struct NativePillButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(isActive ? DesignTokens.neutral100 : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct SidebarRowStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(height: DesignTokens.sidebarProjectRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .fill(isActive ? DesignTokens.selectedRowFill() : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
