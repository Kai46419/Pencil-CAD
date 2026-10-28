import Foundation
import simd

// Formgenerator im Skizzen-Controller: Form wählen, beim Aufziehen zeigen und setzen, Werte der zuletzt
// gesetzten Form nachträglich ändern, Auswahl als eigene Form speichern (Bibliothek: ShapeLibrary.swift).

extension SketchController {
    /// Formgenerator aktiv (Polygon-Ablauf mit einer Form der Bibliothek)
    var isGeneratingShape: Bool { tool == .polygon && generatedShape != nil }

    /// Kachel „Formen“ der linken Leiste: zuletzt benutzte Form wieder aufnehmen.
    func startShapeGenerator() {
        var shape = ShapeLibrary.shared.lastShape ?? .standard
        if let id = shape.customID, ShapeLibrary.shared.shape(id) == nil { shape = .standard }
        shape.placement = nil
        activate(shape)
    }

    /// Form der Bibliothek wählen (Zahl, Verhältnis und Drehung der Kachel, Größe bleibt).
    func chooseShape(_ preset: ShapePreset) {
        var shape = generatedShape ?? ShapeLibrary.shared.lastShape ?? .standard
        shape.choice = .builtIn(preset.kind)
        shape.presetID = preset.id
        shape.params.count = preset.count
        shape.params.inner = preset.inner
        shape.params.rotation = preset.rotation
        shape.placement = nil
        activate(shape)
    }

    /// Eigene Form wählen.
    func chooseCustomShape(_ id: UUID) {
        var shape = generatedShape ?? ShapeLibrary.shared.lastShape ?? .standard
        shape.choice = .custom(id)
        shape.presetID = nil
        shape.params.rotation = 0
        shape.placement = nil
        activate(shape)
    }

    private func activate(_ shape: GeneratedShape) {
        // Erst das Werkzeug (sein Wechsel setzt den Formgenerator zurück), dann die Form
        if tool != .polygon { tool = .polygon }
        generatedShape = shape
        ShapeLibrary.shared.lastShape = shape
    }

    /// Form mit Größe und Drehung aus dem Aufziehen (Mitte → Stift). Ohne Zug gelten die Werte rechts.
    private func generatedShapeFor(center: Point2, through: Point2?) -> GeneratedShape? {
        guard var shape = generatedShape else { return nil }
        if let through, simd_distance(center, through) > 1e-6 {
            shape.params.size = 2 * simd_distance(center, through)
            // Der Stift zeigt „oben“ der Form; die Grunddrehung der Kachel (Kreuz X) bleibt erhalten
            let base = ShapePreset.all.first { $0.id == shape.presetID }?.rotation ?? 0
            let angle = atan2(through.y - center.y, through.x - center.x) * 180 / .pi - 90 + base
            shape.params.rotation = Self.shapeDegrees(angle)
        }
        return shape
    }

    /// Winkel auf −180…180° und Hundertstel gerundet (glatte Werte im Feld).
    private static func shapeDegrees(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a <= -180 { a += 360 }
        return (a * 100).rounded() / 100
    }

    /// Vorschau beim Aufziehen.
    func generatedShapePreview(center: Point2, through: Point2) -> [SketchEntity] {
        guard let shape = generatedShapeFor(center: center, through: through) else { return [] }
        return ShapeGeometry.placed(shape, center: center)
    }

    /// Form setzen: gewöhnliche Linien, Bögen und Kreise (Konturen zum Extrudieren).
    func placeGeneratedShape(center: Point2, through: Point2?) {
        guard var shape = generatedShapeFor(center: center, through: through) else { return }
        let placed = ShapeGeometry.placed(shape, center: center)
        guard !placed.isEmpty else {
            notice = "Diese Form ist nicht mehr vorhanden – bitte eine andere wählen."
            return
        }
        let base = entities.count
        beginCommit()
        for entity in placed { appendCommitted(entity) }
        finishCommit(editable: nil)
        let range = base..<entities.count
        shape.placement = ShapePlacement(center: center, range: range, fingerprint: shapeFingerprint(range),
                                         constraintCount: constraints.count, undoRevision: undoRevision)
        generatedShape = shape
        var remembered = shape
        remembered.placement = nil
        ShapeLibrary.shared.lastShape = remembered
    }

    private func shapeFingerprint(_ range: Range<Int>) -> [Point2] {
        guard range.lowerBound >= 0, range.upperBound <= entities.count else { return [] }
        return entities[range].flatMap(\.handlePoints)
    }

    /// Zuletzt gesetzte Form ist unverändert das Ende der Skizze (nichts anderes geschah danach).
    var canEditPlacedShape: Bool {
        guard let placement = generatedShape?.placement else { return false }
        return placement.range.upperBound == entities.count && placement.constraintCount == constraints.count
            && placement.undoRevision == undoRevision
            && shapeFingerprint(placement.range) == placement.fingerprint
    }

    /// Werte rechts ändern; die zuletzt gesetzte Form wird dabei neu gezeichnet.
    func updateGeneratedShape(_ change: (inout ShapeParameters) -> Void) {
        guard var shape = generatedShape else { return }
        let editable = canEditPlacedShape
        let placement = shape.placement
        change(&shape.params)
        shape.placement = nil
        generatedShape = shape
        ShapeLibrary.shared.lastShape = shape
        guard editable, let placement else { return }
        // Stand vor dem Setzen wiederherstellen und mit den neuen Werten erneut setzen (ein Rückgängig-Schritt)
        revertCommit()
        placeGeneratedShape(center: placement.center, through: nil)
    }

    // MARK: Eigene Formen

    /// Gewählte Elemente (Text ausgenommen) für „Eigene Form speichern“.
    var shapeSaveCandidates: [SketchEntity] {
        selectedEntities.sorted().filter { entities.indices.contains($0) }.map { entities[$0] }
            .filter { if case .text = $0 { return false } else { return true } }
    }

    /// Auswahl als eigene Form in der Bibliothek speichern und gleich wählen.
    @discardableResult
    func saveSelectionAsShape(name: String) -> Bool {
        guard let saved = ShapeLibrary.shared.add(name: name, entities: shapeSaveCandidates) else {
            notice = "Keine Form gespeichert: erst mit dem Pfeil Linien, Bögen oder Kreise wählen."
            return false
        }
        notice = "Form „\(saved.name)“ gespeichert – zu finden unter „Eigene“."
        chooseCustomShape(saved.id)
        return true
    }

    /// Eigene Form löschen; war sie gewählt, gilt wieder die Standardform.
    func deleteCustomShape(_ id: UUID) {
        ShapeLibrary.shared.remove(id)
        if generatedShape?.customID == id { chooseShape(ShapePreset.all[4]) }
        if ShapeLibrary.shared.lastShape?.customID == id { ShapeLibrary.shared.lastShape = nil }
    }
}
