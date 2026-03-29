import AppKit
import QuartzCore

/// The content view for each overlay window. Stacks blur + tint + grain layers.
@MainActor
final class FocusOverlayContentView: NSView {

    private let blurView = PanelBlurView(frame: .zero)
    private let tintLayer = TintLayer()
    private var tintHostView: NSView?
    private var grainHostView: NSView?
    private var grainRenderer: GrainRenderer?
    private let screen: NSScreen

    init(frame: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        setupBlur()
        setupTint()
        setupGrain()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupBlur() {
        blurView.frame = bounds
        addSubview(blurView)
    }

    private func setupTint() {
        let tintHost = NSView(frame: bounds)
        tintHost.wantsLayer = true
        tintHost.autoresizingMask = [.width, .height]
        tintHost.layer?.addSublayer(tintLayer)
        tintLayer.frame = bounds
        addSubview(tintHost, positioned: .above, relativeTo: blurView)
        self.tintHostView = tintHost
    }

    private func setupGrain() {
        if let renderer = GrainRenderer() {
            self.grainRenderer = renderer
            renderer.metalLayer.frame = bounds
            renderer.metalLayer.opacity = 0
            renderer.metalLayer.compositingFilter = "overlayBlendMode"

            let grainHost = NSView(frame: bounds)
            grainHost.wantsLayer = true
            grainHost.autoresizingMask = [.width, .height]
            grainHost.layer?.addSublayer(renderer.metalLayer)
            addSubview(grainHost, positioned: .above, relativeTo: tintHostView)
            self.grainHostView = grainHost
        }
    }

    override func layout() {
        super.layout()
        blurView.frame = bounds
        tintHostView?.frame = bounds
        tintLayer.frame = tintHostView?.bounds ?? bounds
        grainHostView?.frame = bounds
        grainRenderer?.metalLayer.frame = grainHostView?.bounds ?? bounds
        grainRenderer?.updateSize(bounds.size, scaleFactor: screen.backingScaleFactor)
    }

    func updateEffects(state: OverlayState) {
        blurView.updateIntensity(state.blurAmount)

        tintLayer.update(
            color: state.tintColor,
            opacity: state.tintOpacity,
            enabled: state.tintEnabled
        )

        if state.grainIntensity > 0.01 {
            let grainOpacity = Float(state.grainIntensity * 0.5)
            grainRenderer?.metalLayer.opacity = grainOpacity
            grainRenderer?.start()
        } else {
            grainRenderer?.metalLayer.opacity = 0
        }

        // grayscale removed
    }

    func clearMask() {
        guard layer?.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.mask = nil
        CATransaction.commit()
    }

    func teardown() {
        grainRenderer?.stop()
    }
}
