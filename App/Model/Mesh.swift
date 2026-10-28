import CoreGraphics
import Foundation
import simd

/// Muss zum `Vertex`-Struct in Shaders.metal passen (je 16 Byte für float3).
struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD3<Float> = SceneBody.defaultColor
}

/// Eine Fläche eines Körpers in der Szene.
struct FaceRef: Hashable {
    var body: Int
    var face: Int
}

/// Eine Kante eines Körpers in der Szene (Nummer ab 1, passend zu PCKShape.filleting(edges:)).
struct EdgeRef: Hashable {
    var body: Int
    var edge: Int
}

struct Mesh {
    var vertices: [Vertex] = []
    var indices: [UInt32] = []
    /// Je Dreieck: zu welchem Körper und welcher Fläche es gehört.
    var triangleFaces: [FaceRef] = []
    /// Kantenlinien als Punktpaare.
    var edges: [SIMD3<Float>] = []
    /// Je Punktpaar: zu welcher Kante es gehört (edge 0 = unbekannt).
    var edgeRefs: [EdgeRef] = []

    static let empty = Mesh()

    var triangleCount: Int { indices.count / 3 }

    init() {}

    init(_ kernelMesh: PCKMesh, body: Int, color: SIMD3<Float> = SceneBody.defaultColor) {
        let floats: [Float] = kernelMesh.vertexData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        vertices = stride(from: 0, to: floats.count - 5, by: 6).map { i in
            Vertex(position: SIMD3(floats[i], floats[i + 1], floats[i + 2]),
                   normal: SIMD3(floats[i + 3], floats[i + 4], floats[i + 5]),
                   color: color)
        }
        let rawIndices: [UInt32] = kernelMesh.indexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let faces: [UInt32] = kernelMesh.faceIndexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        // Nur vollständige Dreiecke mit gültigen Punkten und Flächennummer: ein fehlerhaftes Netz vom
        // Kernel darf nicht zu Zugriffen außerhalb der Felder führen (Absturz beim Antippen/Zeichnen)
        let count = UInt32(vertices.count)
        var kept: [UInt32] = []
        var keptFaces: [FaceRef] = []
        kept.reserveCapacity(rawIndices.count)
        keptFaces.reserveCapacity(faces.count)
        for t in 0..<min(rawIndices.count / 3, faces.count) {
            let a = rawIndices[t * 3], b = rawIndices[t * 3 + 1], c = rawIndices[t * 3 + 2]
            guard a < count, b < count, c < count else { continue }
            kept += [a, b, c]
            keptFaces.append(FaceRef(body: body, face: Int(faces[t])))
        }
        indices = kept
        triangleFaces = keptFaces
        let edgeFloats: [Float] = kernelMesh.edgeData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        edges = stride(from: 0, to: edgeFloats.count - 2, by: 3).map { i in
            SIMD3(edgeFloats[i], edgeFloats[i + 1], edgeFloats[i + 2])
        }
        let edgeNumbers: [UInt32] = kernelMesh.edgeIndexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        edgeRefs = (0..<edges.count / 2).map { i in
            EdgeRef(body: body, edge: i < edgeNumbers.count ? Int(edgeNumbers[i]) : 0)
        }
    }

    mutating func append(_ other: Mesh) {
        let offset = UInt32(vertices.count)
        vertices += other.vertices
        indices += other.indices.map { $0 + offset }
        triangleFaces += other.triangleFaces
        edges += other.edges
        edgeRefs += other.edgeRefs
    }

    /// Achsenparalleler Hüllquader (min, max).
    /// Punkte mit NaN/∞ (fehlerhafte Importnetze) zählen nicht mit, sonst stimmen Einpassen und Nah-/Fernebene nicht.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for vertex in vertices {
            let p = vertex.position
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            if let current = result {
                result = (min: simd_min(current.min, p), max: simd_max(current.max, p))
            } else {
                result = (min: p, max: p)
            }
        }
        return result
    }

    /// Indizes aller Dreiecke einer Fläche (für die Hervorhebung).
    func triangleIndices(of face: FaceRef) -> [UInt32] {
        var result: [UInt32] = []
        for (t, ref) in triangleFaces.enumerated() where ref == face {
            result += indices[t * 3..<t * 3 + 3]
        }
        return result
    }

    /// Eckpunkte der Dreiecke einer Fläche (je drei), z. B. für die Hervorhebung beim Schweben.
    func trianglePoints(of face: FaceRef) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for (t, ref) in triangleFaces.enumerated() where ref == face {
            for k in 0..<3 { result.append(vertices[Int(indices[t * 3 + k])].position) }
        }
        return result
    }

    /// Indizes aller Dreiecke eines Körpers.
    func triangleIndices(ofBody body: Int) -> [UInt32] {
        var result: [UInt32] = []
        for (t, ref) in triangleFaces.enumerated() where ref.body == body {
            result += indices[t * 3..<t * 3 + 3]
        }
        return result
    }

    /// Hüllquader eines Körpers.
    func bounds(ofBody body: Int) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for (t, ref) in triangleFaces.enumerated() where ref.body == body {
            for k in 0..<3 {
                let p = vertices[Int(indices[t * 3 + k])].position
                if let current = result {
                    result = (min: simd_min(current.min, p), max: simd_max(current.max, p))
                } else {
                    result = (min: p, max: p)
                }
            }
        }
        return result
    }

    /// Flächenschwerpunkt einer Fläche (nach Dreiecksfläche gewichtet).
    func centroid(of face: FaceRef) -> SIMD3<Float>? {
        var sum = SIMD3<Float>(repeating: 0)
        var area: Float = 0
        for (t, ref) in triangleFaces.enumerated() where ref == face {
            let a = vertices[Int(indices[t * 3])].position
            let b = vertices[Int(indices[t * 3 + 1])].position
            let c = vertices[Int(indices[t * 3 + 2])].position
            let w = simd_length(simd_cross(b - a, c - a)) / 2
            sum += w * (a + b + c) / 3
            area += w
        }
        return area > 0 ? sum / area : nil
    }

    /// Linien der angegebenen Kanten als Punktpaare (für die Hervorhebung).
    func edgeSegments(of selected: [EdgeRef]) -> [SIMD3<Float>] {
        let wanted = Set(selected)
        var result: [SIMD3<Float>] = []
        for (i, ref) in edgeRefs.enumerated() where wanted.contains(ref) {
            result += [edges[i * 2], edges[i * 2 + 1]]
        }
        return result
    }

    /// Kante, die einem Bildschirmpunkt am nächsten liegt (höchstens tolerance Punkte entfernt).
    /// project bildet Weltpunkte auf den Bildschirm ab (nil = hinter der Kamera).
    /// Liefert auch den nächsten Punkt auf der Kante in Weltkoordinaten.
    func nearestEdge(to screen: CGPoint, tolerance: CGFloat,
                     project: (SIMD3<Float>) -> CGPoint?) -> (edge: EdgeRef, point: SIMD3<Float>)? {
        var best: (distance: CGFloat, index: Int, t: CGFloat)?
        for (i, ref) in edgeRefs.enumerated() where ref.edge > 0 {
            guard let a = project(edges[i * 2]), let b = project(edges[i * 2 + 1]) else { continue }
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            var t: CGFloat = 0
            if lengthSquared > 0 {
                t = ((screen.x - a.x) * ab.x + (screen.y - a.y) * ab.y) / lengthSquared
                t = min(max(t, 0), 1)
            }
            let dx = a.x + t * ab.x - screen.x, dy = a.y + t * ab.y - screen.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (distance, i, t)
            }
        }
        guard let best else { return nil }
        // Bildschirm-Parameter als Näherung für den Punkt auf der Kante
        let a = edges[best.index * 2], b = edges[best.index * 2 + 1]
        return (edgeRefs[best.index], a + Float(best.t) * (b - a))
    }

    /// Nächstgelegene getroffene Fläche entlang eines Strahls (Möller-Trumbore).
    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (face: FaceRef, point: SIMD3<Float>)? {
        var best: (t: Float, triangle: Int)?
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])].position
            let b = vertices[Int(indices[t * 3 + 1])].position
            let c = vertices[Int(indices[t * 3 + 2])].position
            let e1 = b - a, e2 = c - a
            let p = simd_cross(direction, e2)
            let det = simd_dot(e1, p)
            if abs(det) < 1e-9 { continue }
            let inv = 1 / det
            let s = origin - a
            let u = simd_dot(s, p) * inv
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1)
            let v = simd_dot(direction, q) * inv
            if v < 0 || u + v > 1 { continue }
            let distance = simd_dot(e2, q) * inv
            if distance > 0, distance < (best?.t ?? .infinity) {
                best = (distance, t)
            }
        }
        guard let best, best.triangle < triangleFaces.count else { return nil }
        return (triangleFaces[best.triangle], origin + best.t * direction)
    }

    /// Binäres STL (Einheit mm).
    func binarySTL() -> Data {
        var data = Data(count: 80)
        appendLittleEndian(UInt32(triangleCount), to: &data)
        for t in 0..<triangleCount {
            let a = vertices[Int(indices[t * 3])].position
            let b = vertices[Int(indices[t * 3 + 1])].position
            let c = vertices[Int(indices[t * 3 + 2])].position
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 0, 0)
            for v in [normal, a, b, c] {
                appendLittleEndian(v.x.bitPattern, to: &data)
                appendLittleEndian(v.y.bitPattern, to: &data)
                appendLittleEndian(v.z.bitPattern, to: &data)
            }
            appendLittleEndian(UInt16(0), to: &data)
        }
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

extension Mesh {
    /// Abstand eines Punkts zu einem Dreieck (nächster Punkt nach Ericson, „Real-Time Collision Detection“).
    static func distance(from p: SIMD3<Float>, toTriangle a: SIMD3<Float>, _ b: SIMD3<Float>,
                         _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return simd_distance(p, a) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return simd_distance(p, b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            return simd_distance(p, a + ab * (d1 / (d1 - d3)))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return simd_distance(p, c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            return simd_distance(p, a + ac * (d2 / (d2 - d6)))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            return simd_distance(p, b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))
        }
        let sum = va + vb + vc
        guard sum != 0 else { return simd_distance(p, a) }
        return simd_distance(p, a + ab * (vb / sum) + ac * (vc / sum))
    }
}
