import AppKit
import QuartzCore

// MARK: - Tint Layer

final class TintLayer: CALayer {

    override init() {
        super.init()
        backgroundColor = NSColor.clear.cgColor
        opacity = 0
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func update(color: NSColor, opacity tintOpacity: Double, enabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if enabled {
            backgroundColor = color.cgColor
            opacity = Float(min(max(tintOpacity, 0), 1))
        } else {
            opacity = 0
        }
        CATransaction.commit()
    }
}

// MARK: - Grayscale Filter

enum GrayscaleFilter {

    static func setGrayscale(on layer: CALayer, enabled: Bool) {
        if enabled {
            layer.filters = [makeSaturationFilter()]
        } else {
            layer.filters = nil
        }
    }

    private static func makeSaturationFilter() -> CIFilter {
        let filter = CIFilter(
            name: "CIColorControls",
            parameters: ["inputSaturation": 0.0]
        )!
        filter.name = "grayscale"
        return filter
    }
}

// MARK: - Mask Builder

enum MaskBuilder {

    static func buildMask(
        overlayBounds: CGRect,
        focusedFrames: [CGRect],
        cornerRadius: CGFloat = 10.0
    ) -> CAShapeLayer {
        let path = CGMutablePath()
        path.addRect(overlayBounds)

        for frame in focusedFrames {
            let cutout = frame.insetBy(dx: -4, dy: -4)
            path.addRoundedRect(
                in: cutout,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius
            )
        }

        let mask = CAShapeLayer()
        mask.path = path
        mask.fillRule = .evenOdd
        mask.frame = overlayBounds
        return mask
    }

    static func convertToViewCoordinates(
        windowFrame: CGRect,
        screen: NSScreen
    ) -> CGRect {
        let screenFrame = screen.frame
        guard let mainScreen = NSScreen.screens.first else { return windowFrame }
        let mainScreenHeight = mainScreen.frame.height

        let appKitY = mainScreenHeight - windowFrame.origin.y - windowFrame.height
        let localX = windowFrame.origin.x - screenFrame.origin.x
        let localY = appKitY - screenFrame.origin.y

        return CGRect(x: localX, y: localY, width: windowFrame.width, height: windowFrame.height)
    }
}
