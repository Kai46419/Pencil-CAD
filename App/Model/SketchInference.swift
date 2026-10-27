import Foundation
import simd

// Fang („Rastfunktion“) nach SolidCraft (MIT OR Apache-2.0, crates/ui-egui/src/sketch_tools.rs `refine_snap`,
// inference.rs, sketch_dims.rs `snap_axis`/`on_curve_axis`, viewport.rs `sketch_point_at`): je Stiftposition genau
// ein Fangkandidat in fester Reihenfolge – vorhandener Punkt, Körperecke, Schnittpunkt, Linienmitte, Tangente und
// „durch das Zentrum“ (nur Linie), auf Kurve, waagerecht/senkrecht zum vorigen Punkt, parallel/senkrecht/
// Verlängerung (nur Linie), sonst Feinraster. Jeder Fang wird beim Absetzen zu einer Bedingung (SketchCommit.swift).
// PencilCAD ergänzt (wie der klassische Fang bis Build 149, Kai): Winkelschritte zu 15° absolut und zum vorigen
// Linienstück, Ausrichtung an gemerkten Punkten, Verlängerungen aller Linien und die Schnitte dieser Leitlinien –
// jeweils mit gestrichelter Hilfslinie. Punkt-, Schnitt- und Mittenfang haben Vorrang.

/// Eingabeart für die Fangradien (SolidCraft rechnet mit Mauspunkten; Stift ×1,5, Finger ×3).
enum SnapInput {
    case pencil, finger, hover
}

/// Fangradien in Skizzenmaß (mm) für die aktuelle Zoomstufe und Eingabeart (Spezifikation C.4).
struct SnapMetrics {
    /// Millimeter je Bildschirmpunkt
    var mmPerPoint: Double
    var input: SnapInput = .pencil
    /// Halbe sichtbare Höhe in mm (für das 1-2-5-Raster)
    var viewHalfHeight: Double = 0

    private var factor: Double { input == .finger ? 3 : 1.5 }
    /// Schnittpunkt, Mitte, Tangente, Zentrum, H/V, //, ⊥ (SolidCraft 7 pt)
    var refine: Double { 7 * factor * mmPerPoint }
    /// Auf Kurve, Verlängerung (0,8 · tol)
    var onCurve: Double { refine * 0.8 }
    /// „Nur Mitte“: 1,5 · tol
    var preferredMidpoint: Double { refine * 1.5 }
    /// Vorhandener Skizzenpunkt: 8 pt + 2 pt Bonus der aktiven Skizze
    var pointPick: Double { 10 * factor * mmPerPoint }
    /// Kurve unter dem Stift: 6 pt + 2 pt Bonus
    var curvePick: Double { 8 * factor * mmPerPoint }
    /// Geweckte Kreis- bzw. Bogenmitte (SolidCraft 16 pt)
    var wokenCenter: Double { (input == .finger ? 40 : 24) * mmPerPoint }
    /// Spline schließen (8 pt)
    var splineClose: Double { 8 * factor * mmPerPoint }
    /// Achsfang der Linie (2,5°, Finger 3°)
    var axisSnap: Double { (input == .finger ? 3.0 : 2.5) * .pi / 180 }
    /// Kürzer als das: Tippen statt Ziehen
    var tapSlop: Double { (input == .finger ? 10 : 6) * mmPerPoint }
    /// Winkelschritte (15°) der Linie: größte Abweichung in Bildschirmgrad (Stift 4°, Finger 6°)
    var angleSnap: Double { (input == .finger ? 6.0 : 4.0) * .pi / 180 }
    /// Gemerkte Fangpunkte in Stiftnähe für die Anzeige (50 pt)
    var trackRadius: Double { 50 * mmPerPoint }
    /// Ausrichtung an Skizzenpunkten bis zu diesem Abstand vom Stift (300 pt)
    var alignReach: Double { 300 * mmPerPoint }
    /// Linienzug fortsetzen: so nah am Zugende aufgesetzt, setzt der Stift dort an (1,6 · Punktfang)
    var chainReach: Double { pointPick * 1.6 }

    /// SolidCraft `grid_step`: raw = h/10, Stufe 1-2-5 · 10ⁿ, Hauptlinie jede 5.
    static func gridStep(halfHeight: Double) -> (minor: Double, major: Double) {
        let raw = max(halfHeight / 10, 1e-3)
        let power: Double = pow(10.0, floor(log10(raw)))
        let ratio = raw / power
        let minor: Double = ratio < 2 ? power : (ratio < 5 ? 2 * power : 5 * power)
        return (minor, 5 * minor)
    }

    /// Feinraster des Fangs: ein Zehntel der Rasterstufe.
    var fineGridStep: Double {
        let half = viewHalfHeight > 0 ? viewHalfHeight : mmPerPoint * 400
        return Self.gridStep(halfHeight: half).minor / 10
    }
}

/// Was ein Fang beim Absetzen bedeutet (SolidCraft-Punktargument bzw. Inferenz).
enum SnapTarget: Equatable {
    /// Vorhandener Skizzenpunkt (nil: Ursprung oder Punkt der laufenden Eingabe)
    case point(SketchPointRef?)
    /// Körperecke (projiziert)
    case modelVertex(Point2)
    /// Schnittpunkt zweier Kurven
    case crossing(SketchCurveRef, SketchCurveRef)
    /// Linienmitte
    case midpoint(SketchCurveRef)
    /// Punkt auf einer Kurve
    case onCurve(SketchCurveRef)
    /// Tangentenpunkt an Kreis/Bogen vom vorigen Punkt aus
    case tangent(SketchCurveRef)
    /// Linie durch das Zentrum eines Kreises/Bogens; rim = Ende auf dem Rand, atCenter = Ende im Zentrum
    case throughCenter(SketchCurveRef, rim: Bool, atCenter: Bool)
    case horizontal
    case vertical
    case parallel(SketchCurveRef)
    case perpendicular(SketchCurveRef)
    /// Auf der Verlängerung einer Linie
    case lineExtension(SketchCurveRef)
    /// Winkelschritt (15°) vom vorigen Punkt bzw. zum vorigen Linienstück – ohne Bedingung
    case angle
    /// Waagerecht bzw. senkrecht auf Höhe eines gemerkten Punkts – ohne Bedingung
    case aligned
    case grid

    /// Fang mit Punktargument: großer Ring (6 pt) statt kleinem (3 pt).
    var isPointArgument: Bool {
        switch self {
        case .point, .modelVertex, .crossing, .midpoint, .onCurve, .throughCenter: true
        default: false
        }
    }

    /// Punktfänge klicken immer (Haptik); Leitlinien und Kurven nur mit „Haptik beim Zeichnen“.
    var isPointSnap: Bool {
        switch self {
        case .point, .modelVertex, .crossing, .midpoint, .throughCenter: true
        default: false
        }
    }

    /// Fang auf einer Leitlinie (Richtung bzw. Ausrichtung): der Achsfang beim Setzen ändert ihn nicht mehr.
    var isGuide: Bool {
        switch self {
        case .horizontal, .vertical, .parallel, .perpendicular, .lineExtension, .angle, .aligned: true
        default: false
        }
    }
}

/// Zusätzliche Fangquellen der Klickfolge (PencilCAD): Winkelschritte, voriges Linienstück, gemerkte Punkte.
struct SnapTracking {
    /// Winkelschritte (15°) vom vorigen Punkt: Linie und erste Kante des 3-Punkt-Rechtecks
    var angleSteps = false
    /// Vorige Linie am vorigen Punkt: Richtung, in der sie dort weiterliefe, und ihre Kurve
    var previous: (direction: Point2, ref: SketchCurveRef)?
    /// Punkte für die Ausrichtung waagerecht/senkrecht (gemerkte Fangpunkte, Punkte der laufenden Eingabe)
    var points: [Point2] = []
    /// Spurpunkte (Objektfangspur): Start des laufenden Linienzugs und per Schweben, Drücken bzw. Doppeltippen
    /// gemerkte Punkte – dort zusätzlich Spuren senkrecht zu jeder anliegenden schrägen Linie (trackLeads)
    var traces: [Point2] = []
}

/// Leitlinie eines Fangs: Strahl ab origin in Richtung dir (Einheitsvektor, zum Stift hin), gültig ab minAlong,
/// Fangabstand quer dazu reach. weight bevorzugt bei ähnlichem Abstand (kleiner = wichtiger).
struct SnapLead {
    enum Rounding {
        /// Ohne Rundung
        case keep
        /// Die freie Koordinate einer waagerechten bzw. senkrechten Leitlinie ins Feinraster
        case coordinate
        /// Die Länge entlang des Strahls ins Feinraster (nie x und y einzeln – sonst würde aus 45° z. B. 42°)
        case length
    }

    var origin: Point2
    var dir: Point2
    var minAlong: Double
    var reach: Double
    var weight: Double
    var target: SnapTarget
    var label: String
    var rounding: Rounding
    /// Gestrichelte Linie über den Stift hinaus (Strahl vom vorigen Punkt)
    var overshoot: Double = 0

    var isHorizontal: Bool { abs(dir.y) < 1e-12 }
    var isVertical: Bool { abs(dir.x) < 1e-12 }

    func along(_ p: Point2) -> Double { simd_dot(p - origin, dir) }

    /// Fußpunkt auf der Leitlinie, waagerecht/senkrecht genau auf der Koordinate des Ursprungs
    func foot(_ p: Point2) -> Point2 { exact(origin + dir * along(p)) }

    func exact(_ p: Point2) -> Point2 {
        if isHorizontal { return Point2(p.x, origin.y) }
        if isVertical { return Point2(origin.x, p.y) }
        return p
    }

    /// Fußpunkt mit der Rundung der Leitlinie.
    func snapped(_ p: Point2, step: Double) -> Point2 {
        let t = along(p)
        let at = foot(p)
        guard step > 0 else { return at }
        switch rounding {
        case .keep:
            return at
        case .coordinate:
            if isHorizontal { return Point2((at.x / step).rounded() * step, origin.y) }
            if isVertical { return Point2(origin.x, (at.y / step).rounded() * step) }
            return at
        case .length:
            let rounded = (t / step).rounded() * step
            return rounded >= minAlong ? exact(origin + dir * rounded) : at
        }
    }

    /// Schnitt mit einer anderen Leitlinie (nicht nahezu parallel), auf beiden im gültigen Bereich.
    func crossing(_ other: SnapLead) -> Point2? {
        let denominator = dir.x * other.dir.y - dir.y * other.dir.x
        guard abs(denominator) > 0.05 else { return nil }
        let w = other.origin - origin
        let t = (w.x * other.dir.y - w.y * other.dir.x) / denominator
        var x = exact(origin + dir * t)
        x = other.exact(x)
        guard t >= minAlong, other.along(x) >= other.minAlong else { return nil }
        return x
    }

    func guide(to p: Point2) -> (Point2, Point2) { (origin, p + dir * overshoot) }

    /// Welcher Fang beim Schnitt zweier Leitlinien die Bedingung stellt (kleiner zuerst). Waagerecht/senkrecht und
    /// rechtwinklig zum vorigen Stück entstehen beim Setzen ohnehin aus der genauen Lage (SketchCommit.swift).
    var rank: Int {
        switch target {
        case .onCurve, .lineExtension: 0
        case .parallel, .perpendicular: 1
        case .horizontal, .vertical: 2
        case .angle: 3
        default: 4
        }
    }
}

/// Ein Fangkandidat: Punkt, Bedeutung, gestrichelte Leitlinie und Schild („X“, „Mid“, „On“, „H“ …).
struct SnapCandidate {
    var point: Point2
    var target: SnapTarget?
    var guide: (Point2, Point2)?
    var label: String = ""
    /// Weitere gestrichelte Hilfslinien (Ausrichtung an Punkten, Verlängerungen, Winkelstrahl), zusätzlich zu guide.
    var guides: [(Point2, Point2)] = []

    static func free(_ p: Point2) -> SnapCandidate { SnapCandidate(point: p, target: nil, guide: nil, label: "") }

    var hasArgument: Bool { target?.isPointArgument ?? false }
}

/// Kurven und Punkte der Skizze mit ihren Referenzen, einmal je Änderung aufgebaut.
struct SketchInference {
    enum Shape {
        case line(Point2, Point2)
        case circle(center: Point2, radius: Double)
        case arc(ArcGeometry)
        /// Ellipse, Spline: als Linienzug angenähert
        case polyline([Point2])
    }

    struct Curve {
        var ref: SketchCurveRef
        var shape: Shape
        var construction: Bool
    }

    struct Node {
        var point: Point2
        var ref: SketchPointRef?
        var isCenter: Bool
        /// Ursprung: bei Gleichstand gewinnt ein beweglicher Punkt
        var movable: Bool
    }

    private(set) var curves: [Curve] = []
    private(set) var nodes: [Node] = []
    private(set) var modelPoints: [Point2] = []

    init() {}

    init(entities: [SketchEntity], construction: Set<Int>, modelPoints: [Point2] = []) {
        self.modelPoints = modelPoints
        for (index, entity) in entities.enumerated() {
            if case .text = entity { continue }
            let handles = entity.handlePoints
            for (k, p) in handles.enumerated() {
                var isCenter = false
                switch entity {
                // SolidCraft kennt keine Rechteckmitte als Punkt
                case .rectangle where k == 4: continue
                case .circle, .ellipse, .regularPolygon: isCenter = k == 0
                case .arc: isCenter = k == 2
                default: break
                }
                nodes.append(Node(point: p, ref: SketchPointRef(entity: index, index: k), isCenter: isCenter,
                                  movable: true))
            }
            let isConstruction = construction.contains(index)
            let first = SketchCurveRef(entity: index, index: 0)
            switch entity {
            case .point:
                break
            case .arc(let a, let m, let b):
                if let arc = ArcGeometry(a, m, b) {
                    curves.append(Curve(ref: first, shape: .arc(arc), construction: isConstruction))
                } else {
                    curves.append(Curve(ref: first, shape: .line(a, b), construction: isConstruction))
                }
            case .line, .rectangle, .regularPolygon, .polyline, .circle:
                for k in 0..<entity.curveCount {
                    let ref = SketchCurveRef(entity: index, index: k)
                    switch entity.constraintCurve(k) {
                    case .line(let a, let b):
                        curves.append(Curve(ref: ref, shape: .line(a, b), construction: isConstruction))
                    case .circle(let c, let r):
                        curves.append(Curve(ref: ref, shape: .circle(center: c, radius: r), construction: isConstruction))
                    case .other:
                        break
                    }
                }
            default:
                for line in entity.drawing where line.count >= 2 {
                    curves.append(Curve(ref: first, shape: .polyline(line), construction: isConstruction))
                }
            }
        }
        // Ursprung der Skizze (fest)
        nodes.append(Node(point: .zero, ref: nil, isCenter: false, movable: false))
    }

    // MARK: Stufe 0: vorhandener Punkt

    /// Nächster Skizzenpunkt unter dem Stift (Bildschirmabstand < 8 pt + Bonus), bei Gleichstand der bewegliche.
    func pointHit(_ lp: Point2, metrics: SnapMetrics, kinds: Set<SnapKind>, extra: [Point2]) -> Node? {
        var best: (distance: Double, node: Node)?
        let all = nodes + extra.map { Node(point: $0, ref: nil, isCenter: false, movable: true) }
        for node in all {
            if node.isCenter ? !kinds.contains(.center) : !kinds.contains(.endpoint) { continue }
            let d = simd_distance(node.point, lp)
            guard d < metrics.pointPick else { continue }
            if let current = best {
                let tie = abs(d - current.distance) < 1e-9
                if tie ? !(node.movable && !current.node.movable) : d >= current.distance { continue }
            }
            best = (d, node)
        }
        return best?.node
    }

    /// Kurve unter dem Stift (zum Wecken der Kreismitte und für die Auswahl der Tangentenkreise).
    func curveHit(_ lp: Point2, radius: Double) -> Curve? {
        var best: (distance: Double, curve: Curve)?
        for curve in curves {
            let d = curve.shape.distance(to: lp)
            if d < radius, d < (best?.distance ?? .infinity) { best = (d, curve) }
        }
        return best?.curve
    }

    func curve(_ ref: SketchCurveRef) -> Curve? {
        curves.first { $0.ref == ref }
    }

    // MARK: refine_snap

    /// Fang an lp in der Reihenfolge von SolidCraft. prev = zuletzt gesetzter Punkt des Werkzeugs, lineTool =
    /// Inferenzen nur für die Linie (Tangente, Zentrum, parallel/senkrecht/Verlängerung), midOnly = nur Mitten,
    /// fineStep = Feinraster (für H/V und das Raster), gridOn = Raster aktiv, tracking = Winkelschritte und
    /// gemerkte Punkte der Klickfolge (PencilCAD).
    func refine(_ lp: Point2, prev: Point2?, lineTool: Bool, metrics: SnapMetrics, midOnly: Bool, kinds: Set<SnapKind>,
                extra: [Point2], woken: Point2?, fineStep: Double, gridOn: Bool,
                tracking: SnapTracking = SnapTracking()) -> SnapCandidate {
        // 0: vorhandener Punkt bzw. geweckte Mitte
        if let node = pointHit(lp, metrics: metrics, kinds: kinds, extra: extra) {
            return SnapCandidate(point: node.point, target: .point(node.ref), guide: nil, label: "")
        }
        if let woken, simd_distance(woken, lp) < metrics.wokenCenter,
           let node = nodes.first(where: { $0.isCenter && simd_distance($0.point, woken) < 1e-9 }) {
            return SnapCandidate(point: node.point, target: .point(node.ref), guide: nil, label: "")
        }
        let tol = metrics.refine
        // 1: Körperecke
        if kinds.contains(.modelPoint) {
            var best: (distance: Double, point: Point2)?
            for q in modelPoints {
                let d = simd_distance(q, lp)
                if d < metrics.pointPick, d < (best?.distance ?? .infinity) { best = (d, q) }
            }
            if let best { return SnapCandidate(point: best.point, target: .modelVertex(best.point), guide: nil, label: "Pt") }
        }
        // 2: Schnittpunkt zweier Kurven
        if !midOnly, kinds.contains(.intersection), let crossing = nearestCrossing(lp, tolerance: tol, extra: extra) {
            return SnapCandidate(point: crossing.point, target: .crossing(crossing.a, crossing.b), guide: nil, label: "X")
        }
        // 3: Linienmitte (Bögen nicht)
        if kinds.contains(.midpoint) {
            let reach = midOnly ? metrics.preferredMidpoint : tol
            var best: (distance: Double, point: Point2, ref: SketchCurveRef)?
            for curve in curves {
                guard case .line(let a, let b) = curve.shape else { continue }
                let m = (a + b) / 2
                let d = simd_distance(m, lp)
                if d < reach, d < (best?.distance ?? .infinity) { best = (d, m, curve.ref) }
            }
            if let best { return SnapCandidate(point: best.point, target: .midpoint(best.ref), guide: nil, label: "Mid") }
        }
        if midOnly { return gridded(lp, fineStep: fineStep, gridOn: gridOn) }
        // 4, 5: Tangente und durch das Zentrum (nur Linie)
        if lineTool, let prev {
            if kinds.contains(.tangent), let found = tangent(prev: prev, lp: lp, tolerance: tol) { return found }
            if kinds.contains(.center), let found = throughCenter(prev: prev, lp: lp, tolerance: tol) { return found }
        }
        // Leitlinien (PencilCAD): waagerecht/senkrecht zum vorigen Punkt, Winkelschritte, parallel/senkrecht,
        // Verlängerungen und Ausrichtung an gemerkten Punkten
        let leads = self.leads(lp, prev: prev, lineTool: lineTool, metrics: metrics, kinds: kinds, tracking: tracking)
        // 6: auf Kurve – kreuzt dort eine Leitlinie die Kurve, genau auf dem Schnitt
        if kinds.contains(.onCurve) {
            var best: (distance: Double, point: Point2, ref: SketchCurveRef)?
            for curve in curves {
                let q = curve.shape.project(lp)
                let d = simd_distance(q, lp)
                if d < metrics.onCurve, d < (best?.distance ?? .infinity) { best = (d, q, curve.ref) }
            }
            if let best {
                if let crossed = leadOnCurve(lp, curve: best.ref, leads: leads, tolerance: tol) { return crossed }
                return SnapCandidate(point: best.point, target: .onCurve(best.ref), guide: nil, label: "On")
            }
        }
        // 7, 8: Leitlinien und ihre Schnitte (H/V, Winkel, //, ⊥, Verlängerung, Ausrichtung); die freie Länge folgt
        // dem Feinraster entlang der Leitlinie
        if let found = leadSnap(lp, leads: leads, tolerance: tol, fineStep: gridOn ? fineStep : 0) { return found }
        // 9: Raster
        return gridded(lp, fineStep: fineStep, gridOn: gridOn)
    }

    private func gridded(_ lp: Point2, fineStep: Double, gridOn: Bool) -> SnapCandidate {
        guard gridOn, fineStep > 0 else { return .free(lp) }
        let p = Point2((lp.x / fineStep).rounded() * fineStep, (lp.y / fineStep).rounded() * fineStep)
        return SnapCandidate(point: p, target: .grid, guide: nil, label: "")
    }

    /// Nächster Schnittpunkt zweier Kurven nahe lp (höchstens 256 Kurven); ohne Schnittpunkte, auf denen schon
    /// ein Punkt liegt (dort greift Stufe 0).
    private func nearestCrossing(_ lp: Point2, tolerance tol: Double, extra: [Point2])
        -> (point: Point2, a: SketchCurveRef, b: SketchCurveRef)? {
        var candidates: [Curve] = []
        for curve in curves where curve.shape.distance(to: lp) <= tol {
            candidates.append(curve)
            if candidates.count >= 256 { break }
        }
        guard candidates.count >= 2 else { return nil }
        var best: (distance: Double, point: Point2, a: SketchCurveRef, b: SketchCurveRef)?
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                // Kanten desselben Elements treffen sich an Ecken: das sind Punkte
                let first = candidates[i], second = candidates[j]
                for p in first.shape.primitives {
                    for q in second.shape.primitives {
                        for x in SketchTrim.intersections(p, q) {
                            let d = simd_distance(x, lp)
                            guard d <= tol, d < (best?.distance ?? .infinity) else { continue }
                            if nodes.contains(where: { simd_distance($0.point, x) <= 1e-4 })
                                || extra.contains(where: { simd_distance($0, x) <= 1e-4 }) { continue }
                            best = (d, x, first.ref, second.ref)
                        }
                    }
                }
            }
        }
        return best.map { ($0.point, $0.a, $0.b) }
    }

    // MARK: Inferenzen der Linie (inference.rs)

    /// Tangente vom vorigen Punkt an einen Kreis bzw. Bogen (nicht an Konstruktionskreise).
    func tangent(prev: Point2, lp: Point2, tolerance tol: Double) -> SnapCandidate? {
        var best: (distance: Double, candidate: SnapCandidate)?
        for curve in curves where !curve.construction {
            guard let round = curve.shape.round else { continue }
            let d = simd_distance(prev, round.center)
            guard d > round.radius + 1e-9 else { continue }
            let base = atan2(prev.y - round.center.y, prev.x - round.center.x)
            let half = acos(round.radius / d)
            for s in [-1.0, 1.0] {
                let angle = base + s * half
                let t = round.center + Point2(cos(angle), sin(angle)) * round.radius
                guard curve.shape.distance(to: t) < 1e-6 else { continue }
                let e = simd_distance(t, lp)
                if e < tol, e < (best?.distance ?? .infinity) {
                    best = (e, SnapCandidate(point: t, target: .tangent(curve.ref), guide: (prev, t), label: "T"))
                }
            }
        }
        return best?.candidate
    }

    /// Die Linie vom vorigen Punkt läuft durch das Zentrum eines Kreises bzw. Bogens: auf dem Rand ein
    /// Durchmesser bzw. Radius, auf dem Zentrum das Zentrum, sonst ein freier Punkt auf der Radiallinie.
    func throughCenter(prev: Point2, lp: Point2, tolerance tol: Double) -> SnapCandidate? {
        var best: (distance: Double, candidate: SnapCandidate)?
        for curve in curves {
            guard let round = curve.shape.round, round.radius > 1e-9 else { continue }
            let o = round.center, r = round.radius
            let toCenter = o - prev
            let d = simd_length(toCenter)
            guard d > 1e-9 else { continue }
            let dir = toCenter / d
            let v = lp - prev
            let off = abs(v.x * dir.y - v.y * dir.x)
            guard off <= tol else { continue }
            let along = simd_dot(v, dir)
            guard along >= tol else { continue }
            let past = along + tol >= d
            let far = prev + dir * (d + r)
            let onArc = curve.shape.distance(to: far) < 1e-6
            let nearCurve = curve.shape.distance(to: lp) < tol * 0.8
            let rim = nearCurve && onArc && past && simd_distance(far, lp) <= tol
            let atCentre = simd_distance(lp, o) <= tol
            var at: Point2
            var target: SnapTarget
            if rim, !atCentre || simd_distance(far, lp) <= simd_distance(lp, o) {
                at = far
                target = .throughCenter(curve.ref, rim: true, atCenter: false)
            } else if atCentre {
                at = o
                target = .throughCenter(curve.ref, rim: false, atCenter: true)
            } else if past {
                at = prev + dir * along
                if simd_distance(at, o) <= tol {
                    at = o
                    target = .throughCenter(curve.ref, rim: false, atCenter: true)
                } else {
                    target = .throughCenter(curve.ref, rim: false, atCenter: false)
                }
            } else {
                continue
            }
            guard simd_distance(at, prev) >= 1e-6 else { continue }
            let distance = simd_distance(at, lp)
            if distance <= tol, distance < (best?.distance ?? .infinity) {
                best = (distance, SnapCandidate(point: at, target: target, guide: (prev, at), label: "Ctr"))
            }
        }
        return best?.candidate
    }

    // MARK: Leitlinien (PencilCAD, wie der klassische Fang bis Build 149)

    /// Alle Leitlinien für den Stift an lp: waagerecht/senkrecht und Winkelschritte vom vorigen Punkt, Winkel zum
    /// vorigen Linienstück, parallel/senkrecht zu schrägen Linien (nur Linie), Verlängerungen und Ausrichtung.
    func leads(_ lp: Point2, prev: Point2?, lineTool: Bool, metrics: SnapMetrics, kinds: Set<SnapKind>,
               tracking: SnapTracking) -> [SnapLead] {
        let tol = metrics.refine
        let overshoot = tol * 4
        var result: [SnapLead] = []
        /// Fangabstand eines Strahls in Bildschirmgrad, begrenzt
        func angular(_ t: Double, minimum: Double) -> Double {
            min(max(t * tan(metrics.angleSnap), minimum), tol * 2.5)
        }
        if let prev {
            let v = lp - prev
            let length = simd_length(v)
            // Waagerecht/senkrecht zum vorigen Punkt (SolidCraft 7 pt, weiter weg auch im Winkelmaß)
            if kinds.contains(.alignment) {
                result.append(SnapLead(origin: prev, dir: Point2(v.x < 0 ? -1 : 1, 0), minAlong: tol,
                                       reach: angular(abs(v.x), minimum: tol), weight: 0.8, target: .horizontal,
                                       label: "H", rounding: .coordinate, overshoot: overshoot))
                result.append(SnapLead(origin: prev, dir: Point2(0, v.y < 0 ? -1 : 1), minAlong: tol,
                                       reach: angular(abs(v.y), minimum: tol), weight: 0.8, target: .vertical,
                                       label: "V", rounding: .coordinate, overshoot: overshoot))
            }
            if tracking.angleSteps, kinds.contains(.angle), length >= tol * 2 {
                result += angleLeads(v, prev: prev, previous: tracking.previous,
                                     reach: angular(length, minimum: tol * 0.5), tolerance: tol, overshoot: overshoot)
            }
            // Parallel bzw. senkrecht zu einer schrägen Linie (achsparallele Richtungen übernimmt H/V)
            if lineTool, kinds.contains(.parallel), length >= tol * 2 {
                for curve in curves where !curve.construction {
                    guard case .line(let a, let b) = curve.shape else { continue }
                    let segment = b - a
                    let l = simd_length(segment)
                    guard l > 1e-9 else { continue }
                    let d = segment / l
                    guard abs(d.x) >= 1e-9, abs(d.y) >= 1e-9 else { continue }
                    // Am Ende dieser Linie übernimmt der Winkel zum vorigen Stück („Ext“, „⊥“)
                    if simd_distance(a, prev) < 1e-9 || simd_distance(b, prev) < 1e-9 { continue }
                    for (isParallel, base) in [(true, d), (false, Point2(-d.y, d.x))] {
                        let dir = simd_dot(v, base) < 0 ? -base : base
                        let target: SnapTarget = isParallel ? .parallel(curve.ref) : .perpendicular(curve.ref)
                        result.append(SnapLead(origin: prev, dir: dir, minAlong: tol * 2, reach: tol, weight: 1,
                                               target: target, label: isParallel ? "//" : "⊥", rounding: .length,
                                               overshoot: overshoot))
                    }
                }
            }
        }
        // Verlängerung über die Enden hinaus (gestrichelt ab dem Ende); die Linie, an der weitergezeichnet wird,
        // verlängert der Winkel zum vorigen Stück
        for curve in curves where !curve.construction && kinds.contains(.lineExtension) {
            guard case .line(let a, let b) = curve.shape else { continue }
            let l = simd_distance(a, b)
            guard l > 1e-9 else { continue }
            if let prev, simd_distance(a, prev) < 1e-9 || simd_distance(b, prev) < 1e-9 { continue }
            let d = (b - a) / l
            for (end, dir) in [(b, d), (a, -d)] {
                result.append(SnapLead(origin: end, dir: dir, minAlong: tol, reach: metrics.onCurve, weight: 0.9,
                                       target: .lineExtension(curve.ref), label: "Ext", rounding: .keep))
            }
        }
        // Ausrichtung: waagerecht bzw. senkrecht auf Höhe gemerkter Punkte (gestrichelt vom Punkt zum Stift)
        if kinds.contains(.alignment) {
            for q in tracking.points {
                if let prev, simd_distance(q, prev) < 1e-9 { continue }
                result.append(SnapLead(origin: q, dir: Point2(lp.x < q.x ? -1 : 1, 0), minAlong: tol, reach: tol,
                                       weight: 1.1, target: .aligned, label: "↔", rounding: .coordinate))
                result.append(SnapLead(origin: q, dir: Point2(0, lp.y < q.y ? -1 : 1), minAlong: tol, reach: tol,
                                       weight: 1.1, target: .aligned, label: "↕", rounding: .coordinate))
            }
            // Spuren an gemerkten Punkten (senkrecht zu anliegenden Linien)
            result += trackLeads(lp, prev: prev, metrics: metrics, sources: tracking.traces)
        }
        return result
    }

    /// Objektfangspuren (wie AutoCAD „Objektfangspur“, Kai: gedrehtes Viereck mit 90° schließen): an jedem
    /// Spurpunkt eine gestrichelte Spur senkrecht zu jeder dort anliegenden bzw. durchlaufenden schrägen Linie.
    /// Waagerecht/senkrecht übernimmt die Ausrichtung (↔, ↕), parallel die Verlängerung („Ext“). Die Spur stellt
    /// keine Bedingung (.aligned, rank 4): kreuzt sie die Leitlinie vom vorigen Punkt, bestimmt jene die Bedingung;
    /// die Rechtwinkligkeit zur Spur entsteht erst mit dem nächsten Stück aus der genauen Lage. Höchstens 8
    /// Spurpunkte, nur bis alignReach vom Stift.
    func trackLeads(_ lp: Point2, prev: Point2?, metrics: SnapMetrics, sources: [Point2]) -> [SnapLead] {
        let tol = metrics.refine
        var result: [SnapLead] = []
        for q in sources.prefix(8) {
            guard simd_distance(q, lp) <= metrics.alignReach else { continue }
            // Am vorigen Punkt übernimmt der Winkel zum vorigen Stück („⊥“)
            if let prev, simd_distance(q, prev) < 1e-9 { continue }
            var normals: [Point2] = []
            for curve in curves where !curve.construction {
                guard case .line(let a, let b) = curve.shape, curve.shape.distance(to: q) < 1e-6 else { continue }
                let l = simd_distance(a, b)
                guard l > 1e-9 else { continue }
                let d = (b - a) / l
                // Achsparallele Linie: die Senkrechte ist ↔ bzw. ↕
                guard abs(d.x) >= 1e-9, abs(d.y) >= 1e-9 else { continue }
                let n = Point2(-d.y, d.x)
                // Gleiche Richtung schon da (zwei Linien auf einer Geraden)
                if normals.contains(where: { abs($0.x * n.y - $0.y * n.x) < 1e-9 }) { continue }
                normals.append(n)
                let dir = simd_dot(lp - q, n) < 0 ? -n : n
                result.append(SnapLead(origin: q, dir: dir, minAlong: tol, reach: tol, weight: 1.05, target: .aligned,
                                       label: "⊥", rounding: .length))
            }
        }
        return result
    }

    /// Winkelschritte vom vorigen Punkt (v = Stift − voriger Punkt): 15°-Schritte zur Skizzenachse und, an einem
    /// Linienende, 15°-Schritte zum vorigen Stück (0° = gerade weiter, 90° = rechtwinklig). 0/90/180/270° zur
    /// Achse übernimmt H/V.
    private func angleLeads(_ v: Point2, prev: Point2, previous: (direction: Point2, ref: SketchCurveRef)?,
                            reach: Double, tolerance tol: Double, overshoot: Double) -> [SnapLead] {
        let step = Double.pi / 12
        var result: [SnapLead] = []
        let k = Int((atan2(v.y, v.x) / step).rounded())
        if k % 6 != 0 {
            let angle = Double(k) * step
            let degrees = (k * 15 + 360) % 360
            result.append(SnapLead(origin: prev, dir: Point2(cos(angle), sin(angle)), minAlong: tol * 2, reach: reach,
                                   weight: 1, target: .angle, label: "\(degrees)°", rounding: .length,
                                   overshoot: overshoot))
        }
        guard let previous else { return result }
        let u = previous.direction
        let relative = atan2(u.x * v.y - u.y * v.x, simd_dot(u, v))
        let kr = Int((relative / step).rounded())
        // 180°: zurück auf das vorige Stück
        guard abs(kr) < 12 else { return result }
        let dir: Point2
        switch kr {
        case 0: dir = u
        case 6: dir = Point2(-u.y, u.x)
        case -6: dir = Point2(u.y, -u.x)
        default:
            let c = cos(Double(kr) * step), s = sin(Double(kr) * step)
            dir = Point2(u.x * c - u.y * s, u.x * s + u.y * c)
        }
        // Achsparallel: H/V
        guard abs(dir.x) >= 1e-9, abs(dir.y) >= 1e-9 else { return result }
        let steps = atan2(dir.y, dir.x) / step
        let onAxisStep = abs(steps - steps.rounded()) < 1e-6
        let target: SnapTarget
        let label: String
        let weight: Double
        switch abs(kr) {
        case 0:
            target = .parallel(previous.ref)
            label = "Ext"
            weight = 0.85
        case 6:
            target = .perpendicular(previous.ref)
            label = "⊥"
            weight = 0.85
        default:
            // Liegt die Richtung ohnehin auf einem 15°-Schritt zur Achse, zeigt der den Winkel
            guard !onAxisStep else { return result }
            target = .angle
            label = "∠\(abs(kr) * 15)°"
            weight = 1
        }
        result.append(SnapLead(origin: prev, dir: dir, minAlong: tol * 2, reach: reach, weight: weight, target: target,
                               label: label, rounding: .length, overshoot: overshoot))
        return result
    }

    /// Nächste Leitlinie am Stift bzw. der Schnitt zweier Leitlinien (Vorrang, wenn er nahe liegt).
    func leadSnap(_ lp: Point2, leads: [SnapLead], tolerance tol: Double, fineStep: Double) -> SnapCandidate? {
        var near: [(lead: SnapLead, score: Double)] = []
        for lead in leads {
            guard lead.along(lp) >= lead.minAlong else { continue }
            let offset = simd_distance(lead.foot(lp), lp)
            guard offset <= lead.reach else { continue }
            near.append((lead: lead, score: offset * lead.weight))
        }
        guard !near.isEmpty else { return nil }
        near.sort { $0.score < $1.score }
        if near.count > 12 { near.removeLast(near.count - 12) }
        var best: (distance: Double, point: Point2, first: SnapLead, second: SnapLead)?
        for i in near.indices {
            for j in near.indices where j > i {
                guard let x = near[i].lead.crossing(near[j].lead) else { continue }
                let d = simd_distance(x, lp)
                if d <= tol * 1.5, d < (best?.distance ?? .infinity) { best = (d, x, near[i].lead, near[j].lead) }
            }
        }
        if let best {
            let firstLeads = best.first.rank <= best.second.rank
            let primary = firstLeads ? best.first : best.second
            let secondary = firstLeads ? best.second : best.first
            var candidate = SnapCandidate(point: best.point, target: primary.target, guide: primary.guide(to: best.point),
                                          label: primary.label + " " + secondary.label)
            candidate.guides = [secondary.guide(to: best.point)]
            return candidate
        }
        let lead = near[0].lead
        let at = lead.snapped(lp, step: fineStep)
        return SnapCandidate(point: at, target: lead.target, guide: lead.guide(to: at), label: lead.label)
    }

    /// Punkt auf der Kurve, wo eine Leitlinie nahe dem Stift sie schneidet (z. B. waagerecht vom vorigen Punkt bis
    /// an eine schräge Linie, oder auf Höhe eines gemerkten Punkts auf einem Kreis).
    private func leadOnCurve(_ lp: Point2, curve ref: SketchCurveRef, leads: [SnapLead], tolerance tol: Double)
        -> SnapCandidate? {
        guard let curve = self.curve(ref) else { return nil }
        var best: (distance: Double, point: Point2, lead: SnapLead)?
        for lead in leads {
            guard lead.along(lp) >= lead.minAlong else { continue }
            let foot = lead.foot(lp)
            guard simd_distance(foot, lp) <= lead.reach else { continue }
            let piece = TrimPrimitive.segment(foot - lead.dir * (tol * 3), foot + lead.dir * (tol * 3))
            for primitive in curve.shape.primitives {
                for hit in SketchTrim.intersections(piece, primitive) {
                    let x = lead.exact(hit)
                    let d = simd_distance(x, lp)
                    guard d <= tol, lead.along(x) >= lead.minAlong, d < (best?.distance ?? .infinity) else { continue }
                    best = (d, x, lead)
                }
            }
        }
        guard let best else { return nil }
        return SnapCandidate(point: best.point, target: .onCurve(ref), guide: best.lead.guide(to: best.point),
                             label: "On")
    }

    // MARK: Gemerkte Fangpunkte (PencilCAD)

    /// Art eines Punktfangs zum Merken; nil = kein Punkt.
    func trackKind(_ target: SnapTarget?, at p: Point2) -> SnapKind? {
        guard let target else { return nil }
        switch target {
        case .point:
            let node = nodes.first { simd_distance($0.point, p) < 1e-9 }
            return node?.isCenter == true ? .center : .endpoint
        case .modelVertex: return .modelPoint
        case .crossing: return .intersection
        case .midpoint: return .midpoint
        case .throughCenter(_, _, let atCenter): return atCenter ? .center : nil
        default: return nil
        }
    }

    /// Liegt p noch auf der Skizze (Punkt, Kurve, Körperecke)? Gemerkte Punkte verfallen nach Rückgängig u. Ä.
    func holds(_ p: Point2) -> Bool {
        nodes.contains { simd_distance($0.point, p) < 1e-6 } || modelPoints.contains { simd_distance($0, p) < 1e-6 }
            || curves.contains { $0.shape.distance(to: p) < 1e-6 }
    }

    /// Punkte für die Ausrichtung nahe dem Stift: Enden, Zentren, Linienmitten, die nächsten zuerst (höchstens limit).
    func alignmentPoints(near lp: Point2, reach: Double, kinds: Set<SnapKind>, limit: Int = 24) -> [Point2] {
        var found: [(distance: Double, point: Point2)] = []
        for node in nodes {
            let allowed = node.isCenter ? kinds.contains(.center) : kinds.contains(.endpoint)
            let d = simd_distance(node.point, lp)
            if allowed, d <= reach { found.append((distance: d, point: node.point)) }
        }
        if kinds.contains(.midpoint) {
            for curve in curves {
                guard case .line(let a, let b) = curve.shape else { continue }
                let m = (a + b) / 2
                let d = simd_distance(m, lp)
                if d <= reach { found.append((distance: d, point: m)) }
            }
        }
        found.sort { $0.distance < $1.distance }
        return found.prefix(limit).map { $0.point }
    }

    /// Fangpunkte in Stiftnähe für die Anzeige: Enden, Zentren, Linienmitten, Schnittpunkte, Körperecken.
    func trackedNodes(near lp: Point2, radius: Double, kinds: Set<SnapKind>, extra: [Point2])
        -> [(kind: SnapKind, point: Point2)] {
        var result: [(kind: SnapKind, point: Point2)] = []
        func add(_ kind: SnapKind, _ p: Point2) {
            guard simd_distance(p, lp) <= radius, !result.contains(where: { simd_distance($0.point, p) < 1e-6 }) else {
                return
            }
            result.append((kind: kind, point: p))
        }
        for node in nodes {
            let kind: SnapKind = node.isCenter ? .center : .endpoint
            if kinds.contains(kind) { add(kind, node.point) }
        }
        if kinds.contains(.endpoint) {
            for p in extra { add(.endpoint, p) }
        }
        if kinds.contains(.midpoint) {
            for curve in curves {
                if case .line(let a, let b) = curve.shape { add(.midpoint, (a + b) / 2) }
            }
        }
        if kinds.contains(.intersection) {
            for x in crossings(near: lp, radius: radius) { add(.intersection, x) }
        }
        if kinds.contains(.modelPoint) {
            for q in modelPoints { add(.modelPoint, q) }
        }
        return result
    }

    /// Schnittpunkte der Kurven im Umkreis (höchstens 48 Kurven, nur ihre Stücke im Umkreis).
    private func crossings(near lp: Point2, radius: Double) -> [Point2] {
        var pieces: [[TrimPrimitive]] = []
        for curve in curves where curve.shape.distance(to: lp) <= radius {
            let near = curve.shape.primitives.filter { primitive in
                if case .segment(let a, let b) = primitive { return Shape.line(a, b).distance(to: lp) <= radius }
                return true
            }
            if !near.isEmpty { pieces.append(near) }
            if pieces.count >= 48 { break }
        }
        guard pieces.count >= 2 else { return [] }
        var result: [Point2] = []
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                for p in pieces[i] {
                    for q in pieces[j] {
                        for x in SketchTrim.intersections(p, q) where simd_distance(x, lp) <= radius {
                            result.append(x)
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: Achsfang (sketch_dims.rs)

    /// Winkel bis limit neben 0/90/180/270° rasten genau dort ein.
    static func snapAxis(_ angle: Double, limit: Double) -> Double {
        let quarter = Double.pi / 2
        let k = (angle / quarter).rounded()
        return abs(angle - k * quarter) < limit ? k * quarter : angle
    }

    /// Linienende auf einer Kurve im Achsfang: wo die Waagerechte bzw. Senkrechte vom Start die Kurve nahe dem
    /// Stift schneidet (vom Kreiszentrum aus der Quadrantenpunkt), auf der Kurve und genau achsparallel.
    func onCurveAxis(start a: Point2, candidate: SnapCandidate, limit: Double) -> SnapCandidate? {
        guard case .onCurve(let ref)? = candidate.target, let curve = self.curve(ref) else { return nil }
        let v = candidate.point - a
        let length = simd_length(v)
        guard length > 1e-9 else { return nil }
        let angle = atan2(v.y, v.x)
        let snapped = Self.snapAxis(angle, limit: limit)
        guard snapped != angle else { return nil }
        let dir = Point2(cos(snapped), sin(snapped))
        let horizontal = abs(dir.y) < abs(dir.x)
        // Achse als lange Strecke ab dem Start
        let reach = length * 4 + 1
        let axis = TrimPrimitive.segment(a, a + dir * reach)
        let tol = 1e-9 * (1 + length)
        var best: (distance: Double, point: Point2)?
        for primitive in curve.shape.primitives {
            for hit in SketchTrim.intersections(axis, primitive) {
                let q = horizontal ? Point2(hit.x, a.y) : Point2(a.x, hit.y)
                guard simd_dot(q - a, dir) > tol, curve.shape.distance(to: q) <= max(tol, 1e-7),
                      simd_distance(q, candidate.point) <= length * 0.1 else { continue }
                let d = simd_distance(q, candidate.point)
                if d < (best?.distance ?? .infinity) { best = (d, q) }
            }
        }
        guard let best else { return nil }
        var result = candidate
        result.point = best.point
        return result
    }
}

extension SketchInference.Shape {
    /// Kreis bzw. Bogen: Mittelpunkt und Radius
    var round: (center: Point2, radius: Double)? {
        switch self {
        case .circle(let c, let r): return (c, r)
        case .arc(let arc): return (arc.center, arc.radius)
        default: return nil
        }
    }

    var isStraight: Bool {
        if case .line = self { return true }
        return false
    }

    /// Nächster Punkt der Kurve.
    func project(_ p: Point2) -> Point2 {
        switch self {
        case .line(let a, let b):
            let ab = b - a
            let l2 = simd_length_squared(ab)
            guard l2 > 1e-18 else { return a }
            let t = min(max(simd_dot(p - a, ab) / l2, 0), 1)
            return a + ab * t
        case .circle(let c, let r):
            let d = p - c
            let l = simd_length(d)
            return l > 1e-12 ? c + d / l * r : c + Point2(r, 0)
        case .arc(let arc):
            let d = p - arc.center
            let l = simd_length(d)
            let onCircle = l > 1e-12 ? arc.center + d / l * arc.radius : arc.point(0)
            if arc.parameter(onCircle) != nil { return onCircle }
            let s = arc.point(0), e = arc.point(1)
            return simd_distance(s, p) <= simd_distance(e, p) ? s : e
        case .polyline(let points):
            return polylineDistance(from: p, to: points, closed: false).point
        }
    }

    func distance(to p: Point2) -> Double {
        simd_distance(project(p), p)
    }

    /// Grundformen für Schnittpunkte
    var primitives: [TrimPrimitive] {
        switch self {
        case .line(let a, let b): return [.segment(a, b)]
        case .circle(let c, let r): return [.circle(center: c, radius: r)]
        case .arc(let arc): return [.arc(arc)]
        case .polyline(let points):
            guard points.count >= 2 else { return [] }
            return (0..<(points.count - 1)).map { TrimPrimitive.segment(points[$0], points[$0 + 1]) }
        }
    }

    /// Länge der Kurve (für den Radiusvorschlag des 2-Tangenten-Kreises)
    var length: Double {
        switch self {
        case .line(let a, let b): return simd_distance(a, b)
        case .circle(_, let r): return 2 * .pi * r
        case .arc(let arc): return abs(arc.sweep) * arc.radius
        case .polyline(let points):
            guard points.count >= 2 else { return 0 }
            var total = 0.0
            for k in 1..<points.count { total += simd_distance(points[k - 1], points[k]) }
            return total
        }
    }
}
