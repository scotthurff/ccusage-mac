import SwiftUI

extension Provider {
    var color: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.45, blue: 0.25)
        case .codex: return Color(red: 0.25, green: 0.58, blue: 0.65)
        case .other: return Color.gray
        }
    }

    // Deeper shade of Claude orange for the Fable sub-slice
    static let fableColor = Color(red: 0.63, green: 0.28, blue: 0.13)
}

struct PopoverContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            LimitsView()
            Divider()
            dailyListSection
                .padding(.top, 8)
                .padding(.bottom, 8)
            Divider()
            monthlyTotalSection
            Divider()
            FooterView()
        }
        .frame(width: 360)
        .fontDesign(.monospaced)
    }

    // MARK: - Today Hero

    private var todaySection: some View {
        HStack {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.secondary)
            Text("Today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if appState.hasData {
                Text(appState.todayCostLabel)
                    .font(.system(.title, weight: .semibold))
            } else {
                Text("--")
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Last 7 Days

    private var dailyListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.hasData {
                ForEach(appState.last7Days) { day in
                    dayRow(day)
                }
            } else if appState.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    Text("Couldn't load data.")
                        .font(.callout)
                    Text("Is ccusage installed?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        Task { await appState.refresh() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func dayRow(_ day: DailyUsage) -> some View {
        HStack(spacing: 8) {
            Text(AppState.displayDate(day.date).uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            GeometryReader { geo in
                if day.totalCost <= 0 {
                    // Zero-cost day: keep the original single min-width bar
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 4)
                } else {
                    let fraction = appState.maxDailyCost > 0
                        ? day.totalCost / appState.maxDailyCost
                        : 0
                    let barWidth = max(4, geo.size.width * fraction)
                    let segments: [(color: Color, cost: Double)] = [
                        (Provider.claude.color, day.cost(for: .claude) - day.fableCost),
                        (Provider.fableColor, day.fableCost),
                        (Provider.codex.color, day.cost(for: .codex)),
                        (Provider.other.color, day.cost(for: .other))
                    ]
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            let segmentWidth = barWidth * segment.cost / day.totalCost
                            if segmentWidth >= 1 {
                                Rectangle()
                                    .fill(segment.color)
                                    .frame(width: segmentWidth)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(height: 12)

            VStack(alignment: .trailing, spacing: 1) {
                Text(AppState.formatCurrency(day.totalCost))
                    .font(.caption)
                Text("\(AppState.formatTokens(day.totalTokens)) tok")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Monthly Total

    private var monthlyTotalSection: some View {
        HStack {
            Text("Last 14 Days".uppercased())
                .font(.subheadline.weight(.medium))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(AppState.formatCurrency(appState.monthlyTotal))
                    .font(.subheadline.weight(.semibold))
                Text("\(AppState.formatTokens(appState.monthlyTokens)) tok")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
