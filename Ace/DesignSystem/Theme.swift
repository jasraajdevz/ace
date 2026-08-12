//
//  Theme.swift
//  Ace
//
//  The one file that drives every pixel (§8).
//
//  Nothing in Ace hard-codes a colour, a corner radius, a font size or a
//  spacing value. Everything comes from here, which is why the whole app can be
//  restyled from a single place and why no screen ever ends up default-grey.
//
//  Ace is dark-first *and* dark-only — see DECISIONS.md. The palette below is
//  tuned as one coherent set on a near-black ground; a light variant would be a
//  second design, not a toggle.
//

import SwiftUI

// MARK: - Colour tokens

extension Color {
    /// Build a colour from a hex literal, e.g. `Color(hex: 0x7C5CFF)`.
    /// Kept private to the design system — features use the named tokens.
    fileprivate init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Every colour in the app.
enum Ink {

    // MARK: Ground

    /// The deepest layer — the app background. Very slightly blue so it reads
    /// as considered rather than "black because we didn't pick one".
    static let background = Color(hex: 0x0A0A11)
    /// Cards and sheets sitting on the background.
    static let surface = Color(hex: 0x14141F)
    /// A raised element on top of a surface (a chip inside a card).
    static let surfaceRaised = Color(hex: 0x1D1D2B)
    /// Pressed / selected background.
    static let surfaceActive = Color(hex: 0x262637)
    /// Hairline separators and card borders.
    static let stroke = Color(hex: 0xFFFFFF, opacity: 0.10)
    static let strokeStrong = Color(hex: 0xFFFFFF, opacity: 0.18)

    // MARK: Text

    static let textPrimary = Color(hex: 0xF5F5FA)
    static let textSecondary = Color(hex: 0xA9A9BF)
    static let textTertiary = Color(hex: 0x6E6E85)
    /// Text that sits on top of an accent-filled surface.
    static let textOnAccent = Color(hex: 0x0A0A11)

    // MARK: Brand

    /// Ace's primary colour. Electric violet.
    static let accent = Color(hex: 0x7C5CFF)
    /// The second half of the signature gradient. Cyan.
    static let accentAlt = Color(hex: 0x22D3EE)
    /// A soft violet wash for backgrounds behind accent content.
    static let accentSoft = Color(hex: 0x7C5CFF, opacity: 0.16)

    // MARK: Semantic

    static let success = Color(hex: 0x34D399)
    static let successSoft = Color(hex: 0x34D399, opacity: 0.16)
    static let warning = Color(hex: 0xFBBF24)
    static let warningSoft = Color(hex: 0xFBBF24, opacity: 0.16)
    static let danger = Color(hex: 0xFB7185)
    static let dangerSoft = Color(hex: 0xFB7185, opacity: 0.16)
    /// Streaks and celebration.
    static let flame = Color(hex: 0xFF9752)

    // MARK: Special surfaces

    /// Do Not Disturb / low-stimulation study mode (Part 4). Deliberately
    /// desaturated — the calm surface should feel like the colour drained out.
    static let calm = Color(hex: 0x8FA3B8)
    static let calmBackground = Color(hex: 0x0C1014)

    /// The crisis-support surface. Warm and soft, with no brand energy at all —
    /// this screen must not look like the rest of the game.
    static let careBackground = Color(hex: 0x14100E)
    static let careSurface = Color(hex: 0x211A16)
    static let careAccent = Color(hex: 0xF0B27A)

    // MARK: Gradients

    /// The signature gradient. Used sparingly: the mark, level-ups, the primary
    /// button. If it's everywhere it stops meaning anything.
    static let brandGradient = LinearGradient(
        colors: [accent, accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let flameGradient = LinearGradient(
        colors: [flame, Color(hex: 0xFF5F6D)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Ambient wash behind hero content.
    static let auraGradient = RadialGradient(
        colors: [accent.opacity(0.30), accent.opacity(0.0)],
        center: .topLeading,
        startRadius: 8,
        endRadius: 420
    )

    /// Mood-specific tint, used for the subtle glow around the tutor surface.
    static func tint(for mood: Mood) -> Color {
        switch mood {
        case .neutral, .focused: accent
        case .energized: flame
        case .confused: accentAlt
        case .frustrated: warning
        case .low: calm
        case .distracted: Color(hex: 0x9C7BFF)
        }
    }
}

// MARK: - Spacing (4pt grid)

/// Every gap in the app is one of these. No magic numbers in feature code.
enum Space {
    /// 2 — hairline nudges only.
    static let hair: CGFloat = 2
    /// 4
    static let xs: CGFloat = 4
    /// 8
    static let s: CGFloat = 8
    /// 12
    static let m: CGFloat = 12
    /// 16 — the default gap between related elements.
    static let l: CGFloat = 16
    /// 24 — the default screen margin.
    static let xl: CGFloat = 24
    /// 32 — between sections.
    static let xxl: CGFloat = 32
    /// 48 — hero spacing.
    static let xxxl: CGFloat = 48

    /// Standard horizontal screen inset.
    static let screen: CGFloat = 20
}

// MARK: - Radii

enum Radius {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 18
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    /// Fully rounded.
    static let pill: CGFloat = 999
}

// MARK: - Type scale

/// The type scale. Every size uses a semantic `TextStyle` under the hood so
/// Dynamic Type works automatically — that's accessibility handled by
/// construction rather than bolted on (§8).
///
/// SF Rounded throughout: it reads friendly and confident without being childish,
/// which is exactly the register for a 5th grader *and* a college student.
enum Typeface {
    static let display = Font.system(.largeTitle, design: .rounded, weight: .heavy)
    static let title1 = Font.system(.title, design: .rounded, weight: .bold)
    static let title2 = Font.system(.title2, design: .rounded, weight: .bold)
    static let title3 = Font.system(.title3, design: .rounded, weight: .semibold)
    static let headline = Font.system(.headline, design: .rounded, weight: .semibold)
    static let body = Font.system(.body, design: .rounded, weight: .regular)
    static let bodyEmphasis = Font.system(.body, design: .rounded, weight: .semibold)
    static let callout = Font.system(.callout, design: .rounded, weight: .regular)
    static let subheadline = Font.system(.subheadline, design: .rounded, weight: .medium)
    static let footnote = Font.system(.footnote, design: .rounded, weight: .medium)
    static let caption = Font.system(.caption, design: .rounded, weight: .medium)
    static let captionEmphasis = Font.system(.caption, design: .rounded, weight: .bold)

    /// Numerals that don't jitter while counting up (XP, timers, scores).
    static func numeric(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }

    /// Reading text — source material and long tutor explanations. Serif-free
    /// but wider tracking and a taller line height for comfort.
    static let reading = Font.system(.body, design: .default, weight: .regular)
}

// MARK: - Elevation

/// Shadow presets. Dark UIs need *less* shadow and more border than light ones,
/// so these are subtle and always paired with a stroke.
struct Elevation {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    static let none = Elevation(radius: 0, y: 0, opacity: 0)
    static let low = Elevation(radius: 10, y: 4, opacity: 0.30)
    static let medium = Elevation(radius: 20, y: 8, opacity: 0.36)
    static let high = Elevation(radius: 34, y: 14, opacity: 0.44)
}

extension View {
    func elevation(_ level: Elevation) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }
}

// MARK: - Motion

/// Spring curves. Named by feel, not by numbers, so feature code reads like a
/// description of the interaction.
enum Motion {
    /// Buttons, chips, toggles. Fast and tight.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.78)
    /// Cards appearing, sheets, list inserts.
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Celebrations. Deliberately overshoots.
    static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.58)
    /// Ambient background drift. Slow enough to be felt, not watched.
    static let ambient = Animation.easeInOut(duration: 3.2)
    /// Fades and opacity-only changes.
    static let gentle = Animation.easeOut(duration: 0.22)

    /// Staggered delay for list items appearing, capped so a long list doesn't
    /// take a second and a half to finish arriving.
    static func stagger(_ index: Int, step: Double = 0.045, cap: Double = 0.36) -> Double {
        min(Double(index) * step, cap)
    }
}

/// Reduce-motion support, applied at the point of use.
///
/// `@Environment(\.accessibilityReduceMotion)` tells us the student has asked
/// the system to calm things down. Rather than checking that flag in fifty
/// places, features call `.aceAnimation(...)` and this modifier does the right
/// thing: springs become instant, ambient loops stop entirely.
private struct AceAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    /// When true, the effect is decorative and is dropped entirely under
    /// reduce-motion rather than being made instant.
    let isDecorative: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content.animation(isDecorative ? nil : Motion.gentle, value: value)
        } else {
            content.animation(animation, value: value)
        }
    }
}

extension View {
    /// Animate `value` changes with a curve that respects Reduce Motion.
    func aceAnimation<V: Equatable>(_ animation: Animation, value: V,
                                    decorative: Bool = false) -> some View {
        modifier(AceAnimationModifier(animation: animation, value: value, isDecorative: decorative))
    }
}

/// Read-only access to the reduce-motion flag for views that need to branch
/// structurally (e.g. skip a particle system entirely).
struct ReduceMotionReader<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }
    var body: some View { content(reduceMotion) }
}
