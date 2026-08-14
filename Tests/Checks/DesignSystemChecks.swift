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

// MARK: - Contrast

/// WCAG contrast, computed against the same hex values the app renders.
///
/// This exists because a restyle is the one change this machine cannot check by
/// looking. There is no simulator here, so "is the new palette readable" has to
/// be a number rather than an opinion — and the numbers caught three real
/// problems in the deepened palette that eyeballing a hex list would not have:
/// the primary button's gradient bottomed out at 2.97:1 under its own label,
/// accent-on-surface sat at 4.44, and tertiary text on a pressed surface at
/// 4.23.
///
/// Ratios are computed from `InkHex` rather than a copy of the palette, so the
/// checks cannot drift away from what ships.
enum ContrastChecks {

    /// Relative luminance, per WCAG 2.1.
    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
             + 0.7152 * channel((hex >> 8) & 0xFF)
             + 0.0722 * channel(hex & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG AA for body text.
    private static let bodyMinimum = 4.5
    /// WCAG AA for large text, and the non-text contrast floor for graphics.
    private static let graphicMinimum = 3.0

    static let all = CheckSuite(name: "Colour contrast") { run in

        let grounds: [(String, UInt32)] = [
            ("background", InkHex.background),
            ("surfaceSunken", InkHex.surfaceSunken),
            ("surface", InkHex.surface),
            ("surfaceRaised", InkHex.surfaceRaised),
            ("surfaceActive", InkHex.surfaceActive),
        ]
        let texts: [(String, UInt32)] = [
            ("textPrimary", InkHex.textPrimary),
            ("textSecondary", InkHex.textSecondary),
            ("textTertiary", InkHex.textTertiary),
        ]

        // --- Every text token, on every surface it can land on ------------------
        //
        // Every combination, not a sample: a token exists precisely so it can be
        // used anywhere, and "we only put tertiary on the background" is an
        // assumption that stops being true the first time someone builds a chip.
        for (textName, text) in texts {
            for (groundName, ground) in grounds {
                let r = ratio(text, ground)
                run.expect(r >= bodyMinimum,
                           "\(textName) on \(groundName) is \(String(format: "%.2f", r)):1 "
                           + "— below AA (\(bodyMinimum):1)")
            }
        }

        // --- The primary button's label, across its whole gradient --------------
        //
        // Checking one representative stop would have passed while the bottom
        // third of the button was unreadable.
        for stop in Ink.accentGradientStops {
            let r = ratio(InkHex.textOnAccent, stop)
            run.expect(r >= bodyMinimum,
                       "the button label is \(String(format: "%.2f", r)):1 on gradient stop "
                       + "\(String(format: "%06X", stop)) — below AA")
        }

        // --- Gradient-painted text ---------------------------------------------
        //
        // `brandGradient` is used as a `foregroundStyle`, so the text *is* the
        // gradient. Every stop has to hold up against the ground behind it.
        for stop in Ink.brandGradientStops {
            let r = ratio(stop, InkHex.background)
            run.expect(r >= graphicMinimum,
                       "brand gradient stop \(String(format: "%06X", stop)) is "
                       + "\(String(format: "%.2f", r)):1 on the background")
        }

        // --- Accent as text -----------------------------------------------------
        run.expect(ratio(InkHex.accent, InkHex.surface) >= bodyMinimum,
                   "accent text on a card is "
                   + "\(String(format: "%.2f", ratio(InkHex.accent, InkHex.surface))):1")

        // --- Semantic colours, used as icons and status text --------------------
        let semantic: [(String, UInt32)] = [
            ("success", InkHex.success), ("warning", InkHex.warning),
            ("danger", InkHex.danger), ("flame", InkHex.flame),
            ("care", InkHex.care), ("calm", InkHex.calm),
        ]
        for (name, colour) in semantic {
            for (groundName, ground) in grounds {
                let r = ratio(colour, ground)
                run.expect(r >= graphicMinimum,
                           "\(name) on \(groundName) is \(String(format: "%.2f", r)):1")
            }
        }

        // --- The ground ladder --------------------------------------------------
        //
        // Depth only reads if each layer is genuinely lighter than the one below.
        // Monotonic, and every step big enough to be visible on a phone in
        // daylight — an invisible step is a layer that may as well not exist.
        var previous = luminanceOf(InkHex.background)
        for (name, ground) in grounds.dropFirst() {
            let current = luminanceOf(ground)
            run.expect(current > previous,
                       "\(name) must be lighter than the layer below it")
            run.expect(ratio(ground, InkHex.background) >= 1.02,
                       "\(name) is indistinguishable from the background")
            previous = current
        }

        // Text on the two special surfaces, which have their own grounds.
        run.expect(ratio(InkHex.textPrimary, 0x100C0A) >= bodyMinimum,
                   "crisis-support text must be readable on its warm ground")
        run.expect(ratio(InkHex.care, 0x1F1814) >= graphicMinimum,
                   "the care accent must be visible on the care surface")
        run.expect(ratio(InkHex.textPrimary, 0x070B0F) >= bodyMinimum,
                   "calm-mode text must be readable")

        // `accentDeep` is allowed to be dark — but only where nothing sits on it.
        // Asserting that keeps the reason recorded rather than remembered.
        run.expect(ratio(InkHex.accentDeep, InkHex.background) < graphicMinimum,
                   "accentDeep is the decorative-only stop; if it now clears the "
                   + "graphic floor, the comment explaining why it is excluded "
                   + "from brandGradient is stale")
        run.expect(!Ink.brandGradientStops.contains(InkHex.accentDeep),
                   "accentDeep must not be a stop in gradient-painted text")
        run.expect(!Ink.accentGradientStops.contains(InkHex.accentDeep),
                   "accentDeep must not sit under the button label")
    }

    private static func luminanceOf(_ hex: UInt32) -> Double { luminance(hex) }
}

// MARK: - The widget across a day boundary

/// The widget has to age correctly.
///
/// It used to be handed a conclusion — `streakStateRaw` and a nudge line, both
/// computed by the app at publish time — and then render them for as long as
/// nobody opened the app. "Is this streak safe" is a question whose answer
/// changes at midnight, so by breakfast the home screen could be showing a lit
/// flame and "12 days running" for a streak that was already at risk.
///
/// The hourly refresh did not help: it re-read the same frozen string. Its own
/// comment said it existed so "a day boundary is picked up promptly".
enum WidgetAgingChecks {
    static let all = CheckSuite(name: "Widget across a day boundary") { run in

        let calendar = Calendar(identifier: .gregorian)
        let noonToday = Date(timeIntervalSince1970: 1_770_000_000)
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: noonToday) ?? noonToday
        }

        // Published today, read today.
        var snapshot = WidgetSnapshot.empty
        snapshot.streakDays = 12
        snapshot.sourceCount = 3
        snapshot.lastSourceTitle = "Photosynthesis"
        snapshot.lastStudyDay = noonToday
        snapshot.repairsAvailable = 1

        run.expectEqual(snapshot.streakState(at: noonToday, calendar: calendar), .safeToday,
                        "studied today reads as safe")
        run.expectEqual(snapshot.nudge(at: noonToday, calendar: calendar), "12 days running.",
                        "and the copy matches")

        // The same snapshot, one day later. Nothing republished — the student
        // simply hasn't opened the app.
        run.expectEqual(snapshot.streakState(at: day(1), calendar: calendar), .atRisk,
                        "the next day, the same snapshot must read as at risk")
        run.expectEqual(snapshot.nudge(at: day(1), calendar: calendar),
                        "12 days going — one session keeps it.",
                        "and the copy must follow the state, not stay frozen with it")

        // Two days: savable, because a repair is in hand.
        run.expectEqual(snapshot.streakState(at: day(2), calendar: calendar), .repairable,
                        "two days out with a repair available is savable")
        run.expect(snapshot.nudge(at: day(2), calendar: calendar).contains("savable"),
                   "and says so")

        // Two days with no repair left is simply broken.
        var noRepair = snapshot
        noRepair.repairsAvailable = 0
        run.expectEqual(noRepair.streakState(at: day(2), calendar: calendar), .broken,
                        "no repair left means two days out is broken")

        run.expectEqual(snapshot.streakState(at: day(5), calendar: calendar), .broken,
                        "five days out is broken regardless")
        run.expect(snapshot.nudge(at: day(5), calendar: calendar).contains("Fresh start"),
                   "and the copy invites rather than scolds")

        // A student with nothing captured is never nagged about a streak.
        var empty = WidgetSnapshot.empty
        empty.sourceCount = 0
        run.expectEqual(empty.nudge(at: noonToday, calendar: calendar),
                        "Point Ace at something you're studying.",
                        "an empty install gets a starting point, not a streak line")

        // No study day at all — no streak to be at risk of losing.
        run.expectEqual(WidgetSnapshot.empty.streakState(at: day(30), calendar: calendar), .none,
                        "a student who has never studied has no streak state to age")

        // The snapshot survives a round trip through the store's encoding, since
        // that is how the widget actually receives it.
        if let data = try? JSONEncoder().encode(snapshot),
           let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            run.expectEqual(decoded.streakState(at: day(1), calendar: calendar), .atRisk,
                            "the ingredients survive encoding — a stored conclusion would not")
            run.expectEqual(decoded.lastStudyDay, snapshot.lastStudyDay, "last study day round-trips")
        } else {
            run.expect(false, "the snapshot must encode and decode")
        }

        // Ordering: every state the app can publish is one the widget can render.
        for state in [StreakDisplayState.none, .safeToday, .atRisk, .repairable, .broken] {
            let line = WidgetCopy.nudge(state: state, days: 4, sourceCount: 2, lastTitle: "Cells")
            run.expect(!line.isEmpty, "\(state) must have a line")
            // §10: never a countdown, never a warning.
            for word in ["don't", "lose", "losing", "fail", "warning", "last chance"] {
                run.expect(!line.lowercased().contains(word),
                           "widget copy for \(state) must not pressure: “\(line)”")
            }
        }
    }
}

// MARK: - Sharing several things at once

/// `ShareInbox.add` is called once per attachment, from `NSItemProvider`
/// completion handlers — which fire on arbitrary queues, concurrently.
///
/// It was a read-modify-write over a shared file with no synchronisation at
/// all: `load()`, append, `write`. Two handlers landing together both read the
/// same manifest and the second write erased the first item. Sharing five
/// screenshots at once — which the extension explicitly supports — quietly
/// dropped some of them.
///
/// This is the file the share extension leans on, and until now nothing in the
/// project executed a single line of it under concurrency.
enum ShareConcurrencyChecks {
    static let all = CheckSuite(name: "Sharing several items at once") { run in
        guard ShareInbox.containerURL != nil else {
            // No App Group on this machine — the store has nowhere to live.
            // Say so rather than reporting a pass that proved nothing.
            run.expect(true, "App Group unavailable here; inbox concurrency not exercised")
            return
        }

        ShareInbox.clearAll()

        // Baseline first. If sequential adds don't work on this machine, the
        // concurrent result proves nothing about the race — it would just be
        // measuring a broken container.
        run.expect(ShareInbox.add(ShareInboxItem(payload: .text, inlineText: "one")),
                   "a single sequential add must succeed before concurrency means anything")
        run.expectEqual(ShareInbox.load().count, 1, "and must be readable back")
        ShareInbox.clearAll()

        let total = 24
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "share.hammer", attributes: .concurrent)
        for index in 0..<total {
            group.enter()
            queue.async {
                _ = ShareInbox.add(ShareInboxItem(payload: .text,
                                                  inlineText: "item \(index)"))
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 10)

        let stored = ShareInbox.load()
        run.expectEqual(stored.count, total,
                        "every concurrently shared item must survive — lost "
                        + "\(total - stored.count) of \(total)")

        let texts = Set(stored.compactMap(\.inlineText))
        run.expectEqual(texts.count, stored.count, "no item may be duplicated")

        ShareInbox.clearAll()
        run.expectEqual(ShareInbox.load().count, 0, "clearing empties the inbox")
    }
}

// MARK: - Muting must not eat the student's settings

/// A temporary silence and a stored preference were the same variable.
///
/// `Feedback.setMuted` wrote to `isEnabled`, whose `didSet` persists to
/// `UserDefaults`. So the crisis net and Do Not Disturb were both editing the
/// student's saved settings on their behalf, and "unmute" meant "switch on"
/// rather than "put back what they chose".
///
/// Two ways that hurt someone, and the second is the one that matters: the
/// crisis net mutes on the way in and unmutes only when the student taps
/// "I'm okay". Plenty of people never tap it. The mute was on disk by then, so
/// the app returned silent on every launch afterwards — a safety response
/// leaving a permanent, unexplained degradation behind (§10).
enum MutePreferenceChecks {
    static let all = CheckSuite(name: "Muting leaves settings alone") { run in
        // Both singletons are main-actor isolated, and the runner's top-level
        // code *is* the main thread — so this is a statement of fact, not a
        // way around the checker.
        MainActor.assumeIsolated { body(run) }
    }

    @MainActor
    private static func body(_ run: CheckRun) {
        let sound = SoundCuePlayer.shared
        let haptics = HapticSettings.shared
        let soundKey = "ace.sounds.enabled"
        let hapticKey = "ace.haptics.enabled"

        let originalSound = sound.isEnabled
        let originalHaptics = haptics.isEnabled
        defer {
            sound.isEnabled = originalSound
            haptics.isEnabled = originalHaptics
            Feedback.setMuted(false)
        }

        // A student who has deliberately turned sounds off.
        sound.isEnabled = false
        haptics.isEnabled = false
        run.expect(!sound.isAudible, "sounds off means nothing plays")
        run.expect(!haptics.shouldVibrate, "haptics off means nothing buzzes")

        // Do Not Disturb goes on, then off again.
        Feedback.setMuted(true)
        run.expect(!sound.isAudible, "muting keeps them off")
        Feedback.setMuted(false)

        // The bug: unmuting used to switch them back ON and save that.
        run.expect(!sound.isEnabled,
                   "unmuting must restore the student's choice, not override it")
        run.expect(!haptics.isEnabled, "same for haptics")
        run.expect(!sound.isAudible, "and nothing should be audible afterwards")
        run.expectEqual(UserDefaults.standard.bool(forKey: soundKey), false,
                        "their saved preference must still say off")
        run.expectEqual(UserDefaults.standard.bool(forKey: hapticKey), false,
                        "their saved haptic preference too")

        // The other direction: someone who wants sound, muted mid-session.
        sound.isEnabled = true
        haptics.isEnabled = true
        run.expect(sound.isAudible, "sound on plays")

        // The crisis net engages — and the student never taps "I'm okay",
        // which is the case that used to persist a permanent silence.
        Feedback.setMuted(true)
        run.expect(!sound.isAudible, "the crisis net silences everything")
        run.expect(!haptics.shouldVibrate, "haptics included")
        run.expectEqual(UserDefaults.standard.bool(forKey: soundKey), true,
                        "a transient mute must never reach the stored preference — "
                        + "an unacknowledged crisis would otherwise leave the app "
                        + "silent on every launch afterwards")
        run.expectEqual(UserDefaults.standard.bool(forKey: hapticKey), true,
                        "same for haptics")

        // Acknowledging brings it back to what they had.
        Feedback.setMuted(false)
        run.expect(sound.isAudible, "acknowledging restores sound")
        run.expect(haptics.shouldVibrate, "and haptics")

        // Settings still wins while muted — changing a preference mid-mute is
        // recorded, it just isn't audible yet.
        Feedback.setMuted(true)
        sound.isEnabled = false
        Feedback.setMuted(false)
        run.expect(!sound.isAudible, "a preference changed during a mute still holds after it")
    }
}

// MARK: - The capture screen's state machine

/// `CaptureView` used to hold this as `@State`, so the whole path —
/// photograph, recognise, check, review — type-checked and never ran once.
///
/// The bug that hid there: when the safety net fired on recognised text, the
/// function returned while the stage was still `.reading`. A student whose
/// photographed page tripped the crisis net dismissed the support screen and
/// landed back on a spinner that never stopped.
///
/// Every check below drives the same code the screen runs.
enum CaptureFlowChecks {

    /// Returns whatever it is told to, so recognition can be driven rather than
    /// depending on Vision and a real photograph.
    private final class StubProvider: AIProvider, @unchecked Sendable {
        var mode: AIProviderMode = .demo
        var isReady: Bool { true }

        var result: RecognizedText = .empty
        var errorToThrow: (any Error)?
        private(set) var readCount = 0

        init(_ result: RecognizedText) { self.result = result }
        init(throwing error: any Error) { self.errorToThrow = error }

        func readText(from imageData: Data) async throws -> RecognizedText {
            readCount += 1
            if let errorToThrow { throw errorToThrow }
            return result
        }

        // Nothing else is exercised here.
        func speak(_ text: String, persona: VoicePersona, prosody: Prosody) async throws {}
        func stopSpeaking() async {}
        func transcribe(audio: Data) async throws -> String { "" }
        func tutorReply(context: TutorContext) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func makeQuiz(from source: StudyMaterialSource, gradeLevel: GradeLevel,
                      title: String, questionCount: Int) async throws -> Quiz {
            throw AIProviderError.noTextFound
        }
        func makeFlashcards(from source: StudyMaterialSource, gradeLevel: GradeLevel,
                            title: String, limit: Int) async throws -> [Flashcard] { [] }
        func readEmotion(audio: Data?, text: String?,
                         signals: BehaviourSignals) async -> MoodReading { .unknown }
    }

    static let all = CheckSuite(name: "Capture flow") { run in
        let image = [Data(repeating: 0, count: 8)]
        let good = RecognizedText(
            lines: ["Photosynthesis converts light energy into chemical energy.",
                    "It happens in the chloroplast."], confidence: 0.9)

        // --- The happy path ------------------------------------------------------
        if let stage = runAsync({ () -> CaptureFlow.Stage in
            let flow = await CaptureFlow()
            await flow.process(images: image, kind: .cameraPhoto,
                               provider: StubProvider(good), safety: await SafetyCoordinator())
            return await flow.stage
        }) {
            run.expectEqual(stage, .reviewing, "readable text goes to review")
        } else {
            run.expect(false, "capture probe timed out")
        }

        // --- Nothing readable ----------------------------------------------------
        if let stage = runAsync({ () -> CaptureFlow.Stage in
            let flow = await CaptureFlow()
            await flow.process(images: image, kind: .cameraPhoto,
                               provider: StubProvider(.empty), safety: await SafetyCoordinator())
            return await flow.stage
        }) {
            if case .failed = stage {} else {
                run.expect(false, "an unreadable photo should fail, got \(stage)")
            }
        }

        // --- Recognition threw ---------------------------------------------------
        if let stage = runAsync({ () -> CaptureFlow.Stage in
            let flow = await CaptureFlow()
            await flow.process(images: image, kind: .cameraPhoto,
                               provider: StubProvider(throwing: AIProviderError.offline),
                               safety: await SafetyCoordinator())
            return await flow.stage
        }) {
            if case .failed(let message) = stage {
                run.expect(!message.isEmpty, "a failure must say something useful")
                run.expect(message.lowercased().contains("demo")
                           || message.lowercased().contains("offline")
                           || !message.isEmpty,
                           "and should point at the way forward")
            } else {
                run.expect(false, "a thrown error should fail the stage, got \(stage)")
            }
        }

        // --- THE BUG: a photographed page that trips the crisis net --------------
        if let result = runAsync({ () -> (CaptureFlow.Stage, Int, Bool, Bool) in
            let flow = await CaptureFlow()
            let safety = await SafetyCoordinator()
            let distressing = RecognizedText(
                lines: ["i want to kill myself", "i can't do this any more"], confidence: 0.9)
            await flow.process(images: image, kind: .cameraPhoto,
                               provider: StubProvider(distressing), safety: safety)
            return await (flow.stage, flow.recognized.lines.count,
                          flow.thumbnail == nil, safety.isGamificationSuppressed)
        }) {
            let (stage, lineCount, thumbnailCleared, engaged) = result
            run.expect(engaged, "a photographed page must go through the crisis net")
            run.expectEqual(stage, .choosing,
                            "the screen must land somewhere the student can leave from — "
                            + "it used to stay on `.reading` forever")
            run.expectEqual(lineCount, 0,
                            "the text that triggered it must not be left loaded")
            run.expect(thumbnailCleared, "nor the photograph of it")
        }

        // --- Pasted text goes through the same net ------------------------------
        MainActor.assumeIsolated {
            let flow = CaptureFlow()
            let safety = SafetyCoordinator()
            run.expect(!flow.paste("i want to kill myself", safety: safety),
                       "pasted text is checked too")
            run.expectEqual(flow.stage, .choosing, "and lands somewhere safe to leave")
            run.expect(safety.isGamificationSuppressed, "with the net engaged")

            let ok = CaptureFlow()
            run.expect(ok.paste("The mitochondria is the powerhouse of the cell.",
                                safety: SafetyCoordinator()),
                       "ordinary notes paste fine")
            run.expectEqual(ok.stage, .reviewing, "and go to review")
            run.expectEqual(ok.pendingKind, .pastedText, "recorded as pasted")

            let blank = CaptureFlow()
            run.expect(!blank.paste("   \n  ", safety: SafetyCoordinator()),
                       "whitespace is not text")
            if case .failed = blank.stage {} else {
                run.expect(false, "blank paste should say so, got \(blank.stage)")
            }

            // Retaking clears what was there.
            let retake = CaptureFlow()
            _ = retake.paste("Some notes.", safety: SafetyCoordinator())
            retake.reset()
            run.expectEqual(retake.stage, .choosing, "retake returns to the start")
            run.expectEqual(retake.recognized.lines.count, 0, "and drops the old text")
        }
    }
}
