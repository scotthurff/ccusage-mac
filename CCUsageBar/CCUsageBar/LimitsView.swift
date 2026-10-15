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
                providerRows(.claude, title: "CLAUDE", color: Provider.claude.color, modelColor: Provider.fableColor)
                providerRows(.codex, title: "CODEX", color: Provider.codex.color, modelColor: Provider.codex.color)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // The provider row carries its 5-hour and weekly gauges and the reading's
    // age; model caps and any other windows follow on their own rows.
    @ViewBuilder
    private func providerRows(_ provider: QuotaProvider, title: String, color: Color, modelColor: Color) -> some View {
        let presentation = appState.presentation(provider)
        let rows = MacQuotaDisplay.rows(presentation, title: title)
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if index == 0, let age = MacQuotaDisplay.ageText(presentation) {
                        Text(age)
                            .font(.caption2)
                            .foregroundStyle(MacQuotaDisplay.isOutdated(presentation)
                                             ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                            .help(Self.ageHelp(presentation))
                    }
                }
                .frame(width: 56, alignment: .leading)
                let rowColor = row.isModel ? modelColor : color
                slot(row.short, placeholder: index == 0 ? "5h" : nil, color: rowColor)
                slot(row.long, placeholder: index == 0 ? "wk" : nil, color: rowColor)
            }
        }
    }

    // A gauge, an empty "--" gauge on the provider row, or blank space that
    // keeps the columns aligned.
    @ViewBuilder
    private func slot(_ window: WindowPresentation?, placeholder: String?, color: Color) -> some View {
        if let window {
            gauge(MacQuotaDisplay.gauge(window), minutes: window.window.durationMinutes, color: color)
        } else if let placeholder {
            HStack(spacing: 4) {
                Text(placeholder)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                track(fill: 0, color: color)
                Text("--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("No reading yet")
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 1)
        }
    }

    private func gauge(_ gauge: MacGauge, minutes: Int?, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(gauge.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            track(fill: gauge.fill, color: Self.fillColor(gauge.tone, base: color))
            // An outdated number reads as dated history; a passed reset is struck through.
            Text(gauge.percentText)
                .font(.caption2)
                .strikethrough(gauge.isStruckThrough)
                .foregroundStyle(gauge.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if let reset = gauge.resetsAt {
                Text("·\(Self.formatReset(reset, weekly: (minutes ?? 0) >= 1_440))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(gauge.help)
    }

    private func track(fill: Double, color: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.12))
            Capsule()
                .fill(color)
                .frame(width: 34 * fill / 100)
        }
        .frame(width: 34, height: 5)
    }

    private static func fillColor(_ tone: MacGauge.Tone, base: Color) -> Color {
        switch tone {
        case .normal: return base
        case .warning: return .red
        case .neutral: return Color.gray.opacity(0.6)
        }
    }

    private static func ageHelp(_ presentation: ProviderPresentation) -> String {
        switch presentation.freshness {
        case .outdated(.failedAttempt): return "The last check failed. These numbers are from the earlier reading."
        case .outdated(.aged): return "This reading is more than an hour old."
        case .unverified: return "This reading's time is in the future, so its numbers can't be trusted."
        case .current, .unknown: return "Time since this reading"
        }
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
