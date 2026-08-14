//
//  StudyReminders.swift
//  Ace
//
//  Telling the student when there is work waiting.
//
//  Ace had no notifications of any kind — not one call to
//  `UNUserNotificationCenter` anywhere in the project — while computing a due
//  date for every card it had ever made. The schedule was right and nothing
//  ever acted on it, so the whole point of spaced repetition (review it just
//  before you'd forget) depended on the student happening to open the app on
//  the correct day.
//
//  The rules this follows, which are the difference between a reminder and a
//  nag (§10):
//
//   • **One a day, maximum.** Not one per deck, not one per card.
//   • **Only when there is something to do.** No "come back!" when nothing is
//     due — that is the app asking for attention rather than offering something.
//   • **Never a guilt trip.** No streak countdowns, no "you're falling behind",
//     no red numbers. The copy comes from `ReviewQueue.summary`, which is
//     written to invite.
//   • **Silent while the crisis net is engaged.** A push about flashcards in
//     the middle of that would be indefensible.
//   • **Cancelled the moment the work is done**, so finishing a review at 9pm
//     does not produce a reminder about it at 9am.
//

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The bit of `UNUserNotificationCenter` this needs.
///
/// A protocol so the scheduling rules can be checked without the real
/// notification centre, which is unavailable outside an app bundle and would
/// otherwise make every decision here untestable — the same reason
/// `SecretStore` exists.
protocol ReminderScheduler: Sendable {
    func requestAuthorization() async -> Bool
    func cancelAll() async
    /// Schedule one reminder.
    func schedule(id: String, title: String, body: String, at date: Date) async
}

enum StudyReminders {

    /// One identifier, reused, so scheduling twice replaces rather than stacks.
    static let dailyIdentifier = "ace.reminder.daily"

    /// Default nudge time: late afternoon, when school is out and the evening
    /// has not yet been given away.
    static let defaultHour = 17

    /// Work out what should be scheduled, given the queue and the clock.
    ///
    /// Returns nil when nothing should fire. Separated from the scheduling
    /// itself so the decision — which is the part with rules in it — can be
    /// checked directly.
    static func plan(entries: [ReviewEntry],
                     now: Date = Date(),
                     hour: Int = defaultHour,
                     isSuppressed: Bool = false,
                     calendar: Calendar = .current) -> ReminderPlan? {
        // The crisis net outranks everything, including this.
        guard !isSuppressed else { return nil }

        let dueNow = ReviewQueue.due(from: entries, now: now)

        // Something is already waiting: remind at the next nudge time.
        if !dueNow.isEmpty {
            guard let body = ReviewQueue.summary(from: entries, now: now, calendar: calendar),
                  let fireAt = nextOccurrence(ofHour: hour, after: now, calendar: calendar)
            else { return nil }
            return ReminderPlan(fireAt: fireAt, title: "Ready when you are", body: body)
        }

        // Nothing due yet — line one up for the day the next card wakes.
        guard let next = ReviewQueue.nextDue(from: entries, now: now),
              let fireAt = occurrence(ofHour: hour, onDayOf: next, calendar: calendar),
              fireAt > now
        else { return nil }

        let count = entries.filter {
            !$0.state.isNew && calendar.isDate($0.state.dueDate, inSameDayAs: next)
        }.count
        let cards = count == 1 ? "1 card" : "\(count) cards"
        return ReminderPlan(fireAt: fireAt,
                            title: "Ready when you are",
                            body: "\(cards) ready to review.")
    }

    /// Apply a plan. Always cancels first, so there is only ever one.
    static func apply(_ plan: ReminderPlan?, using scheduler: some ReminderScheduler) async {
        await scheduler.cancelAll()
        guard let plan else { return }
        await scheduler.schedule(id: dailyIdentifier,
                                 title: plan.title,
                                 body: plan.body,
                                 at: plan.fireAt)
    }

    // MARK: - Times

    static func nextOccurrence(ofHour hour: Int,
                               after now: Date,
                               calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        guard let today = calendar.date(from: components) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    static func occurrence(ofHour hour: Int,
                           onDayOf date: Date,
                           calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = 0
        return calendar.date(from: components)
    }
}

/// What to schedule, and when.
struct ReminderPlan: Sendable, Equatable {
    let fireAt: Date
    let title: String
    let body: String
}

// MARK: - The real one

#if canImport(UserNotifications)
/// Talks to iOS.
struct SystemReminderScheduler: ReminderScheduler {

    func requestAuthorization() async -> Bool {
        // `.alert` and `.sound` only. No badge: a red number on the icon is a
        // debt the student did not agree to, and it is the single most common
        // reason an otherwise welcome app gets its notifications switched off.
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func cancelAll() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [StudyReminders.dailyIdentifier])
    }

    func schedule(id: String, title: String, body: String, at date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                         from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
