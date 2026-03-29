import AppKit
import ApplicationServices
import Observation

// MARK: - Window Snapshot

struct FocusWindowSnapshot: Equatable, Sendable {
    let windowID: CGWindowID
    let frame: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let windowName: String
    let displayID: CGDirectDisplayID

    static func fromCGWindowInfo(_ info: [String: Any]) -> FocusWindowSnapshot? {
        guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              let ownerName = info[kCGWindowOwnerName as String] as? String
        else { return nil }

        guard let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let w = boundsDict["Width"] as? CGFloat,
              let h = boundsDict["Height"] as? CGFloat
        else { return nil }

        let frame = CGRect(x: x, y: y, width: w, height: h)
        let windowName = info[kCGWindowName as String] as? String ?? ""

        let center = CGPoint(x: frame.midX, y: frame.midY)
        var displayCount: UInt32 = 0
        var matchedDisplay: CGDirectDisplayID = CGMainDisplayID()
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
        CGGetDisplaysWithPoint(center, 8, &displayIDs, &displayCount)
        if displayCount > 0 { matchedDisplay = displayIDs[0] }

        return FocusWindowSnapshot(
            windowID: windowID, frame: frame, ownerPID: ownerPID,
            ownerName: ownerName, windowName: windowName, displayID: matchedDisplay
        )
    }
}

// MARK: - Accessibility Bridge

@MainActor
enum OverlayAccessibilityBridge {

    private static var hasPrompted = false
    private static var isTrusted = false

    static func focusedWindowFrame(for pid: pid_t) -> CGRect? {
        guard isTrusted else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow
        )
        guard result == .success, let window = focusedWindow else { return nil }
        // swiftlint:disable:next force_cast
        let windowElement = window as! AXUIElement

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            windowElement, kAXPositionAttribute as CFString, &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            windowElement, kAXSizeAttribute as CFString, &sizeValue
        ) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    static func promptIfNeeded() {
        // NeuraMind handles its own AX prompting via PermissionManager.
        // Just silently check trust.
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        hasPrompted = true
    }

    static func refreshTrustStatus() {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Window Poller

@Observable
@MainActor
final class FocusOverlayPoller {
    private(set) var focusedSnapshots: [FocusWindowSnapshot] = []
    private var timer: Timer?
    private let overlayState: OverlayState
    private var lastFrontmostPID: pid_t = 0
    private var trustCheckCounter = 0
    private var stableCounter = 0

    private var axObserver: AXObserver?
    private var needsUpdate = true
    private var clickMonitor: Any?

    init(overlayState: OverlayState) {
        self.overlayState = overlayState
    }

    func start() {
        setupWorkspaceObservers()
        setupClickMonitor()
        OverlayAccessibilityBridge.promptIfNeeded()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        teardownAXObserver()
        focusedSnapshots = []
    }

    private func setupClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsUpdate = true }
        }
    }

    private func setupWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsUpdate = true
                self?.stableCounter = 0

                if let app = NSWorkspace.shared.frontmostApplication {
                    // Don't observe our own app -- avoids constant AX notifications
                    // from NeuraMind panels triggering expensive re-polls
                    let isOwnApp = app.bundleIdentifier.map {
                        $0.contains("neuramind") || $0.contains("NeuraMind")
                    } ?? false

                    if isOwnApp {
                        self?.teardownAXObserver()
                    } else {
                        self?.setupAXObserver(for: app.processIdentifier)
                    }
                }
                // Immediate poll on app switch for instant overlay reorder
                self?.poll()
            }
        }
    }

    private func setupAXObserver(for pid: pid_t) {
        teardownAXObserver()
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverCreate(pid, { (_, _, _, refcon) in
            guard let refcon else { return }
            let poller = Unmanaged<FocusOverlayPoller>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { poller.needsUpdate = true }
            }
        }, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let notifications: [CFString] = [
            kAXFocusedWindowChangedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
        ]
        for notif in notifications {
            AXObserverAddNotification(observer, appElement, notif, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.axObserver = observer
    }

    private func teardownAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObserver = nil
    }

    private func poll() {
        trustCheckCounter += 1
        if trustCheckCounter >= 50 {
            trustCheckCounter = 0
            OverlayAccessibilityBridge.refreshTrustStatus()
        }

        guard overlayState.isEnabled else {
            if !focusedSnapshots.isEmpty { focusedSnapshots = [] }
            return
        }

        if !needsUpdate {
            stableCounter += 1
            if stableCounter < 10 { return }  // 1 second safety net (10Hz * 10)
        }
        needsUpdate = false
        stableCounter = 0

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        // Skip our own app -- leave overlay frozen in its last position.
        // Do NOT clear focusedSnapshots so the overlay doesn't hide/show (flash).
        if let bundleID = frontApp.bundleIdentifier,
           bundleID.contains("neuramind") || bundleID.contains("NeuraMind") {
            return
        }

        let pid = frontApp.processIdentifier

        if pid != lastFrontmostPID {
            setupAXObserver(for: pid)
            lastFrontmostPID = pid
        }

        let axFrame = OverlayAccessibilityBridge.focusedWindowFrame(for: pid)

        let windowListInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let appWindows = windowListInfo.compactMap { info -> FocusWindowSnapshot? in
            guard let snapshot = FocusWindowSnapshot.fromCGWindowInfo(info),
                  snapshot.ownerPID == pid else { return nil }
            guard snapshot.frame.width > 50 && snapshot.frame.height > 50 else { return nil }
            return snapshot
        }

        if let axFrame = axFrame {
            let matched = appWindows.first { s in
                abs(s.frame.origin.x - axFrame.origin.x) < 5
                && abs(s.frame.origin.y - axFrame.origin.y) < 5
                && abs(s.frame.width - axFrame.width) < 5
                && abs(s.frame.height - axFrame.height) < 5
            }
            let best = matched.map {
                FocusWindowSnapshot(
                    windowID: $0.windowID, frame: axFrame,
                    ownerPID: $0.ownerPID, ownerName: $0.ownerName,
                    windowName: $0.windowName, displayID: $0.displayID
                )
            } ?? appWindows.first
            let result = best.map { [$0] } ?? []
            if result != focusedSnapshots { focusedSnapshots = result }
        } else if let first = appWindows.first {
            if focusedSnapshots != [first] { focusedSnapshots = [first] }
        } else {
            if !focusedSnapshots.isEmpty { focusedSnapshots = [] }
        }
    }
}
