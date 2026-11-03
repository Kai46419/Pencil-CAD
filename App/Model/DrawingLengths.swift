import Foundation
import simd

enum DrawingLengthKind: String, CaseIterable, Identifiable {
    case aligned = "Ausgerichtet"
    case horizontal = "Waagerecht"
    case vertical = "Senkrecht"

    var id: Self { self }
}

/// Endpunkt einer sichtbaren Kante, einschließlich der Ansicht und ihres Blattmaßstabs.
struct DrawingVertex: Equatable {
    var point: Point2
    var view: DrawingView
    var scale: Double
}

struct DrawingLength: Identifiable {
    var id = UUID()
    var from: DrawingVertex
    var to: DrawingVertex
    var kind: DrawingLengthKind
    var handle: Point2
}

struct DrawingLengthShape {
    var elements: [DrawingElement]
    var line: [Point2]
    var label: (min: Point2, max: Point2)
    var value: Double
}

extension TechnicalDrawing {
    static func nearestVertex(in layout: DrawingLayout, to point: Point2,
                              maxDistance: Double) -> DrawingVertex? {
        var closest: DrawingVertex?
        var distance = maxDistance
        for (view, projected) in layout.views where view != .iso {
            for line in projected.visible {
                for vertex in line {
                    let d = simd_distance(vertex, point)
                    if d < distance {
                        distance = d
                        closest = DrawingVertex(point: vertex, view: view, scale: projected.scale)
                    }
                }
            }
        }
        return closest
    }

    static func containsVertex(_ vertex: DrawingVertex, in layout: DrawingLayout) -> Bool {
        guard let projected = layout.views[vertex.view], abs(projected.scale - vertex.scale) < 1e-9 else { return false }
        return projected.visible.contains { line in line.contains { simd_distance($0, vertex.point) < 0.01 } }
    }

    static func length(from: DrawingVertex, to: DrawingVertex, kind: DrawingLengthKind) -> DrawingLength? {
        guard from.view == to.view, from.view != .iso, from.scale.isFinite, from.scale > 0,
              abs(from.scale - to.scale) < 1e-9 else { return nil }
        let delta = to.point - from.point
        let measured = kind == .horizontal ? abs(delta.x) : kind == .vertical ? abs(delta.y) : simd_length(delta)
        guard measured / from.scale >= 0.01 else { return nil }
        let middle = (from.point + to.point) / 2
        let handle: Point2
        switch kind {
        case .horizontal: handle = Point2(middle.x, min(from.point.y, to.point.y) - 10)
        case .vertical: handle = Point2(min(from.point.x, to.point.x) - 10, middle.y)
        case .aligned:
            let normal = Point2(-delta.y, delta.x) / simd_length(delta)
            handle = middle + normal * 10
        }
        return DrawingLength(from: from, to: to, kind: kind, handle: handle)
    }

    static func lengthShape(_ length: DrawingLength) -> DrawingLengthShape? {
        guard length.from.view == length.to.view, length.from.scale > 0,
              abs(length.from.scale - length.to.scale) < 1e-9 else { return nil }
        let a = length.from.point, b = length.to.point
        let delta = b - a
        let q0: Point2, q1: Point2, value: Double, textAngle: Double
        switch length.kind {
        case .horizontal:
            q0 = Point2(a.x, length.handle.y)
            q1 = Point2(b.x, length.handle.y)
            value = abs(delta.x) / length.from.scale
            textAngle = 0
        case .vertical:
            q0 = Point2(length.handle.x, a.y)
            q1 = Point2(length.handle.x, b.y)
            value = abs(delta.y) / length.from.scale
            textAngle = 90
        case .aligned:
            let distance = simd_length(delta)
            guard distance > 1e-9 else { return nil }
            let normal = Point2(-delta.y, delta.x) / distance
            let offset = simd_dot(length.handle - (a + b) / 2, normal)
            q0 = a + normal * offset
            q1 = b + normal * offset
            value = distance / length.from.scale
            var angle = atan2(delta.y, delta.x) * 180 / .pi
            if angle > 90 { angle -= 180 }
            if angle < -90 { angle += 180 }
            textAngle = angle
        }
        guard value.isFinite, value >= 0.01, q0.x.isFinite, q0.y.isFinite, q1.x.isFinite, q1.y.isFinite else { return nil }
        let d = (q1 - q0) / simd_distance(q0, q1)
        var elements: [DrawingElement] = []
        for (source, target) in [(a, q0), (b, q1)] where simd_distance(source, target) > 2 {
            let direction = simd_normalize(target - source)
            elements.append(.polyline([source + direction * 1.5, target + direction * 2], .dimension))
        }
        if simd_distance(q0, q1) >= 8 {
            elements.append(.polyline([q0, q1], .dimension))
            elements.append(.arrow(tip: q0, direction: -d))
            elements.append(.arrow(tip: q1, direction: d))
        } else {
            elements.append(.polyline([q0 - d * 6, q1 + d * 6], .dimension))
            elements.append(.arrow(tip: q0, direction: d))
            elements.append(.arrow(tip: q1, direction: -d))
        }
        let text = number(value)
        let center = (q0 + q1) / 2
        let normal = Point2(-d.y, d.x)
        let baseline = center + normal * 1.5
        elements.append(.text(text, at: baseline, height: 3.5, rotation: textAngle, centered: true))
        let extent = max(textWidth(text, height: 3.5), 3.5) / 2 + 2
        let label = (min: center - Point2(repeating: extent), max: center + Point2(repeating: extent))
        return DrawingLengthShape(elements: elements, line: [q0, q1], label: label, value: value)
    }

    static func hitsLength(_ shape: DrawingLengthShape, _ point: Point2, tolerance: Double) -> Bool {
        let label = shape.label
        if point.x >= label.min.x - tolerance, point.x <= label.max.x + tolerance,
           point.y >= label.min.y - tolerance, point.y <= label.max.y + tolerance { return true }
        return polylineDistance(from: point, to: shape.line, closed: false).distance <= tolerance
    }

    static func withDimensions(_ layout: DrawingLayout, angles: [DrawingAngle], lengths: [DrawingLength]) -> DrawingLayout {
        var result = withAngles(layout, angles)
        for length in lengths {
            if let shape = lengthShape(length) { result.elements += shape.elements }
        }
        return result
    }
}
