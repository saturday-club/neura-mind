import AppKit
import Observation

/// Manages per-display overlay windows using layer-0 window ordering.
/// The overlay sits behind the focused window so the active window naturally occludes it.
@MainActor
final class FocusOverlayManager {
    private var overlays: [CGDirectDisplayID: (window: FocusOverlayWindow, contentView: FocusOverlayContentView)] = [:]
    private let overlayState: OverlayState
    private let poller: FocusOverlayPoller
    private let notchEars = NotchEarOverlay()
    private var lastSnapshots: [FocusWindowSnapshot] = []
    private var overlaysVisible = false
    private var wasEnabled = false

    init(overlayState: OverlayState, poller: FocusOverlayPoller) {
        self.overlayState = overlayState
        self.poller = poller
        setupDisplayNotifications()
        setupSpaceNotifications()
    }

    func createOverlays() {
        removeAllOverlays()
        let screens = NSScreen.screens
        // Overlay windows created per-display
        for screen in screens {
            createOverlay(for: screen)
        }
        if overlayState.isEnabled {
            wasEnabled = false
        }
    }

    func removeAllOverlays() {
        for (_, entry) in overlays {
            entry.contentView.teardown()
            entry.window.close()
        }
        overlays.removeAll()
        notchEars.teardown()
        overlaysVisible = false
    }

    func update() {
        // Handle disable
        if !overlayState.isEnabled {
            if wasEnabled {
                wasEnabled = false
                for (_, entry) in overlays {
                    entry.contentView.teardown()
                    entry.window.fadeOut()
                }
                notchEars.hide()
                overlaysVisible = false
                lastSnapshots = []
            }
            return
        }

        // FAST PATH: When NeuraMind is frontmost the poller freezes snapshots
        // (they stay non-empty from the last real app). The overlay just keeps its
        // current position -- no hiding, no showing, no flash.
        // Only hide if snapshots are truly empty (e.g. overlay just enabled, no app yet).
        let snapshots = poller.focusedSnapshots
        if snapshots.isEmpty {
            if overlaysVisible {
                for (_, entry) in overlays { entry.window.orderOut(nil) }
                overlaysVisible = false
            }
            notchEars.hide()
            lastSnapshots = []
            return
        }

        // If snapshots haven't changed (NeuraMind frontmost = frozen snapshots),
        // skip expensive window reordering but still push effects so slider
        // changes (blur, tint, grain) are applied in real time.
        if snapshots == lastSnapshots && overlaysVisible {
            for (_, entry) in overlays {
                entry.contentView.updateEffects(state: overlayState)
            }
            notchEars.updateEffects(state: overlayState)
            return
        }

        // Handle enable transition
        if !wasEnabled {
            wasEnabled = true
            for (_, entry) in overlays {
                entry.window.fadeIn()
            }
            overlaysVisible = true
        }

        // Reconcile displays
        let currentDisplayIDs = Set(overlays.keys)
        let activeScreens = NSScreen.screens
        let activeDisplayIDs = Set(activeScreens.map { $0.displayID })

        for displayID in currentDisplayIDs.subtracting(activeDisplayIDs) {
            if let entry = overlays.removeValue(forKey: displayID) {
                entry.contentView.teardown()
                entry.window.close()
            }
        }

        for screen in activeScreens where !currentDisplayIDs.contains(screen.displayID) {
            createOverlay(for: screen)
        }

        // Push effects
        for (_, entry) in overlays {
            entry.contentView.updateEffects(state: overlayState)
        }
        notchEars.updateEffects(state: overlayState)

        // Check fullscreen: hide main overlays, show notch ears instead
        let fsScreen = fullscreenScreen()
        if let fsScreen {
            if overlaysVisible {
                for (_, entry) in overlays { entry.window.orderOut(nil) }
                overlaysVisible = false
            }
            notchEars.show(on: fsScreen, state: overlayState)
            return
        }

        // Not fullscreen: main overlays cover ears, hide ear windows
        notchEars.hide()

        let focusChanged = snapshots != lastSnapshots

        if focusChanged || !overlaysVisible {
            lastSnapshots = snapshots
            let topWindowID = snapshots.first?.windowID

            for (_, entry) in overlays {
                if let wid = topWindowID {
                    entry.window.orderBelow(windowNumber: Int(wid))
                } else {
                    entry.window.orderFrontRegardless()
                }
                entry.contentView.clearMask()
            }
            overlaysVisible = true
        } else {
            for (_, entry) in overlays where !entry.window.isVisible {
                entry.window.orderFrontRegardless()
            }
        }
    }

    private func fullscreenScreen() -> NSScreen? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  let x = bounds["X"] as? CGFloat,
                  let _ = bounds["Y"] as? CGFloat
            else { continue }

            for screen in NSScreen.screens {
                let sf = screen.frame
                let notchInset = screen.safeAreaInsets.top
                let matchesFull = abs(h - sf.height) < 2
                let matchesBelowNotch = notchInset > 0 && abs(h - (sf.height - notchInset)) < 2
                let displayMatch = abs(w - sf.width) < 2
                    && (matchesFull || matchesBelowNotch)
                    && abs(x - sf.origin.x) < 2
                if displayMatch { return screen }
            }
        }
        return nil
    }

    private func createOverlay(for screen: NSScreen) {
        let window = FocusOverlayWindow(screen: screen)
        let contentView = FocusOverlayContentView(frame: screen.frame, screen: screen)
        window.contentView = contentView
        overlays[screen.displayID] = (window, contentView)
    }

    private func setupDisplayNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.createOverlays()
                self?.update()
            }
        }
    }

    private func setupSpaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastSnapshots = []
                self?.update()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    MainActor.assumeIsolated {
                        self?.lastSnapshots = []
                        self?.update()
                    }
                }
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
