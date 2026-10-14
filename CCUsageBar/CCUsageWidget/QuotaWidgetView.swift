import SwiftUI
import WidgetKit

// The Home Screen widget's look at the small, medium, and large sizes, drawn
// from the Mac's published readings. Shared with the app's preview screen.

enum UsagePalette {
    static let claude = Color(red: 0.85, green: 0.45, blue: 0.25)
    static let fable = Color(red: 0.63, green: 0.28, blue: 0.13)
    static let codex = Color(red: 0.25, green: 0.58, blue: 0.65)
    static let background = Color(white: 0.11)

    // A limit's bar color in the widget and the app: gray for an outdated or
    // unconfirmed value, red from the warning line up, otherwise the tint.
    static func barFill(usedPercent: Double, isStale: Bool, tint: WidgetTint) -> Color {
        if isStale { return .gray.opacity(0.5) }
        return usedPercent >= QuotaPresentation.warningPercent ? .red : tint.color
    }
}

// What the widget says when it has no readings to show. None of these carry
// account values.
enum WidgetNotice: Equatable {
    case preview                 // the widget gallery and the loading placeholder
    case waitingForFirstReading
    case iCloudOff
    case iCloudRestricted
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    // nil until a reading from the Mac reaches this phone.
    var snapshot: QuotaSnapshot?
    // The saved page; the view clamps it to the pages that exist at its size.
    var page = 0
    var notice: WidgetNotice?
}

enum WidgetTint: Equatable {
    case claude, fable, codex, neutral

    var color: Color {
        switch self {
        case .claude: UsagePalette.claude
        case .fable: UsagePalette.fable
        case .codex: UsagePalette.codex
        case .neutral: .gray
        }
    }
}

enum RowDensity {
    case full, compact, mini
}

// One limit as the widget draws it.
struct WidgetRow: Identifiable, Equatable {
    let id: String
    let provider: QuotaProvider
    let label: String        // "Fable weekly"
    let shortLabel: String   // "Fable"
    let usedPercent: Double
    let resetsAt: Date?
    let longWindow: Bool     // a day or longer: its reset shows a weekday
    let isModelCap: Bool
    let state: WindowState
    let tint: WidgetTint

    // Outdated or past its reset: drawn gray, with the last number kept.
    var isStale: Bool { state != .current }
    var link: URL { QuotaWidgetModel.link(for: provider) }
}

// One provider's block: name, reading age, limits, and Codex's extras.
struct WidgetSection: Identifiable, Equatable {
    let provider: QuotaProvider
    let name: String
    let tint: WidgetTint
    let freshness: Freshness
    let observedAt: Date?
    let rows: [WidgetRow]
    let resetCredits: ResetCreditsInfo?
    let creditBalance: Double?

    var id: String { provider.rawValue }
    var link: URL { QuotaWidgetModel.link(for: provider) }
    var extrasLineCount: Int { (resetCredits == nil ? 0 : 1) + (creditBalance == nil ? 0 : 1) }

    // The small size shows a model cap only when it is closer to its limit
    // than every account-wide window, that is, when it's the one that binds.
    // Only the closest such cap fits.
    var smallRows: [WidgetRow] {
        guard let widest = rows.filter({ !$0.isModelCap }).map(\.usedPercent).max() else { return rows }
        let binding = rows.filter { $0.isModelCap && $0.usedPercent > widest }.max { $0.usedPercent < $1.usedPercent }
        return rows.filter { !$0.isModelCap || $0.id == binding?.id }
    }
}

// Turns a snapshot into the words, colors, and links the widget shows.
enum QuotaWidgetModel {
    // The widget's background opens the app without picking a provider.
    static let backgroundLink = URL(string: "ccusage://limits")!

    static func link(for provider: QuotaProvider) -> URL {
        var components = URLComponents()
        components.scheme = "ccusage"
        components.host = "provider"
        components.path = "/" + provider.rawValue
        return components.url ?? backgroundLink
    }

    // Claude and Codex always appear; one without a reading shows as unknown.
    static func sections(for snapshot: QuotaSnapshot, now: Date) -> [WidgetSection] {
        QuotaPresentation(now: now).providersIncludingDefaults(in: snapshot).map(section)
    }

    private static func section(_ provider: ProviderPresentation) -> WidgetSection {
        let rows = provider.windows.map { presented in
            let window = presented.window
            return WidgetRow(id: window.id, provider: provider.provider, label: fullLabel(window),
                             shortLabel: shortLabel(window), usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                             longWindow: (window.durationMinutes ?? 0) >= 1_440, isModelCap: window.scope == .model,
                             state: presented.state, tint: tint(provider.provider, scope: window.scope))
        }
        return WidgetSection(provider: provider.provider, name: provider.provider.displayName,
                             tint: tint(provider.provider, scope: .provider), freshness: provider.freshness,
                             observedAt: provider.observedAt, rows: rows, resetCredits: provider.resetCredits,
                             creditBalance: provider.creditBalance)
    }

    // Model caps inside Claude's allowance use the darker Fable color.
    static func tint(_ provider: QuotaProvider, scope: WindowScope) -> WidgetTint {
        switch provider {
        case .claude: scope == .model ? .fable : .claude
        case .codex: .codex
        default: .neutral
        }
    }

    // A model cap's name gains its length when the name lacks it: "Fable weekly".
    static func fullLabel(_ window: QuotaWindow) -> String {
        guard window.scope == .model, let minutes = window.durationMinutes else { return window.label }
        let length = QuotaWindow.lengthName(minutes: minutes).lowercased()
        return window.label.lowercased().hasSuffix(length) ? window.label : "\(window.label) \(length)"
    }

    // "5h" and "Wk" for account-wide windows; a model cap keeps its name.
    static func shortLabel(_ window: QuotaWindow) -> String {
        guard let minutes = window.durationMinutes else { return window.label }
        let short = QuotaWindow.shortName(minutes: minutes)
        guard window.scope == .model else { return short }
        let suffix = " " + QuotaWindow.lengthName(minutes: minutes).lowercased()
        guard window.label.lowercased().hasSuffix(suffix) else { return window.label }
        return "\(window.label.dropLast(suffix.count)) \(short)"
    }

    static func percentText(_ row: WidgetRow, density: RowDensity) -> String {
        let percent = "\(Int(row.usedPercent.rounded()))%"
        return density == .mini ? percent : "\(percent) used"
    }

    // A reset that passed with no newer reading is history, not a fresh 0%.
    static func resetText(_ row: WidgetRow, density: RowDensity, locale: Locale = .autoupdatingCurrent,
                          timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard density != .mini, let resetsAt = row.resetsAt else { return nil }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        let time = row.longWindow
            ? resetsAt.formatted(style.weekday(.abbreviated).hour().minute())
            : resetsAt.formatted(style.hour().minute())
        let passed = row.state == .resetPassedUnconfirmed
        if density == .compact { return passed ? "reset passed" : time }
        return passed ? "· reset \(time), unconfirmed" : "· resets \(time)"
    }

    // "3 full resets · next expires Oct 22", or a weekday within six days.
    static func resetCreditsText(_ credits: ResetCreditsInfo, now: Date, density: RowDensity,
                                 locale: Locale = .autoupdatingCurrent,
                                 timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let count = credits.available == 1 ? "1 full reset" : "\(credits.available) full resets"
        guard density != .mini, credits.available > 0, let expiry = credits.nextExpiry, expiry > now else { return count }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        let date = expiry.timeIntervalSince(now) < QuotaPresentation.weekdayWindow
            ? expiry.formatted(style.weekday(.abbreviated))
            : expiry.formatted(style.month(.abbreviated).day())
        return "\(count) · next expires \(date)"
    }

    static func creditBalanceText(_ balance: Double, locale: Locale = .autoupdatingCurrent) -> String {
        ResetCreditsInfo.balanceText(balance, locale: locale)
    }

    // e.g. "Claude weekly, 17 percent used, resets Saturday 2:59 PM"
    static func accessibilityLabel(_ row: WidgetRow, in section: WidgetSection, locale: Locale = .autoupdatingCurrent,
                                   timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let name = row.isModelCap ? "\(row.label) model limit" : row.label.lowercased()
        var parts = ["\(section.name) \(name)", "\(Int(row.usedPercent.rounded())) percent used"]
        if let resetsAt = row.resetsAt {
            let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
            let time = row.longWindow
                ? resetsAt.formatted(style.weekday(.wide).hour().minute())
                : resetsAt.formatted(style.hour().minute())
            parts.append(row.state == .resetPassedUnconfirmed ? "reset time passed \(time), not yet confirmed" : "resets \(time)")
        }
        if row.state == .outdated { parts.append("outdated reading") }
        return parts.joined(separator: ", ")
    }

    static func noticeText(_ notice: WidgetNotice) -> (title: String, message: String) {
        switch notice {
        case .preview:
            ("Limits from your Mac", "Used percentage, reset time, and reading age for each limit.")
        case .waitingForFirstReading:
            ("Waiting for your Mac's first reading", "Open CCUsageBar on your Mac. Readings arrive through iCloud.")
        case .iCloudOff:
            ("iCloud is off on this iPhone", "Sign in with the same Apple Account as your Mac.")
        case .iCloudRestricted:
            ("iCloud is restricted on this iPhone", "Screen Time or a device profile is blocking it.")
        }
    }
}

// MARK: - Views

// One widget size's content. The widget adds its own background and link.
struct QuotaWidgetContent: View {
    let entry: QuotaEntry
    let family: WidgetFamily

    // Always dark, regardless of the phone's appearance setting. Home Screen
    // widgets stop growing text at the xxLarge size (measured on iOS 26.5)
    // while still reporting the larger setting; the same limit here keeps the
    // paging estimate and the app's preview in step with the Home Screen.
    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .dynamicTypeSize(...QuotaPaging.largestWidgetTextSize)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            ReadingsView(sections: QuotaWidgetModel.sections(for: snapshot, now: entry.date),
                         page: entry.page, now: entry.date, family: family)
        } else {
            NoticeView(notice: entry.notice ?? .waitingForFirstReading, family: family)
        }
    }
}

private struct ReadingsView: View {
    let sections: [WidgetSection]
    let page: Int
    let now: Date
    let family: WidgetFamily
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if family == .systemSmall {
            // The small size never pages; it shows the binding limits only.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sections) { section in
                    SectionView(section: section, rows: section.smallRows, showsExtras: true,
                                showsMessage: section.rows.isEmpty, density: .mini, now: now)
                }
                Spacer(minLength: 0)
            }
            // Anything that can't fit runs off the bottom, never the header.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        } else {
            GeometryReader { proxy in
                paged(height: proxy.size.height)
            }
        }
    }

    // Rows that don't fit at this size and text size move to later pages.
    @ViewBuilder private func paged(height: CGFloat) -> some View {
        let pages = QuotaPaging.pages(for: sections, family: family, height: height, typeSize: typeSize)
        let current = QuotaPaging.clamp(page, pageCount: pages.count)
        VStack(alignment: .leading, spacing: 0) {
            if family == .systemMedium {
                // Providers side by side with one-line rows.
                HStack(alignment: .top, spacing: 16) {
                    ForEach(pages[current]) { slice in
                        sectionView(slice, density: .compact)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(pages[current]) { slice in
                        sectionView(slice, density: .full)
                    }
                }
            }
            Spacer(minLength: 0)
            if pages.count > 1 {
                PagerView(page: current, pageCount: pages.count)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionView(_ slice: WidgetPageSlice, density: RowDensity) -> some View {
        let section = sections[slice.section]
        return SectionView(section: section, rows: Array(section.rows[slice.rows]), showsExtras: slice.showsExtras,
                           showsMessage: slice.showsMessage, density: density, now: now)
    }
}

private struct SectionView: View {
    let section: WidgetSection
    let rows: [WidgetRow]
    let showsExtras: Bool
    let showsMessage: Bool
    let density: RowDensity
    let now: Date

    // Medium and large rows open the provider's details. The small size
    // can't hold links, so its whole face opens the app.
    var body: some View {
        if density == .mini {
            stack
        } else {
            // The tint keeps link text white in the app's preview, as on the Home Screen.
            Link(destination: section.link) { stack }
                .tint(Color.primary)
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if density == .full { header } else { compactHeader }
            if showsMessage {
                Text(section.freshness == .unknown ? "No reading yet" : "No limits reported")
                    .font(density == .full ? .subheadline : density == .compact ? .caption : .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(rows) { row in
                WindowRow(row: row, section: section, density: density)
            }
            if showsExtras && section.extrasLineCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    if let credits = section.resetCredits {
                        Text(QuotaWidgetModel.resetCreditsText(credits, now: now, density: density))
                    }
                    if let balance = section.creditBalance {
                        Text(QuotaWidgetModel.creditBalanceText(balance))
                    }
                }
                .font(density == .full ? .caption : .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
    }

    private var spacing: CGFloat {
        switch density {
        case .full: 10
        case .compact: 7
        case .mini: 4
        }
    }

    private var nameColor: Color {
        section.freshness == .current ? section.tint.color : .secondary
    }

    private var status: String? {
        switch section.freshness {
        case .outdated: "Outdated"
        case .unverified: "Unverified"
        case .current, .unknown: nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.name)
                .font(.headline)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            if let status {
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let ageText {
                ageText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(section.name)
                .font(density == .mini ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 2)
            // Small size: gray styling marks an outdated reading; the word won't fit.
            if let ageText {
                Group {
                    if let status, density == .compact { Text("\(status) · \(ageText)") } else { ageText }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // Self-updating age in whole minutes; iOS 17 falls back to the
    // seconds-level relative style. On the Home Screen, self-updating text
    // fills the row's free width, so the callers align it trailing. A reading
    // stamped ahead of this phone's clock shows its time instead of a
    // negative age.
    private var ageText: Text? {
        guard let observedAt = section.observedAt else { return nil }
        if section.freshness == .unverified {
            return Text(observedAt, style: .time)
        }
        if #available(iOS 18.0, *) {
            return Text(.currentDate, format: .reference(to: observedAt, allowedFields: [.minute, .hour, .day]))
        }
        return Text("\(observedAt, style: .relative) ago")
    }
}

private struct WindowRow: View {
    let row: WidgetRow
    let section: WidgetSection
    let density: RowDensity

    private var fill: Color {
        UsagePalette.barFill(usedPercent: row.usedPercent, isStale: row.isStale, tint: row.tint)
    }

    var body: some View {
        Group {
            switch density {
            case .full: fullBody
            case .compact: compactBody
            case .mini: miniBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QuotaWidgetModel.accessibilityLabel(row, in: section))
    }

    // One line: label, bar, percentage. Reset times live in the larger sizes.
    private var miniBody: some View {
        HStack(spacing: 5) {
            Text(row.shortLabel)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 30, alignment: .leading)
            UsageBar(percent: row.usedPercent, tint: fill, height: 5)
            Text(QuotaWidgetModel.percentText(row, density: .mini))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(row.isStale ? .secondary : .primary)
                .frame(minWidth: 28, alignment: .trailing)
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(row.shortLabel)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let reset = QuotaWidgetModel.resetText(row, density: .compact) {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 2)
                Text(QuotaWidgetModel.percentText(row, density: .compact))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.isStale ? .secondary : .primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            UsageBar(percent: row.usedPercent, tint: fill, height: 5)
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let reset = QuotaWidgetModel.resetText(row, density: .full) {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(QuotaWidgetModel.percentText(row, density: .full))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.isStale ? .secondary : .primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            UsageBar(percent: row.usedPercent, tint: fill)
        }
    }
}

// Also the app's bar. The track follows the color scheme, so it stays
// readable in the app's light mode as well as in the always-dark widget.
struct UsageBar: View {
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
        .accessibilityHidden(true)
    }
}

// Previous and next buttons. Separate tap targets from the provider links;
// they change only the saved page.
private struct PagerView: View {
    let page: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            button(forward: false, enabled: page > 0, symbol: "chevron.left", label: "Previous page")
            Text("\(page + 1) of \(pageCount)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Page \(page + 1) of \(pageCount)")
            button(forward: true, enabled: page < pageCount - 1, symbol: "chevron.right", label: "Next page")
        }
    }

    @ViewBuilder
    private func button(forward: Bool, enabled: Bool, symbol: String, label: String) -> some View {
        let image = Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .frame(width: 30, height: 22)
            .contentShape(Rectangle())
        if enabled {
            Button(intent: QuotaPageIntent(forward: forward, pageCount: pageCount)) { image }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(label)
        } else {
            image
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

// No readings yet: say why, with no bars and no account values.
private struct NoticeView: View {
    let notice: WidgetNotice
    let family: WidgetFamily

    var body: some View {
        let text = QuotaWidgetModel.noticeText(notice)
        let small = family == .systemSmall
        VStack(alignment: .leading, spacing: small ? 4 : 6) {
            Text("\(Text("Claude").foregroundStyle(UsagePalette.claude)) & \(Text("Codex").foregroundStyle(UsagePalette.codex))")
                .font(small ? .footnote.weight(.semibold) : .headline)
            Text(text.title)
                .font(small ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            Text(text.message)
                .font(small ? .caption2 : .caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
