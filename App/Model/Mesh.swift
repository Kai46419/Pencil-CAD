import Foundation
import simd

/// Muss zum `Vertex`-Struct in Shaders.metal passen (je 16 Byte für float3).
struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct Mesh {
    var vertices: [Vertex] = []
    var indices: [UInt32] = []

    static let empty = Mesh()

    var triangleCount: Int { indices.count / 3 }

    init() {}

    init(_ kernelMesh: PCKMesh) {
        let floats: [Float] = kernelMesh.vertexData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        vertices = stride(from: 0, to: floats.count, by: 6).map { i in
            Vertex(position: SIMD3(floats[i], floats[i + 1], floats[i + 2]),
                   normal: SIMD3(floats[i + 3], floats[i + 4], floats[i + 5]))
        }
        indices = kernelMesh.indexData.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// Achsenparalleler Hüllquader (min, max).
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = vertices.first?.position else { return nil }
        return vertices.reduce((first, first)) { acc, v in
            (simd_min(acc.0, v.position), simd_max(acc.1, v.position))
        }
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
