import Foundation
import os

@MainActor
class AppState: ObservableObject {
    private static let logger = Logger(subsystem: "com.ccusagebar", category: "state")

    @Published var dailyData: [DailyUsage] = []
    @Published var totals: UsageTotals?
    @Published var isLoading = false
    @Published var lastRefresh: Date?
    @Published var errorMessage: String?
    @Published var hasAttemptedLimitsFetch = false
    // Each provider's latest accepted state: what the phone will be sent.
    @Published private(set) var quotaSlots: [QuotaProvider: ProviderSlot] = [:]

    static let quotaProviders: [QuotaProvider] = [.claude, .codex]
    private static let quotaStateKey = "quotaState"

    private let runner = CCUsageRunner()
    private let defaults: UserDefaults
    private let collectors: [QuotaProvider: QuotaCollector]
    private let publisher: QuotaPublisher?
    private let now: () -> Date
    // Local hashes of each provider's signed-in account. Never published.
    private var accountKeys: [QuotaProvider: String] = [:]
    private var inFlight: [QuotaProvider: Int] = [:]
    private var lastFinished: [QuotaProvider: Int] = [:]
    private var nextSequence = 0
    private var refreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    // Issued when a collection starts. Its result is accepted only if the
    // provider's account context is unchanged and no later collection has
    // already been accepted.
    struct CollectionTicket: Equatable {
        let provider: QuotaProvider
        let generation: String
        let sequence: Int
    }

    init(defaults: UserDefaults = .standard,
         claudeCollector: QuotaCollector = ClaudeLimitsFetcher(),
         codexCollector: QuotaCollector = CodexLimitsClient(),
         publisher: QuotaPublisher? = nil,
         now: @escaping () -> Date = { Date() },
         startsAutomatically: Bool = true) {
        self.defaults = defaults
        self.collectors = [.claude: claudeCollector, .codex: codexCollector]
        // The running app publishes to iCloud. Tests and checks that don't
        // start automatically publish only through a publisher they pass in.
        self.publisher = publisher ?? (startsAutomatically ? QuotaPublisher.live(defaults: defaults) : nil)
        self.now = now
        loadCache()
        loadQuotaState()
        guard startsAutomatically else { return }
        Task { await refresh() }
        startRefreshLoop()
        startClock()
    }

    var todayCostLabel: String {
        let todayStr = Self.todayDateString()
        if let today = dailyData.last(where: { $0.date == todayStr }) {
            return Self.formatCurrency(today.totalCost)
        }
        if !dailyData.isEmpty {
            return "$0.00"
        }
        return "--"
    }

    var hasData: Bool {
        !dailyData.isEmpty
    }

    var last7Days: [DailyUsage] {
        Array(dailyData.suffix(7).reversed())
    }

    var maxDailyCost: Double {
        last7Days.map(\.totalCost).max() ?? 1
    }

    var monthlyTotal: Double {
        totals?.totalCost ?? dailyData.reduce(0) { $0 + $1.totalCost }
    }

    var monthlyTokens: Int {
        totals?.totalTokens ?? dailyData.reduce(0) { $0 + $1.totalTokens }
    }

    var currentMonthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        return formatter.string(from: Date())
    }

    var lastRefreshText: String? {
        guard let lastRefresh else { return nil }
        let seconds = Int(-lastRefresh.timeIntervalSinceNow)
        if seconds < 60 { return "Refreshed just now" }
        if seconds < 3600 { return "Refreshed \(seconds / 60)m ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Last updated \(formatter.string(from: lastRefresh))"
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // Fan out concurrently; each source fails independently.
        async let usage: Void = refreshUsage()
        await refreshQuotas()
        await usage
    }

    func refreshQuotas() async {
        async let claude: Void = collect(.claude)
        async let codex: Void = collect(.codex)
        _ = await (claude, codex)
        hasAttemptedLimitsFetch = true
        publishQuotas()
    }

    private func refreshUsage() async {
        let since = Self.sinceDateString()
        do {
            let response = try await runner.fetchUsage(since: since)
            dailyData = response.daily
            totals = response.totals
            lastRefresh = Date()
            errorMessage = nil
            saveCache(response)
            Self.logger.info("Refreshed: \(response.daily.count) days, total $\(response.totals.totalCost, format: .fixed(precision: 2))")
        } catch {
            errorMessage = error.localizedDescription
            Self.logger.error("Refresh failed: \(error)")
        }
    }

    // MARK: - Quotas

    private func collect(_ provider: QuotaProvider) async {
        guard let collector = collectors[provider], let ticket = beginCollection(provider) else { return }
        finishCollection(ticket, await collector.collect())
    }

    // One collection per provider at a time.
    func beginCollection(_ provider: QuotaProvider) -> CollectionTicket? {
        guard inFlight[provider] == nil else { return nil }
        nextSequence += 1
        inFlight[provider] = nextSequence
        return CollectionTicket(provider: provider, generation: slot(provider).generation, sequence: nextSequence)
    }

    // Success replaces the provider's whole window list with the new reading.
    // Failure keeps the previous reading and its date, and records the failed
    // attempt, which marks that reading outdated.
    func finishCollection(_ ticket: CollectionTicket, _ result: QuotaCollectionResult) {
        let provider = ticket.provider
        if inFlight[provider] == ticket.sequence { inFlight[provider] = nil }
        var slot = slot(provider)
        guard ticket.generation == slot.generation, ticket.sequence > lastFinished[provider, default: 0] else {
            Self.logger.info("Dropped a superseded \(provider.rawValue) result")
            return
        }
        lastFinished[provider] = ticket.sequence

        // A different account never inherits the previous account's readings.
        // A missing identity signal, or a refreshed login token, is not a switch.
        if let key = result.accountKey {
            if let bound = accountKeys[provider], bound != key {
                Self.logger.info("\(provider.rawValue) account changed; dropped the previous account's readings")
                slot = Self.emptySlot(provider)
            }
            accountKeys[provider] = key
        }

        slot.acceptedAttempt += 1
        if let observation = result.observation {
            slot.observation = observation
            slot.lastAttempt = CollectionAttempt(at: observation.observedAt, outcome: .success)
        } else {
            slot.lastAttempt = CollectionAttempt(at: now(), outcome: .failure)
        }
        quotaSlots[provider] = slot
        saveQuotaState()
    }

    // Drops a provider's readings and starts a new account context. A read
    // still in flight belongs to the old context and will be rejected.
    func invalidate(_ provider: QuotaProvider) {
        quotaSlots[provider] = Self.emptySlot(provider)
        accountKeys[provider] = nil
        inFlight[provider] = nil
        saveQuotaState()
        publishQuotas()
    }

    // Hands a copy of the current slots to the publisher without waiting for
    // iCloud. Publishing never changes a slot or the menu bar.
    private func publishQuotas() {
        publisher?.submit(providerSlots)
    }

    func slot(_ provider: QuotaProvider) -> ProviderSlot {
        quotaSlots[provider] ?? ProviderSlot(provider: provider, generation: "", acceptedAttempt: 0,
                                             observation: nil, lastAttempt: nil)
    }

    var providerSlots: [ProviderSlot] {
        Self.quotaProviders.compactMap { quotaSlots[$0] }
    }

    // The shared rules the phone uses: age, outdated, unknown, passed resets.
    func presentation(_ provider: QuotaProvider) -> ProviderPresentation {
        QuotaPresentation(now: now()).provider(slot(provider))
    }

    var hasLimitsData: Bool {
        quotaSlots.values.contains { $0.observation != nil }
    }

    // Hottest current gauge across providers and model caps. Outdated or
    // unconfirmed numbers stay out of the menu bar; the popover keeps them.
    // Hint: CL/CX for providers, first two letters for model caps (Fable → FA).
    var hottestLimit: (hint: String, percent: Double)? {
        Self.quotaProviders
            .flatMap { provider in
                presentation(provider).windows
                    .filter { $0.state == .current }
                    .map { (hint: Self.menuBarHint(provider, $0.window), percent: $0.window.usedPercent) }
            }
            .max { $0.percent < $1.percent }
    }

    private static func menuBarHint(_ provider: QuotaProvider, _ window: QuotaWindow) -> String {
        if window.scope == .model { return String(window.label.uppercased().prefix(2)) }
        switch provider {
        case .claude: return Provider.claude.menuBarHint
        case .codex: return Provider.codex.menuBarHint
        default: return String(provider.rawValue.uppercased().prefix(2))
        }
    }

    var limitWarningActive: Bool {
        (hottestLimit?.percent ?? 0) >= 80
    }

    // Menu bar: "$80 · CL 62%" — cost-only when no current limit, limit-only
    // when cost missing, existing "--" when neither.
    var menuBarLabel: String {
        let limitPart = hottestLimit.map { hottest in
            "\(hottest.hint) \(Int(hottest.percent.rounded()))%"
        }
        if let cost = todayCost {
            if let limitPart {
                return "$\(Int(cost.rounded())) · \(limitPart)"
            }
            return todayCostLabel
        }
        return limitPart ?? "--"
    }

    private var todayCost: Double? {
        guard hasData else { return nil }
        let todayStr = Self.todayDateString()
        return dailyData.last(where: { $0.date == todayStr })?.totalCost ?? 0
    }

    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900)) // 15 minutes
                await self?.refresh()
            }
        }
    }

    // Ages and passed resets change with time alone; redraw once a minute.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Cache

    private func loadCache() {
        if let data = defaults.data(forKey: "cachedUsageResponse") {
            do {
                let response = try JSONDecoder().decode(UsageResponse.self, from: data)
                dailyData = response.daily
                totals = response.totals
                lastRefresh = defaults.object(forKey: "cacheTimestamp") as? Date
                Self.logger.info("Loaded cache: \(response.daily.count) days")
            } catch {
                Self.logger.error("Cache decode failed: \(error)")
            }
        }
    }

    private func saveCache(_ response: UsageResponse) {
        do {
            let data = try JSONEncoder().encode(response)
            defaults.set(data, forKey: "cachedUsageResponse")
            defaults.set(Date(), forKey: "cacheTimestamp")
        } catch {
            Self.logger.error("Cache save failed: \(error)")
        }
    }

    private struct StoredQuotaState: Codable {
        var slots: [ProviderSlot]
        // Keyed by provider; local account hashes only.
        var accountKeys: [String: String]
    }

    // Loading never changes an observation date. On the first launch of this
    // version, Claude's old cache moves over with its original date; Codex's
    // old cache came from local logs, so Codex starts unknown instead.
    private func loadQuotaState() {
        if let data = defaults.data(forKey: Self.quotaStateKey) {
            if let stored = try? JSONDecoder.quota.decode(StoredQuotaState.self, from: data) {
                for slot in stored.slots where Self.quotaProviders.contains(slot.provider) {
                    quotaSlots[slot.provider] = slot
                }
                for provider in Self.quotaProviders {
                    if quotaSlots[provider] == nil { quotaSlots[provider] = Self.emptySlot(provider) }
                    accountKeys[provider] = stored.accountKeys[provider.rawValue]
                }
                return
            }
            Self.logger.error("Stored quota state was unreadable; starting from the old caches")
        }
        var claude = Self.emptySlot(.claude)
        if let data = defaults.data(forKey: "cachedClaudeLimits"),
           let legacy = try? JSONDecoder().decode(ProviderLimits.self, from: data),
           let observation = legacy.migratedClaudeObservation(now: now()) {
            claude.observation = observation
            claude.lastAttempt = CollectionAttempt(at: observation.observedAt, outcome: .success)
        }
        quotaSlots = [.claude: claude, .codex: Self.emptySlot(.codex)]
        saveQuotaState()
    }

    private func saveQuotaState() {
        let stored = StoredQuotaState(
            slots: providerSlots,
            accountKeys: Dictionary(uniqueKeysWithValues: accountKeys.map { ($0.key.rawValue, $0.value) }))
        do {
            defaults.set(try JSONEncoder.quota.encode(stored), forKey: Self.quotaStateKey)
        } catch {
            Self.logger.error("Quota state save failed: \(error)")
        }
    }

    // A new account context: an opaque id, no readings yet.
    private static func emptySlot(_ provider: QuotaProvider) -> ProviderSlot {
        ProviderSlot(provider: provider, generation: UUID().uuidString, acceptedAttempt: 0,
                     observation: nil, lastAttempt: nil)
    }

    // MARK: - Helpers

    static func formatTokens(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(value)"
    }

    static func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
    }

    static func todayDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    static func sinceDateString() -> String {
        // ccusage hangs on large date ranges, so request a 14-day window
        // (popover only shows last 7 days; extra buffer for stability)
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    static func displayDate(_ dateString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = inputFormatter.date(from: dateString) else { return dateString }

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "EEE MMM d"
        return outputFormatter.string(from: date)
    }
}
