import Foundation
import simd

// Text in der Skizze als Einheit (Kai: „Wenn ich einen Text geschrieben habe, kann ich ihn nicht mehr anklicken
// und verschieben … Ich muss auf jeden Fall meine Schrift nochmal auswählen können mit dem Auswahlwerkzeug“).
// Ein Text ist ein einziges Skizzenelement (SketchEntity.text); seine Buchstabenumrisse werden bei jeder Änderung
// aus der Schrift neu erzeugt. Hier: Treffer, Ändern, Einträge im Browser „Ebenen“ und Textkörper.

extension SketchText {
    /// Gleicher Text mit geänderten Einstellungen, an derselben Stelle (der Anker bleibt).
    func with(string: String? = nil, height: Double? = nil, fontName: String? = nil,
              alignment: TextAlignmentOption? = nil, rotation: Double? = nil) -> SketchText {
        SketchText(string: string ?? self.string, anchor: anchor, height: height ?? self.height,
                   fontName: fontName ?? self.fontName, alignment: alignment ?? self.alignment,
                   rotation: rotation ?? self.rotation)
    }

    /// Kurzname für Browser und Körper: ohne Zeilenumbrüche, lange Texte gekürzt.
    var shortLabel: String {
        let flat = string.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > 24 else { return flat }
        return String(flat.prefix(23)) + "…"
    }

    /// Drehung in Grad (für die Textkarte).
    var rotationDegrees: Double { rotation * 180 / .pi }

    /// Punkt im System des Texts: Anker = Ursprung, Grundlinie = x-Achse.
    func local(_ p: Point2) -> Point2 {
        let d = p - anchor
        let c = cos(rotation), s = sin(rotation)
        let x: Double = c * d.x + s * d.y
        let y: Double = c * d.y - s * d.x
        return Point2(x, y)
    }

    /// Umgebendes Rechteck der Buchstaben im System des Texts (nil ohne Umrisse).
    var localBounds: (min: Point2, max: Point2)? {
        let points: [Point2] = loops.flatMap(\.polygon).map { local($0) }
        guard let first = points.first else { return nil }
        let lo = points.reduce(first) { simd_min($0, $1) }
        let hi = points.reduce(first) { simd_max($0, $1) }
        return (lo, hi)
    }

    /// Liegt p auf dem Text? Gezählt wird das (etwas vergrößerte) umgebende Rechteck, damit auch dünne Schrift
    /// und die Lücken zwischen den Buchstaben leicht zu treffen sind.
    func contains(_ p: Point2, tolerance: Double) -> Bool {
        guard let box = localBounds else { return false }
        let q = local(p)
        let margin = tolerance * 0.5
        let insideX = q.x >= box.min.x - margin && q.x <= box.max.x + margin
        let insideY = q.y >= box.min.y - margin && q.y <= box.max.y + margin
        return insideX && insideY
    }
}

// MARK: Skizze

extension SketchController {
    /// Text unter dem Finger bzw. Stift (zuletzt gezeichneter zuerst).
    func textIndex(at p: Point2, tolerance: Double) -> Int? {
        for index in entities.indices.reversed() {
            guard case .text(let text) = entities[index] else { continue }
            if text.contains(p, tolerance: tolerance) { return index }
        }
        return nil
    }

    /// Text an Stelle index (nil, wenn dort kein Text steht).
    func sketchText(at index: Int) -> SketchText? {
        guard entities.indices.contains(index), case .text(let text) = entities[index] else { return nil }
        return text
    }

    /// Der allein gewählte Text (für die Textkarte), sonst nil.
    var selectedTextIndex: Int? {
        let chosen = selectedEntities
        guard chosen.count == 1, let index = chosen.first, sketchText(at: index) != nil else { return nil }
        return index
    }

    /// Text ändern: Umrisse neu aus der Schrift erzeugen, an derselben Stelle.
    func updateText(at index: Int, _ change: (SketchText) -> SketchText) {
        guard let old = sketchText(at: index) else { return }
        let new = change(old)
        guard !new.string.trimmingCharacters(in: .whitespaces).isEmpty else {
            notice = "Ein Text braucht mindestens ein Zeichen – zum Entfernen „Löschen“ tippen."
            return
        }
        guard !new.loops.isEmpty else {
            notice = "Mit dieser Schrift entstehen keine Umrisse."
            return
        }
        replaceText(at: index, with: new)
    }
}

// MARK: Browser „Ebenen“

/// Ein Text der gespeicherten Skizze als Unterpunkt im Browser.
struct SketchTextItem: Identifiable {
    /// Index des Elements in der Skizze
    let entity: Int
    let text: SketchText
    let isConstruction: Bool

    var id: Int { entity }
}

extension SketchTextItem {
    /// Alle Texte der Elemente in Zeichenreihenfolge.
    static func items(_ entities: [SketchEntity], construction: Set<Int>) -> [SketchTextItem] {
        entities.indices.compactMap { index -> SketchTextItem? in
            guard case .text(let text) = entities[index] else { return nil }
            return SketchTextItem(entity: index, text: text, isConstruction: construction.contains(index))
        }
    }
}

extension StoredSketch {
    /// Alle Texte der gespeicherten Skizze in Zeichenreihenfolge.
    var textItems: [SketchTextItem] {
        SketchTextItem.items(entities, construction: construction)
    }

    /// Inhalt der Texte, aus denen alle gewählten Bereiche stammen (jede Außenkontur liegt auf Buchstabenumrissen);
    /// nil, sobald ein Bereich auch aus anderen Kurven besteht.
    func textContent(of chosen: [SketchRegion]) -> String? {
        guard !chosen.isEmpty else { return nil }
        var texts: [(text: SketchText, outlines: [TextOutline], tolerance: Double)] = []
        for index in entities.indices where !construction.contains(index) {
            guard case .text(let text) = entities[index] else { continue }
            let outlines: [TextOutline] = text.loops.compactMap { TextOutline($0.polygon) }
            // Abstand der Bogenpunkte zu den Sehnen der Umrisse wächst mit der Schrifthöhe
            let tolerance: Double = max(1e-3, text.height * 2e-3)
            texts.append((text, outlines, tolerance))
        }
        guard !texts.isEmpty else { return nil }
        var used: [Int] = []
        for region in chosen {
            let polygon = region.outer.polygon
            guard let match = texts.indices.first(where: { k in
                Self.outline(polygon, liesOn: texts[k].outlines, tolerance: texts[k].tolerance)
            }) else { return nil }
            if !used.contains(match) { used.append(match) }
        }
        let labels: [String] = used.sorted().map { texts[$0].text.shortLabel }
        return labels.joined(separator: " ")
    }

    /// Ob (bis zu 24 gleichmäßig verteilte) Punkte des Umrisses alle auf den Textumrissen liegen.
    private static func outline(_ polygon: [Point2], liesOn outlines: [TextOutline], tolerance: Double) -> Bool {
        guard !polygon.isEmpty else { return false }
        let step = max(polygon.count / 24, 1)
        for k in stride(from: 0, to: polygon.count, by: step) {
            let p = polygon[k]
            let near = outlines.contains { $0.passes(near: p, tolerance: tolerance) }
            if !near { return false }
        }
        return true
    }
}

/// Buchstabenumriss mit umgebendem Rechteck (schneller Vortest beim Erkennen von Textbereichen).
struct TextOutline {
    let points: [Point2]
    let lo: Point2
    let hi: Point2

    init?(_ points: [Point2]) {
        guard let first = points.first else { return nil }
        self.points = points
        lo = points.reduce(first) { simd_min($0, $1) }
        hi = points.reduce(first) { simd_max($0, $1) }
    }

    func passes(near p: Point2, tolerance: Double) -> Bool {
        let insideX = p.x >= lo.x - tolerance && p.x <= hi.x + tolerance
        let insideY = p.y >= lo.y - tolerance && p.y <= hi.y + tolerance
        guard insideX && insideY else { return false }
        return polylineDistance(from: p, to: points, closed: true).distance <= tolerance
    }
}

// MARK: Textkörper

extension ModelStore {
    /// Neue Körper aus reinen Textbereichen heißen „Text „ABC““ und zeigen im Browser das Textsymbol.
    /// Jeder Buchstabe bleibt wie jeder Bereich ein eigener Körper (dann nummeriert).
    func labelTextBodies(_ result: inout [SceneBody], regions: [SketchRegion], sketch: StoredSketch, mode: ExtrudeMode) {
        guard mode == .newBody, result.count > bodies.count, let content = sketch.textContent(of: regions) else { return }
        SceneBody.labelText(&result, from: bodies.count, content: content)
    }
}

extension SceneBody {
    /// Körper ab start (neu angehängt) als Textkörper benennen: „Text „ABC““, mehrere nummeriert.
    static func labelText(_ result: inout [SceneBody], from start: Int, content: String) {
        guard start >= 0, start < result.count else { return }
        let added = Array(start..<result.count)
        let base = "Text „\(content)“"
        for (k, index) in added.enumerated() {
            result[index].name = added.count == 1 ? base : "\(base) \(k + 1)"
            result[index].textLabel = content
        }
    }

    /// Name vom Programm vergeben („Körper 3“ bzw. „Text „ABC““, ggf. nummeriert), nicht vom Nutzer.
    var hasAutomaticName: Bool {
        if let textLabel { return name.hasPrefix("Text „\(textLabel)“") }
        return name.hasPrefix("Körper ")
    }

    /// Nach dem Nachbau des Verlaufs: Textbenennung des neu gerechneten Körpers übernehmen (Text wurde geändert).
    /// Ein selbst vergebener Name bleibt, nur die Kennung wird nachgezogen.
    func takingTextLabel(from rebuilt: SceneBody) -> SceneBody {
        guard rebuilt.textLabel != textLabel else { return self }
        var body = self
        if hasAutomaticName { body.name = rebuilt.name }
        body.textLabel = rebuilt.textLabel
        return body
    }

    /// Symbol im Browser: Textkörper, Komponente bzw. gewöhnlicher Körper.
    var browserSymbol: String {
        if textLabel != nil { return "textformat" }
        return componentID == nil ? "cube.fill" : "shippingbox.fill"
    }
}
