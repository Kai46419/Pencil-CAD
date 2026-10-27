import Foundation

// Zoomabhängiges Raster: Im Skizzenmodus zeigt das Raster das gewählte Fangraster. Wird es im Bild zu eng,
// erscheint ein gröberes Vielfaches davon (nur Anzeige – der Fang bleibt beim gewählten Wert). Ohne Fangraster
// (3D, Fang aus) richtet sich die Weite nur nach dem Zoom, in Schritten passend zur Projekteinheit.

extension Renderer {
    /// Mindestabstand zweier Rasterlinien in Bildschirmpunkten.
    private static let minimumGridSpacing: Float = 14
    /// Fangraster weiter als das (Punkte): feineres Raster zeigen, sonst wäre kaum eine Linie im Bild.
    private static let maximumGridSpacing: Float = 400

    /// Angezeigte Rasterweite (mm) und jede wievielte Linie kräftiger ist.
    func displayGrid(perPoint: Float) -> (step: Float, majorEvery: Int) {
        let unit = LengthUnit.current
        let perPoint = max(perPoint, 1e-9)
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
