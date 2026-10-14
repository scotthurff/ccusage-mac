import SwiftUI
import WidgetKit

@main
struct CCUsagePhoneApp: App {
    var body: some Scene {
        WindowGroup {
            PreviewScreen()
        }
    }
}

// Shows the widget at each Home Screen size, using the preview readings.
// Replaced by the real companion screens once iCloud delivery exists.
struct PreviewScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WidgetPreviewCard(title: "Small", family: .systemSmall, size: CGSize(width: 176, height: 176))
                    WidgetPreviewCard(title: "Medium", family: .systemMedium, size: CGSize(width: 377, height: 176))
                    WidgetPreviewCard(title: "Large", family: .systemLarge, size: CGSize(width: 377, height: 393))
                    SmokeSection()
                }
                .padding()
            }
            .navigationTitle("CCUsage")
        }
    }
}

private struct WidgetPreviewCard: View {
    let title: String
    let family: WidgetFamily
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            UsageWidgetContent(
                entry: UsageEntry(date: .now, providers: UsagePreview.providers, isPreview: true),
                family: family
            )
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(UsagePalette.background)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}

// TEMPORARY feasibility check (plan U1). Shows the synthetic CloudKit record
// written by the Mac smoke check.
private struct SmokeSection: View {
    @State private var account = "checking…"
    @State private var result = "not fetched"
    @State private var fetching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iCloud delivery test (temporary)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Account: \(account)")
                .font(.caption)
            Text(result)
                .font(.caption.monospaced())
            Button(fetching ? "Fetching…" : "Fetch test record") {
                Task { await fetch() }
            }
            .font(.caption)
            .disabled(fetching)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await fetch() }
    }

    private func fetch() async {
        fetching = true
        defer { fetching = false }
        account = await CloudKitSmoke.accountStatusDescription()
        do {
            if let reading = try await CloudKitSmoke.read() {
                result = """
                nonce \(reading.nonce) from \(reading.writer)
                written \(reading.writtenAt.formatted(date: .abbreviated, time: .standard))
                fetched \(Date().formatted(date: .omitted, time: .standard))
                """
            } else {
                result = "No record yet. Run the Mac smoke check."
            }
        } catch {
            result = "Fetch failed: \(error.localizedDescription)"
        }
    }
}
