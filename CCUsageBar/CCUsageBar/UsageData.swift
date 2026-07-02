import Foundation

struct UsageResponse: Codable {
    let daily: [DailyUsage]
    let totals: UsageTotals
}

enum Provider: CaseIterable {
    case claude
    case codex
    case other

    static func classify(modelName: String) -> Provider {
        if modelName.hasPrefix("claude") { return .claude }
        if modelName.hasPrefix("gpt") { return .codex }
        return .other
    }

    var menuBarHint: String {
        switch self {
        case .claude: return "CL"
        case .codex: return "CX"
        case .other: return "??"
        }
    }
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

    func cost(for provider: Provider) -> Double {
        modelBreakdowns
            .filter { Provider.classify(modelName: $0.modelName) == provider }
            .reduce(0) { $0 + $1.cost }
    }

    // Fable sub-slice of the Claude cost, for its own bar shade
    var fableCost: Double {
        modelBreakdowns
            .filter { $0.modelName.hasPrefix("claude-fable") }
            .reduce(0) { $0 + $1.cost }
    }
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
