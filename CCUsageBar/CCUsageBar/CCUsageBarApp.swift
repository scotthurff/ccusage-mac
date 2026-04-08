import SwiftUI
import AppKit

@main
struct CCUsageBarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environmentObject(appState)
        } label: {
            Image(nsImage: menuBarImage(cost: appState.todayCostLabel))
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarImage(cost: String) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (cost as NSString).size(withAttributes: attrs)

        let iconSize: CGFloat = 12
        let spacing: CGFloat = 3
        let totalWidth = iconSize + spacing + textSize.width
        let height: CGFloat = 16

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            // Draw SF Symbol
            if let symbolImage = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage
                let iconRect = NSRect(x: 0, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                configured.draw(in: iconRect)
            }

            // Draw cost text
            let textOrigin = NSPoint(x: iconSize + spacing, y: (height - textSize.height) / 2)
            (cost as NSString).draw(at: textOrigin, withAttributes: attrs)

            return true
        }

        image.isTemplate = true
        return image
    }
}
