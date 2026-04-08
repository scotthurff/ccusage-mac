import SwiftUI

@main
struct CCUsageBarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environmentObject(appState)
        } label: {
            Label {
                Text(appState.todayCostLabel)
            } icon: {
                Image(systemName: "chart.bar.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
