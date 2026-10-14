import SwiftUI
import WidgetKit

@main
struct CCUsagePhoneApp: App {
    var body: some Scene {
        WindowGroup {
            SmokeView()
        }
    }
}

// TEMPORARY feasibility screen (plan U1). Shows the synthetic CloudKit record
// written by the Mac smoke check. Replaced by the real companion UI later.
struct SmokeView: View {
    @State private var account = "checking…"
    @State private var result = "not fetched"
    @State private var fetching = false

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud") {
                    LabeledContent("Account", value: account)
                }
                Section("Synthetic record from Mac") {
                    Text(result).font(.body.monospaced())
                }
                Section {
                    Button(fetching ? "Fetching…" : "Fetch now") {
                        Task { await fetch() }
                    }
                    .disabled(fetching)
                }
                Section {
                    Text("Synthetic smoke test. Not usage data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("CCUsage smoke test")
        }
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
