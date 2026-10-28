import SwiftUI
import simd

// Kai: „Wenn ich einen Volumenkörper verändere (z. B. eine Seite aufziehe), möchte ich in der rechten Spalte
// ‚Extrudieren‘, die Fläche, ‚Körper 1‘ und ‚Abstand‘ sehen, was ich gerade mache. Darunter die gesamte Länge:
// Würfel 20 × 20 × 20, ich extrudiere um 10 mm → Abstand 10 mm und darunter 30 mm.“
// Gesamtlänge = Ausdehnung des Ergebniskörpers in Zugrichtung (äußerste Netzpunkte entlang der Zugnormalen).
// Gerechnet wird nur auf dem angezeigten Netz (die Vorschau ist schon gerechnet): keine Booleans je Bild, gemerkt je
// Netzstand (ModelStore.revision).

@MainActor
enum ExtrudeInfo {
    /// Was das Panel über der Wertzeile zeigt.
    struct Summary {
        /// „Fläche 3“, „2 Flächen“, „Bereich · Skizze 1“
        var face: String
        /// „Körper 1“, „Körper 2 (neu)“, „Neuer Körper“
        var body: String
        /// Ausdehnung in Zugrichtung in mm; nil = noch nichts zu messen (z. B. freie Skizze ohne Abstand)
        var total: Double?
    }

    // MARK: Zusammenfassung

    /// Ebene Körperflächen (Press Pull) bzw. Skizzenbereiche; nil = noch nichts gewählt.
    static func summary(faces: [FaceRef], regions: [RegionRef], model: ModelStore) -> Summary? {
        if let first = regions.first {
            return regionSummary(regions, first: first, model: model)
        }
        guard let first = faces.first else { return nil }
        let faceText = faces.count == 1 ? "Fläche \(first.face)" : "\(faces.count) Flächen"
        let direction: SIMD3<Double>? = model.faceHandle?.direction ?? model.plane(of: first)?.normal
        let changed = changedBodies(model)
        // Ohne Vorschau (Abstand 0): Ausdehnung des Ausgangskörpers; die Körpernummern gelten dann im Netz
        let measured: Set<Int> = changed.isEmpty ? Set(faces.map(\.body)) : changed
        let names = bodyNames(Set(faces.map(\.body)).sorted(), in: model.bodies)
        let total = direction.flatMap { extent(model, bodies: measured, along: $0) }
        return Summary(face: faceText, body: names.isEmpty ? "Körper" : names, total: total)
    }

    private static func regionSummary(_ regions: [RegionRef], first: RegionRef, model: ModelStore) -> Summary? {
        guard model.sketches.indices.contains(first.sketch) else { return nil }
        let sketch = model.sketches[first.sketch]
        let faceText = regions.count == 1 ? "Bereich · \(sketch.name)" : "\(regions.count) Bereiche · \(sketch.name)"
        let direction = sketch.plane.normal
        let changed = changedBodies(model)
        if !changed.isEmpty {
            // Vorschau: die veränderten bzw. neuen Körper (Durchloch: Körper bleibt gleich lang)
            let shown = model.shownBodies
            let names = changed.sorted().compactMap { index -> String? in
                guard shown.indices.contains(index) else { return nil }
                // Neuer Körper: hinten angehängt
                let isNew = model.regionMode == .newBody && index >= model.bodies.count
                return isNew ? "\(shown[index].name) (neu)" : shown[index].name
            }
            return Summary(face: faceText, body: names.isEmpty ? "Körper" : names.joined(separator: ", "),
                           total: extent(model, bodies: changed, along: direction))
        }
        // Noch keine Vorschau: Skizze auf einer Körperfläche misst den Ausgangskörper, eine freie Skizze nichts
        if let source = sketch.plane.sourceBody, model.bodies.indices.contains(source) {
            return Summary(face: faceText, body: model.bodies[source].name,
                           total: extent(model, bodies: [source], along: direction))
        }
        return Summary(face: faceText, body: model.regionMode == .newBody || model.bodies.isEmpty ? "Neuer Körper" : "–",
                       total: nil)
    }

    private static func bodyNames(_ indices: [Int], in bodies: [SceneBody]) -> String {
        indices.compactMap { bodies.indices.contains($0) ? bodies[$0].name : nil }.joined(separator: ", ")
    }

    // MARK: Messen

    /// Körper, die die Vorschau verändert oder neu anlegt (Nummern in shownBodies = Nummern im Netz). Verglichen
    /// wird die Geometrie selbst: verschobene Nummern (Verbinden fasst zusammen) zählen nicht als verändert.
    static func changedBodies(_ model: ModelStore) -> Set<Int> {
        guard model.hasPreview else { return [] }
        let known = Set(model.bodies.map { ObjectIdentifier($0.shape) })
        var result: Set<Int> = []
        for (index, body) in model.shownBodies.enumerated() where !known.contains(ObjectIdentifier(body.shape)) {
            result.insert(index)
        }
        return result
    }

    private struct CacheKey: Equatable {
        var revision: Int
        var bodies: Set<Int>
        var axis: SIMD3<Double>
    }

    private static var cache: (key: CacheKey, value: Double?)?

    /// Abstand der äußersten Netzpunkte der Körper entlang der Richtung (mm, auf 1/1000 gerundet); nil = nichts
    /// sichtbar.
    static func extent(_ model: ModelStore, bodies: Set<Int>, along direction: SIMD3<Double>) -> Double? {
        guard !bodies.isEmpty, simd_length(direction) > 1e-12 else { return nil }
        let axis: SIMD3<Double> = simd_normalize(direction)
        let key = CacheKey(revision: model.revision, bodies: bodies, axis: axis)
        if let cache, cache.key == key { return cache.value }
        let mesh = model.mesh
        let floatAxis = SIMD3<Float>(axis)
        var low = Float.infinity
        var high = -Float.infinity
        let count = min(mesh.triangleFaces.count, mesh.indices.count / 3)
        for t in 0..<count where bodies.contains(mesh.triangleFaces[t].body) {
            for k in 0..<3 {
                let index = Int(mesh.indices[t * 3 + k])
                guard index < mesh.vertices.count else { continue }
                let d = simd_dot(mesh.vertices[index].position, floatAxis)
                low = min(low, d)
                high = max(high, d)
            }
        }
        let value: Double? = low <= high ? (Double(high - low) * 1000).rounded() / 1000 : nil
        cache = (key, value)
        return value
    }
}

// MARK: - Panelzeilen

/// „Fläche“ und „Körper“ über den Werten: was gerade gezogen wird (nur lesen).
struct ExtrudeInfoRows: View {
    let summary: ExtrudeInfo.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PanelInfoRow(title: "Fläche", value: summary.face, icon: "square.on.square")
            PanelInfoRow(title: "Körper", value: summary.body, icon: "cube")
        }
    }
}

/// Nur-Lese-Zeile: Beschriftung oben, Wert im gedämpften Feld (kein Eingabefeld).
struct PanelInfoRow: View {
    let title: String
    let value: String
    var icon: String?

    var body: some View {
        PaletteLabeled(title: title) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// „Gesamtlänge“ unter dem Abstand: Ergebnis, gedämpft, aber gut lesbar (live während des Ziehens).
struct ExtrudeTotalRow: View {
    let total: Double?

    private var text: String {
        total.map { LengthUnit.current.format($0) } ?? "–"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        PaletteLabeled(title: "Gesamtlänge") {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(text)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton - 4)
            .background(PaletteStyle.field.opacity(0.55), in: shape)
            .overlay {
                shape.strokeBorder(PaletteStyle.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .help("Ausdehnung des Körpers in Zugrichtung")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gesamtlänge")
        .accessibilityValue(text)
    }
}
