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
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private let gridBuffer: MTLBuffer?
    private let gridVertexCount: Int
    private var sketchBuffer: MTLBuffer?
    private var sketchVertexCount = 0
    /// Höhe des Rasters (= Skizzenebene); nil blendet es aus.
    var gridZ: Float? = 0
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

        let lineDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
        lineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_line")

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        let overlayDescriptor = MTLDepthStencilDescriptor()
        overlayDescriptor.depthCompareFunction = .always
        overlayDescriptor.isDepthWriteEnabled = false

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let linePipeline = try? device.makeRenderPipelineState(descriptor: lineDescriptor),
              let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
              let overlayDepthState = device.makeDepthStencilState(descriptor: overlayDescriptor) else { return nil }

        let grid = Renderer.makeGrid(halfSize: 200, step: 10)
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.linePipeline = linePipeline
        self.depthState = depthState
        self.overlayDepthState = overlayDepthState
        self.gridBuffer = device.makeBuffer(bytes: grid, length: MemoryLayout<Vertex>.stride * grid.count)
        self.gridVertexCount = grid.count
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

    /// Skizzenlinien als Punktpaare in der Ebene Z = z.
    func updateSketch(segments: [SIMD2<Double>], z: Double) {
        let vertices = segments.map {
            Vertex(position: SIMD3(Float($0.x), Float($0.y), Float(z)), normal: SIMD3(0, 0, 1))
        }
        sketchVertexCount = vertices.count
        sketchBuffer = vertices.isEmpty
            ? nil
            : device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count)
    }

    private static func makeGrid(halfSize: Float, step: Float) -> [Vertex] {
        var vertices: [Vertex] = []
        let up = SIMD3<Float>(0, 0, 1)
        for v in stride(from: -halfSize, through: halfSize, by: step) {
            vertices += [Vertex(position: SIMD3(v, -halfSize, 0), normal: up),
                         Vertex(position: SIMD3(v, halfSize, 0), normal: up),
                         Vertex(position: SIMD3(-halfSize, v, 0), normal: up),
                         Vertex(position: SIMD3(halfSize, v, 0), normal: up)]
        }
        return vertices
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

        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)
        }

        encoder.setRenderPipelineState(linePipeline)

        if let gridBuffer, let gridZ {
            var gridUniforms = uniforms
            gridUniforms.model = float4x4(translation: SIMD3(0, 0, gridZ))
            var color = SIMD4<Float>(0.6, 0.63, 0.68, 1)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&gridUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
        }

        if let sketchBuffer, sketchVertexCount > 0 {
            var color = SIMD4<Float>(0.05, 0.4, 0.95, 1)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setVertexBuffer(sketchBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: sketchVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
