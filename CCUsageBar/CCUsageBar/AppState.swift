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
    @Published var claudeLimits: ProviderLimits?
    @Published var codexLimits: ProviderLimits?
    @Published var hasAttemptedLimitsFetch = false

    private let runner = CCUsageRunner()
    private let codexReader = CodexLimitsReader()
    private let claudeFetcher = ClaudeLimitsFetcher()
    private var refreshTask: Task<Void, Never>?

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

    init() {
        loadCache()
        Task { await refresh() }
        startRefreshLoop()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // Fan out concurrently; each source fails independently.
        async let usage: Void = refreshUsage()
        async let claude = claudeFetcher.fetchLimits()
        async let codex = codexReader.fetchLimits()

        // Failure policy: hold last-known values — only overwrite on success.
        // `--` appears only before the first-ever success (no cache, no fetch).
        if let claude = await claude {
            claudeLimits = claude
            saveLimitsCache(claude, key: "cachedClaudeLimits")
        }
        if let codex = await codex {
            codexLimits = codex
            saveLimitsCache(codex, key: "cachedCodexLimits")
        }
        hasAttemptedLimitsFetch = true
        await usage
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

    // MARK: - Limits

    var hasLimitsData: Bool {
        claudeLimits != nil || codexLimits != nil
    }

    // Max of the four gauges, expiry-adjusted via the shared gate.
    var hottestLimitPercent: Double? {
        let windows = [
            claudeLimits?.fiveHour, claudeLimits?.weekly,
            codexLimits?.fiveHour, codexLimits?.weekly
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return windows.map(\.effectivePercent).max()
    }

    var limitWarningActive: Bool {
        (hottestLimitPercent ?? 0) >= 80
    }

    // Menu bar: "$80 · 62%" — cost-only when limits unavailable, %-only when
    // cost missing, existing "--" when neither.
    var menuBarLabel: String {
        let limitPart = hottestLimitPercent.map { "\(Int($0.rounded()))%" }
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

    // MARK: - Cache

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: "cachedUsageResponse") {
            do {
                let response = try JSONDecoder().decode(UsageResponse.self, from: data)
                dailyData = response.daily
                totals = response.totals
                lastRefresh = UserDefaults.standard.object(forKey: "cacheTimestamp") as? Date
                Self.logger.info("Loaded cache: \(response.daily.count) days")
            } catch {
                Self.logger.error("Cache decode failed: \(error)")
            }
        }
        claudeLimits = loadLimitsCache(key: "cachedClaudeLimits")
        codexLimits = loadLimitsCache(key: "cachedCodexLimits")
    }

    private func loadLimitsCache(key: String) -> ProviderLimits? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ProviderLimits.self, from: data)
    }

    private func saveLimitsCache(_ limits: ProviderLimits, key: String) {
        if let data = try? JSONEncoder().encode(limits) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveCache(_ response: UsageResponse) {
        do {
            let data = try JSONEncoder().encode(response)
            UserDefaults.standard.set(data, forKey: "cachedUsageResponse")
            UserDefaults.standard.set(Date(), forKey: "cacheTimestamp")
        } catch {
            Self.logger.error("Cache save failed: \(error)")
        }
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
