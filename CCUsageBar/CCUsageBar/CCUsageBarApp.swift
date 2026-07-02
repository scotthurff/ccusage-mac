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
            Image(nsImage: menuBarImage(label: appState.menuBarLabel, warning: appState.limitWarningActive))
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarImage(label: String, warning: Bool) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)

        let iconSize: CGFloat = 12
        let spacing: CGFloat = 3
        let totalWidth = iconSize + spacing + textSize.width
        let height: CGFloat = 16

        // Warning (any limit >= 80%): swap the chart glyph for a warning
        // triangle — keeps isTemplate so light/dark adaptation is preserved.
        let symbolName = warning ? "exclamationmark.triangle.fill" : "chart.bar.fill"

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { rect in
            // Draw SF Symbol
            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage
                let iconRect = NSRect(x: 0, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
                configured.draw(in: iconRect)
            }

            // Draw label text
            let textOrigin = NSPoint(x: iconSize + spacing, y: (height - textSize.height) / 2)
            (label as NSString).draw(at: textOrigin, withAttributes: attrs)

            return true
        }

        image.isTemplate = true
        return image
    }
}
