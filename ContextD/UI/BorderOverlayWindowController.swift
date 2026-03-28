import AppKit
import SwiftUI
import Combine

/// Creates one full-screen click-through overlay window per display.
/// Subscribes to FocusScoreEngine and updates border color on state changes.
@MainActor
final class BorderOverlayWindowController {
    private var windows: [NSWindow] = []
    private let scoreEngine: FocusScoreEngine
    private var cancellable: AnyCancellable?

    init(scoreEngine: FocusScoreEngine) {
        self.scoreEngine = scoreEngine
    }

    func start() {
        createWindows()
        cancellable = scoreEngine.$overlayState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.update(state: state)
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    /// Call on NSApplication.didChangeScreenParametersNotification (display plug/unplug).
    func rebuildWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
        createWindows()
        update(state: scoreEngine.overlayState)
    }

    // MARK: - Private

    private func createWindows() {
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level            = NSWindow.Level(Int(CGShieldingWindowLevel()) + 1)
        win.backgroundColor  = .clear
        win.isOpaque         = false
        win.hasShadow        = false
        win.ignoresMouseEvents  = true
        win.collectionBehavior  = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: BorderOverlayView(state: scoreEngine.overlayState))
        win.orderFrontRegardless()
        return win
    }

    private func update(state: FocusOverlayState) {
        for win in windows {
            (win.contentView as? NSHostingView<BorderOverlayView>)?.rootView =
                BorderOverlayView(state: state)
        }
    }
}
