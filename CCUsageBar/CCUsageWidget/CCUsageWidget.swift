import SwiftUI
import WidgetKit

// TEMPORARY feasibility widget (plan U1). Fetches the synthetic CloudKit record
// itself, which proves the extension reads iCloud without the app running.
struct SmokeEntry: TimelineEntry {
    let date: Date
    let headline: String
    let detail: String
}

struct SmokeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmokeEntry {
        SmokeEntry(date: .now, headline: "Synthetic smoke test", detail: "—")
    }

    func getSnapshot(in context: Context, completion: @escaping (SmokeEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SmokeEntry>) -> Void) {
        Task {
            let entry = await Self.fetchEntry()
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private static func fetchEntry() async -> SmokeEntry {
        do {
            if let reading = try await CloudKitSmoke.read() {
                return SmokeEntry(
                    date: .now,
                    headline: "nonce \(reading.nonce) from \(reading.writer)",
                    detail: "written \(reading.writtenAt.formatted(date: .omitted, time: .standard))"
                )
            }
            return SmokeEntry(date: .now, headline: "No record yet", detail: await CloudKitSmoke.accountStatusDescription())
        } catch {
            return SmokeEntry(date: .now, headline: "Fetch failed", detail: error.localizedDescription)
        }
    }
}

struct SmokeWidgetView: View {
    let entry: SmokeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SYNTHETIC SMOKE TEST")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(entry.headline).font(.headline.monospaced())
            Text(entry.detail).font(.caption.monospaced())
            Text("widget fetched \(entry.date.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SmokeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CCUsageSmokeTest", provider: SmokeProvider()) { entry in
            SmokeWidgetView(entry: entry)
        }
        .configurationDisplayName("CCUsage iCloud test")
        .description("Temporary synthetic iCloud check.")
        .supportedFamilies([.systemLarge])
    }
}

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
        SmokeWidget()
    }
}
