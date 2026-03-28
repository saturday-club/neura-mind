import AppKit
import SwiftUI

// MARK: - SwiftUI Card View

struct ContextRecoveryCard: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))

            Text("Welcome back. \(message)")
                .font(.system(size: 13))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

// MARK: - NSPanel Controller

/// Manages the floating context recovery card panel.
/// Shows for 8 seconds then auto-dismisses.
@MainActor
final class ContextRecoveryCardController {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func show(message: String) {
        dismiss()   // clear any existing card first

        let card = ContextRecoveryCard(message: message) { [weak self] in
            self?.dismiss()
        }

        let hosting = NSHostingView(rootView: card)
        // Size the hosting view: fixed width 400, let SwiftUI determine height
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        let fittedHeight = max(hosting.fittingSize.height, 44)

        let contentRect = NSRect(x: 0, y: 0, width: 400, height: fittedHeight)
        let newPanel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level            = .floating
        newPanel.backgroundColor  = .clear
        newPanel.isOpaque         = false
        newPanel.hasShadow        = false
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false

        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 400, height: fittedHeight))
        newPanel.contentView = hosting

        // Position: bottom-center of main screen, 40px above the dock
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 200
            let y = screen.visibleFrame.minY + 40
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        newPanel.orderFrontRegardless()
        panel = newPanel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
    }
}
