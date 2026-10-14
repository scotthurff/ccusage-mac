import SwiftUI
import WidgetKit

// Large Home Screen widget: Claude and Codex limits with used percentages,
// reset times, and each provider's reading age.
// PREVIEW: fed by a fixed sample of real 2026-10-14 readings until the iCloud
// snapshot path exists (plan U2-U6). The widget says "Preview" on screen.

struct UsageWindow: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let usedPercent: Double
    let resetsAt: Date?
    let weekly: Bool
    let tint: Color
}

struct ProviderReading: Identifiable {
    let name: String
    let tint: Color
    let observedAt: Date
    let windows: [UsageWindow]
    var id: String { name }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let providers: [ProviderReading]
    let isPreview: Bool
}

enum UsagePalette {
    static let claude = Color(red: 0.85, green: 0.45, blue: 0.25)
    static let fable = Color(red: 0.63, green: 0.28, blue: 0.13)
    static let codex = Color(red: 0.25, green: 0.58, blue: 0.65)
    static let background = Color(white: 0.11)
}

enum UsagePreview {
    // Claude: the Mac app's cached live reading at 11:42 AM.
    // Codex: the live account-limit read at 11:26 AM.
    static let providers: [ProviderReading] = [
        ProviderReading(
            name: "Claude",
            tint: UsagePalette.claude,
            observedAt: Date(timeIntervalSinceReferenceDate: 813_696_141),
            windows: [
                UsageWindow(id: "claude-5h", label: "5-hour", shortLabel: "5h", usedPercent: 2,
                            resetsAt: Date(timeIntervalSinceReferenceDate: 813_713_399), weekly: false, tint: UsagePalette.claude),
                UsageWindow(id: "claude-wk", label: "Weekly", shortLabel: "Wk", usedPercent: 17,
                            resetsAt: Date(timeIntervalSinceReferenceDate: 813_967_199), weekly: true, tint: UsagePalette.claude),
                UsageWindow(id: "claude-fable-wk", label: "Fable weekly", shortLabel: "Fable", usedPercent: 0,
                            resetsAt: Date(timeIntervalSinceReferenceDate: 813_967_200), weekly: true, tint: UsagePalette.fable),
            ]
        ),
        ProviderReading(
            name: "Codex",
            tint: UsagePalette.codex,
            observedAt: Date(timeIntervalSinceReferenceDate: 813_695_200),
            windows: [
                UsageWindow(id: "codex-wk", label: "Weekly", shortLabel: "Wk", usedPercent: 13,
                            resetsAt: Date(timeIntervalSinceReferenceDate: 814_166_108), weekly: true, tint: UsagePalette.codex),
            ]
        ),
    ]
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, providers: UsagePreview.providers, isPreview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // One entry now, plus one at each provider's one-hour mark so the
        // outdated state appears without a new fetch.
        let now = Date.now
        let marks = UsagePreview.providers
            .map { $0.observedAt.addingTimeInterval(UsageFreshness.outdatedAfter) }
            .filter { $0 > now }
        let entries = ([now] + marks).sorted().map {
            UsageEntry(date: $0, providers: UsagePreview.providers, isPreview: true)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

enum UsageFreshness {
    static let outdatedAfter: TimeInterval = 60 * 60
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        UsageWidgetContent(entry: entry, family: family)
            .containerBackground(UsagePalette.background, for: .widget)
    }
}

// Shared with the companion app, which previews both sizes.
struct UsageWidgetContent: View {
    let entry: UsageEntry
    let family: WidgetFamily

    // Always dark, regardless of the phone's appearance setting.
    var body: some View {
        content.environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        if family == .systemMedium {
            // Providers side by side with one-line rows.
            HStack(alignment: .top, spacing: 16) {
                ForEach(entry.providers) { provider in
                    ProviderSection(provider: provider, now: entry.date, compact: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottomTrailing) {
                if entry.isPreview {
                    Text("Preview")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(entry.providers) { provider in
                    ProviderSection(provider: provider, now: entry.date, compact: false)
                }
                Spacer(minLength: 0)
                if entry.isPreview {
                    Text("Preview · sample readings, not live")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct ProviderSection: View {
    let provider: ProviderReading
    let now: Date
    let compact: Bool

    private var isOutdated: Bool {
        now.timeIntervalSince(provider.observedAt) >= UsageFreshness.outdatedAfter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(provider.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOutdated ? Color.secondary : provider.tint)
                    Spacer(minLength: 2)
                    (isOutdated ? Text("Outdated · \(ageText)") : ageText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                header
            }
            ForEach(provider.windows) { window in
                WindowRow(window: window, providerOutdated: isOutdated, now: now, compact: compact)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(provider.name)
                .font(.headline)
                .foregroundStyle(isOutdated ? Color.secondary : provider.tint)
            Spacer()
            if isOutdated {
                Text("Outdated")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ageText
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // Self-updating age in whole minutes; iOS 17 falls back to the
    // seconds-level relative style.
    private var ageText: Text {
        if #available(iOS 18.0, *) {
            return Text(.currentDate, format: .reference(to: provider.observedAt, allowedFields: [.minute, .hour, .day]))
        }
        return Text("\(provider.observedAt, style: .relative) ago")
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let providerOutdated: Bool
    let now: Date
    let compact: Bool

    // A reset that passed without a confirming read is history, not a fresh 0%.
    private var resetPassed: Bool { window.resetsAt.map { $0 <= now } ?? false }
    private var isStale: Bool { providerOutdated || resetPassed }

    private var fill: Color {
        if isStale { return .gray.opacity(0.5) }
        return window.usedPercent >= 80 ? .red : window.tint
    }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .accessibilityElement(children: .combine)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.shortLabel)
                    .font(.caption.weight(.medium))
                if let resetsAt = window.resetsAt {
                    Text(resetPassed ? "reset passed" : resetText(resetsAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 2)
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? .secondary : .primary)
            }
            UsageBar(percent: window.usedPercent, tint: fill, height: 5)
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.subheadline.weight(.medium))
                if let resetsAt = window.resetsAt {
                    Text(resetPassed ? "· reset \(resetText(resetsAt)), unconfirmed" : "· resets \(resetText(resetsAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(Int(window.usedPercent.rounded()))% used")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? .secondary : .primary)
            }
            UsageBar(percent: window.usedPercent, tint: fill)
        }
    }

    private func resetText(_ date: Date) -> String {
        window.weekly
            ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : date.formatted(.dateTime.hour().minute())
    }
}

private struct UsageBar: View {
    let percent: Double
    let tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if percent > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, geometry.size.width * min(percent, 100) / 100))
                }
            }
        }
        .frame(height: height)
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CCUsageWidget", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude & Codex limits")
        .description("Used percentage, reset time, and reading age for each limit.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
