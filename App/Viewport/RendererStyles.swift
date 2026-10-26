import simd

// Darstellung „Verdeckte Kanten“: Kantenbänder mit Bogenlänge für das Strichmuster im Fragment-Shader.

extension Renderer {
    /// Kanten als schmale Bänder in der Bildschirmebene (wie lineTriangles, ohne runde Enden).
    /// normal.x jedes Punkts = Bogenlänge entlang des Linienzugs in Bildschirmpunkten; fragment_dashed_clip
    /// macht daraus gleich lange Striche, egal wie weit hineingezoomt ist.
    func hiddenEdgeTriangles(_ polylines: [[SIMD3<Float>]], color: SIMD3<Float>, width: Float,
                             viewHeight: Float) -> [Vertex] {
        let forward = camera.forward
        let eye = camera.position
        let orthographic = camera.isOrthographic
        let minimumDepth = camera.distance * 0.02
        var out: [Vertex] = []
        out.reserveCapacity(polylines.reduce(0) { $0 + max(0, $1.count - 1) } * 6)
        for line in polylines where line.count >= 2 {
            var arc: Float = 0
            for i in 0..<(line.count - 1) {
                let a = line[i], b = line[i + 1]
                // Hinter der Kamera nichts zeichnen (Kanten sind kurz genug, um sie ganz wegzulassen)
                if !orthographic, simd_dot(a - eye, forward) < minimumDepth || simd_dot(b - eye, forward) < minimumDepth {
                    continue
                }
                let d = b - a
                let length = simd_length(d)
                guard length > 1e-9 else { continue }
                let across = simd_cross(d, orthographic ? forward : a - eye)
                let acrossLength = simd_length(across)
                guard acrossLength > 1e-12 else { continue }
                let side = across / acrossLength
                let scaleA = camera.worldUnitsPerPoint(at: a, viewHeight: viewHeight)
                let scaleB = camera.worldUnitsPerPoint(at: b, viewHeight: viewHeight)
                let halfA = width / 2 * scaleA, halfB = width / 2 * scaleB
                // Länge auf dem Bildschirm (genähert über die mittlere Tiefe)
                let next = arc + length / max((scaleA + scaleB) / 2, 1e-9)
                let na = SIMD3<Float>(arc, 0, 0), nb = SIMD3<Float>(next, 0, 0)
                out += [Vertex(position: a - side * halfA, normal: na, color: color),
                        Vertex(position: b - side * halfB, normal: nb, color: color),
                        Vertex(position: b + side * halfB, normal: nb, color: color),
                        Vertex(position: a - side * halfA, normal: na, color: color),
                        Vertex(position: b + side * halfB, normal: nb, color: color),
                        Vertex(position: a + side * halfA, normal: na, color: color)]
                arc = next
            }
        }
        return out
    }
}
