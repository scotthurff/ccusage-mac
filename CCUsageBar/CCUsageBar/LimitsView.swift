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
                // One grid for both providers, so names, values, and resets
                // line up in columns whatever their lengths.
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    providerRows(.claude, color: Provider.claude.color, capColor: Provider.fableColor)
                    providerRows(.codex, color: Provider.codex.color, capColor: Provider.codex.color)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // A header with the reading's age, then one line per limit the provider
    // reported, in the shared order.
    @ViewBuilder
    private func providerRows(_ provider: QuotaProvider, color: Color, capColor: Color) -> some View {
        let presentation = appState.presentation(provider)
        GridRow {
            header(provider, presentation)
                .gridCellColumns(4)
                .padding(.top, provider == .claude ? 0 : 6)
        }
        if let empty = MacQuotaDisplay.emptyText(presentation) {
            GridRow {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(4)
            }
        }
        ForEach(MacQuotaDisplay.gauges(presentation), id: \.id) { gauge in
            GridRow {
                // At least as wide as the day column below, so the limit bars
                // start where the cost bars do.
                // Uppercase, like the day labels below.
                Text(gauge.label.uppercased())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 70, alignment: .leading)
                bar(gauge, color: gauge.isCap ? capColor : color)
                // An outdated number reads as dated history; a passed reset is struck through.
                Text(gauge.valueText)
                    .strikethrough(gauge.isStruckThrough)
                    .foregroundStyle(gauge.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .gridColumnAlignment(.trailing)
                Text(gauge.resetsAt.map { Self.formatReset($0, weekly: gauge.resetShowsWeekday) } ?? "")
                    .foregroundStyle(.tertiary)
                    .gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .help(gauge.help)
        }
    }

    private func header(_ provider: QuotaProvider, _ presentation: ProviderPresentation) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(provider.displayName.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
            Spacer()
            if let age = MacQuotaDisplay.ageText(presentation) {
                Text(age)
                    .font(.caption2)
                    .foregroundStyle(MacQuotaDisplay.isOutdated(presentation)
                                     ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .help(Self.ageHelp(presentation))
            }
        }
    }

    // Fills the space between the name and the value. Any use above zero
    // shows at least a dot.
    private func bar(_ gauge: MacGauge, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                if gauge.fill > 0 {
                    Capsule()
                        .fill(Self.fillColor(gauge.tone, base: color))
                        .frame(width: max(geometry.size.height, geometry.size.width * gauge.fill / 100))
                }
            }
        }
        .frame(minWidth: 60, maxWidth: .infinity)
        .frame(height: 5)
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
