import Foundation

// Brücke der Skizzenpalette zum SketchController (Freiheitsgrade, Hinweise, Live-Werte aus SketchCommit/ClickTool).

extension SketchController {
    /// Freiheitsgrade für Kopfzeile und Balken (SolidCraft `sketch_palette.rs:288-310`).
    var paletteDOF: (remaining: Int, total: Int, ok: Bool) { degreesOfFreedom }

    /// Hinweistext des laufenden Werkzeugs bzw. der wartenden Bedingung.
    var paletteHint: String {
        if let pendingAction { return pendingAction.hint }
        return currentHint
    }

    /// Live-Werte am Stift während des Zeichnens (Schlüssel wie `SketchToolOptions.locked`).
    var paletteLiveValues: [(key: String, value: Double)] { liveValues }

    /// Live-Wert zu einem Schlüssel; der Durchmesser ergibt sich auch aus dem Radius und umgekehrt.
    func paletteLiveValue(_ key: String) -> Double? {
        let values = paletteLiveValues
        if let hit = values.first(where: { $0.key == key }) { return hit.value }
        switch key {
        case "Durchmesser": return values.first { $0.key == "Radius" }.map { $0.value * 2 }
        case "Radius": return values.first { $0.key == "Durchmesser" }.map { $0.value / 2 }
        case "Länge": return values.first { $0.key == "Abstand" }?.value
        default: return nil
        }
    }

    /// Abgerundetes Rechteck gewählt (Radiusfeld zeigen).
    var paletteRectangleRounded: Bool { rectangleMode == .rounded }

    static func paletteKey(_ kind: SketchDimension.Kind) -> String {
        switch kind {
        case .width: "Breite"
        case .height: "Höhe"
        case .diameter: "Durchmesser"
        case .radius: "Radius"
        case .length: "Länge"
        case .distance: "Abstand"
        case .angle: "Winkel"
        }
    }
}
