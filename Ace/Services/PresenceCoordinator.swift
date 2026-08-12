//
//  PresenceCoordinator.swift
//  Ace
//
//  The object that makes Ace feel like it's *there*.
//
//  It owns the four things that together make up presence:
//    • the body-double session and its quiet check-ins
//    • the Guardian — struggle help and the welcome back
//    • Do Not Disturb
//    • the focus music
//
//  It exists so no screen has to coordinate them. A screen reports what
//  happened ("they answered wrong", "the app went to the background") and this
//  decides whether Ace says anything — applying the DND filter, the Guardian's
//  cooldown, and the safety override in one place rather than five.
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class PresenceCoordinator {

    // MARK: Owned state

    private(set) var session = BodyDoubleSession()
    private(set) var guardian = Guardian()

    /// What Ace has said that's still on screen.
    private(set) var presenceMessage: PresenceMessage?
    private(set) var activeNudge: GuardianNudge?
    /// A comfort response, when something they said deserved one.
    private(set) var comfortMessage: String?

    var doNotDisturb = DoNotDisturbState.off {
        didSet { applyDoNotDisturb() }
    }

    let music = FocusMusicPlayer()

    // MARK: Session bookkeeping

    /// Set while the app is in the background, so the return can be greeted.
    private var leftAt: Date?
    private var tickTask: Task<Void, Never>?
    private weak var appState: AppState?

    init() {}

    // MARK: - Body double

    var isSessionActive: Bool { session.phase.isActive }
    var goal: StudyGoal? { session.goal }

    func begin(goal: StudyGoal, appState: AppState) {
        self.appState = appState
        // Music ducks whenever Ace speaks — whichever provider is producing the
        // voice. Neither side knows about the other.
        appState.onSpeakingChanged = { [weak self] speaking in
            self?.music.setDucking(speaking)
        }
        guardian.reset()
        let opening = session.begin(goal: goal)
        deliver(opening)
        startTicking()

        // Resume whatever ambience they last chose.
        if music.savedScene != .off { music.play(music.savedScene) }
    }

    func pauseSession() {
        session.pause()
        tickTask?.cancel()
    }

    func resumeSession() {
        session.resume()
        startTicking()
    }

    func finishSession() {
        tickTask?.cancel()
        tickTask = nil
        let closing = session.finish()
        deliver(closing)
        music.stop()
    }

    func markLandmarkReached() {
        tickTask?.cancel()
        deliver(session.markLandmarkReached())
    }

    /// Report countable progress toward the goal.
    func recordProgress(_ amount: Int = 1) {
        session.recordCompletion(amount)
    }

    /// The ambient loop. Fires every fifteen seconds; almost always does nothing,
    /// which is the point.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if let message = self.session.tick() {
                    self.deliver(message)
                }
            }
        }
    }

    // MARK: - Guardian

    /// Called after anything that changes how the session is going.
    func evaluateGuardian(signals: BehaviourSignals, mood: MoodReading) {
        // The safety net outranks everything. If it's engaged, the Guardian's
        // job is to be quiet.
        guard appState?.safety.isGamificationSuppressed != true else { return }
        guard activeNudge == nil else { return }

        let action = guardian.evaluate(signals: signals, mood: mood)
        guard action != .none, !guardian.wasDeclined(action) else { return }

        offer(action, mood: mood.mood)
    }

    /// The app came back to the foreground.
    func handleReturnToForeground() {
        guard let leftAt else { return }
        let away = Date().timeIntervalSince(leftAt)
        self.leftAt = nil

        // Under about ten seconds isn't leaving — it's a notification banner or
        // a glance. Greeting that would be absurd.
        guard away > 10, session.phase.isActive else { return }
        guard appState?.safety.isGamificationSuppressed != true else { return }

        appState?.signals.appExits += 1
        offer(.welcomeBack, mood: appState?.mood.mood ?? .neutral, awaySeconds: away)
    }

    func handleLeaveForeground() {
        leftAt = Date()
    }

    private func offer(_ action: GuardianAction, mood: Mood, awaySeconds: TimeInterval = 0) {
        guard let nudge = Guardian.nudge(for: action, mood: mood,
                                         goalText: session.goal?.displayText,
                                         awaySeconds: awaySeconds) else { return }
        guard doNotDisturb.allows(.nudge) || action == .welcomeBack else { return }

        guardian.recordNudge(action)
        activeNudge = nudge

        if nudge.isSpoken, doNotDisturb.allows(.directReply) {
            Task { await appState?.say(nudge.message) }
        } else {
            Feedback.nudge()
        }
    }

    /// The student took the offer.
    func acceptNudge() -> GuardianAction {
        let action = activeNudge?.action ?? .none
        activeNudge = nil
        return action
    }

    /// The student ignored it. Don't offer that again this session.
    func dismissNudge() {
        if let action = activeNudge?.action {
            guardian.recordDeclined(action)
        }
        activeNudge = nil
    }

    // MARK: - Comfort

    /// Check a message for something that deserves a human response.
    ///
    /// Runs strictly *after* the crisis net — anything it caught is its business.
    /// Returns true when comfort took over, so the caller skips the tutor.
    @discardableResult
    func checkComfort(_ message: String, studentName: String) -> Bool {
        guard appState?.safety.isGamificationSuppressed != true else { return false }
        guard let feeling = ComfortResponder.read(message) else { return false }

        comfortMessage = ComfortResponder.respond(to: feeling, studentName: studentName)

        if ComfortResponder.shouldMuteGamification(for: feeling) {
            appState?.celebrationsMuted = true
        }
        // Comfort is always spoken: this is the one moment where hearing it
        // matters more than reading it.
        if let text = comfortMessage {
            Task { await appState?.say(text) }
        }
        return true
    }

    func dismissComfort() { comfortMessage = nil }

    // MARK: - Do Not Disturb

    private func applyDoNotDisturb() {
        // Ace's own noise. The system-level Focus request is a *suggestion* the
        // OS may honour; ours is immediate and certain.
        Feedback.setMuted(doNotDisturb.isOn && doNotDisturb.quietsFeedback)

        if doNotDisturb.isOn && doNotDisturb.quietsAceChatter {
            // Clear anything ambient already on screen. Safety messages are
            // untouched — they're owned by SafetyCoordinator, not this.
            presenceMessage = nil
        }
    }

    func toggleDoNotDisturb() {
        doNotDisturb.isOn.toggle()
        Feedback.tap()
    }

    // MARK: - Delivery

    /// Show a presence message, subject to Do Not Disturb.
    private func deliver(_ message: PresenceMessage) {
        let importance: MessageImportance = message.kind == .closing ? .directReply : .ambient
        guard doNotDisturb.allows(importance) else { return }

        presenceMessage = message
        if message.isSpoken {
            Task { await appState?.say(message.text) }
        }

        // Ambient messages fade on their own. A check-in that needs dismissing
        // is a check-in that interrupted.
        if message.kind == .milestone {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if self?.presenceMessage?.id == message.id { self?.presenceMessage = nil }
            }
        }
    }

    func dismissPresenceMessage() { presenceMessage = nil }
}

// MARK: - Scene phase

/// Bridges SwiftUI's `scenePhase` into the Guardian.
///
/// This is what makes "you slipped off to a YouTube short" work: iOS tells us
/// the app resigned active, and tells us when it came back. Ace never learns
/// *where* they went, which is deliberate — see the welcome-back copy.
struct PresenceLifecycleModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let presence: PresenceCoordinator

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { previous, phase in
            switch phase {
            case .active where previous == .background || previous == .inactive:
                presence.handleReturnToForeground()
            case .background:
                presence.handleLeaveForeground()
            default:
                break
            }
        }
    }
}

extension View {
    /// Watch for the student leaving and coming back.
    func presenceLifecycle(_ presence: PresenceCoordinator) -> some View {
        modifier(PresenceLifecycleModifier(presence: presence))
    }
}
