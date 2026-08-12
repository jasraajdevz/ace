//
//  AceWidget.swift
//  AceWidget
//
//  The widget's timeline. Deliberately dumb: read the snapshot the app wrote,
//  render it, ask to be woken again in an hour.
//
//  There's no clever scheduling here because there doesn't need to be. The app
//  calls `WidgetCenter.reloadAllTimelines()` the instant anything changes
//  (`WidgetBridge.publish`), so the hourly refresh is only a safety net for the
//  one thing the app can't push: the day rolling over and a streak going from
//  "safe" to "at risk" while the app is closed.
//

import SwiftUI
import WidgetKit

struct AceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct AceProvider: TimelineProvider {

    /// Shown in the widget gallery and while the real snapshot loads.
    func placeholder(in context: Context) -> AceEntry {
        AceEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (AceEntry) -> Void) {
        // In the gallery (`isPreview`) show the sample so the widget looks like
        // the product; everywhere else show the truth, even if it's empty.
        let snapshot = context.isPreview ? .preview : WidgetStore.read()
        completion(AceEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AceEntry>) -> Void) {
        let entry = AceEntry(date: Date(), snapshot: WidgetStore.read())

        // One hour. Frequent enough that a day boundary is picked up promptly,
        // sparse enough that iOS never starts throttling our refresh budget.
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct AceWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AceEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                AceMediumWidgetView(snapshot: entry.snapshot)
            default:
                AceSmallWidgetView(snapshot: entry.snapshot)
            }
        }
        // `containerBackground` is required from iOS 17 — a widget without one
        // renders with no background at all on the home screen.
        .containerBackground(for: .widget) {
            WidgetInk.background
        }
        // Tapping opens the app. Part 5 upgrades this to a deep link straight
        // into quick capture via App Intents.
        .widgetURL(URL(string: "ace://open"))
    }
}

struct AceWidget: Widget {
    static let kind = "AceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: AceProvider()) { entry in
            AceWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Ace")
        .description("Your level, your streak, and a nudge back to what you were studying.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
