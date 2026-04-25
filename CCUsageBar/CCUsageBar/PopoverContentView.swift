import SwiftUI

struct PopoverContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            dailyListSection
                .padding(.top, 8)
                .padding(.bottom, 8)
            Divider()
            monthlyTotalSection
            Divider()
            FooterView()
        }
        .frame(width: 320)
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
                let fraction = appState.maxDailyCost > 0
                    ? day.totalCost / appState.maxDailyCost
                    : 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: 0.85, green: 0.45, blue: 0.25))
                    .frame(width: max(4, geo.size.width * fraction))
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
            Text("\(appState.currentMonthName) Total".uppercased())
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
