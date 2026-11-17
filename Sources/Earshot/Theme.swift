import AppKit
import EarshotCore
import SwiftUI

/// Earshot's visual language: warm paper / deep ink surfaces, a sky-blue voice for "Me",
/// one hue per remote speaker, rounded type for controls and a serif for what was said.
enum Theme {
    static let background = dynamic(light: 0xF5F3EE, dark: 0x0F1216)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x181C22)
    static let surfaceHover = dynamic(light: 0xFBFAF7, dark: 0x1E232B)
    static let well = dynamic(light: 0xEBE8E1, dark: 0x090B0E)
    static let ink = dynamic(light: 0x16191E, dark: 0xECEEF2)
    static let inkSoft = dynamic(light: 0x16191E, dark: 0xECEEF2, lightAlpha: 0.64, darkAlpha: 0.66)
    static let inkFaint = dynamic(light: 0x16191E, dark: 0xECEEF2, lightAlpha: 0.42, darkAlpha: 0.42)
    static let hairline = dynamic(light: 0x16191E, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)

    static let me = dynamic(light: 0x0273B0, dark: 0x4CC2F5)
    static let record = dynamic(light: 0xDC3B41, dark: 0xF2555A)
    static let caution = dynamic(light: 0xB8690A, dark: 0xF5B642)

    private static let remote = [
        dynamic(light: 0x0E8F6E, dark: 0x3DD6A3),
        dynamic(light: 0xB8690A, dark: 0xF5B642),
        dynamic(light: 0x6D4FCF, dark: 0xAD95FB),
        dynamic(light: 0xC93A63, dark: 0xFA7D97),
    ]

    /// 0 is "Me"; 1… are remote speakers in order of first appearance.
    static func tone(_ index: Int) -> Color {
        index <= 0 ? me : remote[(index - 1) % remote.count]
    }

    static func tone(channel: Channel, speaker: Int?) -> Int {
        channel == .me ? 0 : max(1, speaker ?? 1)
    }

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x3BBDF7), Color(hex: 0x0284C7)], startPoint: .top, endPoint: .bottom)
    static let recordGradient = LinearGradient(
        colors: [Color(hex: 0xF76268), Color(hex: 0xD9363C)], startPoint: .top, endPoint: .bottom)

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension Font {
    /// Controls, labels, headings.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Transcript and summary prose.
    static func reading(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Timestamps and counters.
    static func stamp(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - Shared pieces

/// A quiet capsule button for secondary actions.
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12, .medium))
            .foregroundStyle(Theme.ink.opacity(isEnabled ? 0.85 : 0.35))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(hovering && isEnabled ? Theme.surfaceHover : Theme.surface)
            )
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

/// Small all-caps label used for section names and speaker tags.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.inkFaint

    var body: some View {
        Text(text.uppercased())
            .font(.ui(10.5, .bold))
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// A rounded panel on the window background.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Makes the hidden-title-bar window draggable by its background.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.background)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Uses thin overlay scrollers even when the system setting is "always show scroll bars",
/// so no grey scroller track cuts through the custom surfaces. Place inside a ScrollView.
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // SwiftUI configures its scroll view after the content is installed, so apply the
            // style a few times, and again whenever the system preference changes.
            for delay in [0.0, 0.15, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.apply() }
                }
            }
        }

        private func apply() {
            var view: NSView? = self
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.drawsBackground = false
                    return
                }
                view = current.superview
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
