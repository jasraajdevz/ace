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

/// The raw hex behind every token.
///
/// Split out so the checks can compute contrast ratios against exactly what
/// ships. A parallel table in the test file would drift the first time anyone
/// nudged a colour, and the whole point of checking contrast is that it stays
/// true after somebody restyles.
enum InkHex {
    // Ground — a five-step ladder from the app background up to a pressed
    // control. The steps are deliberately even: depth reads as a sequence, and
    // an uneven ladder makes one layer look like a mistake.
    static let background: UInt32     = 0x05050B
    static let surfaceSunken: UInt32  = 0x0B0B14
    static let surface: UInt32        = 0x13131E
    static let surfaceRaised: UInt32  = 0x1E1E2D
    static let surfaceActive: UInt32  = 0x29293C

    // Text
    static let textPrimary: UInt32    = 0xF7F7FC
    static let textSecondary: UInt32  = 0xB6B6CD
    static let textTertiary: UInt32   = 0x9292AB
    static let textOnAccent: UInt32   = 0x05050B

    // Brand
    static let accent: UInt32         = 0x9165FF
    static let accentAlt: UInt32      = 0x3DDCFF
    static let accentDeep: UInt32     = 0x5B3BD9
    static let accentMagenta: UInt32  = 0xC85CFF

    // Semantic
    static let success: UInt32        = 0x3DDC97
    static let warning: UInt32        = 0xFFC53D
    static let danger: UInt32         = 0xFF7A8F
    static let flame: UInt32          = 0xFF9752
    static let care: UInt32           = 0xF0B27A
    static let calm: UInt32           = 0x9BB0C6
}

/// Every colour in the app.
enum Ink {

    // MARK: Ground

    /// The deepest layer — the app background. Very slightly blue so it reads
    /// as considered rather than "black because we didn't pick one", and deep
    /// enough that everything above it has somewhere to rise from.
    static let background = Color(hex: InkHex.background)
    /// Recessed: text fields, wells, the inside of a progress track. The only
    /// token below the background, so an inset actually reads as inset.
    static let surfaceSunken = Color(hex: InkHex.surfaceSunken)
    /// Cards and sheets sitting on the background.
    static let surface = Color(hex: InkHex.surface)
    /// A raised element on top of a surface (a chip inside a card).
    static let surfaceRaised = Color(hex: InkHex.surfaceRaised)
    /// Pressed / selected background.
    static let surfaceActive = Color(hex: InkHex.surfaceActive)
    /// Hairline separators and card borders.
    static let stroke = Color(hex: 0xFFFFFF, opacity: 0.08)
    static let strokeStrong = Color(hex: 0xFFFFFF, opacity: 0.16)
    /// The top edge of a raised surface. Light comes from above, so the lit
    /// edge is what actually sells depth on a dark ground — more than shadow
    /// does, because shadow on near-black has almost nowhere to go.
    static let strokeHighlight = Color(hex: 0xFFFFFF, opacity: 0.14)

    // MARK: Text

    static let textPrimary = Color(hex: InkHex.textPrimary)
    static let textSecondary = Color(hex: InkHex.textSecondary)
    static let textTertiary = Color(hex: InkHex.textTertiary)
    /// Text that sits on top of an accent-filled surface.
    static let textOnAccent = Color(hex: InkHex.textOnAccent)

    // MARK: Brand

    /// Ace's primary colour. Electric violet.
    static let accent = Color(hex: InkHex.accent)
    /// The second half of the signature gradient. Cyan.
    static let accentAlt = Color(hex: InkHex.accentAlt)
    /// The dark end of the accent ramp. Gives a filled control somewhere to
    /// fall off to, so it reads as lit rather than painted.
    static let accentDeep = Color(hex: InkHex.accentDeep)
    /// A soft violet wash for backgrounds behind accent content.
    static let accentSoft = Color(hex: InkHex.accent, opacity: 0.18)

    // MARK: Semantic

    static let success = Color(hex: InkHex.success)
    static let successSoft = Color(hex: InkHex.success, opacity: 0.18)
    static let warning = Color(hex: InkHex.warning)
    static let warningSoft = Color(hex: InkHex.warning, opacity: 0.18)
    static let danger = Color(hex: InkHex.danger)
    static let dangerSoft = Color(hex: InkHex.danger, opacity: 0.18)
    /// Streaks and celebration.
    static let flame = Color(hex: InkHex.flame)

    // MARK: Special surfaces

    /// Do Not Disturb / low-stimulation study mode (Part 4). Deliberately
    /// desaturated — the calm surface should feel like the colour drained out.
    static let calm = Color(hex: InkHex.calm)
    static let calmBackground = Color(hex: 0x070B0F)

    /// The crisis-support surface. Warm and soft, with no brand energy at all —
    /// this screen must not look like the rest of the game.
    static let careBackground = Color(hex: 0x100C0A)
    static let careSurface = Color(hex: 0x1F1814)
    static let careAccent = Color(hex: InkHex.care)

    // MARK: Gradients

    /// The signature gradient. Used sparingly: the mark, level-ups, the primary
    /// button. If it's everywhere it stops meaning anything.
    /// Cyan → violet → magenta. It runs *bright to bright* on purpose: this
    /// gradient is used as a `foregroundStyle`, so the text is the gradient, and
    /// a dark stop would leave part of a word nearly invisible. `accentDeep`
    /// belongs in fills that have nothing on top of them, not here — it measures
    /// 2.97:1 on the background, which the contrast checks caught.
    static let brandGradient = LinearGradient(
        colors: [accentAlt, accent, Color(hex: InkHex.accentMagenta)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Every stop of `brandGradient`, for the contrast checks.
    static let brandGradientStops: [UInt32] = [InkHex.accentAlt, InkHex.accent,
                                               InkHex.accentMagenta]

    /// A filled control. Three stops rather than two so the fill has a lit top
    /// and a shadowed bottom instead of a flat wash across it.
    /// Deliberately does NOT reach `accentDeep`. The primary button carries a
    /// near-black label, and black on `accentDeep` is 2.97:1 — the bottom third
    /// of the button would have been unreadable. The ramp stops at a violet that
    /// still clears AA, and `accentDeep` stays for decoration with nothing on
    /// top of it. `DesignSystemChecks` asserts the whole ramp, not just the mid
    /// stop, so this cannot quietly regress.
    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0xA880FF), accent, Color(hex: 0x7C5CFF)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The three stops of `accentGradient`, exposed so contrast can be checked
    /// against every one of them rather than a representative sample.
    static let accentGradientStops: [UInt32] = [0xA880FF, InkHex.accent, 0x7C5CFF]

    /// The lit top edge of a raised surface, fading out by the middle.
    static let sheenGradient = LinearGradient(
        colors: [Color(hex: 0xFFFFFF, opacity: 0.16),
                 Color(hex: 0xFFFFFF, opacity: 0.02),
                 Color(hex: 0xFFFFFF, opacity: 0.0)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Depth for a card: a hair darker at the bottom than the token alone.
    static func surfaceGradient(_ base: Color) -> LinearGradient {
        LinearGradient(colors: [base, base.opacity(0.86)],
                       startPoint: .top, endPoint: .bottom)
    }

    static let flameGradient = LinearGradient(
        colors: [flame, Color(hex: 0xFF5F6D)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Ambient wash behind hero content.
    static let auraGradient = RadialGradient(
        colors: [accent.opacity(0.42), accentDeep.opacity(0.14), accent.opacity(0.0)],
        center: .topLeading,
        startRadius: 8,
        endRadius: 460
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
    static let display = Font.system(.largeTitle, design: .rounded, weight: .black)
    static let title1 = Font.system(.title, design: .rounded, weight: .heavy)
    static let title2 = Font.system(.title2, design: .rounded, weight: .bold)
    static let title3 = Font.system(.title3, design: .rounded, weight: .bold)
    static let headline = Font.system(.headline, design: .rounded, weight: .semibold)

    /// Big rounded type at heavy weights gets loose without help. Negative
    /// tracking only on the display sizes — applying it to body text costs
    /// legibility for no gain.
    static let displayTracking: CGFloat = -0.9
    static let titleTracking: CGFloat = -0.5
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

extension View {
    /// Display type: heaviest weight, tightened.
    ///
    /// A modifier rather than a rule to remember, because rounded type at black
    /// weight is exactly where tracking matters and exactly where it is easiest
    /// to forget.
    func aceDisplay() -> some View {
        font(Typeface.display).tracking(Typeface.displayTracking)
    }

    func aceTitle() -> some View {
        font(Typeface.title1).tracking(Typeface.titleTracking)
    }
}

// MARK: - Elevation

/// Shadow presets. Dark UIs need *less* shadow and more border than light ones,
/// so these are subtle and always paired with a stroke.
struct Elevation {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    static let none = Elevation(radius: 0, y: 0, opacity: 0)
    static let low = Elevation(radius: 14, y: 5, opacity: 0.44)
    static let medium = Elevation(radius: 26, y: 11, opacity: 0.52)
    static let high = Elevation(radius: 44, y: 20, opacity: 0.60)
}

/// A coloured glow, for the few things that should look lit from within: the
/// primary button, the mark, a level-up. Distinct from `Elevation`, which is a
/// black shadow and answers a different question — how far off the page is
/// this, versus is this thing a light source.
struct Glow {
    let color: Color
    let radius: CGFloat
    let opacity: Double

    static let none = Glow(color: .clear, radius: 0, opacity: 0)
    static let accent = Glow(color: Ink.accent, radius: 22, opacity: 0.42)
    static let accentStrong = Glow(color: Ink.accent, radius: 38, opacity: 0.55)
}

extension View {
    func elevation(_ level: Elevation) -> some View {
        shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }

    /// Light coming *out* of the view rather than shadow falling from it.
    func glow(_ glow: Glow) -> some View {
        shadow(color: glow.color.opacity(glow.opacity), radius: glow.radius, x: 0, y: 0)
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
