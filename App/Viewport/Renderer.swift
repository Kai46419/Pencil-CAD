import MetalKit
import simd
import UIKit

/// Muss zum `Uniforms`-Struct in Shaders.metal passen.
private struct Uniforms {
    var viewProjection: float4x4
    var model: float4x4
    var lightDirection: SIMD3<Float>
    var baseColor: SIMD3<Float>
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case shaded = "Schattiert"
    case shadedPlain = "Schattiert ohne Kanten"
    case wireframe = "Drahtgitter"
    case xray = "Röntgen"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .shaded: "cube.fill"
        case .shadedPlain: "cube"
        case .wireframe: "cube.transparent"
        case .xray: "eye"
        }
    }
}

/// Ziehpfeil in Weltkoordinaten: Fuß, Richtung (normiert), Farbe.
struct HandleGraphic {
    var base: SIMD3<Float>
    var direction: SIMD3<Float>
    var color: SIMD3<Float>
}

/// Halbtransparente quadratische Ebenenscheibe (Skizzenebene bzw. Ebenenwahl).
struct PlaneGraphic {
    var center: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var halfSize: Float
    var color: SIMD3<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    /// Länge eines Ziehpfeils in Bildschirmpunkten.
    static let handleLength: Float = 64

    var camera = OrbitCamera()
    /// Lage des Rasters (Skizzenebene); nil blendet es aus.
    var gridTransform: float4x4? = matrix_identity_float4x4
    var displayMode: DisplayMode = .shaded
    var handles: [HandleGraphic] = []
    var planes: [PlaneGraphic] = []

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb
    private let depthFormat: MTLPixelFormat = .depth32Float
    private let sampleCount = 4
    private let solidPipeline: MTLRenderPipelineState
    private let xrayPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let readOnlyDepthState: MTLDepthStencilState
    private let alwaysDepthState: MTLDepthStencilState

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var selectionBuffer: MTLBuffer?
    private var selectionCount = 0
    private var edgeBuffer: MTLBuffer?
    private var edgeCount = 0
    private var edgeHighlightBuffer: MTLBuffer?
    private var edgeHighlightCount = 0
    private let gridBuffer: MTLBuffer?
    private let gridCount: Int
    private var sketchBuffer: MTLBuffer?
    private var sketchCount = 0
    private var previewVertexBuffer: MTLBuffer?
    private var previewIndexBuffer: MTLBuffer?
    private var previewIndexCount = 0
    private var previewEdgeBuffer: MTLBuffer?
    private var previewEdgeCount = 0
    private var previewFilled = true
    private var hasFramedOnce = false

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.925, green: 0.925, blue: 0.93, alpha: 1)

        func pipeline(vertex: String, fragment: String, blended: Bool = false) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            if blended {
                let attachment = descriptor.colorAttachments[0]
                attachment?.isBlendingEnabled = true
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.rasterSampleCount = 4
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }

        guard let solidPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_main"),
              let xrayPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_xray", blended: true),
              let overlayPipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_flat"),
              let linePipeline = pipeline(vertex: "vertex_main", fragment: "fragment_flat"),
              let depthState = depth(.lessEqual, write: true),
              let readOnlyDepthState = depth(.lessEqual, write: false),
              let alwaysDepthState = depth(.always, write: false) else { return nil }

        let grid = Renderer.makeGrid(halfSize: 200, step: 10)
        self.device = device
        self.queue = queue
        self.solidPipeline = solidPipeline
        self.xrayPipeline = xrayPipeline
        self.overlayPipeline = overlayPipeline
        self.linePipeline = linePipeline
        self.depthState = depthState
        self.readOnlyDepthState = readOnlyDepthState
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

    func updateSelection(indices: [UInt32], edges: [SIMD3<Float>]) {
        selectionBuffer = makeBuffer(indices)
        selectionCount = indices.count
        let edgeVertices = edges.map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }
        edgeHighlightBuffer = makeBuffer(edgeVertices)
        edgeHighlightCount = edgeVertices.count
    }

    /// Skizzenlinien als Punktpaare in Weltkoordinaten.
    func updateSketch(points: [SIMD3<Float>]) {
        let vertices = points.map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }
        sketchBuffer = makeBuffer(vertices)
        sketchCount = vertices.count
    }

    /// Vorschau der Extrusion einer Skizze; filled = als Körper, sonst nur Kanten (Abziehen).
    func updatePreview(_ mesh: Mesh?, filled: Bool) {
        let tinted = mesh?.vertices.map { Vertex(position: $0.position, normal: $0.normal, color: SIMD3(0.45, 0.62, 0.95)) }
        previewVertexBuffer = tinted.flatMap { makeBuffer($0) }
        previewIndexBuffer = mesh.flatMap { makeBuffer($0.indices) }
        previewIndexCount = mesh?.indices.count ?? 0
        let edges = (mesh?.edges ?? []).map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }
        previewEdgeBuffer = makeBuffer(edges)
        previewEdgeCount = edges.count
        previewFilled = filled
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count) }
        }
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

    /// Pfeil aus Schaft und Spitze, length in Weltmaß.
    static func arrowVertices(_ handle: HandleGraphic, length: Float) -> [Vertex] {
        let d = simd_normalize(handle.direction)
        let reference: SIMD3<Float> = abs(d.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(reference, d)), v = simd_cross(d, u)
        let shaftRadius = length * 0.05, headRadius = length * 0.14, headLength = length * 0.34
        let base = handle.base
        let shaftEnd = base + d * (length - headLength), tip = base + d * length
        let color = handle.color
        let segments = 18
        var out: [Vertex] = []
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let r0 = cos(a0) * u + sin(a0) * v, r1 = cos(a1) * u + sin(a1) * v
            // Schaft
            let p0 = base + r0 * shaftRadius, p1 = base + r1 * shaftRadius
            let q0 = shaftEnd + r0 * shaftRadius, q1 = shaftEnd + r1 * shaftRadius
            out += [Vertex(position: p0, normal: r0, color: color), Vertex(position: p1, normal: r1, color: color),
                    Vertex(position: q1, normal: r1, color: color), Vertex(position: p0, normal: r0, color: color),
                    Vertex(position: q1, normal: r1, color: color), Vertex(position: q0, normal: r0, color: color)]
            // Boden der Spitze
            out += [Vertex(position: shaftEnd, normal: -d, color: color),
                    Vertex(position: shaftEnd + r1 * headRadius, normal: -d, color: color),
                    Vertex(position: shaftEnd + r0 * headRadius, normal: -d, color: color)]
            // Mantel der Spitze
            let n0 = simd_normalize(r0 * headLength + d * headRadius)
            let n1 = simd_normalize(r1 * headLength + d * headRadius)
            out += [Vertex(position: shaftEnd + r0 * headRadius, normal: n0, color: color),
                    Vertex(position: shaftEnd + r1 * headRadius, normal: n1, color: color),
                    Vertex(position: tip, normal: simd_normalize(n0 + n1), color: color)]
        }
        // Griffkugel am Fuß (Oktaeder)
        let k = shaftRadius * 2.2
        let axes = [u, -u, v, -v, d, -d]
        let faces: [(Int, Int, Int)] = [(0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
        for (a, b, c) in faces {
            let n = simd_normalize(axes[a] + axes[b] + axes[c])
            out += [Vertex(position: base + axes[a] * k, normal: n, color: color),
                    Vertex(position: base + axes[b] * k, normal: n, color: color),
                    Vertex(position: base + axes[c] * k, normal: n, color: color)]
        }
        return out
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
        encode(encoder, aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)),
               viewHeight: Float(view.bounds.height))
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Bild der aktuellen Ansicht (für Screenshot und Projekt-Vorschaubild), Größe in Pixeln.
    func snapshot(width: Int, height: Int, viewHeight: CGFloat) -> UIImage? {
        guard width > 0, height > 0 else { return nil }
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage,
                     storage: MTLStorageMode) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.textureType = samples > 1 ? .type2DMultisample : .type2D
            descriptor.sampleCount = samples
            descriptor.usage = usage
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }
        guard let color = texture(colorFormat, samples: sampleCount, usage: .renderTarget, storage: .private),
              let resolve = texture(colorFormat, samples: 1, usage: [.renderTarget, .shaderRead], storage: .shared),
              let depthTexture = texture(depthFormat, samples: sampleCount, usage: .renderTarget, storage: .private),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = resolve
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.925, green: 0.925, blue: 0.93, alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(encoder, aspect: Float(width) / Float(height), viewHeight: Float(viewHeight))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        resolve.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, aspect: Float, viewHeight: Float) {
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

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
        func drawEdges(depth: MTLDepthStencilState) {
            guard let edgeBuffer, edgeCount > 0 else { return }
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setDepthStencilState(depth)
            encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            setColor(0.12, 0.13, 0.16)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeCount)
        }

        // Raster zuerst, damit es hinter halbtransparenten Körpern liegt
        if let gridBuffer, let gridTransform {
            var gridUniforms = uniforms
            gridUniforms.model = gridTransform
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
            setUniforms(&gridUniforms)
            setColor(0.78, 0.79, 0.81)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridCount)
        }

        // Körper
        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            switch displayMode {
            case .shaded, .shadedPlain:
                encoder.setRenderPipelineState(solidPipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
                if displayMode == .shaded {
                    drawEdges(depth: depthState)
                }
            case .wireframe:
                drawEdges(depth: alwaysDepthState)
            case .xray:
                drawEdges(depth: alwaysDepthState)
                encoder.setRenderPipelineState(xrayPipeline)
                encoder.setDepthStencilState(readOnlyDepthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
            }

            // Ausgewählte Flächen bzw. Körper
            if let selectionBuffer, selectionCount > 0 {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setDepthStencilState(displayMode == .shaded || displayMode == .shadedPlain
                                             ? depthState : alwaysDepthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                setColor(0.98, 0.62, 0.18, 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: selectionCount, indexType: .uint32,
                                              indexBuffer: selectionBuffer, indexBufferOffset: 0)
            }
        }

        // Ebenenscheiben: halbtransparent, hinter Körpern verdeckt
        if !planes.isEmpty {
            var fill: [Vertex] = []
            for plane in planes {
                let n = simd_normalize(simd_cross(plane.u, plane.v))
                let h = plane.halfSize
                let corners = [plane.center - plane.u * h - plane.v * h, plane.center + plane.u * h - plane.v * h,
                               plane.center + plane.u * h + plane.v * h, plane.center - plane.u * h + plane.v * h]
                fill += [0, 1, 2, 0, 2, 3].map { Vertex(position: corners[$0], normal: n, color: plane.color) }
            }
            if let buffer = makeBuffer(fill) {
                encoder.setRenderPipelineState(xrayPipeline)
                encoder.setDepthStencilState(readOnlyDepthState)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fill.count)
            }
            for plane in planes {
                let h = plane.halfSize
                let corners = [plane.center - plane.u * h - plane.v * h, plane.center + plane.u * h - plane.v * h,
                               plane.center + plane.u * h + plane.v * h, plane.center - plane.u * h + plane.v * h]
                let outline = [0, 1, 1, 2, 2, 3, 3, 0].map { Vertex(position: corners[$0], normal: SIMD3(0, 0, 1)) }
                guard let buffer = makeBuffer(outline) else { continue }
                encoder.setRenderPipelineState(linePipeline)
                encoder.setDepthStencilState(readOnlyDepthState)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                setColor(plane.color.x * 0.8, plane.color.y * 0.8, plane.color.z * 0.8)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: outline.count)
            }
        }

        // Gewählte Kanten
        if let edgeHighlightBuffer, edgeHighlightCount > 0 {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setDepthStencilState(alwaysDepthState)
            encoder.setVertexBuffer(edgeHighlightBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            setColor(0.98, 0.55, 0.08)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeHighlightCount)
        }

        // Vorschau der Extrusion
        if previewFilled, let previewVertexBuffer, let previewIndexBuffer, previewIndexCount > 0 {
            encoder.setRenderPipelineState(xrayPipeline)
            encoder.setDepthStencilState(readOnlyDepthState)
            encoder.setVertexBuffer(previewVertexBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: previewIndexCount, indexType: .uint32,
                                          indexBuffer: previewIndexBuffer, indexBufferOffset: 0)
        }
        if let previewEdgeBuffer, previewEdgeCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(alwaysDepthState)
            encoder.setVertexBuffer(previewEdgeBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            setColor(0.1, 0.4, 0.95)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: previewEdgeCount)
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

        // Ziehpfeile obenauf, Größe bleibt auf dem Bildschirm gleich
        var arrows: [Vertex] = []
        for handle in handles {
            let length = Renderer.handleLength * camera.worldUnitsPerPoint(at: handle.base, viewHeight: viewHeight)
            arrows += Renderer.arrowVertices(handle, length: length)
        }
        if let arrowBuffer = makeBuffer(arrows) {
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setDepthStencilState(alwaysDepthState)
            encoder.setVertexBuffer(arrowBuffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: arrows.count)
        }
    }
}
