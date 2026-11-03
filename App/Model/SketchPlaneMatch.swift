import simd

extension SketchPlane {
    /// Dieselbe Ebene (gleiche Normalenrichtung, gleicher Abstand), z. B. dieselbe Körperfläche noch einmal
    /// angetippt. Dann bleibt die Skizze, wie sie ist (ein Wechsel würde sie leeren).
    func coincides(with other: SketchPlane, tolerance: Double = 1e-4) -> Bool {
        let alignment: Double = simd_dot(normal, other.normal)
        guard alignment > 0.9999 else { return false }
        let offset: Double = simd_dot(other.origin - origin, normal)
        return abs(offset) <= tolerance
    }
}
