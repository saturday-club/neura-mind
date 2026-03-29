import AppKit
import Observation

/// Observable state for the focus overlay effects.
/// Controls blur, tint, and grain applied to the overlay windows.
/// When adaptive tint is on, tint shifts from the user's chosen color toward red
/// as focus score drops (more app switching = more red).
@Observable
@MainActor
final class OverlayState {
    static let shared = OverlayState()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "overlay.isEnabled") }
    }

    var blurAmount: Double {
        didSet { UserDefaults.standard.set(blurAmount, forKey: "overlay.blurAmount") }
    }

    var grainIntensity: Double {
        didSet { UserDefaults.standard.set(grainIntensity, forKey: "overlay.grainIntensity") }
    }

    var tintEnabled: Bool {
        didSet { UserDefaults.standard.set(tintEnabled, forKey: "overlay.tintEnabled") }
    }

    /// The live tint color (may be blended toward red by adaptive tint).
    var tintColor: NSColor {
        didSet {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tintColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            UserDefaults.standard.set(Double(r), forKey: "overlay.tintRed")
            UserDefaults.standard.set(Double(g), forKey: "overlay.tintGreen")
            UserDefaults.standard.set(Double(b), forKey: "overlay.tintBlue")
        }
    }

    var tintOpacity: Double {
        didSet { UserDefaults.standard.set(tintOpacity, forKey: "overlay.tintOpacity") }
    }

    /// When true, tint color shifts toward red as focus score drops.
    var adaptiveTintEnabled: Bool {
        didSet { UserDefaults.standard.set(adaptiveTintEnabled, forKey: "overlay.adaptiveTint") }
    }

    struct TintPreset: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let color: NSColor

        static let presets: [TintPreset] = [
            TintPreset(id: "blue", name: "Ocean", color: NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)),
            TintPreset(id: "purple", name: "Dusk", color: NSColor(srgbRed: 0.5, green: 0.3, blue: 0.8, alpha: 1)),
            TintPreset(id: "green", name: "Forest", color: NSColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1)),
            TintPreset(id: "amber", name: "Warm", color: NSColor(srgbRed: 0.9, green: 0.6, blue: 0.2, alpha: 1)),
            TintPreset(id: "red", name: "Rose", color: NSColor(srgbRed: 0.9, green: 0.3, blue: 0.4, alpha: 1)),
            TintPreset(id: "teal", name: "Teal", color: NSColor(srgbRed: 0.2, green: 0.7, blue: 0.7, alpha: 1)),
            TintPreset(id: "system", name: "System", color: NSColor.controlAccentColor),
        ]
    }

    private init() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            "overlay.isEnabled": false,
            "overlay.blurAmount": 0.6,
            "overlay.grainIntensity": 0.4,
            "overlay.tintEnabled": false,
            "overlay.tintOpacity": 0.15,
            "overlay.adaptiveTint": true,
        ])
        self.isEnabled = ud.bool(forKey: "overlay.isEnabled")
        self.blurAmount = ud.double(forKey: "overlay.blurAmount")
        self.grainIntensity = ud.double(forKey: "overlay.grainIntensity")
        self.tintEnabled = ud.bool(forKey: "overlay.tintEnabled")
        self.tintOpacity = ud.double(forKey: "overlay.tintOpacity")
        self.adaptiveTintEnabled = ud.bool(forKey: "overlay.adaptiveTint")

        let r = ud.double(forKey: "overlay.tintRed")
        let g = ud.double(forKey: "overlay.tintGreen")
        let b = ud.double(forKey: "overlay.tintBlue")
        if r == 0 && g == 0 && b == 0 {
            self.tintColor = NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1) // Ocean default
        } else {
            self.tintColor = NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        }

        // Persist base color if not set yet
        if ud.double(forKey: "overlay.baseTintRed") == 0
            && ud.double(forKey: "overlay.baseTintGreen") == 0
            && ud.double(forKey: "overlay.baseTintBlue") == 0 {
            saveBaseColor(tintColor)
        }
    }

    func toggle() { isEnabled.toggle() }

    /// User picks a new base color via preset dots.
    func setBaseColor(_ color: NSColor) {
        saveBaseColor(color)
        tintColor = color
    }

    // Smoothing state for gradual color transitions
    private var currentR: CGFloat = 0
    private var currentG: CGFloat = 0
    private var currentB: CGFloat = 0
    private var smoothingInitialized = false

    /// Blend the base tint toward red based on focus score.
    /// Called at 15Hz from the update timer.
    /// Uses exponential smoothing so color changes feel gradual, not jumpy.
    /// Score 1.0 = 100% base color (calm). Score 0.0 = 100% red (drifting).
    func applyFocusBlend(focusScore: Double) {
        guard adaptiveTintEnabled, tintEnabled, isEnabled else { return }

        let ud = UserDefaults.standard
        let baseR = CGFloat(ud.double(forKey: "overlay.baseTintRed"))
        let baseG = CGFloat(ud.double(forKey: "overlay.baseTintGreen"))
        let baseB = CGFloat(ud.double(forKey: "overlay.baseTintBlue"))

        // Initialize smoothing from current tint
        if !smoothingInitialized {
            currentR = baseR; currentG = baseG; currentB = baseB
            smoothingInitialized = true
        }

        let score = min(max(focusScore, 0), 1)

        // Gentle curve: red only kicks in at truly bad scores
        // score=1.0 -> t=0, score=0.5 -> t=0.25, score=0.3 -> t=0.49, score=0.0 -> t=1.0
        let drift = 1.0 - score
        let t = CGFloat(drift * drift)

        // Warning red target
        let warnR: CGFloat = 1.0
        let warnG: CGFloat = 0.22
        let warnB: CGFloat = 0.25

        let targetR = baseR * (1 - t) + warnR * t
        let targetG = baseG * (1 - t) + warnG * t
        let targetB = baseB * (1 - t) + warnB * t

        // Exponential smoothing: lerp 5% per frame at 15Hz
        // = ~50% change per second, full transition in ~3-4 seconds
        let smoothing: CGFloat = 0.05
        currentR += (targetR - currentR) * smoothing
        currentG += (targetG - currentG) * smoothing
        currentB += (targetB - currentB) * smoothing

        tintColor = NSColor(srgbRed: currentR, green: currentG, blue: currentB, alpha: 1.0)
    }

    private func saveBaseColor(_ color: NSColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        UserDefaults.standard.set(Double(r), forKey: "overlay.baseTintRed")
        UserDefaults.standard.set(Double(g), forKey: "overlay.baseTintGreen")
        UserDefaults.standard.set(Double(b), forKey: "overlay.baseTintBlue")
    }
}
