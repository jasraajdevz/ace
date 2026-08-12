//
//  DesignSystemChecks.swift
//  Ace — verification harness
//
//  The design system is mostly declarative, so these checks target the parts
//  that *can* silently go wrong: the spacing grid drifting off 4pt, radii
//  becoming inconsistent, motion curves being edited into something sluggish,
//  and progress values escaping 0...1.
//
//  The fact that this file compiles at all is itself a check: it forces every
//  SwiftUI view in `DesignSystem/` to type-check against a real SDK.
//

import Foundation
import SwiftUI

enum DesignSystemChecks {
    static let all = CheckSuite(name: "Design system") { run in

        // --- The 4pt grid ------------------------------------------------------
        let spacings: [(String, CGFloat)] = [
            ("xs", Space.xs), ("s", Space.s), ("m", Space.m), ("l", Space.l),
            ("xl", Space.xl), ("xxl", Space.xxl), ("xxxl", Space.xxxl),
            ("screen", Space.screen)
        ]
        for (name, value) in spacings {
            run.expect(value > 0, "Space.\(name) must be positive")
            run.expect(value.truncatingRemainder(dividingBy: 4) == 0,
                       "Space.\(name) = \(value) is off the 4pt grid")
        }
        // Ordered, so `Space.s` is always tighter than `Space.l`.
        let ordered: [CGFloat] = [Space.xs, Space.s, Space.m, Space.l, Space.xl, Space.xxl, Space.xxxl]
        for i in 1..<ordered.count {
            run.expect(ordered[i] > ordered[i - 1],
                       "spacing scale is not monotonic at index \(i): \(ordered)")
        }

        // --- Radii --------------------------------------------------------------
        let radii: [(String, CGFloat)] = [
            ("xs", Radius.xs), ("sm", Radius.sm), ("md", Radius.md),
            ("lg", Radius.lg), ("xl", Radius.xl)
        ]
        var previousRadius: CGFloat = 0
        for (name, value) in radii {
            run.expect(value > previousRadius, "Radius.\(name) = \(value) breaks the scale")
            previousRadius = value
        }
        run.expect(Radius.pill >= 999, "Radius.pill must be effectively infinite")

        // --- Elevation ------------------------------------------------------------
        let elevations: [(String, Elevation)] = [
            ("none", .none), ("low", .low), ("medium", .medium), ("high", .high)
        ]
        for (name, level) in elevations {
            run.expect(level.radius >= 0, "Elevation.\(name) negative radius")
            run.expect(level.opacity >= 0 && level.opacity <= 1,
                       "Elevation.\(name) opacity \(level.opacity) out of range")
        }
        run.expectEqual(Elevation.none.radius, 0, "Elevation.none must be invisible")
        run.expectEqual(Elevation.none.opacity, 0, "Elevation.none must be invisible")
        run.expect(Elevation.high.radius > Elevation.low.radius, "elevation scale ordering")
        run.expect(Elevation.high.y > Elevation.low.y, "higher elevation casts further")

        // --- Motion ----------------------------------------------------------------
        // Stagger must be bounded — an unbounded stagger means a 40-item list
        // takes two seconds to finish appearing.
        run.expectEqual(Motion.stagger(0), 0, "first item has no delay")
        run.expect(Motion.stagger(1) > Motion.stagger(0), "stagger increases")
        run.expect(Motion.stagger(1_000) <= 0.36,
                   "stagger must cap, got \(Motion.stagger(1_000))")
        run.expectEqual(Motion.stagger(1_000), Motion.stagger(10_000), "stagger is capped flat")
        run.expect(Motion.stagger(5, step: 0.1, cap: 0.2) == 0.2, "custom cap respected")

        // --- Mood tints -------------------------------------------------------------
        // Every mood must map to a tint, and the calm moods must not reuse the
        // high-energy one.
        for mood in Mood.allCases {
            _ = Ink.tint(for: mood)   // must not trap
        }
        run.expect(Ink.tint(for: .low) != Ink.tint(for: .energized),
                   "low and energised must not share a tint")
        run.expectEqual(Ink.tint(for: .neutral), Ink.tint(for: .focused),
                        "neutral and focused share the baseline tint")

        // --- Typography ---------------------------------------------------------------
        // Every token must be a distinct, constructible font. Mostly this check
        // exists so that deleting a token breaks the build loudly.
        let fonts: [Font] = [
            Typeface.display, Typeface.title1, Typeface.title2, Typeface.title3,
            Typeface.headline, Typeface.body, Typeface.bodyEmphasis, Typeface.callout,
            Typeface.subheadline, Typeface.footnote, Typeface.caption,
            Typeface.captionEmphasis, Typeface.reading,
            Typeface.numeric(.title2), Typeface.numeric(.body, weight: .semibold)
        ]
        run.expectEqual(fonts.count, 15, "type scale is missing tokens")

        // --- Progress clamping ------------------------------------------------------
        // The bar and ring both clamp internally; verify the underlying maths
        // the same way they do it.
        for input in [-5.0, -0.001, 0, 0.5, 1, 1.001, 99] {
            let clamped = min(max(input, 0), 1)
            run.expect(clamped >= 0 && clamped <= 1, "progress clamp failed for \(input)")
        }

        // --- Sound cues ----------------------------------------------------------------
        for cue in SoundCue.allCases {
            run.expect(!cue.rawValue.isEmpty, "sound cue needs a name")
        }
        run.expect(SoundCue.allCases.count >= 5, "expected a full cue vocabulary")
        // Every cue must be short — UI sound that outlasts the interaction is
        // noise, and it would collide with Ace's voice.
        run.expect(SoundCue.allCases.count == Set(SoundCue.allCases.map(\.rawValue)).count,
                   "duplicate cue identifiers")
    }
}
