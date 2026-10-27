import simd

// Schnittansicht (Kai): „Ich brauche auch da wieder einen Pfeil, damit ich durch den Volumenkörper den Schnitt
// führen kann.“ Blauer Ziehpfeil senkrecht zur Schnittebene wie die übrigen Ziehpfeile; Ziehen ändert den Versatz
// der Ebene, der Schnitt läuft live mit (Workspace.apply → section.offset → clipPlane).
extension Workspace {
    /// Ziehpfeil der Schnittansicht: Fuß auf der Schnittebene in der Mitte der sichtbaren Körper, Richtung = Normale
    /// der Bezugsebene (in diese Richtung wächst der Versatz), Wert = Versatz.
    var sectionHandle: DragHandle? {
        guard tool == .section, !sketch.isActive, let section, let plane = model.resolve(section.plane) else {
            return nil
        }
        let normal = simd_normalize(plane.normal)
        let center = visibleBodiesCenter ?? plane.origin
        // Mitte auf die Bezugsebene (Versatz 0) gelotet; der Fuß wandert mit dem Versatz entlang der Normale
        let height = simd_dot(center - plane.origin, normal)
        let axisOrigin = center - normal * height
        return DragHandle(kind: .section, axisOrigin: SIMD3<Float>(axisOrigin), direction: SIMD3<Float>(normal),
                          value: section.offset, color: Self.handleBlue)
    }

    /// Mitte des Hüllquaders aller sichtbaren Körper (ein Durchlauf über das Netz).
    private var visibleBodiesCenter: SIMD3<Double>? {
        let mesh = model.mesh
        let bodies = model.bodies
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for (t, ref) in mesh.triangleFaces.enumerated() {
            guard bodies.indices.contains(ref.body), !bodies[ref.body].isHidden else { continue }
            for k in 0..<3 {
                let p: SIMD3<Float> = mesh.vertices[Int(mesh.indices[t * 3 + k])].position
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
        }
        guard low.x <= high.x else { return nil }
        return SIMD3<Double>((low + high) / 2)
    }
}
