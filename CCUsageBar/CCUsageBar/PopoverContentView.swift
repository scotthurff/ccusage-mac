import SwiftUI

struct PopoverContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            todaySection
            Divider()
            dailyListSection
            Divider()
            monthlyTotalSection
            Divider()
            FooterView()
        }
        .frame(width: 320)
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
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            } else {
                Text("--")
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Last 7 Days

    private var dailyListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Last 7 Days")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)

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
            Text(AppState.displayDate(day.date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            GeometryReader { geo in
                let fraction = appState.maxDailyCost > 0
                    ? day.totalCost / appState.maxDailyCost
                    : 0
                RoundedRectangle(cornerRadius: 3)
                    .fill(.blue.opacity(0.7))
                    .frame(width: max(4, geo.size.width * fraction))
            }
            .frame(height: 12)

            Text(AppState.formatCurrency(day.totalCost))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Monthly Total

    private var monthlyTotalSection: some View {
        HStack {
            Text("\(appState.currentMonthName) Total")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(AppState.formatCurrency(appState.monthlyTotal))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding()
    }
}
