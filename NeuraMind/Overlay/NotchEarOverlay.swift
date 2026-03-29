import AppKit
import QuartzCore

/// Shows tint + grain in the notch ear areas (beside the camera housing) during fullscreen.
@MainActor
final class NotchEarOverlay {

    private struct Ear {
        let window: NSWindow
        let tintLayer: TintLayer
        let grainRenderer: GrainRenderer?
        let screen: NSScreen
    }

    private var leftEar: Ear?
    private var rightEar: Ear?
    private var isVisible = false

    func show(on screen: NSScreen, state: OverlayState) {
        guard screen.safeAreaInsets.top > 0 else { return }

        showEar(&leftEar, rect: screen.auxiliaryTopLeftArea ?? .zero, screen: screen, state: state)
        showEar(&rightEar, rect: screen.auxiliaryTopRightArea ?? .zero, screen: screen, state: state)

        if !isVisible {
            fadeIn()
            isVisible = true
        }
    }

    func hide() {
        guard isVisible else { return }
        fadeOut()
        isVisible = false
    }

    func updateEffects(state: OverlayState) {
        guard isVisible else { return }
        applyEffects(leftEar, state: state)
        applyEffects(rightEar, state: state)
    }

    func teardown() {
        leftEar?.grainRenderer?.stop()
        rightEar?.grainRenderer?.stop()
        leftEar?.window.close()
        rightEar?.window.close()
        leftEar = nil
        rightEar = nil
        isVisible = false
    }

    // MARK: - Private

    private func showEar(_ ear: inout Ear?, rect: CGRect, screen: NSScreen, state: OverlayState) {
        guard !rect.isEmpty else { return }

        // Extend 1px downward to close the gap between ears (32px) and menu bar (33px)
        let adjusted = CGRect(
            x: rect.origin.x,
            y: rect.origin.y - 1,
            width: rect.width,
            height: rect.height + 1
        )

        if ear == nil {
            ear = makeEar(frame: adjusted, screen: screen)
        } else {
            ear?.window.setFrame(adjusted, display: true)
        }
        applyEffects(ear, state: state)
    }

    private func fadeIn() {
        for ear in [leftEar, rightEar] {
            guard let w = ear?.window else { continue }
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1.0
            }
        }
    }

    private func fadeOut() {
        for ear in [leftEar, rightEar] {
            guard let w = ear?.window else { continue }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                w.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    w.orderOut(nil)
                    w.alphaValue = 1.0
                }
            })
        }
    }

    private func makeEar(frame: CGRect, screen: NSScreen) -> Ear {
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Above layer 26 (active app's menu bar) but below popups (101)
        window.level = NSWindow.Level(rawValue: 27)
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .transient
        ]
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true

        // Tint color layer
        let tint = TintLayer()
        tint.frame = root.bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(tint)

        // Grain
        var grain: GrainRenderer?
        if let renderer = GrainRenderer() {
            renderer.metalLayer.frame = root.bounds
            renderer.metalLayer.opacity = 0
            renderer.metalLayer.compositingFilter = "overlayBlendMode"
            renderer.updateSize(root.bounds.size, scaleFactor: screen.backingScaleFactor)

            let grainHost = NSView(frame: root.bounds)
            grainHost.wantsLayer = true
            grainHost.autoresizingMask = [.width, .height]
            grainHost.layer?.addSublayer(renderer.metalLayer)
            root.addSubview(grainHost)
            grain = renderer
        }

        window.contentView = root
        return Ear(window: window, tintLayer: tint, grainRenderer: grain, screen: screen)
    }

    private func applyEffects(_ ear: Ear?, state: OverlayState) {
        guard let ear else { return }
        ear.tintLayer.update(
            color: state.tintColor,
            opacity: state.tintOpacity,
            enabled: state.tintEnabled
        )

        if state.grainIntensity > 0.01 {
            let grainOpacity = Float(state.grainIntensity * 0.5)
            ear.grainRenderer?.metalLayer.opacity = grainOpacity
            ear.grainRenderer?.start()
        } else {
            ear.grainRenderer?.metalLayer.opacity = 0
        }
    }
}
