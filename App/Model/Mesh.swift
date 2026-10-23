import Foundation
import simd

/// Muss zum `Vertex`-Struct in Shaders.metal passen (je 16 Byte für float3).
struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

/// Eine Fläche eines Körpers in der Szene.
struct FaceRef: Hashable {
    var body: Int
    var face: Int
}

struct Mesh {
    var vertices: [Vertex] = []
    var indices: [UInt32] = []
    /// Je Dreieck: zu welchem Körper und welcher Fläche es gehört.
    var triangleFaces: [FaceRef] = []
    /// Kantenlinien als Punktpaare.
    var edges: [SIMD3<Float>] = []

    static let empty = Mesh()

    var triangleCount: Int { indices.count / 3 }

    init() {}

    init(_ kernelMesh: PCKMesh, body: Int) {
        let floats: [Float] = kernelMesh.vertexData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        vertices = stride(from: 0, to: floats.count - 5, by: 6).map { i in
            Vertex(position: SIMD3(floats[i], floats[i + 1], floats[i + 2]),
                   normal: SIMD3(floats[i + 3], floats[i + 4], floats[i + 5]))
        }
        indices = kernelMesh.indexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        let faces: [UInt32] = kernelMesh.faceIndexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        triangleFaces = faces.map { FaceRef(body: body, face: Int($0)) }
        let edgeFloats: [Float] = kernelMesh.edgeData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        edges = stride(from: 0, to: edgeFloats.count - 2, by: 3).map { i in
            SIMD3(edgeFloats[i], edgeFloats[i + 1], edgeFloats[i + 2])
        }
    }

    mutating func append(_ other: Mesh) {
        let offset = UInt32(vertices.count)
        vertices += other.vertices
        indices += other.indices.map { $0 + offset }
        triangleFaces += other.triangleFaces
        edges += other.edges
    }

    /// Achsenparalleler Hüllquader (min, max).
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = vertices.first?.position else { return nil }
        return vertices.reduce((first, first)) { acc, v in
            (simd_min(acc.0, v.position), simd_max(acc.1, v.position))
        }
    }

    /// Indizes aller Dreiecke einer Fläche (für die Hervorhebung).
    func triangleIndices(of face: FaceRef) -> [UInt32] {
        var result: [UInt32] = []
        for (t, ref) in triangleFaces.enumerated() where ref == face {
            result += indices[t * 3..<t * 3 + 3]
        }
        return result
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
