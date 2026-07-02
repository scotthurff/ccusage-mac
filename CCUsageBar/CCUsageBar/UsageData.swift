import Foundation

struct UsageResponse: Codable {
    let daily: [DailyUsage]
    let totals: UsageTotals
}

struct DailyUsage: Codable, Identifiable {
    var id: String { date }
    let date: String
    let inputTokens: Int

    // ccusage v20 renamed "date" to "period" in daily JSON output
    enum CodingKeys: String, CodingKey {
        case date = "period"
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens
        case totalTokens, totalCost, modelsUsed, modelBreakdowns
    }
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let totalCost: Double
    let modelsUsed: [String]
    let modelBreakdowns: [ModelBreakdown]
}

struct ModelBreakdown: Codable, Identifiable {
    var id: String { modelName }
    let modelName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let cost: Double
}

struct UsageTotals: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalCost: Double
    let totalTokens: Int
}
