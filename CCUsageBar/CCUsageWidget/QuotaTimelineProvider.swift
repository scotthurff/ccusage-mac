import Foundation
import os
import WidgetKit

// Builds the widget's timeline. Starts from the shared cache, tries one
// bounded iCloud read, and always finishes with the best cached reading.
// Later entries redraw the same reading as it ages or passes a reset; they
// never stand in for a new observation.
struct QuotaTimelineLoader {
    static let refreshInterval: TimeInterval = 30 * 60
    static let maxEntries = 24
    private static let logger = Logger(subsystem: "com.ccusagebar.widget", category: "timeline")

    let cache: PhoneSnapshotCache
    let checkAccount: () async -> CloudAccountStatus
    let fetchLatest: () async -> CloudFetchResult
    // True just after a page button press: that reload uses only the cache.
    let pagedRecently: () -> Bool
    // The whole iCloud attempt, well inside the time iOS gives a widget.
    var deadline: Duration = .seconds(8)
    var now: () -> Date = Date.init

    static func placeholderEntry(now: Date) -> QuotaEntry {
        QuotaEntry(date: now, notice: .preview)
    }

    // iOS decides when the refresh actually happens.
    static func nextRefresh(after now: Date) -> Date {
        now.addingTimeInterval(refreshInterval)
    }

    // The cache alone, for quick snapshots.
    func cachedEntry() -> QuotaEntry {
        entry(from: cache.read(), account: nil)
    }

    func load() async -> QuotaEntry {
        guard !pagedRecently() else { return cachedEntry() }
        let account = await Self.withDeadline(deadline) { [self] in await refreshCache() }
        if account == nil { Self.logger.info("iCloud check passed its deadline; showing the cache") }
        return entry(from: cache.read(), account: account)
    }

    func timeline() async -> Timeline<QuotaEntry> {
        let entry = await load()
        return Timeline(entries: Self.entries(startingWith: entry), policy: .after(Self.nextRefresh(after: entry.date)))
    }

    // The entry now, then one at each moment the display changes by itself:
    // a reading's one-hour mark, each reset, and Codex's credit expiry.
    static func entries(startingWith entry: QuotaEntry) -> [QuotaEntry] {
        guard let snapshot = entry.snapshot else { return [entry] }
        var marks = Set<Date>()
        for slot in snapshot.providers {
            guard let observation = slot.observation else { continue }
            marks.insert(observation.observedAt.addingTimeInterval(QuotaPresentation.outdatedAfter))
            // A reading stamped ahead of this phone's clock becomes trusted here.
            marks.insert(observation.observedAt.addingTimeInterval(-QuotaPresentation.futureTolerance))
            for window in observation.windows {
                if let reset = window.resetsAt { marks.insert(reset) }
            }
            if let expiry = observation.resetCredits?.nextExpiry {
                marks.insert(expiry)
                marks.insert(expiry.addingTimeInterval(-6 * 86_400))  // switches to a weekday
            }
        }
        let later = marks.filter { $0 > entry.date }.sorted().prefix(maxEntries - 1)
        return [entry] + later.map { QuotaEntry(date: $0, snapshot: entry.snapshot, page: entry.page, notice: entry.notice) }
    }

    // Checks the iCloud account, then fetches only for a confirmed one.
    // Returns the account status it saw.
    private func refreshCache() async -> CloudAccountStatus {
        let account = await checkAccount()
        if cache.bind(account: account) {
            Self.logger.info("iCloud account changed or signed out; cleared the widget's data")
        }
        guard case .available = account else { return account }
        let ticket = cache.beginFetch()
        let result = await fetchLatest()
        switch cache.commit(result, ticket: ticket) {
        case .stored:
            Self.logger.info("Saved a newer reading from iCloud")
        case .staleGeneration:
            Self.logger.info("Dropped a reading fetched before the iCloud account changed")
        case .kept:
            if case .snapshot = result { break }
            Self.logger.info("No new reading from iCloud: \(String(describing: result), privacy: .public)")
        }
        return account
    }

    private func entry(from state: PhoneCacheState, account: CloudAccountStatus?) -> QuotaEntry {
        let date = now()
        if let snapshot = state.stored?.snapshot {
            return QuotaEntry(date: date, snapshot: snapshot, page: state.page)
        }
        let notice: WidgetNotice
        switch account {
        case .noAccount: notice = .iCloudOff
        case .restricted: notice = .iCloudRestricted
        default: notice = .waitingForFirstReading
        }
        return QuotaEntry(date: date, notice: notice)
    }

    // Returns the work's result, or nil once the deadline passes even if the
    // work ignores cancellation.
    private static func withDeadline<T>(_ deadline: Duration, _ work: @escaping () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = FirstFinisher(continuation)
            let task = Task { await work() }
            let timer = Task {
                try? await Task.sleep(for: deadline)
                if gate.finish(nil) { task.cancel() }
            }
            Task {
                let value = await task.value
                if gate.finish(value) { timer.cancel() }
            }
        }
    }
}

// Lets the work and the timer race; whichever finishes first wins.
private final class FirstFinisher<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ value: T?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaTimelineLoader.placeholderEntry(now: .now)
    }

    // The gallery gets the placeholder, never real readings. A widget already
    // on the Home Screen gets its cached readings without waiting on iCloud.
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.loader().cachedEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let loader = Self.loader()
        Task { completion(await loader.timeline()) }
    }

    private static func loader() -> QuotaTimelineLoader {
        QuotaTimelineLoader(
            cache: .appGroup(),
            checkAccount: { await CloudAccountIdentity.current(timeout: .seconds(3)) },
            fetchLatest: { await CloudQuotaStore(timeout: .seconds(4)).fetchLatest() },
            pagedRecently: { WidgetPageTurns.appGroup().happenedRecently() })
    }
}
