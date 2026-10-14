import AppIntents
import SwiftUI
import WidgetKit

// Splitting the medium and large widgets into pages when their rows don't
// fit, and the buttons that move between pages. Paging only touches the
// saved page in the shared cache; it never fetches anything.

// One provider's share of a page.
struct WidgetPageSlice: Equatable, Identifiable {
    let section: Int
    let rows: Range<Int>
    let showsExtras: Bool
    // "No reading yet" or "No limits reported", for a provider without rows.
    let showsMessage: Bool

    var id: Int { section }
}

// Estimated heights in points, slightly generous so rows never clip.
struct WidgetLayoutMetrics: Equatable {
    let header: CGFloat
    let row: CGFloat
    let message: CGFloat
    let extraLine: CGFloat
    let itemSpacing: CGFloat
    let sectionSpacing: CGFloat
    let pager: CGFloat
}

enum QuotaPaging {
    // The largest text size a Home Screen widget draws, whatever the setting.
    static let largestWidgetTextSize = DynamicTypeSize.xxLarge

    // How much larger text is than the default size, from Apple's body sizes.
    static func textScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.35
        case .accessibility1: 1.65
        case .accessibility2: 1.94
        case .accessibility3: 2.35
        case .accessibility4: 2.76
        case .accessibility5: 3.12
        @unknown default: 1
        }
    }

    // Matches the fonts and spacing in QuotaWidgetView: text grows with the
    // text size, bars and gaps don't.
    static func metrics(for family: WidgetFamily, typeSize: DynamicTypeSize) -> WidgetLayoutMetrics {
        let scale = textScale(typeSize)
        let pager = max(22, 14 * scale) + 6
        if family == .systemMedium {
            return WidgetLayoutMetrics(header: 20 * scale, row: 16 * scale + 3 + 5, message: 16 * scale,
                                       extraLine: 14 * scale, itemSpacing: 7, sectionSpacing: 16, pager: pager)
        }
        return WidgetLayoutMetrics(header: 22 * scale, row: 20 * scale + 5 + 8, message: 20 * scale,
                                   extraLine: 16 * scale, itemSpacing: 10, sectionSpacing: 16, pager: pager)
    }

    // Every row lands on exactly one page, in display order. The large size
    // stacks providers; the medium size pages each provider's column. The
    // small size never pages.
    static func pages(for sections: [WidgetSection], family: WidgetFamily, height: CGFloat,
                      typeSize: DynamicTypeSize) -> [[WidgetPageSlice]] {
        if family == .systemSmall {
            return [sections.indices.map { index in
                WidgetPageSlice(section: index, rows: sections[index].rows.indices, showsExtras: true,
                                showsMessage: sections[index].rows.isEmpty)
            }]
        }
        let metrics = metrics(for: family, typeSize: typeSize)
        let pack = { (height: CGFloat) -> [[WidgetPageSlice]] in
            family == .systemMedium
                ? columns(sections, height: height, metrics)
                : stacked(sections, height: height, metrics)
        }
        let unpaged = pack(height)
        // Paging needs room for its buttons, which may push rows further.
        return unpaged.count > 1 ? pack(height - metrics.pager) : unpaged
    }

    static func clamp(_ page: Int, pageCount: Int) -> Int {
        min(max(page, 0), max(pageCount - 1, 0))
    }

    // A saved page out of range counts as the nearest real page first.
    static func step(from page: Int, forward: Bool, pageCount: Int) -> Int {
        clamp(clamp(page, pageCount: pageCount) + (forward ? 1 : -1), pageCount: pageCount)
    }

    @discardableResult
    static func turn(forward: Bool, pageCount: Int, cache: PhoneSnapshotCache) -> Int {
        cache.updatePage { step(from: $0, forward: forward, pageCount: pageCount) }
    }

    private enum Item: Equatable {
        case row(Int), message, extras
    }

    private static func items(_ section: WidgetSection) -> [Item] {
        var items: [Item] = section.rows.isEmpty ? [.message] : section.rows.indices.map { .row($0) }
        if section.extrasLineCount > 0 { items.append(.extras) }
        return items
    }

    private static func itemHeight(_ item: Item, in section: WidgetSection, _ metrics: WidgetLayoutMetrics) -> CGFloat {
        switch item {
        case .row: metrics.row
        case .message: metrics.message
        case .extras: CGFloat(section.extrasLineCount) * metrics.extraLine + CGFloat(section.extrasLineCount - 1) * 2
        }
    }

    private static func slice(_ section: Int, _ items: [Item]) -> WidgetPageSlice {
        let rows = items.compactMap { item -> Int? in
            if case .row(let index) = item { return index }
            return nil
        }
        return WidgetPageSlice(section: section, rows: (rows.first ?? 0)..<((rows.last ?? -1) + 1),
                               showsExtras: items.contains(.extras), showsMessage: items.contains(.message))
    }

    // Fills pages top to bottom. A provider split across pages repeats its
    // header. An empty page always takes one item, so a page too short for
    // any row still moves forward.
    private static func stacked(_ sections: [WidgetSection], height: CGFloat,
                                _ metrics: WidgetLayoutMetrics) -> [[WidgetPageSlice]] {
        var pages: [[WidgetPageSlice]] = []
        var page: [WidgetPageSlice] = []
        var used: CGFloat = 0
        for (index, section) in sections.enumerated() {
            let items = items(section)
            var next = 0
            while next < items.count {
                var total = used + (page.isEmpty ? 0 : metrics.sectionSpacing) + metrics.header
                var taken: [Item] = []
                for item in items[next...] {
                    let added = metrics.itemSpacing + itemHeight(item, in: section, metrics)
                    guard total + added <= height || (page.isEmpty && taken.isEmpty) else { break }
                    total += added
                    taken.append(item)
                }
                if taken.isEmpty {
                    pages.append(page)
                    page = []
                    used = 0
                    continue
                }
                page.append(slice(index, taken))
                used = total
                next += taken.count
                if next < items.count {
                    pages.append(page)
                    page = []
                    used = 0
                }
            }
        }
        if !page.isEmpty || pages.isEmpty { pages.append(page) }
        return pages
    }

    // Each provider fills its own column; page k shows each provider's k-th
    // column, or just its header once its rows have all been shown.
    private static func columns(_ sections: [WidgetSection], height: CGFloat,
                                _ metrics: WidgetLayoutMetrics) -> [[WidgetPageSlice]] {
        let perSection = sections.indices.map { index in
            stacked([sections[index]], height: height, metrics).map { page in
                WidgetPageSlice(section: index, rows: page[0].rows, showsExtras: page[0].showsExtras,
                                showsMessage: page[0].showsMessage)
            }
        }
        let count = max(1, perSection.map(\.count).max() ?? 1)
        return (0..<count).map { pageIndex in
            perSection.indices.map { index in
                pageIndex < perSection[index].count
                    ? perSection[index][pageIndex]
                    : WidgetPageSlice(section: index, rows: 0..<0, showsExtras: false, showsMessage: false)
            }
        }
    }
}

// Remembers the last page-button press. WidgetKit reloads the timeline right
// after one, and that reload should show the new page from the cache
// instead of waiting on iCloud.
struct WidgetPageTurns {
    static let window: TimeInterval = 20
    private static let key = "widgetPageTurnedAt"

    let defaults: UserDefaults?

    static func appGroup() -> WidgetPageTurns {
        WidgetPageTurns(defaults: UserDefaults(suiteName: PhoneSnapshotCache.appGroupIdentifier))
    }

    func record(at date: Date = .now) {
        defaults?.set(date.timeIntervalSince1970, forKey: Self.key)
    }

    func happenedRecently(now: Date = .now) -> Bool {
        guard let seconds = defaults?.object(forKey: Self.key) as? Double else { return false }
        let elapsed = now.timeIntervalSince1970 - seconds
        return elapsed >= 0 && elapsed < Self.window
    }
}

// The widget's previous and next buttons.
struct QuotaPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Change widget page"
    static let isDiscoverable = false

    @Parameter(title: "Forward") var forward: Bool
    // How many pages the widget drew, so the step stays in range.
    @Parameter(title: "Page count") var pageCount: Int

    init() {}

    init(forward: Bool, pageCount: Int) {
        self.forward = forward
        self.pageCount = pageCount
    }

    func perform() async throws -> some IntentResult {
        WidgetPageTurns.appGroup().record()
        QuotaPaging.turn(forward: forward, pageCount: pageCount, cache: .appGroup())
        return .result()
    }
}
