//
//  ReviewQueue.swift
//  Ace
//
//  What is due, across everything.
//
//  Ace has had a real SM-2 scheduler since Part 2 — `ReviewState` carries an
//  ease factor, an interval and a `dueDate`, and `SpacedRepetition.ordered`
//  sorts a deck so the due cards come first. All of that is correct and all of
//  it was invisible: `dueDate` was read in exactly one place, a count inside a
//  single source's detail screen. The student had to remember which of their
//  sources had work waiting and go looking for it.
//
//  Spaced repetition that never tells you it is time is a spreadsheet. This is
//  the piece that turns the schedule into something the app can act on: what is
//  due now, what is overdue, and when the next thing wakes up.
//
//  Pure and Foundation-only on purpose. It takes a flat list of entries rather
//  than SwiftData rows, so the whole thing runs in the checks — the layer above
//  it does the fetching.
//

import Foundation

/// One card's scheduling, with enough about its source to be actionable.
struct ReviewEntry: Sendable, Equatable, Identifiable {
    let id: UUID
    let sourceID: UUID
    let sourceTitle: String
    let state: ReviewState

    init(id: UUID, sourceID: UUID, sourceTitle: String, state: ReviewState) {
        self.id = id
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.state = state
    }
}

/// A source with work waiting.
struct ReviewGroup: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let dueCount: Int
    /// The oldest due date in the group — how long this has been waiting.
    let waitingSince: Date?
}

enum ReviewQueue {

    /// Everything due at `now`, oldest first.
    ///
    /// Overdue before merely due, because a card that slipped a week is the one
    /// closest to being forgotten — that is the entire premise of the schedule.
    /// New cards come last: they have never been learned, so they cannot be
    /// forgotten, and putting them ahead of a lapsing card spends the session on
    /// the wrong material.
    static func due(from entries: [ReviewEntry], now: Date = Date()) -> [ReviewEntry] {
        entries
            .filter { $0.state.dueDate <= now && !$0.state.isNew }
            .sorted { $0.state.dueDate < $1.state.dueDate }
    }

    /// Cards never studied. Offered after the due ones are cleared.
    static func fresh(from entries: [ReviewEntry]) -> [ReviewEntry] {
        entries.filter(\.state.isNew)
    }

    /// Due work grouped by source, biggest first.
    static func groups(from entries: [ReviewEntry], now: Date = Date()) -> [ReviewGroup] {
        let dueEntries = due(from: entries, now: now)
        let bySource = Dictionary(grouping: dueEntries, by: \.sourceID)

        return bySource.map { sourceID, cards in
            ReviewGroup(
                id: sourceID,
                title: cards.first?.sourceTitle ?? "",
                dueCount: cards.count,
                waitingSince: cards.map(\.state.dueDate).min()
            )
        }
        // Count first, then title, so the order is stable rather than however
        // the dictionary happened to hash today.
        .sorted { ($0.dueCount, $1.title) > ($1.dueCount, $0.title) }
    }

    /// When the next card becomes due, if nothing is due yet.
    static func nextDue(from entries: [ReviewEntry], now: Date = Date()) -> Date? {
        entries
            .filter { !$0.state.isNew && $0.state.dueDate > now }
            .map(\.state.dueDate)
            .min()
    }

    /// How far behind the oldest due card is, in whole days.
    static func daysOverdue(from entries: [ReviewEntry],
                            now: Date = Date(),
                            calendar: Calendar = .current) -> Int {
        guard let oldest = due(from: entries, now: now).first?.state.dueDate else { return 0 }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: oldest),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, days)
    }

    // MARK: - What to say about it

    /// The line Ace shows when there is work waiting.
    ///
    /// Every branch is an invitation, and none of them is a scold. A student who
    /// has been away for a fortnight already knows; being told "you're 14 days
    /// behind!" by a phone is how an app gets deleted rather than opened (§10).
    static func summary(from entries: [ReviewEntry],
                        now: Date = Date(),
                        calendar: Calendar = .current) -> String? {
        let count = due(from: entries, now: now).count
        guard count > 0 else { return nil }

        let overdue = daysOverdue(from: entries, now: now, calendar: calendar)
        let cards = count == 1 ? "1 card" : "\(count) cards"

        // Deliberately no number attached to the wait. "Been a while" carries the
        // same information as "23 days" without the sting.
        if overdue >= 7 { return "\(cards) waiting whenever you're ready." }
        if overdue >= 2 { return "\(cards) ready — been a couple of days." }
        return "\(cards) ready to review."
    }
}
