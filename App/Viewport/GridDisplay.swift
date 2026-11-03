import Foundation

// Zoomabhängiges Raster: Im Skizzenmodus zeigt das Raster das gewählte Fangraster. Wird es im Bild zu eng,
// erscheint ein gröberes Vielfaches davon (nur Anzeige – der Fang bleibt beim gewählten Wert). Ohne Fangraster
// (3D, Fang aus) richtet sich die Weite nur nach dem Zoom, in Schritten passend zur Projekteinheit.
// Modus „Automatisch“ (SolidCraft, Renderer.gridAuto): Weite nach der 1-2-5-Regel aus der Sichthöhe, Fang auf ein
// Zehntel davon (SketchGrid).

/// Rasterweite nach SolidCraft (crates/engine/src/view.rs `grid_step`).
enum SketchGrid {
    /// Rasterweite (Nebenlinie) und Hauptlinie (jede 5.) für eine Ansicht der halben Höhe halfHeight (mm):
    /// raw = halfHeight / 10, dann die nächste Stufe aus 1/2/5 × 10ⁿ darunter.
    static func autoStep(halfHeight: Double) -> (minor: Double, major: Double) {
        let raw = max(halfHeight / 10, 1e-3)
        let p: Double = pow(10.0, floor(log10(raw)))
        let ratio = raw / p
        let minor: Double
        if ratio < 2 {
            minor = p
        } else if ratio < 5 {
            minor = 2 * p
        } else {
            minor = 5 * p
        }
        return (minor, minor * 5)
    }

    /// Fangweite im Modus „Automatisch“: ein Zehntel der Rasterweite (Feinraster).
    static func autoSnapStep(halfHeight: Double) -> Double {
        autoStep(halfHeight: halfHeight).minor / 10
    }
}

extension Renderer {
    /// Mindestabstand zweier Rasterlinien in Bildschirmpunkten.
    private static let minimumGridSpacing: Float = 14
    /// Fangraster weiter als das (Punkte): feineres Raster zeigen, sonst wäre kaum eine Linie im Bild.
    private static let maximumGridSpacing: Float = 400

    /// Angezeigte Rasterweite (mm) und jede wievielte Linie kräftiger ist.
    /// viewHeight = Höhe der Ansicht in Punkten (für den Modus „Automatisch“, `gridAuto`).
    func displayGrid(perPoint: Float, viewHeight: Float = 0) -> (step: Float, majorEvery: Int) {
        let unit = LengthUnit.current
        let perPoint = max(perPoint, 1e-9)
        // Modus „Automatisch“ (SolidCraft): Weite 1-2-5 aus der halben Sichthöhe, jede 5. Linie kräftiger
        if gridAuto, viewHeight > 0 {
            let halfHeight = Double(perPoint) * Double(viewHeight) / 2
            let auto = SketchGrid.autoStep(halfHeight: halfHeight)
            let every = max(1, Int((auto.major / auto.minor).rounded()))
            return (Float(auto.minor), every)
        }
        if gridBase > 0, gridBase / perPoint <= Self.maximumGridSpacing {
            let factors: [Float] = unit == .inch
                ? [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]
                : [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
            if let factor = factors.first(where: { gridBase * $0 / perPoint >= Self.minimumGridSpacing }) {
                return (gridBase * factor, unit.majorGridEvery)
            }
        }
        let steps = unit.displayGridSteps
        let step = steps.first { $0 / perPoint >= Self.minimumGridSpacing } ?? steps.last ?? 2000
        return (step, unit.majorGridEvery)
    }
}
