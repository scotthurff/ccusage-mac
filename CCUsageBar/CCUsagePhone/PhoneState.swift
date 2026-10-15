import Foundation
import os

// Where the phone stands with iCloud after its last check.
enum CloudStatus: Equatable {
    case checking
    case upToDate(checkedAt: Date)
    case noRecord              // iCloud has no reading from the Mac
    case signedOut
    case restricted
    case unreachable           // the account check or fetch failed, timed out, or was unreadable
    case updateRequired(version: Int)
}

// Setup guidance or a short note shown above the readings.
struct PhoneNotice: Equatable {
    enum Kind: Equatable {
        case checking, waitingForFirstReading, noRecordKeepingCache, signedOut, restricted, unreachable, updateRequired
    }

    let kind: Kind
    let title: String
    let message: String
}

// Owns what the companion app shows. Renders the shared cache at once, then
// checks the iCloud account and fetches the newest published snapshot. A
// refresh never asks the Mac to collect; it only reads what the Mac published.
@MainActor
final class PhoneState: ObservableObject {
    @Published private(set) var stored: StoredSnapshot?
    @Published private(set) var status: CloudStatus = .checking
    @Published private(set) var isRefreshing = false
    // Set by a widget link; the details screen scrolls to it, then clears it.
    @Published var focusedProvider: QuotaProvider?

    private let cache: PhoneSnapshotCache
    private let fetchLatest: @MainActor () async -> CloudFetchResult
    private let checkAccount: @MainActor () async -> CloudAccountStatus
    private let reloadWidgets: @MainActor () -> Void
    private let clock: @MainActor () -> Date
    private var inFlight: Task<Void, Never>?
    private var refreshAgain = false
    private static let logger = Logger(subsystem: "com.ccusagebar.phone", category: "state")

    init(cache: PhoneSnapshotCache,
         fetchLatest: @escaping @MainActor () async -> CloudFetchResult,
         checkAccount: @escaping @MainActor () async -> CloudAccountStatus,
         reloadWidgets: @escaping @MainActor () -> Void,
         clock: @escaping @MainActor () -> Date = Date.init) {
        self.cache = cache
        self.fetchLatest = fetchLatest
        self.checkAccount = checkAccount
        self.reloadWidgets = reloadWidgets
        self.clock = clock
        stored = cache.read().stored
    }

    var checkedAt: Date? {
        if case .upToDate(let checkedAt) = status { return checkedAt }
        return nil
    }

    // Every provider in the snapshot, plus Claude and Codex as unknown if the
    // snapshot lacks them. Empty when there's no snapshot at all.
    func providers(at now: Date) -> [ProviderPresentation] {
        guard let snapshot = stored?.snapshot else { return [] }
        return QuotaPresentation(now: now).providersIncludingDefaults(in: snapshot)
    }

    // Callers that arrive while a refresh runs wait for that one.
    func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        isRefreshing = true
        let task = Task { await self.runRefreshes() }
        inFlight = task
        await task.value
    }

    // Checks the account right away so a fetch already in flight for the old
    // account is dropped, then fetches for the current one.
    func accountChanged() async {
        apply(await checkAccount())
        if inFlight != nil { refreshAgain = true }
        await refresh()
    }

    func open(_ url: URL) {
        guard let provider = Self.provider(fromDeepLink: url) else {
            Self.logger.info("Ignored link \(url.absoluteString, privacy: .public)")
            return
        }
        focusedProvider = provider
    }

    // ccusage://provider/claude or ccusage://provider/codex
    nonisolated static func provider(fromDeepLink url: URL) -> QuotaProvider? {
        guard url.scheme?.lowercased() == "ccusage", url.host?.lowercased() == "provider",
              let name = url.pathComponents.dropFirst().first?.lowercased() else { return nil }
        switch name {
        case "claude": return .claude
        case "codex": return .codex
        default: return nil
        }
    }

    var notice: PhoneNotice? {
        let hasData = stored != nil
        let keeping = "Showing the readings saved on this iPhone."
        switch status {
        case .checking, .upToDate:
            return hasData ? nil : PhoneNotice(kind: .checking, title: "Checking iCloud…",
                                               message: "Looking for the latest reading from your Mac.")
        case .noRecord:
            return hasData
                ? PhoneNotice(kind: .noRecordKeepingCache, title: "No reading in iCloud right now",
                              message: "\(keeping) They'll update when your Mac publishes again.")
                : PhoneNotice(kind: .waitingForFirstReading, title: "Waiting for the first reading from your Mac",
                              message: "Open CCUsageBar on your Mac and refresh it. Readings show up here after your Mac publishes them to iCloud. Both devices need the same Apple Account.")
        case .signedOut:
            return PhoneNotice(kind: .signedOut, title: "iCloud is off on this iPhone",
                               message: "Sign in to iCloud in Settings with the same Apple Account as your Mac. Readings travel through your private iCloud storage.")
        case .restricted:
            return PhoneNotice(kind: .restricted, title: "iCloud is restricted on this iPhone",
                               message: "Screen Time or a device profile is blocking iCloud." + (hasData ? " \(keeping)" : ""))
        case .unreachable:
            return PhoneNotice(kind: .unreachable, title: "Couldn't get a new reading from iCloud",
                               message: (hasData ? "\(keeping) " : "") + "Check your connection, then pull down to try again.")
        case .updateRequired:
            return PhoneNotice(kind: .updateRequired, title: "Update CCUsage on this iPhone",
                               message: "Your Mac is publishing a newer kind of reading than this app understands. Install the latest build from Xcode."
                                   + (hasData ? " Until then you'll see the last reading this app could read." : ""))
        }
    }

    private func runRefreshes() async {
        var passes = 0
        repeat {
            refreshAgain = false
            passes += 1
            await refreshOnce()
        } while refreshAgain && passes < 3
        // No suspension between the loop check and here, so a late
        // accountChanged either sets refreshAgain in time or starts a new run.
        inFlight = nil
        isRefreshing = false
    }

    private func refreshOnce() async {
        guard apply(await checkAccount()) else { return }
        let ticket = cache.beginFetch()
        let result = await fetchLatest()
        let outcome = cache.commit(result, ticket: ticket)
        // Reread: the widget may have saved something newer meanwhile.
        show(cache.read().stored)
        switch outcome {
        case .staleGeneration:
            Self.logger.info("Dropped a response fetched before the iCloud account changed")
            refreshAgain = true
            return
        case .stored:
            reloadWidgets()
        case .kept:
            break
        }
        status = status(for: result)
    }

    // Binds the cache to the account. Returns whether a fetch may go ahead:
    // only when the account is confirmed, so another account's record can't
    // land in this one's cache.
    @discardableResult
    private func apply(_ account: CloudAccountStatus) -> Bool {
        if cache.bind(account: account) {
            Self.logger.info("iCloud account changed or signed out; cleared phone cache")
            reloadWidgets()
        }
        show(cache.read().stored)
        switch account {
        case .available:
            return true
        case .noAccount:
            status = .signedOut
        case .restricted:
            status = .restricted
        case .temporarilyUnavailable:
            status = .unreachable
        }
        return false
    }

    private func show(_ snapshot: StoredSnapshot?) {
        if snapshot != stored { stored = snapshot }
    }

    private func status(for result: CloudFetchResult) -> CloudStatus {
        switch result {
        case .snapshot:
            return .upToDate(checkedAt: clock())
        case .missing:
            return .noRecord
        case .unsupported(let version):
            Self.logger.error("iCloud snapshot version \(version) is newer than this app supports")
            return .updateRequired(version: version)
        case .malformed:
            Self.logger.error("iCloud snapshot was unreadable")
            return .unreachable
        case .timedOut:
            Self.logger.error("iCloud fetch timed out")
            return .unreachable
        case .unavailable(let reason):
            Self.logger.error("iCloud fetch failed: \(reason, privacy: .public)")
            return .unreachable
        }
    }
}

// The words the details screen and VoiceOver use. Calendar and locale are
// parameters so tests can pin a time zone; the app passes the phone's own,
// which follow time zone changes.
enum PhoneText {
    static func readingAge(_ provider: ProviderPresentation, now: Date,
                           calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        guard let observedAt = provider.observedAt, let age = provider.age else {
            return "Your Mac hasn't read \(provider.provider.displayName) limits yet"
        }
        if provider.freshness == .unverified {
            return "Read on your Mac at \(localTime(observedAt, now: now, calendar: calendar, locale: locale)), ahead of this iPhone's clock"
        }
        return "Read on your Mac \(ago(age))"
    }

    static func freshness(_ freshness: Freshness) -> String {
        switch freshness {
        case .current: "Current"
        case .outdated(.aged): "Outdated · over an hour old"
        case .outdated(.failedAttempt): "Outdated · your Mac's last check failed"
        case .unknown: "No reading yet"
        case .unverified: "Unverified time"
        }
    }

    static func windowLabel(_ window: QuotaWindow) -> String {
        window.scope == .model ? "\(window.label) · model limit" : window.label
    }

    static func percentUsed(_ window: QuotaWindow) -> String {
        "\(Int(window.usedPercent.rounded()))% used"
    }

    // "today 2:59 PM", "Saturday 2:59 PM" within six days, else "Oct 23 at 2:59 PM".
    static func localTime(_ date: Date, now: Date,
                          calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return "today " + date.formatted(style.hour().minute())
        }
        if abs(date.timeIntervalSince(now)) < QuotaPresentation.weekdayWindow {
            return date.formatted(style.weekday(.wide).hour().minute())
        }
        return date.formatted(style.month(.abbreviated).day().hour().minute())
    }

    static func reset(_ window: WindowPresentation, now: Date,
                      calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let resetsAt = window.window.resetsAt else { return nil }
        let time = localTime(resetsAt, now: now, calendar: calendar, locale: locale)
        return window.state == .resetPassedUnconfirmed
            ? "Reset time passed \(time) · not yet confirmed"
            : "Resets \(time)"
    }

    // e.g. "Claude weekly, 17 percent used, resets Saturday 2:59 PM"
    static func accessibilityLabel(_ window: WindowPresentation, provider: ProviderPresentation, now: Date,
                                   calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let name = window.window.scope == .model
            ? "\(window.window.label) model limit"
            : window.window.label.lowercased()
        var parts = ["\(provider.provider.displayName) \(name)",
                     "\(Int(window.window.usedPercent.rounded())) percent used"]
        if let resetsAt = window.window.resetsAt {
            let time = localTime(resetsAt, now: now, calendar: calendar, locale: locale)
            parts.append(window.state == .resetPassedUnconfirmed
                         ? "reset time passed \(time), not yet confirmed"
                         : "resets \(time)")
        }
        if window.state == .outdated { parts.append("outdated reading") }
        return parts.joined(separator: ", ")
    }

    static func resetCredits(_ credits: ResetCreditsInfo, now: Date,
                             calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let count: String
        switch credits.available {
        case 0: return "No full resets"
        case 1: count = "1 full reset"
        default: count = "\(credits.available) full resets"
        }
        guard let expiry = credits.nextExpiry, expiry > now else { return count }
        return "\(count) · next expires \(localTime(expiry, now: now, calendar: calendar, locale: locale))"
    }

    static func creditBalance(_ balance: Double, locale: Locale = .autoupdatingCurrent) -> String {
        ResetCreditsInfo.balanceText(balance, locale: locale)
    }

    static func checked(_ checkedAt: Date, now: Date) -> String {
        "Checked iCloud \(ago(max(0, now.timeIntervalSince(checkedAt))))"
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60, remainder = minutes % 60
        if hours < 24 {
            if remainder == 0 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
            return "\(hours) hr \(remainder) min ago"
        }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}
