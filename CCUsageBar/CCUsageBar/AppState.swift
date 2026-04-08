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

    private let runner = CCUsageRunner()
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

        let since = Self.firstOfMonthString()

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
        guard let data = UserDefaults.standard.data(forKey: "cachedUsageResponse") else { return }
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

    static func firstOfMonthString() -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        return String(format: "%04d%02d01", year, month)
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
