import SwiftUI
import WidgetKit

// The Home Screen widget: Claude and Codex limits at three sizes. The kind
// stays "CCUsageWidget" so widgets already placed keep working.
struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CCUsageWidget", provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude & Codex limits")
        .description("Used percentage, reset time, and reading age for each limit.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        QuotaWidgetContent(entry: entry, family: family)
            .containerBackground(UsagePalette.background, for: .widget)
            .widgetURL(QuotaWidgetModel.backgroundLink)
    }
}

@main
struct CCUsageWidgets: WidgetBundle {
    var body: some Widget {
        QuotaWidget()
    }
}
