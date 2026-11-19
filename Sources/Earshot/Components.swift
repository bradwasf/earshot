import AppKit
import SwiftUI

// The shared building blocks of every screen, drawn from the tokens in `Theme.swift`.
// Views should use these rather than styling controls one by one.

// MARK: - Buttons

/// Capsule buttons in four kinds:
/// - `primary`: ink fill, for the one main action of a surface;
/// - `record`: red fill, for stopping a recording;
/// - `secondary`: a bordered surface, for actions next to a primary;
/// - `ghost`: no chrome until hovered, for toolbars and quiet actions.
struct EarshotButtonStyle: ButtonStyle {
    enum Kind { case primary, record, secondary, ghost }
    enum Size { case small, regular, large }

    var kind: Kind
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(TightLabelStyle(spacing: size == .small ? 4 : 6))
                .font(font)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .opacity(isEnabled ? 1 : 0.42)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var active: Bool { hovering && isEnabled }

        private var font: Font {
            switch size {
            case .small: return TypeScale.captionStrong
            case .regular: return Font.system(size: 12.5, weight: .medium)
            case .large: return Font.system(size: 14, weight: .semibold)
            }
        }

        private var height: CGFloat {
            switch size {
            case .small: return 24
            case .regular: return 28
            case .large: return 38
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .small: return 9
            case .regular: return 12
            case .large: return 18
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary, .record: return Theme.onInk
            case .secondary: return Theme.ink
            case .ghost: return active ? Theme.ink : Theme.inkSoft
            }
        }

        private var fill: AnyShapeStyle {
            let pressed = configuration.isPressed && isEnabled
            switch kind {
            case .primary: return AnyShapeStyle(Theme.ink.opacity(pressed ? 0.78 : active ? 0.88 : 1))
            case .record: return AnyShapeStyle(Theme.record.opacity(pressed ? 0.82 : active ? 0.92 : 1))
            case .secondary:
                return pressed ? AnyShapeStyle(Theme.washStrong) : active ? AnyShapeStyle(Theme.wash) : AnyShapeStyle(Theme.surface)
            case .ghost:
                return pressed ? AnyShapeStyle(Theme.washStrong) : active ? AnyShapeStyle(Theme.wash) : AnyShapeStyle(Color.clear)
            }
        }

        private var border: Color {
            kind == .secondary ? Theme.stroke : .clear
        }
    }
}

extension ButtonStyle where Self == EarshotButtonStyle {
    static var primary: EarshotButtonStyle { EarshotButtonStyle(kind: .primary) }
    static var secondary: EarshotButtonStyle { EarshotButtonStyle(kind: .secondary) }
    static var ghost: EarshotButtonStyle { EarshotButtonStyle(kind: .ghost) }
    static func primary(_ size: EarshotButtonStyle.Size) -> EarshotButtonStyle { .init(kind: .primary, size: size) }
    static func record(_ size: EarshotButtonStyle.Size = .regular) -> EarshotButtonStyle { .init(kind: .record, size: size) }
    static func secondary(_ size: EarshotButtonStyle.Size) -> EarshotButtonStyle { .init(kind: .secondary, size: size) }
    static func ghost(_ size: EarshotButtonStyle.Size) -> EarshotButtonStyle { .init(kind: .ghost, size: size) }
}

/// Icon and title close together, the icon a touch smaller than the text.
struct TightLabelStyle: LabelStyle {
    var spacing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A round symbol button. `label` is read by VoiceOver and is the tooltip unless `help` is given.
struct IconButton: View {
    enum Style { case ghost, secondary, primary }

    let symbol: String
    let label: String
    var help: String?
    var size: CGFloat = 26
    var style: Style = .ghost
    /// Ghost buttons that are "on" (e.g. follow playback) keep a fill.
    var selected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(style == .secondary ? Theme.stroke : .clear))
                .contentShape(Circle())
                .contentShape(.focusEffect, Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Motion.quick, value: hovering)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    private var active: Bool { hovering && isEnabled }

    private var foreground: Color {
        switch style {
        case .primary: return Theme.onInk
        case .secondary: return Theme.ink
        case .ghost: return active || selected ? Theme.ink : Theme.inkSoft
        }
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .primary: return AnyShapeStyle(Theme.ink.opacity(active ? 0.88 : 1))
        case .secondary: return active ? AnyShapeStyle(Theme.wash) : AnyShapeStyle(Theme.surface)
        case .ghost:
            return selected ? AnyShapeStyle(Theme.washStrong) : active ? AnyShapeStyle(Theme.wash) : AnyShapeStyle(Color.clear)
        }
    }
}

/// Plain button that dips slightly when pressed (for custom-drawn buttons).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

/// A text link: inherits its colour, underlines on hover.
struct LinkButton: View {
    let title: String
    var symbol: String?
    var trailingSymbol: String?
    var font: Font = TypeScale.calloutStrong
    var color: Color = Theme.inkSoft
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).underline(hovering, color: Theme.inkFaint).lineLimit(1)
                if let trailingSymbol { Image(systemName: trailingSymbol).imageScale(.small) }
            }
            .font(font)
            .foregroundStyle(hovering ? Theme.ink : color)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Chips and labels

/// A small capsule label: an owner, a speaker, a count.
struct Chip: View {
    enum Style {
        /// Grey on a quiet fill.
        case neutral
        /// Coloured text on a tint of the same colour.
        case soft(Color)
        /// Filled with the colour (stands out: "yours").
        case solid(Color)
    }

    let text: String
    var style: Style = .neutral
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 1.5 : 2)
            .background(Capsule().fill(fill))
            .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .neutral: return Theme.inkSoft
        case .soft(let color): return color
        case .solid: return Theme.onInk
        }
    }

    private var fill: Color {
        switch style {
        case .neutral: return Theme.washStrong
        case .soft(let color): return color.opacity(0.14)
        case .solid(let color): return color
        }
    }
}

/// Small all-caps label for section names and speaker tags.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.inkFaint

    var body: some View {
        Text(text.uppercased())
            .font(TypeScale.label)
            .tracking(0.9)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A keyboard shortcut drawn as a key cap ("⌘R", "↩").
struct KeyHint: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.stroke))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A coloured dot (speaker legends, status lines).
struct Dot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - Surfaces

/// A rounded panel.
struct Card<Content: View>: View {
    enum Style {
        /// White (light) or raised charcoal (dark), with a hairline edge.
        case surface
        /// A quiet ink tint, no edge (callouts on the canvas).
        case wash
        /// Tinted with a colour (a live turn, the playing turn).
        case tinted(Color)
    }

    var style: Style = .surface
    var padding: CGFloat = Space.l
    var radius: CGFloat = Radius.l
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge))
            .shadow(color: shadow, radius: 2, y: 1)
    }

    private var fill: AnyShapeStyle {
        switch style {
        case .surface: return AnyShapeStyle(Theme.surface)
        case .wash: return AnyShapeStyle(Theme.wash)
        case .tinted(let color): return AnyShapeStyle(color.opacity(0.08))
        }
    }

    private var edge: Color {
        switch style {
        case .surface: return Theme.hairline
        case .wash: return .clear
        case .tinted(let color): return color.opacity(0.22)
        }
    }

    private var shadow: Color {
        if case .surface = style { return .black.opacity(0.035) }
        return .clear
    }
}

/// A one-pixel divider.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A dashed horizontal rule (pauses, things that are "off").
struct DashedRule: View {
    var color: Color = Theme.stroke

    var body: some View {
        Line().stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// A section's name, with an optional symbol and count, and room for a control on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    var count: String?
    var tint: Color = Theme.inkSoft
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
            Eyebrow(text: title, color: tint)
            if let count { Text(count).font(TypeScale.stamp).foregroundStyle(Theme.inkFaint) }
            Spacer(minLength: Space.s)
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, count: String? = nil, tint: Color = Theme.inkSoft) {
        self.init(title: title, symbol: symbol, count: count, tint: tint) { EmptyView() }
    }
}

/// A calm centred message for a screen with nothing to show yet.
struct EmptyState<Accessory: View, Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Space.l) {
            accessory
            VStack(spacing: Space.s) {
                Text(title)
                    .font(TypeScale.title)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(TypeScale.readingCompact)
                    .foregroundStyle(Theme.inkSoft)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            actions
        }
        .frame(maxWidth: 400)
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Accessory == EmptyView, Actions == EmptyView {
    init(title: String, message: String) {
        self.init(title: title, message: message) { EmptyView() } actions: { EmptyView() }
    }
}

/// A short confirmation that floats above the bottom of the window.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: toast.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onInk.opacity(0.75))
            Text(toast.text).font(TypeScale.calloutStrong).foregroundStyle(Theme.onInk).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.ink))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .padding(.horizontal, Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Inputs

extension View {
    /// The well behind a text field, with a focus edge.
    func fieldChrome(focused: Bool, capsule: Bool = true) -> some View {
        modifier(FieldChrome(focused: focused, capsule: capsule))
    }

    /// Caps the content at the reading width and centres it in wide windows.
    func readableColumn(gutter: CGFloat = Metrics.gutter) -> some View {
        frame(maxWidth: Metrics.column, alignment: .leading)
            .padding(.horizontal, gutter)
            .frame(maxWidth: .infinity)
    }
}

private struct FieldChrome: ViewModifier {
    let focused: Bool
    let capsule: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? 100 : Radius.m, style: .continuous)
        content
            .background(shape.fill(Theme.sunken))
            .overlay(shape.strokeBorder(focused ? Theme.focus : hovering ? Theme.stroke : Theme.hairline, lineWidth: focused ? 1.25 : 1))
            .animation(Motion.quick, value: focused)
            .onHover { hovering = $0 }
    }
}

/// A search box: magnifier, field, clear button.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundColor(Theme.inkFaint))
                .textFieldStyle(.plain)
                .font(TypeScale.body)
                .foregroundStyle(Theme.ink)
                .focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .fieldChrome(focused: focus.wrappedValue)
        .animation(Motion.quick, value: text.isEmpty)
    }
}

/// A rounded checkbox (stock toggles look out of place on the cards).
struct Checkbox: View {
    let done: Bool
    var tint: Color = Theme.ink
    let toggle: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .fill(done ? tint : (hovering && isEnabled ? Theme.wash : Theme.surface))
                RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                    .strokeBorder(done ? tint : (hovering && isEnabled ? Theme.inkSoft : Theme.inkFaint), lineWidth: 1.3)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.onInk)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .padding(3)
            .contentShape(Rectangle())
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Radius.s + 2, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Motion.quick, value: done)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(done ? "Mark as not done" : "Mark as done")
        .accessibilityLabel(done ? "Done" : "Not done")
        .accessibilityAddTraits(done ? [.isSelected] : [])
        // Sit on the text's first baseline, like a list marker.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }
}

/// A sliding segmented switch.
struct PillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    withAnimation(Motion.standard) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(Font.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? Theme.ink : Theme.inkSoft)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                        .contentShape(.focusEffect, Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.sunken))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

// MARK: - Brand

/// The two-lane waveform as a still mark (Me above the line, Them below).
struct Glyph: View {
    var scale: CGFloat = 1
    private let heights: [CGFloat] = [0.3, 0.55, 0.9, 0.65, 1.0, 0.45, 0.75, 0.35, 0.6, 0.25]

    var body: some View {
        HStack(alignment: .center, spacing: 5 * scale) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                VStack(spacing: 3 * scale) {
                    Capsule().fill(Theme.tone(0)).frame(width: 4.5 * scale, height: 24 * scale * height)
                    Capsule().fill(Theme.tone(1)).frame(width: 4.5 * scale, height: 24 * scale * heights[heights.count - 1 - index])
                }
                .frame(height: 56 * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Window plumbing

/// Makes the hidden-title-bar window draggable by its background.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = Theme.canvasNSColor
            // `--window-size 480x520` sets the window's content size at launch (screenshots).
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--window-size"), index + 1 < arguments.count {
                let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])) }
            }
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

/// Inline Markdown (bold, italics, code, links) as styled text.
func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
