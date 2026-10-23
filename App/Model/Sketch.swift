import Foundation
import simd

enum SketchTool: String, CaseIterable, Identifiable {
    case rectangle = "Rechteck"
    case circle = "Kreis"
    case polyline = "Linienzug"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .polyline: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

/// Ebene im Raum mit lokalem 2D-Koordinatensystem (u, v) für die Skizze.
struct SketchPlane {
    var origin: SIMD3<Double>
    var u: SIMD3<Double>
    var v: SIMD3<Double>
    var normal: SIMD3<Double>
    /// true, wenn die Ebene auf einer Körperfläche liegt (Normale zeigt aus dem Material).
    var isOnFace: Bool
    /// Körper, auf dessen Fläche skizziert wird (Ziel für „Vereinigen“).
    var sourceBody: Int?

    static let ground = SketchPlane(origin: .zero, u: [1, 0, 0], v: [0, 1, 0], normal: [0, 0, 1], isOnFace: false)

    /// Ebene durch point mit Normale normal. Der Ursprung liegt dem Weltursprung am nächsten,
    /// damit das Raster bei achsparallelen Flächen auf ganzen Millimetern bleibt.
    init(point: SIMD3<Double>, normal n: SIMD3<Double>, isOnFace: Bool, sourceBody: Int? = nil) {
        let normal = simd_normalize(n)
        let u: SIMD3<Double> = abs(normal.z) > 0.99
            ? [1, 0, 0]
            : simd_normalize(simd_cross(SIMD3<Double>(0, 0, 1), normal))
        self.init(origin: normal * simd_dot(point, normal), u: u, v: simd_cross(normal, u),
                  normal: normal, isOnFace: isOnFace)
        self.sourceBody = sourceBody
    }

    init(origin: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>, normal: SIMD3<Double>, isOnFace: Bool) {
        self.origin = origin
        self.u = u
        self.v = v
        self.normal = normal
        self.isOnFace = isOnFace
    }

    func world(_ p: SIMD2<Double>) -> SIMD3<Double> {
        origin + p.x * u + p.y * v
    }

    func local(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let d = p - origin
        return SIMD2(simd_dot(d, u), simd_dot(d, v))
    }
}

/// Geschlossenes Profil in der Skizzenebene, bereit zum Extrudieren.
enum SketchProfile {
    /// corner = Startecke, size = vorzeichenbehaftete Ausdehnung in u/v
    case rectangle(corner: SIMD2<Double>, size: SIMD2<Double>)
    case polygon([SIMD2<Double>])
    case circle(center: SIMD2<Double>, radius: Double)

    /// Extrudiert zwischen den Abständen from und to entlang der Ebenennormale.
    func solid(on plane: SketchPlane, from: Double, to: Double) -> PCKShape? {
        guard from != to else { return nil }
        switch self {
        case .rectangle, .polygon:
            let base = plane.normal * from
            let xyz = outline.flatMap { p -> [NSNumber] in
                let w = plane.world(p) + base
                return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
            }
            return PCKShape.prism(pointsXYZ: xyz, direction: plane.normal * (to - from))
        case .circle(let center, let radius):
            return PCKShape.cylinder(base: plane.world(center) + plane.normal * min(from, to), axis: plane.normal,
                                     radius: radius, height: abs(to - from))
        }
    }

    var outline: [SIMD2<Double>] {
        switch self {
        case .rectangle(let c, let s):
            return [c, c + SIMD2(s.x, 0), c + s, c + SIMD2(0, s.y)]
        case .polygon(let points):
            return points
        case .circle(let center, let radius):
            return (0..<72).map { i in
                let a = Double(i) / 72 * 2 * .pi
                return center + radius * SIMD2(cos(a), sin(a))
            }
        }
    }
}

/// Zustand der aktuellen Skizze. Bekommt Punkte im lokalen System der Skizzenebene vom Viewport.
@MainActor
final class SketchController: ObservableObject {
    @Published var isActive = false {
        didSet {
            if !isActive {
                reset()
                plane = .ground
            }
        }
    }
    @Published var tool: SketchTool = .rectangle {
        didSet { reset() }
    }
    /// Für Geräte ohne Apple Pencil (z. B. Simulator): ein Finger zeichnet statt zu drehen.
    @Published var fingerDraws = false
    @Published var plane: SketchPlane = .ground {
        didSet { reset() }
    }
    @Published var gridStep: Double = 1

    @Published private(set) var profile: SketchProfile?
    @Published private(set) var liveLabel: String?
    @Published private(set) var revision = 0

    private var dragStart: SIMD2<Double>?
    private var dragCurrent: SIMD2<Double>?
    private var polyline: [SIMD2<Double>] = []

    /// Höhe der Bodenebene; nur wenn nicht auf einer Fläche skizziert wird.
    var groundHeight: Double {
        get { plane.isOnFace ? 0 : plane.origin.z }
        set { plane = SketchPlane(origin: [0, 0, newValue], u: [1, 0, 0], v: [0, 1, 0], normal: [0, 0, 1], isOnFace: false) }
    }

    // MARK: Eingabe

    func began(at point: SIMD2<Double>, tolerance: Double) {
        guard profile == nil else { return }
        let p = snap(point)
        dragStart = p
        dragCurrent = p
        updateLabel()
        revision += 1
    }

    func moved(to point: SIMD2<Double>, tolerance: Double) {
        guard dragStart != nil else { return }
        dragCurrent = snapToFirstPoint(snap(point), tolerance: tolerance)
        updateLabel()
        revision += 1
    }

    func ended(at point: SIMD2<Double>, tolerance: Double) {
        guard let start = dragStart else { return }
        let end = snapToFirstPoint(snap(point), tolerance: tolerance)
        dragStart = nil
        dragCurrent = nil

        switch tool {
        case .rectangle:
            let size = end - start
            if size.x != 0, size.y != 0 {
                profile = .rectangle(corner: start, size: size)
            }
        case .circle:
            let radius = simd_distance(start, end)
            if radius > 0 {
                profile = .circle(center: start, radius: radius)
            }
        case .polyline:
            // Jeder Strich (oder Tipp) setzt den Endpunkt; ein Strich zurück zum Startpunkt schließt das Profil.
            if polyline.isEmpty {
                polyline.append(start)
            }
            if let first = polyline.first, polyline.count >= 3, end == first {
                profile = .polygon(polyline)
                polyline.removeAll()
            } else if end != polyline.last {
                polyline.append(end)
            }
        }
        updateLabel()
        revision += 1
    }

    func cancelStroke() {
        dragStart = nil
        dragCurrent = nil
        updateLabel()
        revision += 1
    }

    func reset() {
        dragStart = nil
        dragCurrent = nil
        polyline.removeAll()
        profile = nil
        liveLabel = nil
        revision += 1
    }

    /// Entfernt beim Linienzug den letzten Punkt.
    func undoPoint() {
        guard tool == .polyline, profile == nil, !polyline.isEmpty else { return }
        polyline.removeLast()
        if polyline.count == 1 { polyline.removeAll() }
        updateLabel()
        revision += 1
    }

    var hasOpenPolyline: Bool { !polyline.isEmpty }

    // MARK: Exakte Maße nach dem Zeichnen

    /// Breite/Tiefe des Rechtecks (Betrag). Die Startecke bleibt fest.
    var rectangleSize: SIMD2<Double>? {
        get {
            guard case .rectangle(_, let size) = profile else { return nil }
            return simd_abs(size)
        }
        set {
            guard let newValue, newValue.x > 0, newValue.y > 0,
                  case .rectangle(let corner, let size) = profile else { return }
            let sign = SIMD2(size.x < 0 ? -1.0 : 1.0, size.y < 0 ? -1.0 : 1.0)
            profile = .rectangle(corner: corner, size: newValue * sign)
            updateLabel()
            revision += 1
        }
    }

    var circleDiameter: Double? {
        get {
            guard case .circle(_, let radius) = profile else { return nil }
            return 2 * radius
        }
        set {
            guard let newValue, newValue > 0, case .circle(let center, _) = profile else { return }
            profile = .circle(center: center, radius: newValue / 2)
            updateLabel()
            revision += 1
        }
    }

    // MARK: Darstellung

    /// Liniensegmente (Punktpaare, lokal) für den Renderer.
    var segments: [SIMD2<Double>] {
        if let profile {
            return closedLoop(profile.outline)
        }
        var result: [SIMD2<Double>] = []
        if tool == .polyline {
            for (a, b) in zip(polyline, polyline.dropFirst()) {
                result += [a, b]
            }
        }
        guard let start = dragStart, let current = dragCurrent else { return result }
        switch tool {
        case .rectangle:
            result += closedLoop(SketchProfile.rectangle(corner: start, size: current - start).outline)
        case .circle:
            result += closedLoop(SketchProfile.circle(center: start, radius: simd_distance(start, current)).outline)
            result += [start, current]
        case .polyline:
            result += [polyline.last ?? start, current]
        }
        return result
    }

    private func closedLoop(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard points.count > 1 else { return [] }
        return points.indices.flatMap { [points[$0], points[($0 + 1) % points.count]] }
    }

    // MARK: Fang und Maße

    private func snap(_ p: SIMD2<Double>) -> SIMD2<Double> {
        (p / gridStep).rounded(.toNearestOrAwayFromZero) * gridStep
    }

    private func snapToFirstPoint(_ p: SIMD2<Double>, tolerance: Double) -> SIMD2<Double> {
        guard tool == .polyline, polyline.count >= 3, let first = polyline.first,
              simd_distance(p, first) <= tolerance else { return p }
        return first
    }

    private func updateLabel() {
        if let profile {
            switch profile {
            case .rectangle(_, let size):
                liveLabel = "\(format(abs(size.x))) × \(format(abs(size.y))) mm"
            case .polygon(let points):
                liveLabel = "Linienzug, \(points.count) Punkte"
            case .circle(_, let radius):
                liveLabel = "Ø \(format(2 * radius)) mm"
            }
            return
        }
        guard let start = dragStart, let current = dragCurrent else {
            liveLabel = polyline.isEmpty ? nil : "Linienzug, \(polyline.count) Punkte – zurück zum Start schließt"
            return
        }
        switch tool {
        case .rectangle:
            liveLabel = "\(format(abs(current.x - start.x))) × \(format(abs(current.y - start.y))) mm"
        case .circle:
            liveLabel = "Ø \(format(2 * simd_distance(start, current))) mm"
        case .polyline:
            liveLabel = "\(format(simd_distance(polyline.last ?? start, current))) mm"
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
