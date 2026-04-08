import SwiftUI

struct FooterView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            if appState.isLoading {
                ProgressView()
                    .controlSize(.mini)
                Text("Refreshing...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let text = appState.lastRefreshText {
                Button {
                    Task { await appState.refresh() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text(text)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
