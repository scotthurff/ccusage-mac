import CloudKit
import SwiftUI
import WidgetKit

@main
struct CCUsagePhoneApp: App {
    @StateObject private var state = PhoneState(
        cache: .appGroup(),
        fetchLatest: { await CloudQuotaStore().fetchLatest() },
        checkAccount: { await CloudAccountIdentity.current() },
        reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    @Environment(\.scenePhase) private var scenePhase

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
