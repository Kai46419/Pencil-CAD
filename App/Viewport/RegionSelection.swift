import UIKit
import simd

// Rahmen- und Lassoauswahl (Vorbild Fusion 360 und Shapr3D): Im Modell wählt ein Rahmen bzw. ein Lasso Körper,
// in der Skizze (Werkzeug „Auswählen“, Stift ins Leere ziehen) Skizzenelemente.

/// Lasso statt Rechteck: frei gezogene Kurve, alles ganz Umschlossene wird gewählt. Gilt für Skizze und Modell,
/// wird für die nächste Sitzung gemerkt (lange drücken auf „Auswählen“ bzw. „Rahmenauswahl“).
enum LassoSelection {
    static let key = "selectionLasso"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum RegionSelection {
    /// Liegt p im Polygon (Bildschirmpunkte)? Gerade-Ungerade-Regel, das Lasso gilt als geschlossen.
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Hüllrechteck eines Linienzugs.
    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var lo = first, hi = first
        for p in points {
            lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y))
            hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y))
        }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    /// Schneidet die Strecke a–b das Rechteck?
    static func segment(_ a: CGPoint, _ b: CGPoint, intersects rect: CGRect) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for k in 0..<4 where segmentsCross(a, b, corners[k], corners[(k + 1) % 4]) { return true }
        return false
    }

    private static func segmentsCross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint, _ s: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(r, s, p), d2 = cross(r, s, q), d3 = cross(p, q, r), d4 = cross(p, q, s)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    // MARK: Skizze

    /// Wie ein Gebiet gewählt wird: Rahmen nach rechts (ganz umschlossen), Rahmen nach links (auch angeschnitten)
    /// oder Lasso (ganz umschlossen).
    enum Area {
        case window(CGRect)
        case crossing(CGRect)
        case lasso([CGPoint])
    }

    /// Skizzenelemente im Gebiet, als Auswahl (alle Kanten eines Elements bzw. sein Punkt).
    @MainActor
    static func sketchRefs(in area: Area, sketch: SketchController, camera: OrbitCamera, viewSize: CGSize) -> [SketchRef] {
        let plane = sketch.plane
        var refs: [SketchRef] = []
        for (index, entity) in sketch.entities.enumerated() {
            let lines = entity.drawing.map { line in
                line.compactMap { camera.project(SIMD3<Float>(plane.world($0)), viewSize: viewSize) }
            }
            let points = lines.flatMap { $0 }
            guard !points.isEmpty else { continue }
            let chosen: Bool
            switch area {
            case .window(let rect):
                chosen = points.allSatisfy { rect.contains($0) }
            case .crossing(let rect):
                chosen = lines.contains { line in
                    line.count == 1 ? rect.contains(line[0])
                        : zip(line, line.dropFirst()).contains { segment($0, $1, intersects: rect) }
                }
            case .lasso(let polygon):
                chosen = points.allSatisfy { contains(polygon, $0) }
            }
            guard chosen else { continue }
            if case .point = entity {
                refs.append(.point(SketchPointRef(entity: index, index: 0)))
            } else if case .text = entity {
                // Text als Ganzes (SketchTextEdit.swift)
                refs.append(.curve(SketchCurveRef(entity: index, index: 0)))
            } else {
                refs += (0..<entity.curveCount).map { SketchRef.curve(SketchCurveRef(entity: index, index: $0)) }
            }
        }
        return refs
    }

    // MARK: Modell

    /// Körper, deren Netz ganz im Lasso liegt.
    static func bodies(inLasso polygon: [CGPoint], mesh: Mesh, camera: OrbitCamera, viewSize: CGSize) -> [Int] {
        var vertexBody = [Int](repeating: -1, count: mesh.vertices.count)
        for t in 0..<min(mesh.triangleCount, mesh.triangleFaces.count) {
            let body = mesh.triangleFaces[t].body
            for k in 0..<3 {
                let index = Int(mesh.indices[t * 3 + k])
                if index < vertexBody.count { vertexBody[index] = body }
            }
        }
        let frame = bounds(polygon)
        var allInside: [Int: Bool] = [:]
        for (index, vertex) in mesh.vertices.enumerated() {
            let body = vertexBody[index]
            guard body >= 0, allInside[body] != false else { continue }
            let isInside = camera.project(vertex.position, viewSize: viewSize)
                .map { frame.contains($0) && contains(polygon, $0) } ?? false
            allInside[body] = isInside
        }
        return allInside.filter { $0.value }.map { $0.key }.sorted()
    }
}

/// Gezogenes Lasso: gestrichelte, leicht gefüllte Kurve (zurück zum Anfang geschlossen).
final class SelectionLassoView: UIView {
    private let outline = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        isUserInteractionEnabled = false
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        outline.strokeColor = UIColor.systemBlue.cgColor
        outline.fillColor = UIColor.systemBlue.withAlphaComponent(0.1).cgColor
        layer.addSublayer(outline)
    }

    /// Lasso zeigen (Punkte in den Koordinaten der übergeordneten Ansicht).
    func show(_ points: [CGPoint], in container: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = container
        outline.frame = bounds
        let path = UIBezierPath()
        if let first = points.first {
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            path.close()
        }
        outline.path = path.cgPath
        CATransaction.commit()
        isHidden = false
    }
}
