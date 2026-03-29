import AppKit
import Metal
import QuartzCore

struct GrainUniforms {
    var time: Float
    var intensity: Float
    var resolution: SIMD2<Float>
}

@MainActor
final class GrainRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    let metalLayer: CAMetalLayer

    private var startTime: CFTimeInterval = 0
    private var isRunning = false
    var intensity: Float = 1.0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.commandQueue = queue

        guard let shaderURL = Bundle.module.url(forResource: "GrainShader", withExtension: "metal"),
              let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8)
        else {
            print("[GrainRenderer] Failed to load shader source")
            return nil
        }

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "grainKernel") else {
                print("[GrainRenderer] Failed to find grainKernel function")
                return nil
            }
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("[GrainRenderer] Shader compilation failed: \(error)")
            return nil
        }

        self.metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = true
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startTime = CACurrentMediaTime()
        render()
    }

    func renderOnce() { render() }

    func stop() { isRunning = false }

    func updateSize(_ size: CGSize, scaleFactor: CGFloat) {
        metalLayer.drawableSize = CGSize(
            width: max(1, size.width * scaleFactor),
            height: max(1, size.height * scaleFactor)
        )
        metalLayer.contentsScale = scaleFactor
        metalLayer.magnificationFilter = .nearest
    }

    private func render() {
        guard isRunning,
              metalLayer.drawableSize.width > 0,
              metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        let time = Float(CACurrentMediaTime() - startTime)
        let w = Float(metalLayer.drawableSize.width)
        let h = Float(metalLayer.drawableSize.height)

        var uniforms = GrainUniforms(
            time: time, intensity: intensity,
            resolution: SIMD2<Float>(w, h)
        )

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(drawable.texture, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.size, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: Int(w), height: Int(h), depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
