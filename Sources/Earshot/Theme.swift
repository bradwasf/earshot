import AppKit
import EarshotCore
import SwiftUI

/// Earshot's design tokens. The look is "ink on paper": warm paper (light) or charcoal (dark)
/// surfaces, controls drawn in ink, and colour kept for meaning only: who is speaking (one hue
/// per speaker), recording (red) and things that need attention (amber). Titles and everything
/// people said are set in a serif for long reading; controls use the system sans.
///
/// Reusable pieces built from these tokens live in `Components.swift`.
enum Theme {
    // MARK: Surfaces

    /// The window.
    static let canvas = dynamic(light: 0xF6F4EF, dark: 0x121315)
    /// Cards, menus, popovers.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1B1D20)
    /// Above a surface: the selected tab, popover rows on hover.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x2E3135)
    /// Wells: fields, the waveform, tracks.
    static let sunken = dynamic(light: 0xECE9E2, dark: 0x0C0D0F)
    /// Hover and quiet fills (ink at low opacity, so it works on any surface).
    static let wash = dynamic(light: 0x1C1B19, dark: 0xEDEBE6, lightAlpha: 0.05, darkAlpha: 0.06)
    /// Pressed, selected.
    static let washStrong = dynamic(light: 0x1C1B19, dark: 0xEDEBE6, lightAlpha: 0.09, darkAlpha: 0.11)

    // MARK: Ink

    static let ink = dynamic(light: 0x1C1B19, dark: 0xEDEBE6)
    /// Secondary text (≥ 4.5:1 on canvas and surface).
    static let inkSoft = dynamic(light: 0x1C1B19, dark: 0xEDEBE6, lightAlpha: 0.68, darkAlpha: 0.68)
    /// Tertiary text: timestamps, placeholders, counts.
    static let inkFaint = dynamic(light: 0x1C1B19, dark: 0xEDEBE6, lightAlpha: 0.50, darkAlpha: 0.48)
    /// Dividers and card edges.
    static let hairline = dynamic(light: 0x1C1B19, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    /// Control borders (a little stronger than a hairline).
    static let stroke = dynamic(light: 0x1C1B19, dark: 0xFFFFFF, lightAlpha: 0.15, darkAlpha: 0.14)
    /// Text and symbols on an ink fill.
    static let onInk = dynamic(light: 0xF6F4EF, dark: 0x121315)

    // MARK: Meaning

    static let record = dynamic(light: 0xCF323A, dark: 0xF0555B)
    static let caution = dynamic(light: 0x8F6200, dark: 0xE8B546)
    /// Keyboard focus and the find bar's edge.
    static let focus = dynamic(light: 0x1D6BC0, dark: 0x6CB6FF, lightAlpha: 0.75, darkAlpha: 0.8)

    /// "Me". Every hue below keeps ≥ 4.5:1 against canvas and surface in its mode.
    static let me = dynamic(light: 0x1D6BC0, dark: 0x6CB6FF)
    private static let remote = [
        dynamic(light: 0x0C7A5C, dark: 0x4BD3A4),  // green
        dynamic(light: 0x9C5800, dark: 0xF0B44E),  // amber
        dynamic(light: 0x7048D4, dark: 0xB7A0FF),  // violet
        dynamic(light: 0xBE3159, dark: 0xFF8DA8),  // rose
    ]

    /// 0 is "Me"; 1… are remote speakers in order of first appearance.
    static func tone(_ index: Int) -> Color {
        index <= 0 ? me : remote[(index - 1) % remote.count]
    }

    static func tone(channel: Channel, speaker: Int?) -> Int {
        channel == .me ? 0 : max(1, speaker ?? 1)
    }

    /// The tone of one of Earshot's labels ("Me", "Them", "Them 2").
    static func tone(label: String) -> Int {
        let identity = SpeakerNames.identity(of: label)
        return tone(channel: identity.channel, speaker: identity.speaker)
    }

    // MARK: Find highlights (a highlighter pen, not a speaker colour)

    static let findMatch = dynamic(light: 0xF5C04A, dark: 0xF5B642, lightAlpha: 0.38, darkAlpha: 0.30)
    static let findCurrent = dynamic(light: 0xF2A900, dark: 0xF5B642, lightAlpha: 0.85, darkAlpha: 0.75)

    // MARK: Plumbing

    static var canvasNSColor: NSColor { NSColor(canvas) }

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

// MARK: - Type

/// The type scale. Controls use the system sans; titles and what people said use the serif.
enum TypeScale {
    /// Screen titles (a call's name).
    static let display = Font.system(size: 24, weight: .semibold, design: .serif)
    /// Empty-state and card titles.
    static let title = Font.system(size: 18, weight: .semibold, design: .serif)
    /// Row titles, prompt-card titles.
    static let headline = Font.system(size: 14, weight: .semibold)
    /// Controls and short UI text.
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    /// Supporting text: status lines, helper text.
    static let callout = Font.system(size: 12)
    static let calloutStrong = Font.system(size: 12, weight: .semibold)
    /// Captions, chips, footers.
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    /// All-caps labels (`Eyebrow`).
    static let label = Font.system(size: 10.5, weight: .semibold)

    /// Transcript turns.
    static let reading = Font.system(size: 15.5, design: .serif)
    /// The summary's "In short".
    static let readingLede = Font.system(size: 17, design: .serif)
    /// Summary items, list previews.
    static let readingSmall = Font.system(size: 14.5, design: .serif)
    static let readingCompact = Font.system(size: 13.5, design: .serif)

    /// Timestamps, counters, durations.
    static let stamp = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    static let stampLarge = Font.system(size: 12, weight: .medium, design: .monospaced)

    /// Line spacing for serif paragraphs.
    static let readingLeading: CGFloat = 4.5
}

// MARK: - Space, shape, motion

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    /// Checkboxes, small tiles.
    static let s: CGFloat = 5
    /// Menu rows, fields, inner highlights.
    static let m: CGFloat = 9
    /// Cards.
    static let l: CGFloat = 14
}

enum Metrics {
    /// Widest the reading column gets; wider windows centre it.
    static let column: CGFloat = 720
    /// Space between the column and the window edge.
    static let gutter: CGFloat = 24
}

enum Motion {
    /// Hover, press, small toggles.
    static let quick = Animation.snappy(duration: 0.16)
    /// Panels appearing, tabs, lists changing.
    static let standard = Animation.snappy(duration: 0.24)
    /// Screens changing.
    static let screen = Animation.snappy(duration: 0.3)
}

// MARK: - Colour helpers

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
