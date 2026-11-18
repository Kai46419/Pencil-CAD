import Foundation
import simd

// Build 104 (Kai): „Geometriekernel abgebrochen“ an einer geraden Kante eines Fusion-STEP-Teils. Ursache: die Kante
// geht glatt in Rundungen über, OpenCASCADE nimmt dann die ganze Tangentenkette (12 Kanten) mit und scheitert
// irgendwo darin. „Nur diese Kante“ rundet bzw. fast gerade Kanten zwischen zwei ebenen Flächen selbst: das
// Eckstück zwischen Kante und Rundung wird als Prisma ausgeschnitten (Prisma minus Zylinder bzw. Dreieck bei der
// Fase) – ohne Kette, wie in Fusion mit ausgeschalteter „Tangentenkette“. Die Rundung endet an den Kantenenden.

extension ModelStore {
    /// Lassen sich alle gewählten Kanten so runden (gerade, zwischen zwei ebenen Flächen, nach außen gewölbt)?
    var canBlendOnlySelectedEdges: Bool {
        guard let first = selectedEdges.first, bodies.indices.contains(first.body),
              selectedEdges.allSatisfy({ $0.body == first.body }) else { return false }
        let shape = bodies[first.body].shape
        return selectedEdges.allSatisfy { Self.singleEdgeFrame(shape, edge: $0.edge) != nil }
    }

    /// Rundung bzw. Fase nur an den gewählten Kanten, mit dem aktuellen Wert
    func blendOnlySelectedEdges() {
        guard requireKernel(), let first = selectedEdges.first, bodies.indices.contains(first.body) else { return }
        let value = edgeValue
        guard value > 1e-6 else {
            message = "Erst einen Radius bzw. eine Fasenbreite eingeben."
            return
        }
        dropPreview()
        let body = first.body
        let original = bodies[body].shape
        var shape = original
        // Werkzeuge alle am Ausgangskörper bestimmen, dann nacheinander abziehen
        var tools: [PCKShape] = []
        for edge in selectedEdges {
            guard let frame = Self.singleEdgeFrame(original, edge: edge.edge),
                  let tool = Self.cornerTool(frame, value: value, chamfer: edgeOperation == .chamfer,
                                             second: edgeSecondValue) else {
                message = "Kante \(edge.edge) lässt sich so nicht bearbeiten (nur gerade Kanten zwischen zwei ebenen Flächen)."
                return
            }
            tools.append(tool)
        }
        for tool in tools {
            guard let cut = shape.cutting(tool, fuzzy: 1e-5) ?? shape.cutting(tool), cut.volume < shape.volume - 1e-9 else {
                message = "Rundung zu groß für diese Kante – kleineren Wert versuchen."
                return
            }
            shape = cut
        }
        var result = bodies
        result[body] = bodies[body].with(shape)
        let name = edgeOperation == .chamfer ? "Fase (nur Kante)" : "Abrunden (nur Kante)"
        commit(result, name: "\(name) \(LengthUnit.current.format(value))")
        message = "\(name): \(selectedEdges.count == 1 ? "1 Kante" : "\(selectedEdges.count) Kanten") ohne Tangentenkette."
    }

    /// Kante A→B mit den nach außen zeigenden Normalen der beiden ebenen Nachbarflächen
    struct SingleEdgeFrame {
        var a: SIMD3<Double>
        var b: SIMD3<Double>
        var n1: SIMD3<Double>
        var n2: SIMD3<Double>
    }

    static func singleEdgeFrame(_ shape: PCKShape, edge: Int) -> SingleEdgeFrame? {
        guard let g = shape.geometry(ofEdge: edge)?.map(\.doubleValue), g.count >= 8, g[0] == 0 else { return nil }
        let a = SIMD3(g[2], g[3], g[4]), b = SIMD3(g[5], g[6], g[7])
        guard simd_distance(a, b) > 1e-6, shape.faceCount > 0 else { return nil }
        var normals: [SIMD3<Double>] = []
        for face in 1...shape.faceCount where shape.edgeNumbers(ofFace: face).contains(where: { $0.intValue == edge }) {
            guard let p = shape.plane(ofFace: face)?.map(\.doubleValue), p.count == 6 else { return nil }
            normals.append(simd_normalize(SIMD3(p[3], p[4], p[5])))
        }
        guard normals.count == 2 else { return nil }
        let n1 = normals[0], n2 = normals[1]
        // Nach außen gewölbte Kante: Material liegt hinter beiden Flächen
        let mid = (a + b) / 2
        let probe = mid - (n1 + n2) * 1e-3
        guard abs(simd_dot(n1, n2)) < 0.999, shape.contains(point: probe) else { return nil }
        return SingleEdgeFrame(a: a, b: b, n1: n1, n2: n2)
    }

    /// Ausschnitt an der Kante: Rundung = Prisma (Kante, Tangentenpunkte, Mittelpunkt) minus Zylinder;
    /// Fase = Dreiecksprisma (Kante und die beiden Fasenpunkte).
    static func cornerTool(_ f: SingleEdgeFrame, value: Double, chamfer: Bool, second: Double?) -> PCKShape? {
        let d = simd_normalize(f.b - f.a)
        // Richtung in Fläche 1 bzw. 2 weg von der Kante ins Material
        var w1 = -f.n2 + simd_dot(f.n2, f.n1) * f.n1
        var w2 = -f.n1 + simd_dot(f.n1, f.n2) * f.n2
        w1 -= simd_dot(w1, d) * d
        w2 -= simd_dot(w2, d) * d
        guard simd_length(w1) > 1e-9, simd_length(w2) > 1e-9 else { return nil }
        w1 = simd_normalize(w1)
        w2 = simd_normalize(w2)
        // Innenwinkel zwischen den Flächen
        let phi = acos(max(-1, min(1, simd_dot(w1, w2))))
        guard phi > 1e-3, phi < .pi - 1e-3 else { return nil }
        let length = simd_distance(f.a, f.b)
        // Etwas Überstand senkrecht zur Kante, damit keine Haut stehen bleibt
        let lift = (f.n1 + f.n2) * (value * 0.02 + 1e-3)
        func prism(_ points: [SIMD3<Double>]) -> PCKShape? {
            PCKShape.prism(pointsXYZ: points.flatMap { [$0.x, $0.y, $0.z] }.map { NSNumber(value: $0) },
                           direction: d * length)
        }
        if chamfer {
            let t1 = value, t2 = second ?? value
            return prism([f.a + lift, f.a + w1 * t1, f.a + w2 * t2])
        }
        let t = value / tan(phi / 2)
        let bisector = simd_normalize(w1 + w2)
        let center = f.a + bisector * (value / sin(phi / 2))
        let p1 = f.a + w1 * t, p2 = f.a + w2 * t
        guard let block = prism([f.a + lift, p1, center, p2]),
              let roll = PCKShape.cylinder(base: center - d * 1e-3, axis: d, radius: value, height: length + 2e-3) else {
            return nil
        }
        return block.cutting(roll)
    }
}
