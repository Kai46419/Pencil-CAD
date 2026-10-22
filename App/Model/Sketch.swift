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

/// Geschlossenes Profil in der Skizzenebene, bereit zum Extrudieren.
enum SketchProfile {
    case polygon([SIMD2<Double>])
    case circle(center: SIMD2<Double>, radius: Double)

    func solid(z: Double, height: Double) -> PCKShape? {
        switch self {
        case .polygon(let points):
            let xy = points.flatMap { [NSNumber(value: $0.x), NSNumber(value: $0.y)] }
            return PCKShape.prism(polygonXY: xy, z: z, height: height)
        case .circle(let center, let radius):
            guard radius > 0, height != 0 else { return nil }
            return PCKShape.cylinder(x: center.x, y: center.y, z: height < 0 ? z + height : z,
                                     radius: radius, height: abs(height))
        }
    }

    var outline: [SIMD2<Double>] {
        switch self {
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

/// Zustand der aktuellen Skizze. Bekommt Weltpunkte in der Skizzenebene vom Viewport.
@MainActor
final class SketchController: ObservableObject {
    @Published var isActive = false {
        didSet { if !isActive { reset() } }
    }
    @Published var tool: SketchTool = .rectangle {
        didSet { reset() }
    }
    /// Für Geräte ohne Apple Pencil (z. B. Simulator): ein Finger zeichnet statt zu drehen.
    @Published var fingerDraws = false
    @Published var planeZ: Double = 0 {
        didSet { revision += 1 }
    }
    @Published var gridStep: Double = 1

    @Published private(set) var profile: SketchProfile?
    @Published private(set) var liveLabel: String?
    @Published private(set) var revision = 0

    private var dragStart: SIMD2<Double>?
    private var dragCurrent: SIMD2<Double>?
    private var polyline: [SIMD2<Double>] = []

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
            let lo = simd_min(start, end), hi = simd_max(start, end)
            if hi.x - lo.x > 0, hi.y - lo.y > 0 {
                profile = .polygon([lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)])
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

    // MARK: Darstellung

    /// Liniensegmente (Paare von Punkten) für den Renderer.
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
            result += closedLoop([start, SIMD2(current.x, start.y), current, SIMD2(start.x, current.y)])
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
            case .polygon(let points) where tool == .rectangle:
                liveLabel = "\(format(points[2].x - points[0].x)) × \(format(points[2].y - points[0].y)) mm"
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
