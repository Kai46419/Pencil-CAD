import Foundation

// Brücke der Skizzenpalette zum SketchController. Paket 3 (Werkzeuge, Eingabeablauf) liefert auf dem Controller
// `degreesOfFreedom`, `liveValues`, `currentHint` und neue Enum-Fälle (ArcMode.tangent, CircleMode.twoTangent/
// .threeTangent, RectangleMode.rounded). Bis zum Zusammenführen liefern diese Eigenschaften Näherungen aus dem
// vorhandenen Zustand, damit die Palette allein kompiliert. Beim Zusammenführen auf die echten Eigenschaften
// umstellen: alle Stellen sind mit `TODO-MERGE` markiert.

extension SketchController {
    /// Freiheitsgrade für Kopfzeile und Balken (SolidCraft `sketch_palette.rs:288-310`).
    // TODO-MERGE: durch `degreesOfFreedom` ersetzen (Rang aus ConstraintSolver, total = 2 × Punkte + Radien).
    var paletteDOF: (remaining: Int, total: Int, ok: Bool) {
        let fixed = determinedEntities
        var total = 0, remaining = 0
        for index in entities.indices where !construction.contains(index) {
            let dof = Self.paletteDegrees(of: entities[index])
            total += dof
            if !fixed.contains(index) { remaining += dof }
        }
        return (remaining, total, true)
    }

    /// Ungefähre Freiheitsgrade eines Elements (nur für die Näherung oben).
    private static func paletteDegrees(of entity: SketchEntity) -> Int {
        switch entity {
        case .line: 4
        case .rectangle: 4
        case .circle: 3
        case .ellipse: 4
        case .regularPolygon: 4
        case .arc: 5
        case .point: 2
        case .spline(let points, _, _, _): 2 * points.count
        case .polyline(let points, _): 2 * points.count
        default: 0
        }
    }

    /// Hinweistext des laufenden Werkzeugs bzw. der wartenden Bedingung.
    // TODO-MERGE: durch `currentHint` ersetzen (Texte je Stufe aus SolidCraft tools.rs / sketch_tools.rs).
    var paletteHint: String {
        if let pendingAction { return pendingAction.hint }
        switch tool {
        case .select:
            return selection.isEmpty ? "Element antippen zum Wählen, ins Leere ziehen für Rahmen bzw. Lasso."
                : "Gewähltes ziehen verschiebt es; Punkte und Ecken lassen sich einzeln ziehen."
        case .polyline:
            return hasOpenChain ? "Nächsten Punkt antippen. „Linie absetzen“ beendet den Zug."
                : "Startpunkt antippen oder Linie ziehen. Finger auflegen macht den Strich zum Bogen."
        case .rectangle:
            if isWaitingForRectangleHeight { return "Höhe antippen bzw. ziehen." }
            switch rectangleMode {
            case .center: return "Mitte antippen, dann eine Ecke."
            case .threePoint: return "Erste Kante ziehen, dann die Höhe."
            default: return "Zwei gegenüberliegende Ecken antippen bzw. ziehen."
            }
        case .circle:
            switch circleMode {
            case .center: return "Mitte antippen, dann einen Punkt auf dem Kreis."
            case .twoPoint: return "Beide Enden des Durchmessers antippen."
            case .threePoint: return isWaitingForSecondStep ? "Dritten Punkt auf dem Kreis antippen."
                : "Zwei Punkte auf dem Kreis, dann den dritten."
            default: return "Kurven antippen, die der Kreis berühren soll."
            }
        case .arc:
            if isWaitingForArcBulge { return "Bogen mit dem Stift aufziehen, antippen setzt ihn." }
            switch arcMode {
            case .threePoint: return "Start und Ende antippen (Linie A→B), dann den Bogen aufziehen."
            case .center: return isWaitingForSecondStep ? "Ende des Bogens antippen bzw. ziehen."
                : "Mitte, dann Start, dann Ende (gegen den Uhrzeigersinn)."
            default: return "Ende einer Linie oder eines Bogens antippen, dann das Bogenende."
            }
        case .ellipse: return "Mitte antippen, dann zur Ecke ziehen."
        case .polygon: return "Mitte antippen, dann eine Ecke bzw. Kantenmitte."
        case .slot: return isWaitingForSecondStep ? "Breite antippen bzw. ziehen." : "Mittellinie ziehen, dann die Breite."
        case .spline: return hasOpenSpline ? "Weitere Punkte setzen; „Spline beenden“ schließt ab."
            : "Punkte nacheinander antippen."
        case .point: return "Punkt antippen."
        case .text: return "Startpunkt antippen, dann den Text eingeben."
        case .offset: return hasOffsetTarget ? "Am Pfeil ziehen oder Abstand eingeben, dann „Übernehmen“."
            : "Kurve oder Kontur antippen."
        case .project: return "Körperkante oder Fläche antippen."
        case .trim: return "Kurvenstück antippen oder über mehrere wischen (Stift oder Finger)."
        case .fillet: return "Ecke zweier Linien antippen."
        case .chamfer: return "Ecke zweier Linien antippen."
        case .scale: return selection.isEmpty ? "Ohne Auswahl wird die ganze Skizze skaliert." : "Faktor eingeben, dann „Skalieren“."
        case .extend: return "Linie nahe dem Ende antippen – sie wächst bis zur nächsten Kurve."
        case .breakCurve: return "Kurve antippen – sie wird an den nächsten Schnittpunkten geteilt."
        case .splitAtPoint: return "Kurve antippen – sie wird genau dort in zwei Teile getrennt."
        case .mirror: return transformStatus
        case .rectPattern, .circPattern: return transformStatus
        case .measure: return "Linie, Kreis oder Punkt antippen – ein zweites misst Abstand und Winkel."
        }
    }

    /// Live-Werte am Stift während des Zeichnens (Schlüssel wie `SketchToolOptions.locked`).
    // TODO-MERGE: durch `liveValues` ersetzen (Wertfelder je Stufe wie SolidCraft `sketch_dims::boxes_for`).
    var paletteLiveValues: [(key: String, value: Double)] {
        guard isInProgress else { return [] }
        return dimensions.filter { !$0.isEditable }.map { (key: Self.paletteKey($0.kind), value: $0.value) }
    }

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
    // TODO-MERGE: `rectangleMode == .rounded`, sobald Paket 3 den Fall anlegt.
    var paletteRectangleRounded: Bool { false }

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
