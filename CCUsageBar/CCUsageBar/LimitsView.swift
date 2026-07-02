import SwiftUI

struct LimitsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !appState.hasLimitsData && !appState.hasAttemptedLimitsFetch {
                // First uncached load: distinct loading state, never `--`
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading limits...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                providerRow("CLAUDE", limits: appState.claudeLimits, color: Provider.claude.color)
                providerRow("CODEX", limits: appState.codexLimits, color: Provider.codex.color)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func providerRow(_ name: String, limits: ProviderLimits?, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            gauge(label: "5h", window: limits?.fiveHour, color: color, weekly: false)
            gauge(label: "wk", window: limits?.weekly, color: color, weekly: true)
        }
    }

    private func gauge(label: String, window: LimitWindow?, color: Color, weekly: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            track(window: window, color: color)
            if let window {
                Text("\(Int(window.effectivePercent.rounded()))%")
                    .font(.caption2)
                if let reset = window.effectiveResetsAt {
                    Text("·\(Self.formatReset(reset, weekly: weekly))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func track(window: LimitWindow?, color: Color) -> some View {
        let percent = window?.effectivePercent ?? 0
        let fillColor = percent >= 80 ? Color.red : color
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
            Capsule()
                .fill(fillColor)
                .frame(width: 34 * min(percent, 100) / 100)
        }
        .frame(width: 34, height: 5)
    }

    // 5h → clock time ("2:14p"), weekly → weekday ("Mon")
    static func formatReset(_ date: Date, weekly: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = weekly ? "EEE" : "h:mma"
        return formatter.string(from: date)
            .replacingOccurrences(of: "AM", with: "a")
            .replacingOccurrences(of: "PM", with: "p")
    }
}
