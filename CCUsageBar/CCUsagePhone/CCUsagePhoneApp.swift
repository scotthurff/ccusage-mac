import CloudKit
import SwiftUI
import WidgetKit

@main
struct CCUsagePhoneApp: App {
    @StateObject private var state = Self.makeState()
    @Environment(\.scenePhase) private var scenePhase

    private static func makeState() -> PhoneState {
        #if DEBUG
        if let fixture = UITestFixture.stateIfRequested() { return fixture }
        #endif
        return PhoneState(
            cache: .appGroup(),
            fetchLatest: { await CloudQuotaStore().fetchLatest() },
            checkAccount: { await CloudAccountIdentity.current() },
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .task { await state.refresh() }
                .onOpenURL { state.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: RunLoop.main)) { _ in
                    Task { await state.accountChanged() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await state.refresh() } }
        }
    }
}

// Shows the widget at each Home Screen size from the readings saved on this
// iPhone, or the same notice the widget shows when there are none.
// Opened from the details screen's "Widget preview" button.
struct PreviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cached: PhoneCacheState?
    @State private var notice = WidgetNotice.waitingForFirstReading

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let cached {
                        // Redraws ages and passed resets as time goes by.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            let entry = QuotaEntry(date: context.date, snapshot: cached.stored?.snapshot,
                                                   page: cached.page, notice: notice)
                            VStack(alignment: .leading, spacing: 20) {
                                WidgetPreviewCard(title: "Small", entry: entry, family: .systemSmall,
                                                  size: CGSize(width: 176, height: 176))
                                WidgetPreviewCard(title: "Medium", entry: entry, family: .systemMedium,
                                                  size: CGSize(width: 377, height: 176))
                                WidgetPreviewCard(title: "Large", entry: entry, family: .systemLarge,
                                                  size: CGSize(width: 377, height: 393))
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("CCUsage")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    // Reads the cache the widget reads. With nothing saved, checks iCloud so
    // the notice matches the widget's.
    private func load() async {
        let state = PhoneSnapshotCache.appGroup().read()
        cached = state
        guard state.stored == nil else { return }
        switch await CloudAccountIdentity.current() {
        case .noAccount: notice = .iCloudOff
        case .restricted: notice = .iCloudRestricted
        case .available, .temporarilyUnavailable: notice = .waitingForFirstReading
        }
    }
}

private struct WidgetPreviewCard: View {
    let title: String
    let entry: QuotaEntry
    let family: WidgetFamily
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            QuotaWidgetContent(entry: entry, family: family)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .background(UsagePalette.background)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                // A picture of the widget: its links and page buttons act on the Home Screen.
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
// TEST ONLY. Debug builds only; Release builds don't contain any of this.
// The CCUsagePhoneUITests target launches the app with
// `-uiTestFixture <name>` to swap iCloud for made-up readings: a cache in a
// fresh temporary folder, a fake account check and fetch, and no widget
// reloads. `-uiTestOpenURL <url>` also hands the app a link, as a widget
// tap would. Without `-uiTestFixture` the app starts normally.
@MainActor
enum UITestFixture {
    private enum Name: String {
        case waitingForFirstReading  // iCloud on, nothing published yet
        case iCloudOff               // no iCloud account on this iPhone
        case populated               // empty cache; the fetch returns both providers
        case failedRefresh           // two-hour-old readings saved; iCloud stops answering after launch
        case manyLimits              // readings saved with enough Claude limits to push Codex off screen
    }

    static func stateIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> PhoneState? {
        guard let index = arguments.firstIndex(of: "-uiTestFixture"), index + 1 < arguments.count else { return nil }
        guard let name = Name(rawValue: arguments[index + 1]) else {
            fatalError("Unknown UI test fixture \(arguments[index + 1])")
        }
        let now = Date()
        let cache = freshCache()
        var account = CloudAccountStatus.available(accountHash: "ui-test-fixture-account")
        var fetch: @MainActor () -> CloudFetchResult = { .missing }
        switch name {
        case .waitingForFirstReading:
            break
        case .iCloudOff:
            account = .noAccount
        case .populated:
            let published = result(now: now, age: 4 * 60)
            fetch = { published }
        case .failedRefresh:
            let saved = result(now: now, age: 2 * 3600)
            save(saved, to: cache, account: account)
            // The refreshes the app starts on its own at launch get the same
            // reading back. Any fetch from three seconds after launch fails,
            // so a test that waits that long sees its own refresh fail.
            fetch = { Date().timeIntervalSince(now) < 3 ? saved : .unavailable("UI test fixture: iCloud unreachable") }
        case .manyLimits:
            let saved = result(now: now, age: 4 * 60, extraClaudeLimits: 12)
            save(saved, to: cache, account: account)
            fetch = { saved }
        }
        let state = PhoneState(cache: cache, fetchLatest: { [fetch] in fetch() },
                               checkAccount: { [account] in account }, reloadWidgets: {})
        if let index = arguments.firstIndex(of: "-uiTestOpenURL"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            // Arrives once the screen is up, as onOpenURL does after a widget tap.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                state.open(url)
            }
        }
        return state
    }

    private static func freshCache() -> PhoneSnapshotCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UITestFixture", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return PhoneSnapshotCache(directory: directory)
    }

    private static func save(_ result: CloudFetchResult, to cache: PhoneSnapshotCache, account: CloudAccountStatus) {
        cache.bind(account: account)
        _ = cache.commit(result, ticket: cache.beginFetch())
    }

    // Clearly fake readings, dated relative to launch so ages and resets stay put.
    private static func result(now: Date, age: TimeInterval, extraClaudeLimits: Int = 0) -> CloudFetchResult {
        let observedAt = now.addingTimeInterval(-age)
        func window(_ id: String, _ label: String, _ minutes: Int, _ used: Double, resetIn: TimeInterval,
                    scope: WindowScope = .provider) -> QuotaWindow {
            QuotaWindow(id: id, label: label, durationMinutes: minutes, usedPercent: used,
                        resetsAt: now.addingTimeInterval(resetIn), scope: scope)
        }
        func slot(_ provider: QuotaProvider, _ windows: [QuotaWindow],
                  resetCredits: ResetCreditsInfo? = nil, creditBalance: Double? = nil) -> ProviderSlot {
            ProviderSlot(provider: provider, generation: "fixture", acceptedAttempt: 1,
                         observation: QuotaObservation(source: "ui-test-fixture", observedAt: observedAt, windows: windows,
                                                       resetCredits: resetCredits, creditBalance: creditBalance),
                         lastAttempt: CollectionAttempt(at: observedAt, outcome: .success))
        }
        var claude = [
            window("claude:5h", "5-hour", 300, 23, resetIn: 2 * 3600),
            window("claude:7d", "Weekly", 10_080, 41, resetIn: 3 * 86_400),
            window("claude:fable", "Fable", 10_080, 9, resetIn: 3 * 86_400, scope: .model),
        ]
        for number in stride(from: 1, through: extraClaudeLimits, by: 1) {
            let id = String(format: "claude:fixture-%02d", number)
            claude.append(window(id, "Fixture model \(number)", 10_080, Double(number * 5),
                                 resetIn: 4 * 86_400, scope: .model))
        }
        let codex = [window("codex:weekly", "Weekly", 10_080, 13, resetIn: 5 * 86_400)]
        let snapshot = QuotaSnapshot(
            version: QuotaSnapshot.currentVersion, revision: 1, publishedAt: observedAt,
            providers: [slot(.claude, claude),
                        slot(.codex, codex,
                             resetCredits: ResetCreditsInfo(available: 2, nextExpiry: now.addingTimeInterval(6 * 86_400)),
                             creditBalance: 1_234)])
        return .snapshot(snapshot, CloudSnapshotMetadata(incarnation: "ui-test-fixture",
                                                         incarnationCreatedAt: now.addingTimeInterval(-30 * 86_400),
                                                         revision: 1))
    }
}
#endif
