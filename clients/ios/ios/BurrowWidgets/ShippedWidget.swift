import SwiftUI
import WidgetKit

/// Shipped today (task 01a21e75 stage 4): tasks done today, quiet and low
/// priority. The count and the newest title; opens the task board.
struct ShippedWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKinds.shipped, intent: WidgetScopeIntent.self, provider: FeedProvider()) { entry in
            ShippedWidgetView(entry: entry)
        }
        .configurationDisplayName("Shipped today")
        .description("What shipped today.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct ShippedWidgetView: View {
    static let title = "Shipped today"
    static let empty = "Nothing shipped yet today"
    let entry: FeedEntry
    var family: WidgetFamily?

    var body: some View {
        FeedSmallCount(title: Self.title, entry: entry, section: .shipped, empty: Self.empty, detail: entry.newestShipped)
            .padding(16)
            .widgetURL(entry.link(path: "/tasks"))
            .feedBackground()
    }
}
