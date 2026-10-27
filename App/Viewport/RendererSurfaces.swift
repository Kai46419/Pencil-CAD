import simd

// Oberflächen im Renderer (SurfaceFinish.swift, decodeSurface in Shaders.metal).

extension Renderer {
    /// true, wenn ein Punkt die Kennung „transparent“ trägt (Bit 4 im Ganzzahlteil von color.g).
    /// Die Punkte eines Körpers liegen hintereinander und tragen alle dieselbe Farbe: daher nur der
    /// erste Punkt jedes Farbwechsels prüfen.
    static func containsTransparent(_ vertices: [Vertex]) -> Bool {
        var last = SIMD3<Float>(repeating: -1)
        for vertex in vertices where vertex.color != last {
            last = vertex.color
            let bits: Float = (vertex.color.y - 0.001).rounded(.down)
            if bits >= 3.5 { return true }
        }
        return false
    }
}
