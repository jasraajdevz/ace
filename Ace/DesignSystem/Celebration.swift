//
//  Celebration.swift
//  Ace
//
//  The reward moments: the XP toast and the level-up.
//
//  Two constraints shape everything here.
//
//  **It has to be worth showing someone.** A level-up that's a grey alert is a
//  level-up nobody screenshots. So: a particle burst, a springing mark, a
//  counting number, and a ring that fills.
//
//  **It has to be skippable and it has to respect Reduce Motion.** Celebration
//  that blocks the student from getting back to work is celebration that gets
//  resented by week two. Every surface here dismisses on tap, auto-dismisses on
//  a timer, and degrades to a still, readable card when the student has asked
//  the system to calm down.
//
//  Particles are drawn with `Canvas` inside a `TimelineView`, which renders on
//  the GPU in one pass — a hundred particles as individual SwiftUI views would
//  drop frames on an older phone.
//

import SwiftUI

// MARK: - Particles

/// One piece of confetti. Plain values so the whole system is a pure function of
/// elapsed time — no per-frame state to keep in sync.
private struct Particle {
    let angle: Double        // radians
    let speed: Double        // points per second
    let size: CGFloat
    let hue: Color
    let spin: Double         // radians per second
    let drift: Double        // horizontal wobble
    let lifetime: Double     // seconds
}

/// A one-shot burst of particles from the centre.
///
/// Deterministic: the particles are generated once from a seed so the burst is
/// identical every time, which makes it feel designed rather than random.
struct ParticleBurst: View {
    var count: Int = 90
    var duration: Double = 1.8
    /// Gravity in points per second squared.
    var gravity: Double = 620

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let particles: [Particle]
    private let start: Date

    init(count: Int = 90, duration: Double = 1.8, gravity: Double = 620, seed: UInt64 = 20_260_812) {
        self.count = count
        self.duration = duration
        self.gravity = gravity
        self.start = Date()

        var generator = SeededGenerator(seed: seed)
        let palette: [Color] = [Ink.accent, Ink.accentAlt, Ink.success, Ink.flame, Ink.warning]
        self.particles = (0..<count).map { index in
            // Spread evenly around the circle with a little jitter, so the burst
            // reads as a ring rather than a clump.
            let base = (Double(index) / Double(count)) * 2 * .pi
            let jitter = Double.random(in: -0.18...0.18, using: &generator)
            return Particle(
                angle: base + jitter,
                speed: Double.random(in: 190...460, using: &generator),
                size: CGFloat.random(in: 4...9, using: &generator),
                hue: palette[Int.random(in: 0..<palette.count, using: &generator)],
                spin: Double.random(in: -7...7, using: &generator),
                drift: Double.random(in: -34...34, using: &generator),
                lifetime: Double.random(in: 0.75...1.0, using: &generator)
            )
        }
    }

    var body: some View {
        // Reduce Motion removes the burst entirely rather than slowing it down.
        // A slow burst is still motion, and motion is the thing being opted out of.
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                Canvas { context, size in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    guard elapsed < duration else { return }

                    let origin = CGPoint(x: size.width / 2, y: size.height / 2)

                    for particle in particles {
                        let life = elapsed / (duration * particle.lifetime)
                        guard life < 1 else { continue }

                        // Simple projectile motion. Position is derived from
                        // elapsed time rather than integrated, so a dropped
                        // frame can never accumulate error.
                        let t = elapsed
                        let x = origin.x
                            + cos(particle.angle) * particle.speed * t
                            + particle.drift * t * t
                        let y = origin.y
                            + sin(particle.angle) * particle.speed * t
                            + 0.5 * gravity * t * t

                        // Fade out over the last 40% of life.
                        let opacity = life < 0.6 ? 1.0 : (1 - (life - 0.6) / 0.4)

                        var transform = context
                        transform.opacity = max(0, opacity)
                        transform.translateBy(x: x, y: y)
                        transform.rotate(by: .radians(particle.spin * t))

                        let rect = CGRect(
                            x: -particle.size / 2, y: -particle.size / 2,
                            width: particle.size, height: particle.size * 1.6
                        )
                        transform.fill(
                            Path(roundedRect: rect, cornerRadius: particle.size * 0.25),
                            with: .color(particle.hue)
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Level up

/// The full-screen level-up moment.
struct LevelUpView: View {
    let level: Int
    let title: String
    /// XP into the new level, 0...1 — the ring picks up where the student is.
    let progress: Double
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markScale: CGFloat = 0.3
    @State private var contentOpacity: Double = 0
    @State private var ringProgress: Double = 0
    @State private var showBurst = false

    var body: some View {
        ZStack {
            // A dimmed, blurred ground rather than an opaque one — the student
            // can still see where they were, so it reads as a moment rather
            // than a screen change.
            Ink.background.opacity(0.88)
                .ignoresSafeArea()

            if showBurst {
                ParticleBurst()
                    .ignoresSafeArea()
            }

            VStack(spacing: Space.xl) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Ink.accentSoft)
                        .frame(width: 190, height: 190)
                        .blur(radius: 44)

                    AceProgressRing(progress: ringProgress, lineWidth: 9)
                        .frame(width: 168, height: 168)

                    VStack(spacing: Space.xs) {
                        Text("LEVEL")
                            .font(.system(size: 12, design: .rounded).weight(.heavy))
                            .tracking(3)
                            .foregroundStyle(Ink.textTertiary)
                        Text("\(level)")
                            .font(.system(size: 68, design: .rounded).weight(.heavy))
                            .foregroundStyle(Ink.brandGradient)
                            .monospacedDigit()
                    }
                }
                .scaleEffect(markScale)

                VStack(spacing: Space.s) {
                    Text(title)
                        .font(Typeface.title2)
                        .foregroundStyle(Ink.textPrimary)
                    Text(encouragement)
                        .font(Typeface.callout)
                        .foregroundStyle(Ink.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(contentOpacity)

                Spacer()

                AceButton(title: "Keep going", action: onDismiss)
                    .opacity(contentOpacity)
                    .padding(.bottom, Space.xl)
            }
            .aceScreenPadding()
        }
        // Tapping anywhere dismisses. Nobody should have to hunt for the exit.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .onAppear(perform: animateIn)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Level \(level). \(title)."))
        .accessibilityAddTraits(.isModal)
    }

    private var encouragement: String {
        // Rotates by level so a regular player isn't reading the same sentence
        // every few days.
        let lines = [
            "That's what showing up looks like.",
            "You've put the hours in. It shows.",
            "Steady progress beats a good week.",
            "You're getting quicker at this.",
            "Nice. Back to it whenever you're ready."
        ]
        return lines[abs(level) % lines.count]
    }

    private func animateIn() {
        Feedback.levelUp()

        guard !reduceMotion else {
            // Still, immediate, fully readable.
            markScale = 1
            contentOpacity = 1
            ringProgress = progress
            return
        }

        withAnimation(Motion.bouncy) { markScale = 1 }
        withAnimation(Motion.gentle.delay(0.18)) { contentOpacity = 1 }
        withAnimation(.easeOut(duration: 0.9).delay(0.24)) { ringProgress = progress }

        // The burst lands a beat after the mark, so the two read as cause and
        // effect rather than as one noisy event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { showBurst = true }
    }
}

// MARK: - XP toast

/// The small "+12 XP" that slides in after something meaningful.
struct XPToast: View, Equatable {
    let amount: Int
    let caption: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = -60
    @State private var opacity: Double = 0

    /// `nonisolated` because a `View` is main-actor isolated and `Equatable` is
    /// not: without it the synthesised entry point lets another actor compare two
    /// toasts while the main actor is mutating them. Only the two immutable,
    /// `Sendable` fields are read, which is what makes stepping outside the actor
    /// safe here rather than merely quiet.
    nonisolated static func == (lhs: XPToast, rhs: XPToast) -> Bool {
        lhs.amount == rhs.amount && lhs.caption == rhs.caption
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Ink.accentAlt)
            Text("+\(amount)")
                .font(Typeface.numeric(.subheadline, weight: .heavy))
                .foregroundStyle(Ink.textPrimary)
            Text(caption)
                .font(Typeface.caption)
                .foregroundStyle(Ink.textSecondary)
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.l)
        .background(Ink.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
        .elevation(.medium)
        .offset(y: reduceMotion ? 0 : offset)
        .opacity(opacity)
        .onAppear {
            withAnimation(reduceMotion ? Motion.gentle : Motion.bouncy) {
                offset = 0
                opacity = 1
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Plus \(amount) XP. \(caption)"))
    }
}

/// Presents XP toasts and the level-up over any screen.
///
/// Screens push events into an `@Observable` `CelebrationCenter` and this
/// modifier deals with stacking, timing and dismissal — so no screen ever has
/// to own that logic.
struct CelebrationOverlay: ViewModifier {
    @Bindable var center: CelebrationCenter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = center.currentToast {
                    XPToast(amount: toast.amount, caption: toast.caption)
                        .id(toast.id)
                        .padding(.top, Space.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .aceAnimation(Motion.smooth, value: center.currentToast?.id)
            .overlay {
                if let levelUp = center.pendingLevelUp {
                    LevelUpView(
                        level: levelUp.level,
                        title: levelUp.title,
                        progress: levelUp.progress
                    ) {
                        center.dismissLevelUp()
                    }
                    .transition(.opacity)
                }
            }
            .aceAnimation(Motion.gentle, value: center.pendingLevelUp?.level)
    }
}

extension View {
    /// Attach XP toasts and the level-up celebration.
    func celebrations(_ center: CelebrationCenter) -> some View {
        modifier(CelebrationOverlay(center: center))
    }
}

/// Queues and times the reward moments.
@MainActor
@Observable
final class CelebrationCenter {

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let amount: Int
        let caption: String
    }

    struct LevelUp: Equatable {
        let level: Int
        let title: String
        let progress: Double
    }

    private(set) var currentToast: Toast?
    private(set) var pendingLevelUp: LevelUp?

    /// Set by the safety layer. While true, nothing here shows anything —
    /// see §10 and `SafetyCoordinator.isGamificationSuppressed`.
    var isSuppressed = false

    private var toastDismissal: Task<Void, Never>?

    /// Show an XP toast. A newer toast replaces an older one rather than
    /// queueing — during a fast quiz a queue would still be draining minutes
    /// later.
    func award(_ event: XPEvent) {
        guard !isSuppressed else { return }
        show(amount: event.amount, caption: event.caption)
    }

    func show(amount: Int, caption: String) {
        guard !isSuppressed, amount > 0 else { return }
        currentToast = Toast(amount: amount, caption: caption)

        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.9))
            guard !Task.isCancelled else { return }
            self?.currentToast = nil
        }
    }

    /// Show the level-up. Any pending toast is cleared first — two rewards on
    /// screen at once dilutes both.
    func celebrateLevelUp(level: Int, title: String, progress: Double) {
        guard !isSuppressed else { return }
        toastDismissal?.cancel()
        currentToast = nil
        pendingLevelUp = LevelUp(level: level, title: title, progress: progress)
    }

    func dismissLevelUp() {
        pendingLevelUp = nil
    }

    /// Clear everything immediately — used when the crisis net engages.
    func silence() {
        toastDismissal?.cancel()
        currentToast = nil
        pendingLevelUp = nil
    }
}
