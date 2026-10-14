import SwiftUI

// Full limit details for each provider, setup guidance when there's nothing
// to show yet, and a refresh that reads the newest snapshot the Mac published.
struct ContentView: View {
    @ObservedObject var state: PhoneState
    @State private var showingWidgetPreview = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // Redraws ages, freshness, and passed resets as time goes by.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        details(now: context.date)
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .refreshable { await state.refresh() }
                .onChange(of: state.focusedProvider) { _, provider in scroll(to: provider, with: proxy) }
                .onAppear { scroll(to: state.focusedProvider, with: proxy) }
            }
            .navigationTitle("Usage limits")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Widget preview") { showingWidgetPreview = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.refresh() }
                    } label: {
                        if state.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(state.isRefreshing)
                    .accessibilityLabel(state.isRefreshing ? "Refreshing" : "Refresh")
                    .accessibilityIdentifier("refresh")
                }
            }
            .sheet(isPresented: $showingWidgetPreview) { PreviewScreen() }
        }
    }

    private func details(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice = state.notice {
                NoticeCard(notice: notice, prominent: state.stored == nil)
            }
            ForEach(state.providers(at: now), id: \.provider) { provider in
                ProviderCard(provider: provider, now: now)
                    .id(provider.provider.rawValue)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let checkedAt = state.checkedAt {
                    Text(PhoneText.checked(checkedAt, now: now))
                        .accessibilityIdentifier("checked-icloud")
                }
                Text("Refresh gets the newest reading your Mac has published to iCloud. It doesn't make your Mac check again. Your Mac checks about every 15 minutes while it's awake.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scroll(to provider: QuotaProvider?, with proxy: ScrollViewProxy) {
        guard let provider else { return }
        Task { @MainActor in
            withAnimation { proxy.scrollTo(provider.rawValue, anchor: .top) }
            state.focusedProvider = nil
        }
    }
}

private struct NoticeCard: View {
    let notice: PhoneNotice
    // True when there are no readings, so the guidance is the whole screen.
    let prominent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if notice.kind == .checking {
                ProgressView()
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(prominent ? .headline : .subheadline.weight(.semibold))
                Text(notice.message).font(prominent ? .body : .footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(prominent ? 20 : 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notice")
    }

    private var symbol: String {
        switch notice.kind {
        case .checking: "icloud"
        case .waitingForFirstReading: "macbook.and.iphone"
        case .noRecordKeepingCache: "clock.arrow.circlepath"
        case .signedOut, .unreachable: "icloud.slash"
        case .restricted: "lock.icloud"
        case .updateRequired: "arrow.down.app"
        }
    }
}

private struct ProviderCard: View {
    let provider: ProviderPresentation
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                stacked {
                    Text(provider.provider.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(provider.freshness == .current ? Self.tint(for: provider.provider) : Color.secondary)
                } trailing: {
                    Text(PhoneText.freshness(provider.freshness))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.15), in: Capsule())
                }
                Text(PhoneText.readingAge(provider, now: now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("provider-header-\(provider.provider.rawValue)")

            if provider.observedAt != nil && provider.windows.isEmpty {
                Text("No limits reported in this reading.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(provider.windows, id: \.window.id) { window in
                windowRow(window)
            }
            if provider.resetCredits != nil || provider.creditBalance != nil {
                Divider()
                if let credits = provider.resetCredits {
                    Label(PhoneText.resetCredits(credits, now: now), systemImage: "arrow.counterclockwise.circle")
                        .accessibilityIdentifier("reset-credits-\(provider.provider.rawValue)")
                }
                if let balance = provider.creditBalance {
                    Label(PhoneText.creditBalance(balance), systemImage: "creditcard")
                        .accessibilityIdentifier("credit-balance-\(provider.provider.rawValue)")
                }
            }
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func windowRow(_ window: WindowPresentation) -> some View {
        let stale = window.state != .current
        return VStack(alignment: .leading, spacing: 6) {
            stacked {
                Text(PhoneText.windowLabel(window.window)).font(.body.weight(.medium))
            } trailing: {
                Text(PhoneText.percentUsed(window.window))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stale ? .secondary : .primary)
            }
            UsageBar(percent: window.window.usedPercent, tint: fill(window))
            if let reset = PhoneText.reset(window, now: now) {
                Text(reset).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PhoneText.accessibilityLabel(window, provider: provider, now: now))
        .accessibilityIdentifier("window-row-\(provider.provider.rawValue)")
    }

    // Side by side normally; one above the other at accessibility text sizes.
    @ViewBuilder
    private func stacked(@ViewBuilder leading: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { leading(); trailing() }
        } else {
            HStack(alignment: .firstTextBaseline) { leading(); Spacer(minLength: 8); trailing() }
        }
    }

    private var badgeColor: Color {
        switch provider.freshness {
        case .current: .green
        case .outdated, .unverified: .orange
        case .unknown: .secondary
        }
    }

    // The widget's rule: past, outdated, or unconfirmed values are gray
    // history, never a fresh reading; Claude's model caps use the Fable color.
    private func fill(_ window: WindowPresentation) -> Color {
        UsagePalette.barFill(usedPercent: window.window.usedPercent, isStale: window.state != .current,
                             tint: QuotaWidgetModel.tint(provider.provider, scope: window.window.scope))
    }

    static func tint(for provider: QuotaProvider) -> Color {
        switch provider {
        case .claude: UsagePalette.claude
        case .codex: UsagePalette.codex
        default: .accentColor
        }
    }
}
