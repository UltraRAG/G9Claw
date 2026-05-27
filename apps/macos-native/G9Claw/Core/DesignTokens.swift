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

    static let popover = neutral900InDark(light: .white)
    static let card = neutral950InDark(light: .white)
    static let contentSurface = adaptive(light: nsColor(255, 255, 255, 0.88), dark: nsColor(24, 24, 26, 0.78))
    static let cardSurface = adaptive(light: nsColor(255, 255, 255, 0.74), dark: nsColor(30, 30, 32, 0.72))
    static let cardSurfaceSubtle = adaptive(light: nsColor(250, 250, 250, 0.64), dark: nsColor(38, 38, 40, 0.58))
    static let controlSurface = adaptive(light: nsColor(255, 255, 255, 0.48), dark: nsColor(46, 46, 48, 0.46))
    static let controlSurfaceActive = adaptive(light: nsColor(255, 255, 255, 0.82), dark: nsColor(58, 58, 60, 0.70))
    static let modalSurface = adaptive(light: nsColor(255, 255, 255, 0.96), dark: nsColor(24, 24, 26, 0.96))
    static let sidebarOverlay = adaptive(light: nsColor(248, 248, 248, 0.18), dark: nsColor(22, 22, 24, 0.26))
    static let mutedForeground = adaptive(light: nsColor(115, 115, 115), dark: nsColor(163, 163, 163))
    static let ring = adaptive(light: nsColor(77, 77, 77), dark: nsColor(163, 163, 163))
    static let destructiveForeground = adaptive(light: nsColor(250, 250, 250), dark: nsColor(250, 250, 250))

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
    static let headerHeight: CGFloat = 44

    static let sidebarMinWidth: CGFloat = 200
    static let sidebarDefaultWidth: CGFloat = 248
    static let sidebarMaxWidth: CGFloat = 320
    static let sidebarContentTopPadding: CGFloat = headerHeight + 8
    static let sidebarSegmentHeight: CGFloat = 28
    static let sidebarProjectRowHeight: CGFloat = 32
    static let sidebarFooterHeight: CGFloat = 54
    static let titlebarSidebarButtonLeading: CGFloat = 78
    static let titlebarControlSize: CGFloat = 32
    static let titlebarSidebarGlyphSize: CGFloat = 14
    static let titlebarContentReserveWhenSidebarHidden: CGFloat = 120
    static let titlebarControlTop: CGFloat = 0

    static let composerMaxWidth: CGFloat = 688
    static let composerTextMinHeight: CGFloat = 44
    static let transcriptMaxWidth: CGFloat = 824
    static let transcriptPaddingH: CGFloat = 20
    static let transcriptPaddingV: CGFloat = 20
    static let filesChatDefaultWidth: CGFloat = 460
    static let filesChatMinWidth: CGFloat = 320
    static let filesPaneMinWidth: CGFloat = 280

    static let welcomeTitleSize: CGFloat = 24
    static let settingsTitleSize: CGFloat = 16

    static let interFontName = "Inter"
    static let interMonoFontName = "SF Mono"

    static func interFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(interFontName, size: size).weight(weight)
    }

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

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
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
            .font(.system(size: 13, weight: isActive ? .medium : .regular))
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.tertiaryText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(isActive ? DesignTokens.controlSurfaceActive : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct NativeGlassCapsuleButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var height: CGFloat = 32
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isActive ? .medium : .regular))
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.secondaryText)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                GlassControlBackground(isActive: isActive, cornerRadius: height / 3)
            )
            .contentShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.snappy(duration: 0.18, extraBounce: 0.04), value: isActive)
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
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
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

struct AppGlassWindowBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .windowBackground, blendingMode: .behindWindow)
            DesignTokens.background.opacity(0.24)
        }
        .allowsHitTesting(false)
    }
}

struct SidebarGlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
            DesignTokens.sidebarOverlay
        }
        .allowsHitTesting(false)
    }
}

struct MainGlassBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .contentBackground, blendingMode: .withinWindow)
            DesignTokens.background.opacity(0.16)
        }
        .allowsHitTesting(false)
    }
}

struct GlassControlBackground: View {
    var isActive: Bool = false
    var cornerRadius: CGFloat = DesignTokens.radius
    var material: NSVisualEffectView.Material = .popover
    var showsShadow: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.clear)
            .background(
                ZStack {
                    VisualEffectBackground(material: material, blendingMode: .withinWindow)
                    (isActive ? DesignTokens.controlSurfaceActive : DesignTokens.controlSurface)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isActive ? DesignTokens.separator.opacity(0.68) : DesignTokens.separator.opacity(0.44), lineWidth: 1)
            )
            .shadow(
                color: showsShadow ? .black.opacity(isActive ? 0.10 : 0.04) : .clear,
                radius: showsShadow ? (isActive ? 10 : 4) : 0,
                y: showsShadow ? (isActive ? 5 : 2) : 0
            )
    }
}

struct ComposerGlassBackground: View {
    var cornerRadius: CGFloat = DesignTokens.largeRadius
    var isFocused: Bool = false
    var chromeless: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.clear)
            .background(
                ZStack {
                    VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
                    DesignTokens.contentSurface
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isFocused ? DesignTokens.neutral300 : DesignTokens.separator.opacity(0.80), lineWidth: 1)
            )
            .shadow(color: .black.opacity(chromeless ? 0.08 : 0.07), radius: 14, y: 8)
    }
}

struct HorizontalResizeHandleSurface: NSViewRepresentable {
    @Binding var isHovering: Bool
    @Binding var isDragging: Bool
    var onDragStart: (CGFloat) -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> HorizontalResizeTrackingView {
        let view = HorizontalResizeTrackingView()
        updateCallbacks(on: view)
        return view
    }

    func updateNSView(_ nsView: HorizontalResizeTrackingView, context: Context) {
        updateCallbacks(on: nsView)
    }

    private func updateCallbacks(on view: HorizontalResizeTrackingView) {
        view.onHoverChanged = { isHovering = $0 }
        view.onDragStateChanged = { isDragging = $0 }
        view.onDragStart = onDragStart
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
    }
}

final class HorizontalResizeTrackingView: NSView {
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onDragStateChanged: (Bool) -> Void = { _ in }
    var onDragStart: (CGFloat) -> Void = { _ in }
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onDoubleClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged(true)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }

        guard let window else { return }
        let startX = screenX(for: event)
        onDragStateChanged(true)
        onDragStart(startX)
        NSCursor.resizeLeftRight.set()

        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                continue
            }

            switch next.type {
            case .leftMouseDragged:
                NSCursor.resizeLeftRight.set()
                onDragChanged(screenX(for: next) - startX)
            case .leftMouseUp:
                onDragStateChanged(false)
                onDragEnded()
                window.invalidateCursorRects(for: self)
                return
            default:
                break
            }
        }
    }

    private func screenX(for event: NSEvent) -> CGFloat {
        guard let eventWindow = event.window ?? window else {
            return NSEvent.mouseLocation.x
        }
        return eventWindow.convertPoint(toScreen: event.locationInWindow).x
    }
}
