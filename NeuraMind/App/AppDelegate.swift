import AppKit
import SwiftUI

// MARK: - AppDelegate

/// NSApplicationDelegate for handling lifecycle events that SwiftUI App can't.
/// Handles: onboarding window on first launch, starting services when ready,
/// NSStatusItem for menu bar icon, and side panel toggle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DualLogger(category: "AppDelegate")
    private var onboardingWindow: NSWindow?

    // Side panel + status item
    private var statusItem: NSStatusItem?
    private var sidePanelController: SidePanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps default to .prohibited activation policy, which prevents
        // windows from coming to the foreground and receiving keyboard input.
        // Set .accessory so windows can be activated on demand while staying out of the Dock.
        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Create status bar icon
        setupStatusItem()

        // Create side panel with menu bar content
        setupSidePanel()

        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if hasOnboarded {
            // Already onboarded -- start services immediately.
            // Skip permission checks: macOS 15+ reports stale status after re-codesign.
            // Captures and AX calls fail gracefully if permission was truly revoked.
            logger.info("Previously onboarded -- starting services directly")
            PermissionManager.shared.startPeriodicCheck()
            ServiceContainer.shared.startServices()
            startIconUpdater()
        } else if PermissionManager.shared.allPermissionsGranted {
            // First launch, permissions already granted (rare but possible)
            logger.info("Permissions granted on first launch -- starting services")
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            PermissionManager.shared.startPeriodicCheck()
            ServiceContainer.shared.startServices()
            startIconUpdater()
        } else {
            // First launch, needs onboarding
            logger.info("First launch -- showing permissions dialog")
            showOnboardingWindow()
        }
    }

    // MARK: - Status Bar Icon

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "eye.fill",
                accessibilityDescription: "NeuraMind"
            )
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        self.statusItem = item
    }

    @objc private func statusItemClicked() {
        sidePanelController?.toggle()
    }

    /// Keep the status bar icon in sync and drive overlay at 15Hz.
    private func startIconUpdater() {
        // 1Hz icon update
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusIcon()
            }
        }
        // 15Hz overlay update (same cadence as Hocus Pocus)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let services = ServiceContainer.shared
                services.overlayManager?.update()

                // Adaptive tint: blend toward red as focus drops
                if let score = services.focusScoreEngine?.currentScore {
                    OverlayState.shared.applyFocusBlend(focusScore: score.value)
                }
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = computeIconName()
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "NeuraMind")
        if button.image?.name() != img?.name() {
            button.image = img
        }
    }

    private func computeIconName() -> String {
        let focusSnapshot = FocusStateStore.currentSnapshot(
            storageManager: ServiceContainer.shared.storageManager
        )
        if focusSnapshot.current != nil, focusSnapshot.drift?.level == "drifting" {
            return "exclamationmark.circle"
        }
        guard let engine = ServiceContainer.shared.captureEngine else {
            return "eye.slash"
        }
        guard engine.isRunning else {
            return "eye.slash"
        }
        if engine.isWinking {
            return "eye"
        }
        switch engine.state {
        case .recording: return "eye.fill"
        case .paused: return "eye.slash"
        case .privacyPaused: return "lock.shield"
        case .sleeping: return "moon.fill"
        }
    }

    // MARK: - Side Panel

    private func setupSidePanel() {
        let controller = SidePanelController {
            SidePanelContent()
        }
        self.sidePanelController = controller
    }

    @objc private func screensDidChange() {
        // Overlay manager handles display changes via its own notification observer
    }

    // MARK: - Onboarding

    private func showOnboardingWindow() {
        let permissionManager = PermissionManager.shared

        let onboardingView = OnboardingView(
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                PermissionManager.shared.startPeriodicCheck()
                ServiceContainer.shared.startServices()
                self?.startIconUpdater()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to NeuraMind"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }
}

// MARK: - Side Panel Content

/// The main side panel view wrapping MenuBarView in GlassCards.
private struct SidePanelContent: View {
    @ObservedObject private var permissionManager = PermissionManager.shared

    private var services: ServiceContainer { ServiceContainer.shared }

    var body: some View {
        if let captureEngine = services.captureEngine {
            GlassPanelView(
                captureEngine: captureEngine,
                permissionManager: permissionManager,
                storageManager: services.storageManager,
                onOpenDailyAssistant: {
                    services.neuraMindController?.toggle()
                },
                onOpenDebug: {
                    services.debugController?.toggle()
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Failed to initialize.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}

// MARK: - Glass Panel View

/// Redesigned menu bar content using GlassCard components.
private struct GlassPanelView: View {
    @ObservedObject var captureEngine: CaptureEngine
    @ObservedObject var permissionManager: PermissionManager
    var storageManager: StorageManager?

    var onOpenDailyAssistant: () -> Void
    var onOpenDebug: () -> Void

    @State private var captureCount24h: Int = 0
    @State private var summaryCount24h: Int = 0
    @State private var estimatedCostToday: Double = 0
    @State private var recentCaptures: [CaptureRecord] = []
    @State private var lastError: String?
    @State private var lastSummaryDate: Date?
    @State private var pendingCaptures: Int = 0
    @State private var focusState: NeuraMindFocusState?
    @State private var focusDrift: FocusDriftMetrics?
    @State private var overlayScore: FocusScore?
    @State private var isMedicated: Bool = false

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) {
                panelCards
            }
            .padding(14)
            .frame(width: 340)
            .onAppear { snapshotState() }
        } else {
            panelCards
                .padding(14)
                .frame(width: 340)
                .onAppear { snapshotState() }
        }
    }

    private var panelCards: some View {
        VStack(spacing: 10) {
            // Status + Power
            GlassCard {
                HStack {
                    StatusHeaderView(
                        state: captureEngine.state,
                        isRunning: captureEngine.isRunning
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // Stats
            GlassCard {
                StatsCardsView(
                    captureCount: captureCount24h,
                    summaryCount: summaryCount24h,
                    estimatedCost: estimatedCostToday
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // Focus
            if focusState != nil || overlayScore != nil {
                GlassCard {
                    VStack(spacing: 8) {
                        if let score = overlayScore {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(score.state.color)
                                    .frame(width: 8, height: 8)
                                Text(score.state.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", score.value * 100))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if focusState != nil {
                            FocusStatusView(
                                focusState: focusState,
                                drift: focusDrift
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            // Medication toggle
            GlassCard {
                HStack(spacing: 8) {
                    Image(systemName: "pill.fill")
                        .foregroundStyle(isMedicated ? .blue : Color(nsColor: .tertiaryLabelColor))
                        .font(.system(size: 12))
                    Text("Medication")
                        .font(.caption)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isMedicated },
                        set: { newValue in
                            isMedicated = newValue
                            ServiceContainer.shared.medicationManager?.toggle()
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.blue)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // Summarization + Interval
            GlassCard {
                VStack(spacing: 8) {
                    SummarizationStatusView(
                        lastSummaryDate: lastSummaryDate,
                        pendingCount: pendingCaptures
                    )
                    Divider().opacity(0.3)
                    IntervalIndicatorView(captureEngine: captureEngine)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // Recent Activity
            GlassCard {
                RecentActivityView(captures: recentCaptures)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            // Warning
            let capturesWorking = captureCount24h > 0
            if lastError != nil || (!permissionManager.allPermissionsGranted && !capturesWorking) {
                GlassCard {
                    WarningBannerView(
                        error: lastError,
                        permissionsOK: permissionManager.allPermissionsGranted || capturesWorking
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            // Focus Overlay Controls
            OverlayControlsCard()

            // Actions
            GlassCard {
                ActionsView(
                    captureEngine: captureEngine,
                    onOpenDailyAssistant: onOpenDailyAssistant,
                    onOpenDebug: onOpenDebug
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // Quit
            GlassCard {
                QuitButton()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func snapshotState() {
        isMedicated = ServiceContainer.shared.medicationManager?.isActive ?? false
        lastError = captureEngine.lastError

        let focusSnapshot = FocusStateStore.currentSnapshot(storageManager: storageManager)
        focusState = focusSnapshot.current
        focusDrift = focusSnapshot.drift
        overlayScore = ServiceContainer.shared.focusScoreEngine?.currentScore

        guard let storage = storageManager else { return }

        captureCount24h = (try? storage.captureCount24h()) ?? 0
        summaryCount24h = (try? storage.summaryCount24h()) ?? 0
        recentCaptures = (try? storage.recentCaptures(limit: 3)) ?? []

        if let health = try? storage.summarizationHealth() {
            lastSummaryDate = health.lastSummaryDate
            pendingCaptures = health.pendingCount
        }

        if let usage = try? storage.totalTokenUsage24h() {
            let inputCost = usage.inputMtok * 0.25
            let outputCost = usage.outputMtok * 1.25
            estimatedCostToday = inputCost + outputCost
        }
    }
}

// MARK: - Overlay Controls Card

/// Focus overlay controls: toggle, blur, tint, grain sliders.
private struct OverlayControlsCard: View {
    @State private var overlayState = OverlayState.shared

    var body: some View {
        GlassCard {
            VStack(spacing: 12) {
                // Header + toggle
                HStack {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(overlayState.isEnabled ? .blue : .secondary)
                    Text("Focus Overlay")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $overlayState.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                if overlayState.isEnabled {
                    VStack(spacing: 14) {
                        // Blur
                        OverlaySliderRow(
                            icon: "drop.fill",
                            label: "Blur",
                            value: $overlayState.blurAmount,
                            color: .blue
                        )

                        // Tint
                        OverlaySliderRow(
                            icon: "circle.fill",
                            label: "Tint",
                            value: $overlayState.tintOpacity,
                            color: Color(nsColor: overlayState.tintColor)
                        )

                        // Grain
                        OverlaySliderRow(
                            icon: "water.waves",
                            label: "Grain",
                            value: $overlayState.grainIntensity,
                            color: .cyan
                        )
                    }

                    // Tint presets
                    HStack(spacing: 6) {
                        ForEach(OverlayState.TintPreset.presets) { preset in
                            Button {
                                overlayState.tintEnabled = true
                                overlayState.setBaseColor(preset.color)
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: preset.color))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Button {
                            overlayState.adaptiveTintEnabled.toggle()
                        } label: {
                            Image(systemName: overlayState.adaptiveTintEnabled ? "waveform.path.ecg" : "waveform.path")
                                .font(.system(size: 12))
                                .foregroundStyle(overlayState.adaptiveTintEnabled ? .red : .secondary)
                                .help(overlayState.adaptiveTintEnabled ? "Adaptive: shifts red on drift" : "Adaptive tint off")
                        }
                        .buttonStyle(.plain)
                        Button {
                            overlayState.tintEnabled.toggle()
                        } label: {
                            Image(systemName: overlayState.tintEnabled ? "paintbrush.fill" : "paintbrush")
                                .font(.system(size: 12))
                                .foregroundStyle(overlayState.tintEnabled ? .blue : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .animation(.easeOut(duration: 0.2), value: overlayState.isEnabled)
        }
    }
}

/// Slider row for overlay effect controls.
private struct OverlaySliderRow: View {
    let icon: String
    let label: String
    @Binding var value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 34, alignment: .leading)

            OverlaySliderTrack(value: $value, color: color)
        }
    }
}

/// Custom slider track matching Hocus Pocus style.
private struct OverlaySliderTrack: View {
    @Binding var value: Double
    let color: Color
    var trackHeight: CGFloat = 4
    var thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.07))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.5), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, CGFloat(value) * w), height: trackHeight)

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: CGFloat(value) * (w - thumbSize))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                value = min(1, max(0, drag.location.x / w))
                            }
                    )
            }
            .frame(height: thumbSize)
            .frame(maxHeight: .infinity)
        }
        .frame(height: thumbSize)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startServices = Notification.Name("com.neuramind.startServices")
}

// MARK: - Debug Window Controller

@MainActor
final class DebugWindowController {
    private var window: NSWindow?
    private let storageManager: StorageManager

    init(storageManager: StorageManager) {
        self.storageManager = storageManager
    }

    func toggle() {
        if let window = window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let contentView = DebugTimelineView(storageManager: storageManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NeuraMind - Database Debug"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DebugWindow")
        self.window = window
    }
}

// MARK: - Enrichment Panel Controller

@MainActor
final class EnrichmentPanelController {
    private var panel: NSPanel?
    private let enrichmentEngine: EnrichmentEngine

    init(enrichmentEngine: EnrichmentEngine) {
        self.enrichmentEngine = enrichmentEngine
    }

    func toggle() {
        if let panel = panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        if panel == nil { createPanel() }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { panel?.orderOut(nil) }

    private func createPanel() {
        let contentView = EnrichmentPanel(enrichmentEngine: enrichmentEngine)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "NeuraMind - Enrich Prompt"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        self.panel = panel
    }
}
