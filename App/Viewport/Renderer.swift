import MetalKit
import simd
import UIKit

/// Muss zum `Uniforms`-Struct in Shaders.metal passen.
private struct Uniforms {
    var viewProjection: float4x4
    var model: float4x4
    var lightDirection: SIMD3<Float>
    var baseColor: SIMD3<Float>
    /// Schnittansicht: xyz = Normale, w = Abstand; Normale 0 = aus
    var clipPlane: SIMD4<Float> = .zero
    /// xyz = Kameraposition, w = Anteil, um den Überlagerungen (Kanten, Skizzen) zur Kamera rücken
    var eye: SIMD4<Float> = .zero
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case shaded = "Schattiert"
    case shadedPlain = "Schattiert ohne Kanten"
    case wireframe = "Drahtgitter"
    case xray = "Röntgen"
    /// Schattiert, Kanten hinter Flächen blass gestrichelt (wie in technischen Zeichnungen)
    case hiddenEdges = "Verdeckte Kanten"
    /// Streifen aus der Spiegelrichtung zur Prüfung von Flächenübergängen
    case zebra = "Zebra"

    var id: Self { self }

    /// Körper deckend gezeichnet (Auswahl wird dann von Flächen davor verdeckt)
    var isSolid: Bool { self == .shaded || self == .shadedPlain || self == .hiddenEdges || self == .zebra }

    var systemImage: String {
        switch self {
        case .shaded: "cube.fill"
        case .shadedPlain: "cube"
        case .wireframe: "cube.transparent"
        case .xray: "eye"
        case .hiddenEdges: "square.dashed"
        case .zebra: "line.3.horizontal"
        }
    }
}

/// Ziehpfeil in Weltkoordinaten: Fuß, Richtung (normiert), Farbe.
struct HandleGraphic {
    var base: SIMD3<Float>
    var direction: SIMD3<Float>
    var color: SIMD3<Float>
    /// Größe relativ zu handleLength
    var scale: Float = 1
}

/// Halbtransparente quadratische Ebenenscheibe (Skizzenebene bzw. Ebenenwahl).
struct PlaneGraphic {
    var center: SIMD3<Float>
    var u: SIMD3<Float>
    var v: SIMD3<Float>
    var halfSize: Float
    var color: SIMD3<Float>
}

/// Linienzüge in Weltkoordinaten, mit fester Bildschirmbreite gezeichnet.
struct LineGroup {
    var polylines: [[SIMD3<Float>]]
    var color: SIMD3<Float>
    /// Breite in Bildschirmpunkten
    var width: Float
    /// Punkte (z. B. Knoten beim Schweben) mit Radius in Bildschirmpunkten
    var dots: [SIMD3<Float>] = []
    var dotRadius: Float = 0
    /// true = immer sichtbar, false = von Körpern verdeckt
    var onTop = true
}

/// Bild (Canvas) als Rechteck: Ecken links unten, rechts unten, rechts oben, links oben.
struct CanvasGraphic {
    var texture: MTLTexture
    var corners: [SIMD3<Float>]
    var opacity: Float
}

/// Halbtransparente Füllung (Skizzenbereiche), Dreiecke in Weltkoordinaten.
struct FillGroup {
    var triangles: [SIMD3<Float>]
    var color: SIMD4<Float>
    /// true = vor Körpern sichtbar (Griffe), false = von Körpern verdeckt
    var onTop = false
}

/// Hintergrund wie bei Shapr3D: neutrales helles Grau (linear, ergibt etwa sRGB 237). Gilt mit „Helles Design“.
let viewportBackground = MTLClearColor(red: 0.845, green: 0.845, blue: 0.845, alpha: 1)

/// Hintergrund Anthrazit wie SolidCraft (#2E3440, oben = unten, kein Verlauf).
let viewportBackgroundDark = MTLClearColor(red: Double(SketchTheme.Metal.background.x),
                                           green: Double(SketchTheme.Metal.background.y),
                                           blue: Double(SketchTheme.Metal.background.z), alpha: 1)

/// Hintergrund nach dem gewählten Design (AppTheme).
var currentViewportBackground: MTLClearColor {
    AppTheme.isDark ? viewportBackgroundDark : viewportBackground
}

/// Muss zum `GridStyle`-Struct in Shaders.metal passen.
private struct GridStyle {
    var color: SIMD4<Float>
    /// xyz = Mitte der Ansicht auf der Rasterebene (Welt)
    var center: SIMD4<Float>
    /// x = Abstand, ab dem das Raster dimmt, y = Abstand, ab dem es verschwunden ist
    var range: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    /// Länge eines Ziehpfeils in Bildschirmpunkten.
    static let handleLength: Float = 64

    var camera = OrbitCamera()
    /// Lage des Rasters (Skizzenebene); nil blendet es aus.
    var gridTransform: float4x4? = matrix_identity_float4x4
    /// Fangraster der Skizze in mm (0 = keins): das angezeigte Raster folgt ihm bzw. einem Vielfachen davon
    var gridBase: Float = 0
    /// Raster „Automatisch“ (SolidCraft): Weite 1-2-5 nach der Sichthöhe statt nach gridBase (GridDisplay.swift)
    var gridAuto = false
    /// Skizze: Raster minimal zur Kamera gezogen, damit es auf einer Körperfläche in der Skizzenebene sichtbar
    /// bleibt (sonst deckte die gleich tiefe Fläche das Raster zu)
    var gridOverFaces = false
    /// Skizze mit sichtbaren Achsen: die Rasterlinien durch den Weltursprung weglassen, sonst lägen sie gleich tief
    /// unter der Achse und der Tiefentest ließe die Achse stückweise verschwinden (wirkte gestrichelt, Kai)
    var gridSkipsOriginLines = false
    var displayMode: DisplayMode = .shaded
    var handles: [HandleGraphic] = []
    var planes: [PlaneGraphic] = []
    var lineGroups: [LineGroup] = []
    var fills: [FillGroup] = []
    var canvases: [CanvasGraphic] = []
    /// Schnittansicht (siehe Uniforms.clipPlane)
    var clipPlane: SIMD4<Float> = .zero
    /// Wird vor jedem Bild aufgerufen; der Viewport gleicht dort seinen Zustand ab (höchstens einmal je Bild).
    var willDraw: (() -> Void)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb
    private let depthFormat: MTLPixelFormat = .depth32Float
    private let sampleCount = 4
    private let solidPipeline: MTLRenderPipelineState
    private let xrayPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let colorOverlayPipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let fillPipeline: MTLRenderPipelineState
    private let texturePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let readOnlyDepthState: MTLDepthStencilState
    private let alwaysDepthState: MTLDepthStencilState
    /// Verdeckte Kanten (Tiefe „größer“) und Zebra; optional, damit ein Fehler hier den Viewport nicht verhindert
    private let hiddenEdgePipeline: MTLRenderPipelineState?
    private let zebraPipeline: MTLRenderPipelineState?
    /// Glas und klare Kunststoffe: zweiter, durchsichtiger Durchgang über den Körpern (SurfaceFinish.swift)
    private let glassPipeline: MTLRenderPipelineState?
    private let behindDepthState: MTLDepthStencilState?
    /// Raster mit weichem Rand (fragment_grid); ohne sie das bisherige Raster mit hartem Rand
    private let gridPipeline: MTLRenderPipelineState?
    private let gridOverlayPipeline: MTLRenderPipelineState?
    /// Für das Neuzeichnen, wenn „Helles Design“ umgeschaltet wird
    private weak var view: MTKView?
    private var drawnDark = AppTheme.isDark
    private var themeObserver: NSObjectProtocol?

    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var selectionBuffer: MTLBuffer?
    private var selectionCount = 0
    private var edgeBuffer: MTLBuffer?
    private var edgeCount = 0
    /// Körperkanten als zusammenhängende Linienzüge (für die breite Darstellung)
    private var edgePolylines: [[SIMD3<Float>]] = []
    /// Gewählte Kanten (Punktpaare)
    private var edgeHighlight: [SIMD3<Float>] = []
    private var hasFramedOnce = false
    /// Mindestens ein durchsichtiger Körper im Netz (dann zeichnet der Glas-Durchgang)
    private var hasGlass = false

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = currentViewportBackground

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
              let overlayPipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_flat_clip"),
              let linePipeline = pipeline(vertex: "vertex_main", fragment: "fragment_flat"),
              let colorPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_color"),
              let colorOverlayPipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_color"),
              let edgePipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_color_clip"),
              let fillPipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_flat", blended: true),
              let texturePipeline = pipeline(vertex: "vertex_main", fragment: "fragment_texture", blended: true),
              let depthState = depth(.lessEqual, write: true),
              let readOnlyDepthState = depth(.lessEqual, write: false),
              let alwaysDepthState = depth(.always, write: false) else { return nil }

        self.device = device
        self.queue = queue
        self.solidPipeline = solidPipeline
        self.xrayPipeline = xrayPipeline
        self.overlayPipeline = overlayPipeline
        self.linePipeline = linePipeline
        self.colorPipeline = colorPipeline
        self.colorOverlayPipeline = colorOverlayPipeline
        self.edgePipeline = edgePipeline
        self.fillPipeline = fillPipeline
        self.texturePipeline = texturePipeline
        self.depthState = depthState
        self.readOnlyDepthState = readOnlyDepthState
        self.alwaysDepthState = alwaysDepthState
        hiddenEdgePipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_dashed_clip", blended: true)
        zebraPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_zebra")
        glassPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_glass", blended: true)
        behindDepthState = depth(.greater, write: false)
        gridPipeline = pipeline(vertex: "vertex_main", fragment: "fragment_grid", blended: true)
        gridOverlayPipeline = pipeline(vertex: "vertex_overlay", fragment: "fragment_grid", blended: true)
        self.view = view
        super.init()
        // „Helles Design“ umgeschaltet: Hintergrund und Farben neu zeichnen
        themeObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.drawnDark != AppTheme.isDark else { return }
            self.view?.setNeedsDisplay()
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    // MARK: Daten

    func update(mesh: Mesh) {
        vertexBuffer = makeBuffer(mesh.vertices)
        indexBuffer = makeBuffer(mesh.indices)
        indexCount = mesh.indices.count
        hasGlass = Renderer.containsTransparent(mesh.vertices)
        let edges = mesh.edges.map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }
        edgeBuffer = makeBuffer(edges)
        edgeCount = edges.count
        var polylines: [[SIMD3<Float>]] = []
        for i in stride(from: 0, to: mesh.edges.count - 1, by: 2) {
            let a = mesh.edges[i], b = mesh.edges[i + 1]
            if let last = polylines.last?.last, last == a {
                polylines[polylines.count - 1].append(b)
            } else {
                polylines.append([a, b])
            }
        }
        edgePolylines = polylines
        selectionBuffer = nil
        selectionCount = 0

        // Nur beim Öffnen des Projekts einpassen. War es leer, wurde früher beim ersten Extrudieren
        // auf den neuen Körper gezoomt – das stört; die Ansicht bleibt jetzt, wie sie ist.
        if !hasFramedOnce {
            if let bounds = mesh.bounds {
                camera.frame(min: bounds.min, max: bounds.max)
            }
            hasFramedOnce = true
        }
    }

    func updateSelection(indices: [UInt32], edges: [SIMD3<Float>]) {
        selectionBuffer = makeBuffer(indices)
        selectionCount = indices.count
        edgeHighlight = edges
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count) }
        }
    }

    /// Raster um den sichtbaren Ausschnitt (lokal in der Rasterebene): Weite passend zum Zoom,
    /// jede fünfte Linie kräftiger. Liefert feine und kräftige Linien als Punktpaare.
    private func gridLines(transform: float4x4, viewWidth: Float,
                           viewHeight: Float) -> (minor: [Vertex], major: [Vertex], center: SIMD2<Float>, half: Float) {
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let u = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let v = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let perPoint = camera.worldUnitsPerPoint(viewHeight: viewHeight)
        let (step, majorEvery) = displayGrid(perPoint: perPoint, viewHeight: viewHeight)
        // Mitte: Ziel der Kamera, auf die Ebene projiziert
        let d = camera.target - origin
        let center = SIMD2<Float>(simd_dot(d, u), simd_dot(d, v))
        let reach = max(viewWidth, viewHeight) * perPoint * (camera.isOrthographic ? 0.8 : 3)
        let half = min(reach, step * 160)
        let lo = ((center - half) / step).rounded(.down), hi = ((center + half) / step).rounded(.up)
        let up = SIMD3<Float>(0, 0, 1)
        // Weltursprung in Rasterkoordinaten: Linien dort zeichnen die Achsen (gridSkipsOriginLines)
        let originLocal = SIMD2<Float>(simd_dot(-origin, u), simd_dot(-origin, v))
        let skipTolerance = step * 0.01
        var minor: [Vertex] = [], major: [Vertex] = []
        for i in stride(from: lo.x, through: hi.x, by: 1) {
            if gridSkipsOriginLines, abs(i * step - originLocal.x) < skipTolerance { continue }
            let line = [Vertex(position: SIMD3(i * step, lo.y * step, 0), normal: up),
                        Vertex(position: SIMD3(i * step, hi.y * step, 0), normal: up)]
            if Int(i) % majorEvery == 0 { major += line } else { minor += line }
        }
        for j in stride(from: lo.y, through: hi.y, by: 1) {
            if gridSkipsOriginLines, abs(j * step - originLocal.y) < skipTolerance { continue }
            let line = [Vertex(position: SIMD3(lo.x * step, j * step, 0), normal: up),
                        Vertex(position: SIMD3(hi.x * step, j * step, 0), normal: up)]
            if Int(j) % majorEvery == 0 { major += line } else { minor += line }
        }
        return (minor, major, center, half)
    }

    /// Ausblenden des Rasters wie SolidCraft (GridFade): voll nahe der Mitte, ab 0,6 × Sichtweite dimmend,
    /// bei 2,2 × verschwunden, immer vor dem eigenen Rand. Liefert Mitte (Welt) und Abstände.
    private func gridFade(transform: float4x4, center: SIMD2<Float>, half: Float,
                          viewHeight: Float) -> (center: SIMD3<Float>, start: Float, end: Float) {
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let u = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let v = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let world: SIMD3<Float> = origin + u * center.x + v * center.y
        let normalRaw = simd_cross(u, v)
        let normalLength = simd_length(normalRaw)
        let normal: SIMD3<Float> = normalLength > 1e-9 ? normalRaw / normalLength : SIMD3<Float>(0, 0, 1)
        let slant: Float = max(abs(simd_dot(camera.forward, normal)), 0.25)
        let halfHeight: Float = camera.worldUnitsPerPoint(viewHeight: viewHeight) * viewHeight / 2
        let reach: Float = halfHeight / slant
        let end: Float = min(2.2 * reach, half)
        let start: Float = 0.6 * min(reach, end)
        return (world, start, end)
    }

    /// Breite Linien als Dreiecke in der Bildschirmebene, Ecken gerundet.
    private func lineTriangles(_ group: LineGroup, viewHeight: Float) -> [Vertex] {
        let forward = camera.forward
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 0, 1)))
        let up = simd_cross(right, forward)
        let color = group.color
        let normal = -forward
        var out: [Vertex] = []
        func scale(_ p: SIMD3<Float>) -> Float {
            camera.worldUnitsPerPoint(at: p, viewHeight: viewHeight)
        }
        func disc(_ p: SIMD3<Float>, radius: Float, segments: Int) {
            for k in 0..<segments {
                let a0 = Float(k) / Float(segments) * 2 * .pi, a1 = Float(k + 1) / Float(segments) * 2 * .pi
                out += [Vertex(position: p, normal: normal, color: color),
                        Vertex(position: p + (cos(a0) * right + sin(a0) * up) * radius, normal: normal, color: color),
                        Vertex(position: p + (cos(a1) * right + sin(a1) * up) * radius, normal: normal, color: color)]
            }
        }
        let eye = camera.position
        let minimumDepth = camera.distance * 0.02
        func inFront(_ p: SIMD3<Float>) -> Bool {
            camera.isOrthographic || simd_dot(p - eye, forward) >= minimumDepth
        }
        for line in group.polylines where line.count >= 2 {
            var previous: SIMD3<Float>?
            for i in 0..<(line.count - 1) {
                var a = line[i], b = line[i + 1]
                // Am Betrachter abschneiden: Lange Linien (Achsen) würden sonst durch die Kamera laufen
                if !camera.isOrthographic {
                    let da = simd_dot(a - eye, forward), db = simd_dot(b - eye, forward)
                    if da < minimumDepth, db < minimumDepth {
                        previous = nil
                        continue
                    }
                    if da < minimumDepth {
                        a += (b - a) * ((minimumDepth - da) / (db - da))
                    } else if db < minimumDepth {
                        b += (a - b) * ((minimumDepth - db) / (da - db))
                    }
                }
                let d = b - a
                let length = simd_length(d)
                guard length > 1e-9 else { continue }
                // Quer zur Linie und zum Sehstrahl: auf dem Bildschirm genau senkrecht zur Linie.
                // Breite je Ende nach dessen Tiefe, so bleibt die Linie auf ganzer Länge gleich breit.
                let across = simd_cross(d, camera.isOrthographic ? forward : a - eye)
                let acrossLength = simd_length(across)
                guard acrossLength > 1e-12 else { continue }
                let side = across / acrossLength
                let halfA = group.width / 2 * scale(a), halfB = group.width / 2 * scale(b)
                out += [Vertex(position: a - side * halfA, normal: normal, color: color),
                        Vertex(position: b - side * halfB, normal: normal, color: color),
                        Vertex(position: b + side * halfB, normal: normal, color: color),
                        Vertex(position: a - side * halfA, normal: normal, color: color),
                        Vertex(position: b + side * halfB, normal: normal, color: color),
                        Vertex(position: a + side * halfA, normal: normal, color: color)]
                // Rund an Enden und deutlichen Knicken, damit keine Lücken entstehen
                let direction = d / length
                if previous == nil || simd_dot(previous!, direction) < 0.94 {
                    disc(a, radius: halfA, segments: 8)
                }
                previous = direction
            }
            if let last = line.last, inFront(last) {
                disc(last, radius: group.width / 2 * scale(last), segments: 8)
            }
        }
        for dot in group.dots {
            disc(dot, radius: group.dotRadius * scale(dot), segments: 12)
        }
        return out
    }

    /// Pfeil wie in Fusion 360: schlanker Schaft, kräftige Kegelspitze (etwas dunkler), length in Weltmaß.
    static func arrowVertices(_ handle: HandleGraphic, length: Float) -> [Vertex] {
        let d = simd_normalize(handle.direction)
        let reference: SIMD3<Float> = abs(d.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(reference, d)), v = simd_cross(d, u)
        let shaftRadius = length * 0.035, headRadius = length * 0.13, headLength = length * 0.32
        let base = handle.base
        let shaftEnd = base + d * (length - headLength), tip = base + d * length
        let color = handle.color
        let headColor = handle.color * 0.82
        let segments = 20
        var out: [Vertex] = []
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let r0 = cos(a0) * u + sin(a0) * v, r1 = cos(a1) * u + sin(a1) * v
            // Schaft mit Boden
            let p0 = base + r0 * shaftRadius, p1 = base + r1 * shaftRadius
            let q0 = shaftEnd + r0 * shaftRadius, q1 = shaftEnd + r1 * shaftRadius
            out += [Vertex(position: p0, normal: r0, color: color), Vertex(position: p1, normal: r1, color: color),
                    Vertex(position: q1, normal: r1, color: color), Vertex(position: p0, normal: r0, color: color),
                    Vertex(position: q1, normal: r1, color: color), Vertex(position: q0, normal: r0, color: color)]
            out += [Vertex(position: base, normal: -d, color: color), Vertex(position: p1, normal: -d, color: color),
                    Vertex(position: p0, normal: -d, color: color)]
            // Boden der Spitze
            out += [Vertex(position: shaftEnd, normal: -d, color: headColor),
                    Vertex(position: shaftEnd + r1 * headRadius, normal: -d, color: headColor),
                    Vertex(position: shaftEnd + r0 * headRadius, normal: -d, color: headColor)]
            // Mantel der Spitze
            let n0 = simd_normalize(r0 * headLength + d * headRadius)
            let n1 = simd_normalize(r1 * headLength + d * headRadius)
            out += [Vertex(position: shaftEnd + r0 * headRadius, normal: n0, color: headColor),
                    Vertex(position: shaftEnd + r1 * headRadius, normal: n1, color: headColor),
                    Vertex(position: tip, normal: simd_normalize(n0 + n1), color: headColor)]
        }
        return out
    }

    // MARK: Zeichnen

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        willDraw?()
        drawnDark = AppTheme.isDark
        view.clearColor = currentViewportBackground
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
        pass.colorAttachments[0].clearColor = currentViewportBackground
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
        // Kernel-Dreiecke sind von außen gesehen gegen den Uhrzeigersinn
        encoder.setFrontFacing(.counterClockwise)

        // Licht kommt leicht versetzt aus Blickrichtung, damit Flächen Kontrast haben.
        let toEye = simd_normalize(camera.position - camera.target)
        var uniforms = Uniforms(
            viewProjection: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
            model: matrix_identity_float4x4,
            lightDirection: simd_normalize(toEye + SIMD3(0.3, 0.2, 0.6)),
            baseColor: SIMD3(0.55, 0.62, 0.72),
            clipPlane: clipPlane,
            eye: SIMD4<Float>(camera.position, 0.0015)
        )

        func setUniforms(_ u: inout Uniforms) {
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        }
        func setColor(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
            var color = SIMD4<Float>(r, g, b, a)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        }
        // Kanten wie bei Shapr3D als feine dunkle Linien mit fester Bildschirmbreite. Direkt auf dem Hintergrund
        // (Drahtgitter, Röntgen) im dunklen Design hell, sonst wären sie auf Anthrazit unsichtbar.
        let dark = AppTheme.isDark
        let edgeOnBody = SIMD3<Float>(0.07, 0.075, 0.09)
        let edgeOnBackground: SIMD3<Float> = dark ? SketchTheme.Metal.edgeOnBackground : edgeOnBody
        func drawEdges(depth: MTLDepthStencilState, onBackground: Bool = false) {
            let edgeColor: SIMD3<Float> = onBackground ? edgeOnBackground : edgeOnBody
            let group = LineGroup(polylines: edgePolylines, color: edgeColor, width: 1.1, onTop: false)
            let triangles = lineTriangles(group, viewHeight: viewHeight)
            if let buffer = makeBuffer(triangles) {
                encoder.setRenderPipelineState(edgePipeline)
                encoder.setDepthStencilState(depth)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
            } else if let edgeBuffer, edgeCount > 0 {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setDepthStencilState(depth)
                encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                if onBackground && dark {
                    setColor(edgeColor.x, edgeColor.y, edgeColor.z)
                } else {
                    setColor(0.12, 0.13, 0.16)
                }
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeCount)
            }
        }

        // Raster zuerst, damit es hinter halbtransparenten Körpern liegt
        if let gridTransform {
            let grid = gridLines(transform: gridTransform, viewWidth: viewHeight * aspect, viewHeight: viewHeight)
            var gridUniforms = uniforms
            gridUniforms.model = gridTransform
            encoder.setDepthStencilState(depthState)
            setUniforms(&gridUniforms)
            // Farben: hell Grau 0,74/0,67 wie bisher, dunkel SolidCraft #3B414C/#494F5A
            let minorColor: SIMD3<Float> = dark ? SketchTheme.Metal.grid : SIMD3<Float>(repeating: 0.74)
            let majorColor: SIMD3<Float> = dark ? SketchTheme.Metal.gridMajor : SIMD3<Float>(repeating: 0.67)
            let gridSets: [([Vertex], SIMD3<Float>)] = [(grid.minor, minorColor), (grid.major, majorColor)]
            let fadePipeline: MTLRenderPipelineState? = gridOverFaces ? gridOverlayPipeline : gridPipeline
            if let fadePipeline {
                // Weicher Rand statt hartem Abbruch (SolidCraft GridFade)
                let fade = gridFade(transform: gridTransform, center: grid.center, half: grid.half, viewHeight: viewHeight)
                encoder.setRenderPipelineState(fadePipeline)
                for (lines, color) in gridSets {
                    guard let buffer = makeBuffer(lines) else { continue }
                    var style = GridStyle(color: SIMD4<Float>(color, 1),
                                          center: SIMD4<Float>(fade.center, 0),
                                          range: SIMD4<Float>(fade.start, fade.end, 0, 0))
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    encoder.setFragmentBytes(&style, length: MemoryLayout<GridStyle>.stride, index: 2)
                    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
                }
            } else {
                encoder.setRenderPipelineState(gridOverFaces ? fillPipeline : linePipeline)
                for (lines, color) in gridSets {
                    guard let buffer = makeBuffer(lines) else { continue }
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    setColor(color.x, color.y, color.z)
                    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
                }
            }
        }

        // Körper
        if let vertexBuffer, let indexBuffer, indexCount > 0 {
            switch displayMode {
            case .hiddenEdges, .zebra:
                if displayMode == .zebra, let zebraPipeline {
                    encoder.setRenderPipelineState(zebraPipeline)
                    var view = SIMD4<Float>(camera.forward, camera.isOrthographic ? 1 : 0)
                    encoder.setFragmentBytes(&view, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                } else {
                    encoder.setRenderPipelineState(solidPipeline)
                }
                encoder.setDepthStencilState(depthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
                // Verdeckte Kanten zuerst (ohne Tiefe zu schreiben), die sichtbaren darüber
                if displayMode == .hiddenEdges, let hiddenEdgePipeline, let behindDepthState {
                    let dashed = hiddenEdgeTriangles(edgePolylines, color: SIMD3(0.30, 0.33, 0.40), width: 1,
                                                     viewHeight: viewHeight)
                    if let buffer = makeBuffer(dashed) {
                        encoder.setRenderPipelineState(hiddenEdgePipeline)
                        encoder.setDepthStencilState(behindDepthState)
                        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                        setUniforms(&uniforms)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: dashed.count)
                    }
                }
                drawEdges(depth: depthState)
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
                drawEdges(depth: alwaysDepthState, onBackground: true)
            case .xray:
                drawEdges(depth: alwaysDepthState, onBackground: true)
                encoder.setRenderPipelineState(xrayPipeline)
                encoder.setDepthStencilState(readOnlyDepthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
            }

            // Glas und klare Kunststoffe durchsichtig darüber (fragment_main lässt sie aus), ohne Tiefe zu schreiben
            let solidDrawn: Bool = displayMode.isSolid && (displayMode != .zebra || zebraPipeline == nil)
            if hasGlass, solidDrawn, let glassPipeline {
                encoder.setRenderPipelineState(glassPipeline)
                encoder.setDepthStencilState(readOnlyDepthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                              indexBuffer: indexBuffer, indexBufferOffset: 0)
            }

            // Ausgewählte Flächen bzw. Körper
            if let selectionBuffer, selectionCount > 0 {
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setDepthStencilState(displayMode.isSolid ? depthState : alwaysDepthState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                setColor(0.98, 0.62, 0.18, 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: selectionCount, indexType: .uint32,
                                              indexBuffer: selectionBuffer, indexBufferOffset: 0)
            }
        }

        // Bilder: halbtransparent, von Körpern davor verdeckt (uv steckt in der Normale)
        for canvas in canvases where canvas.corners.count == 4 {
            let uv: [SIMD3<Float>] = [[0, 1, 0], [1, 1, 0], [1, 0, 0], [0, 0, 0]]
            let quad = [0, 1, 2, 0, 2, 3].map { Vertex(position: canvas.corners[$0], normal: uv[$0]) }
            guard let buffer = makeBuffer(quad) else { continue }
            var noClip = uniforms
            noClip.clipPlane = .zero
            encoder.setRenderPipelineState(texturePipeline)
            encoder.setDepthStencilState(readOnlyDepthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            setUniforms(&noClip)
            setColor(1, 1, 1, canvas.opacity)
            encoder.setFragmentTexture(canvas.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quad.count)
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

        // Gewählte Kanten: breiter und orange über den normalen Kanten
        if edgeHighlight.count >= 2 {
            let pairs = stride(from: 0, to: edgeHighlight.count - 1, by: 2).map { [edgeHighlight[$0], edgeHighlight[$0 + 1]] }
            let group = LineGroup(polylines: pairs, color: SIMD3(0.98, 0.55, 0.08), width: 3)
            let triangles = lineTriangles(group, viewHeight: viewHeight)
            if let buffer = makeBuffer(triangles) {
                encoder.setRenderPipelineState(colorPipeline)
                encoder.setDepthStencilState(alwaysDepthState)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                setUniforms(&uniforms)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
            }
        }

        // Skizzenbereiche: halbtransparent, auf Flächen nicht flimmernd
        for fill in fills {
            guard let buffer = makeBuffer(fill.triangles.map { Vertex(position: $0, normal: SIMD3(0, 0, 1)) }) else { continue }
            encoder.setRenderPipelineState(fillPipeline)
            encoder.setDepthStencilState(fill.onTop ? alwaysDepthState : readOnlyDepthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            setColor(fill.color.x, fill.color.y, fill.color.z, fill.color.w)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fill.triangles.count)
        }

        // Skizzenlinien, Fangsymbole und Knoten mit fester Breite in Bildschirmpunkten
        for group in lineGroups {
            let triangles = lineTriangles(group, viewHeight: viewHeight)
            guard let buffer = makeBuffer(triangles) else { continue }
            encoder.setRenderPipelineState(group.onTop ? colorPipeline : colorOverlayPipeline)
            encoder.setDepthStencilState(group.onTop ? alwaysDepthState : readOnlyDepthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            setUniforms(&uniforms)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
        }

        // Ziehpfeile obenauf, Größe bleibt auf dem Bildschirm gleich
        var arrows: [Vertex] = []
        for handle in handles {
            let length = Renderer.handleLength * handle.scale * camera.worldUnitsPerPoint(at: handle.base, viewHeight: viewHeight)
            arrows += Renderer.arrowVertices(handle, length: length)
        }
        if let arrowBuffer = makeBuffer(arrows) {
            // Nicht von der Schnittebene abschneiden (der Pfeil der Schnittansicht zeigt in die ausgeblendete Hälfte)
            var noClip = uniforms
            noClip.clipPlane = .zero
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setDepthStencilState(alwaysDepthState)
            encoder.setVertexBuffer(arrowBuffer, offset: 0, index: 0)
            setUniforms(&noClip)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: arrows.count)
        }
    }
}
