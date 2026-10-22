import MetalKit
import simd

/// Muss zum `Uniforms`-Struct in Shaders.metal passen.
private struct Uniforms {
    var viewProjection: float4x4
    var model: float4x4
    var lightDirection: SIMD3<Float>
    var baseColor: SIMD3<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    var camera = OrbitCamera()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var hasFramedOnce = false

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.rasterSampleCount = view.sampleCount

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        super.init()
    }

    func update(mesh: Mesh) {
        guard !mesh.indices.isEmpty else {
            vertexBuffer = nil
            indexBuffer = nil
            indexCount = 0
            return
        }
        vertexBuffer = device.makeBuffer(bytes: mesh.vertices, length: MemoryLayout<Vertex>.stride * mesh.vertices.count)
        indexBuffer = device.makeBuffer(bytes: mesh.indices, length: MemoryLayout<UInt32>.stride * mesh.indices.count)
        indexCount = mesh.indices.count

        if !hasFramedOnce, let bounds = mesh.bounds {
            camera.frame(min: bounds.min, max: bounds.max)
            hasFramedOnce = true
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            let size = view.drawableSize
            let aspect = Float(size.width / max(size.height, 1))
            // Licht kommt leicht versetzt aus Blickrichtung, damit Kanten Kontrast haben.
            let toEye = simd_normalize(camera.position - camera.target)
            var uniforms = Uniforms(
                viewProjection: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
                model: matrix_identity_float4x4,
                lightDirection: simd_normalize(toEye + SIMD3(0.3, 0.2, 0.6)),
                baseColor: SIMD3(0.55, 0.62, 0.72)
            )
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
