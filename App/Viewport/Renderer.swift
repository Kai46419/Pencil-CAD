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
    /// Lage des Rasters (Skizzenebene); nil blendet es aus.
    var gridTransform: float4x4? = matrix_identity_float4x4

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let alwaysDepthState: MTLDepthStencilState

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var selectionBuffer: MTLBuffer?
    private var selectionCount = 0
    private var edgeBuffer: MTLBuffer?
    private var edgeCount = 0
    private let gridBuffer: MTLBuffer?
    private let gridCount: Int
    private var sketchBuffer: MTLBuffer?
    private var sketchCount = 0
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

        func pipeline(vertex: String, fragment: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            descriptor.rasterSampleCount = view.sampleCount
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true

        let alwaysDescriptor = MTLDepthStencilDescriptor()
        alwaysDescriptor.depthCompareFunction = .always
        alwaysDescriptor.isDepthWriteEnabled = false

        guard let solidPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_main"),
              let overlayPipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_flat"),
              let linePipeline = pipeline(vertex: "vertex_main", fragment: "fragment_flat"),
              let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
              let alwaysDepthState = device.makeDepthStencilState(descriptor: alwaysDescriptor) else { return nil }

        let grid = Renderer.makeGrid(halfSize: 200, step: 10)
        self.device = device
        self.queue = queue
        self.solidPipeline = solidPipeline
        self.overlayPipeline = overlayPipeline
        self.linePipeline = linePipeline
        self.depthState = depthState
        self.alwaysDepthState = alwaysDepthState
        self.gridBuffer = device.makeBuffer(bytes: grid, length: MemoryLayout<Vertex>.stride * grid.count)
        self.gridCount = grid.count
        super.init()
    }

    // MARK: Daten

    func update(mesh: Mesh) {
        vertexBuffer = makeBuffer(mesh.vertices)
        indexBuffer = makeBuffer(mesh.indices)
        indexCount = mesh.indices.count
        let edges = mesh.edges.map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }
        edgeBuffer = makeBuffer(edges)
        edgeCount = edges.count
        selectionBuffer = nil
        selectionCount = 0

        if !hasFramedOnce, let bounds = mesh.bounds {
            camera.frame(min: bounds.min, max: bounds.max)
            hasFramedOnce = true
        }
    }

    func updateSelection(indices: [UInt32]) {
        selectionBuffer = makeBuffer(indices)
        selectionCount = indices.count
    }

    /// Skizzenlinien als Punktpaare in Weltkoordinaten.
    func updateSketch(points: [SIMD3<Float>]) {
        let vertices = points.map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }
        sketchBuffer = makeBuffer(vertices)
        sketchCount = vertices.count
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return device.makeBuffer(bytes: array, length: MemoryLayout<T>.stride * array.count)
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

    // MARK: Zeichnen

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        let size = view.drawableSize
        let aspect = Float(size.width / max(size.height, 1))
        // Licht kommt leicht versetzt aus Blickrichtung, damit Flächen Kontrast haben.
        let toEye = simd_normalize(camera.position - camera.target)
        var uniforms = Uniforms(
            viewProjection: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
            model: matrix_identity_float4x4,
            lightDirection: simd_normalize(toEye + SIMD3(0.3, 0.2, 0.6)),
            baseColor: SIMD3(0.55, 0.62, 0.72)
        )

        func setUniforms(_ u: inout Uniforms) {
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        }
        func setColor(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
            var color = SIMD4<Float>(r, g, b, a)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        }

        // Körper
        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)

            // Ausgewählte Fläche
            if let selectionBuffer, selectionCount > 0 {
                encoder.setRenderPipelineState(overlayPipeline)
                setColor(0.98, 0.62, 0.18)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: selectionCount, indexType: .uint32,
                                              indexBuffer: selectionBuffer, indexBufferOffset: 0)
            }
        }

        // Kanten
        if let edgeBuffer, edgeCount > 0 {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            setColor(0.12, 0.14, 0.18)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeCount)
        }

        // Raster auf der Skizzenebene
        if let gridBuffer, let gridTransform {
            var gridUniforms = uniforms
            gridUniforms.model = gridTransform
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            setUniforms(&gridUniforms)
            setColor(0.62, 0.65, 0.7)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridCount)
        }

        // Skizze immer obenauf
        if let sketchBuffer, sketchCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(alwaysDepthState)
            encoder.setVertexBuffer(sketchBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            setColor(0.05, 0.4, 0.95)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: sketchCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
