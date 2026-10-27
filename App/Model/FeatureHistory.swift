import Foundation
import simd

// Parametrischer Verlauf (Fahrplan Nr. 1, Vorbild Fusion 360/Onshape): Jeder Schritt, der Körper erzeugt oder
// ändert, wird als Feature mit seinen Werten aufgezeichnet (Extrudieren, Drehen, Grundkörper, Abrunden/Fase,
// Fläche ziehen, Schale, Boolesch, Verschieben/Drehen, Spiegeln, Muster, Löschen). Ändern sich eine Skizze, ein
// Maß, eine Variable oder ein Feature-Wert, rechnet der Nachbau ab dem betroffenen Feature alle folgenden neu.
//
// Pragmatische Lösung des Topologie-Namensproblems: Skizzenbereiche werden über einen Punkt im Bereich gefunden,
// Kanten über Mitte, Richtung ins Material und Länge, Flächen über Mitte, Normale und Größe – beim Nachbau gilt
// die nächstgelegene passende Kante bzw. Fläche. Schritte, die sich nicht nachbauen lassen (Direktmodellierung,
// Import, KI, Fläche versetzen …), werden als „fester Stand“ gespeichert (die geänderten Körper als STEP im Ordner
// features/), damit der Nachbau trotzdem durchläuft und ab dort mit dem gespeicherten Stand weitermacht.

// MARK: - Datenmodell

enum FeatureKind: String, Codable, CaseIterable {
    /// Fester Stand: Körper zum Zeitpunkt einer nicht nachbaubaren Änderung (bzw. Ausgangsstand alter Projekte)
    case snapshot
    case extrude
    case revolve
    case primitive
    case fillet
    case chamfer
    /// Ebene Fläche(n) eines Körpers ziehen
    case faceExtrude
    case shell
    case boolean
    case move
    case rotate
    case mirror
    case pattern
    case delete

    var systemImage: String {
        switch self {
        case .snapshot: "cube.transparent"
        case .extrude: "square.stack.3d.up"
        case .revolve: "arrow.triangle.2.circlepath"
        case .primitive: "cube"
        case .fillet: "app"
        case .chamfer: "octagon"
        case .faceExtrude: "arrow.up.and.down.square"
        case .shell: "shippingbox"
        case .boolean: "square.on.square.dashed"
        case .move: "move.3d"
        case .rotate: "rotate.3d"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .pattern: "square.grid.3x1.below.line.grid.1x2"
        case .delete: "trash"
        }
    }
}

/// Art eines Feature-Werts: bestimmt Einheit und wie eine Formel ausgerechnet wird.
enum FeatureUnit: String, Codable {
    /// mm; Zahlen in Formeln zählen in der Projekteinheit
    case length
    /// Grad
    case angle
    /// Anzahl (ganzzahlig)
    case count

    func evaluate(_ text: String, variables: [String: Double]) throws -> Double {
        switch self {
        case .length:
            return try Formula.evaluateLength(text, variables: variables)
        case .angle:
            return try Formula.evaluate(text, variables: variables)
        case .count:
            let value = try Formula.evaluate(text, variables: variables)
            return value.rounded()
        }
    }
}

/// Änderbarer Wert eines Features; formula (z. B. „wand * 2“) lässt ihn Variablen folgen.
struct FeatureParameter: Codable, Identifiable, Hashable {
    var key: String
    var title: String
    var value: Double
    var unit: FeatureUnit
    var formula: String?

    var id: String { key }

    static func length(_ key: String, _ title: String, _ value: Double) -> FeatureParameter {
        FeatureParameter(key: key, title: title, value: value, unit: .length)
    }

    static func angle(_ key: String, _ title: String, _ value: Double) -> FeatureParameter {
        FeatureParameter(key: key, title: title, value: value, unit: .angle)
    }

    static func count(_ key: String, _ title: String, _ value: Int) -> FeatureParameter {
        FeatureParameter(key: key, title: title, value: Double(value), unit: .count)
    }
}

/// Skizzenbereich als Punkt im Bereich (lokale Skizzenkoordinaten) statt als Index; Index und Anzahl der
/// Bereiche dienen als Rückfall, wenn der Punkt nach einer Änderung in keinem Bereich mehr liegt.
struct RegionProbe: Codable, Hashable {
    var sketchID: UUID
    var point: SIMD2<Double>
    var index: Int
    var regionCount: Int
}

/// Kante als geometrische Signatur: Mitte, Richtung ins Material (Winkelhalbierende) und Länge.
struct EdgeSignature: Codable, Hashable {
    var body: Int
    var midpoint: SIMD3<Double>
    var direction: SIMD3<Double>
    var length: Double
}

/// Fläche als geometrische Signatur: Mitte, mittlere Normale (0 bei rundum gekrümmten Flächen) und Größe.
struct FaceSignature: Codable, Hashable {
    var body: Int
    var center: SIMD3<Double>
    var normal: SIMD3<Double>
    var area: Double
}

/// Darstellung eines gespeicherten Körpers (wie bodies.json).
struct SnapshotBodyMeta: Codable, Hashable {
    var name: String
    var color: [Float]
    var isHidden: Bool
    var sketchID: UUID?
    var folder: String?
    var componentID: UUID?
    var placement: [Double]?
    /// Material (Materials.swift); fehlt in älteren Ständen
    var material: String? = nil
    /// Gewinde (ThreadNotes.swift); fehlt in älteren Ständen
    var threads: [ThreadNote]? = nil
    /// Oberfläche (SurfaceFinish.swift); fehlt in älteren Ständen
    var finish: String? = nil
    /// Inhalt des Texts bei Textkörpern (SketchTextEdit.swift); fehlt in älteren Ständen
    var textLabel: String? = nil
}

/// Fester Stand: full = alle Körper, sonst nur die geänderten (changed, in dieser Reihenfolge) und die neuen.
struct SnapshotInfo: Codable, Hashable {
    var full: Bool
    var changed: [Int] = []
    var metas: [SnapshotBodyMeta] = []
}

/// Eingaben eines Features (je nach Art belegt).
struct FeatureData: Codable {
    /// ExtrudeMode, BooleanKind bzw. Musterart („linear“/„kreis“) als Rohwert
    var mode: String?
    var direction: String?
    var thinSide: String?
    var thin: Bool?
    var throughHoles: Bool?
    /// Skizze lag beim Aufzeichnen auf einer Körperfläche (Richtung beim Abziehen)
    var onFace: Bool?
    var regions: [RegionProbe]?
    /// Kopien gelöschter Skizzen, damit der Nachbau auch ohne sie gelingt
    var sketchCopies: [StoredSketch]?
    var edges: [EdgeSignature]?
    var faces: [FaceSignature]?
    /// Ziel-Körper (Index)
    var target: Int?
    /// Betroffene Körper (Indizes)
    var bodies: [Int]?
    var tools: [Int]?
    var keepTools: Bool?
    var primitive: String?
    /// Punkt: Einfügepunkt, Achsursprung bzw. Ebenenpunkt
    var origin: SIMD3<Double>?
    /// Richtung: Achse bzw. Normale
    var axis: SIMD3<Double>?
    var axis2: SIMD3<Double>?
    /// Je Körper: Drehmitte bzw. Spiegelpunkt
    var points: [SIMD3<Double>]?
    var copies: Bool?
    var divides: Bool?
    var closed: Bool?
    var snapshot: SnapshotInfo?
    /// Neuer Körper: jeder Skizzenbereich ein eigener Körper (separatedParts). Fehlt in älteren Ständen: dort wurden
    /// angrenzende Bereiche zusammengefasst und berührende Teile verschmolzen – beim Nachbau ebenso, damit die
    /// Körpernummern späterer Schritte stimmen.
    var separateParts: Bool?
}

/// Ein Schritt im parametrischen Verlauf.
struct Feature: Codable, Identifiable {
    var id = UUID()
    var name: String
    var kind: FeatureKind
    var parameters: [FeatureParameter] = []
    var data = FeatureData()
    /// Unterdrückt: beim Nachbau übersprungen (ausgegraut in der Zeitleiste)
    var isSuppressed = false
    /// Beim letzten Nachbau fehlgeschlagen (rot in der Zeitleiste) und übersprungen
    var failed = false
    /// Grund des Fehlschlags
    var problem: String?

    init(name: String, kind: FeatureKind) {
        self.name = name
        self.kind = kind
    }

    var systemImage: String {
        if kind == .primitive, let primitive = data.primitive.flatMap(Primitive.init(rawValue:)) {
            return primitive.systemImage
        }
        if kind == .boolean, let boolean = data.mode.flatMap(BooleanKind.init(rawValue:)) {
            return boolean.systemImage
        }
        if kind == .pattern, data.mode == "kreis" { return "circle.grid.cross" }
        return kind.systemImage
    }

    func value(_ key: String) -> Double? {
        parameters.first { $0.key == key }?.value
    }

    var usesFormulas: Bool { parameters.contains { $0.formula != nil } }
}

struct FeatureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Aufzeichnung, die erst beim Übernehmen vervollständigt wird (Bereiche, Kanten, Flächen → Signaturen).
struct PendingFeature {
    var feature: Feature
    var regions: [RegionRef] = []
    var edges: [EdgeRef] = []
    var faces: [FaceRef] = []
}

/// Zustand des Verlaufs, der nicht veröffentlicht wird (ModelStore.featureRecorder).
final class FeatureRecorder {
    /// Feature der offenen Vorschau (wird mit commitPreview übernommen)
    var preview: PendingFeature?
    /// Feature des nächsten commit
    var pending: PendingFeature?
    /// Nachbau: neue Feature-Liste für den nächsten commit
    var replacement: [Feature]?
    /// Körper nach jedem Feature (nur im Speicher; beschleunigt den Nachbau)
    var cache: [UUID: [SceneBody]] = [:]
    /// Körper der festen Stände (aus features/<id>.step nachgeladen)
    var snapshots: [UUID: [SceneBody]] = [:]
}

/// Inhalt von features.json.
private struct FeatureFile: Codable {
    var features: [Feature]
    var bodyCount: Int
}

/// Bereich samt Skizze (beim Nachbau aufgelöst).
private struct ResolvedRegion {
    var region: SketchRegion
    var sketch: StoredSketch
}

/// Mitte, mittlere Normale und Größe einer Fläche (aus dem Anzeigenetz).
private struct FaceStats {
    var center: SIMD3<Double>
    var normal: SIMD3<Double>
    var area: Double
}

// MARK: - Aufzeichnen

extension ModelStore {
    /// Gewählte Skizzenbereiche extrudiert (Vorschau).
    func noteExtrude(mode: ExtrudeMode, distance: Double) {
        guard let first = selectedRegions.first, sketches.indices.contains(first.sketch) else { return }
        let plane = sketches[first.sketch].plane
        let name = mode == .newBody ? "Extrudieren" : "Extrudieren (\(mode.rawValue))"
        var feature = Feature(name: name, kind: .extrude)
        feature.parameters.append(.length("distance", "Abstand", distance))
        if regionDirection == .twoSides {
            feature.parameters.append(.length("second", "Zweite Seite", regionSecondValue))
        }
        if regionTaper != 0 {
            feature.parameters.append(.angle("taper", "Verjüngung", regionTaper))
        }
        if regionThin {
            feature.parameters.append(.length("thickness", "Wandstärke", regionThinThickness))
        }
        feature.data.mode = mode.rawValue
        feature.data.direction = regionDirection.rawValue
        feature.data.thin = regionThin
        feature.data.thinSide = regionThinSide.rawValue
        feature.data.throughHoles = regionThroughHoles
        feature.data.onFace = plane.isOnFace
        feature.data.target = unionTarget(plane.sourceBody)
        feature.data.separateParts = true
        featureRecorder.preview = PendingFeature(feature: feature, regions: selectedRegions)
    }

    /// Bereiche um eine Achse gedreht (Vorschau).
    func noteRevolve(axisOrigin: SIMD3<Double>, axis: SIMD3<Double>, degrees: Double, mode: ExtrudeMode) {
        guard hasPreview, let first = selectedRegions.first, sketches.indices.contains(first.sketch) else { return }
        let name = mode == .newBody ? "Drehen" : "Drehen (\(mode.rawValue))"
        var feature = Feature(name: name, kind: .revolve)
        feature.parameters.append(.angle("angle", "Winkel", degrees))
        feature.data.mode = mode.rawValue
        feature.data.origin = axisOrigin
        feature.data.axis = axis
        feature.data.target = unionTarget(sketches[first.sketch].plane.sourceBody)
        feature.data.separateParts = true
        featureRecorder.preview = PendingFeature(feature: feature, regions: selectedRegions)
    }

    /// Grundkörper eingefügt (Vorschau).
    func notePrimitive(_ primitive: Primitive, size: SIMD3<Double>, base: SIMD3<Double>) {
        var feature = Feature(name: primitive.rawValue, kind: .primitive)
        switch primitive {
        case .box:
            feature.parameters = [.length("x", "Breite", size.x), .length("y", "Tiefe", size.y), .length("z", "Höhe", size.z)]
        case .cylinder, .cone:
            feature.parameters = [.length("x", "Durchmesser", size.x), .length("z", "Höhe", size.z)]
        case .sphere:
            feature.parameters = [.length("x", "Durchmesser", size.x)]
        case .torus:
            feature.parameters = [.length("x", "Durchmesser", size.x), .length("z", "Rohr-Ø", size.z)]
        }
        feature.data.primitive = primitive.rawValue
        feature.data.origin = base
        featureRecorder.preview = PendingFeature(feature: feature)
    }

    /// Kanten abgerundet bzw. gefast (Vorschau). value = tatsächlich verwendeter Wert.
    func noteBlend(_ operation: EdgeOperation, value: Double, second: Double? = nil, end: Double? = nil) {
        guard let body = selectedEdges.first?.body else { return }
        var feature: Feature
        if operation == .fillet {
            feature = Feature(name: end == nil ? "Abrunden" : "Variabel abrunden", kind: .fillet)
            feature.parameters.append(.length("radius", end == nil ? "Radius" : "Anfangsradius", value))
            if let end { feature.parameters.append(.length("end", "Endradius", end)) }
        } else {
            feature = Feature(name: "Fase", kind: .chamfer)
            feature.parameters.append(.length("distance", "Abstand", value))
            if let second { feature.parameters.append(.length("second", "Zweiter Abstand", second)) }
        }
        feature.data.target = body
        featureRecorder.preview = PendingFeature(feature: feature, edges: selectedEdges.filter { $0.body == body })
    }

    /// Ebene Flächen gezogen (Vorschau).
    func noteFaceExtrude(distance: Double) {
        let faces = selectedFaces.filter { bodies.indices.contains($0.body) }
        guard !faces.isEmpty else { return }
        var feature = Feature(name: faces.count > 1 ? "Flächen ziehen" : "Fläche ziehen", kind: .faceExtrude)
        feature.parameters.append(.length("distance", "Abstand", distance))
        featureRecorder.preview = PendingFeature(feature: feature, faces: faces)
    }

    /// Schale (Vorschau).
    func noteShell(thickness: Double, closed: Bool) {
        guard let face = selection else { return }
        var feature = Feature(name: "Schale", kind: .shell)
        feature.parameters.append(.length("thickness", "Wandstärke", thickness))
        feature.data.target = face.body
        feature.data.closed = closed
        let faces = closed ? [] : selectedFaces.filter { $0.body == face.body }
        featureRecorder.preview = PendingFeature(feature: feature, faces: faces)
    }

    /// Boolesche Operation (direkt übernommen).
    func noteBoolean(_ kind: BooleanKind, target: Int, tools: [Int], keepTools: Bool, clearance: Double = 0) {
        var feature = Feature(name: kind.rawValue, kind: .boolean)
        if kind == .subtract, clearance > 0 {
            // Spiel beim Abziehen (MoldTools.swift): in der Zeitleiste änderbar
            feature.parameters.append(.length("clearance", "Spiel", clearance))
        }
        feature.data.mode = kind.rawValue
        feature.data.target = target
        feature.data.tools = tools
        feature.data.keepTools = keepTools
        featureRecorder.pending = PendingFeature(feature: feature)
    }

    /// Körper gelöscht (direkt übernommen).
    func noteDelete(_ indices: [Int]) {
        var feature = Feature(name: indices.count == 1 ? "Löschen" : "\(indices.count) Körper löschen", kind: .delete)
        feature.data.bodies = indices
        featureRecorder.pending = PendingFeature(feature: feature)
    }

    /// Gewählte Körper verschoben bzw. als Reihe kopiert (Vorschau).
    func noteMove(offset: SIMD3<Double>, copies: Bool, count: Int, divides: Bool) {
        let name = count > 1 ? "Reihe kopieren" : copies ? "Kopieren" : "Verschieben"
        var feature = Feature(name: name, kind: .move)
        feature.parameters = [.length("x", "X", offset.x), .length("y", "Y", offset.y), .length("z", "Z", offset.z)]
        if copies { feature.parameters.append(.count("count", "Anzahl", count)) }
        feature.data.bodies = selectedBodies
        feature.data.copies = copies
        feature.data.divides = divides
        featureRecorder.preview = PendingFeature(feature: feature)
    }

    /// Körper gedreht: centers je Körper (direct = sofort übernommen statt Vorschau).
    func noteRotate(_ indices: [Int], centers: [SIMD3<Double>], axis: SIMD3<Double>, degrees: Double, copies: Bool,
                    direct: Bool) {
        var feature = Feature(name: copies ? "Gedreht kopieren" : "Drehen", kind: .rotate)
        feature.parameters.append(.angle("angle", "Winkel", degrees))
        feature.data.bodies = indices
        feature.data.points = centers
        feature.data.axis = axis
        feature.data.copies = copies
        if direct {
            featureRecorder.pending = PendingFeature(feature: feature)
        } else {
            featureRecorder.preview = PendingFeature(feature: feature)
        }
    }

    /// Gespiegelt (Vorschau). Die Spiegelpunkte sind die Körpermitten bzw. der Punkt der Bezugsebene.
    func noteMirror(_ plane: MirrorPlane, keepOriginal: Bool, fixed: (origin: SIMD3<Double>, normal: SIMD3<Double>)?) {
        let indices = selectedBodies.filter { bodies.indices.contains($0) }
        var points: [SIMD3<Double>] = []
        for index in indices {
            // Spiegeln an einer achsparallelen Ebene durch die Mitte lässt den Hüllquader gleich
            let point = fixed?.origin ?? center(ofBody: index) ?? SIMD3<Double>(0, 0, 0)
            points.append(point)
        }
        var feature = Feature(name: "Spiegeln", kind: .mirror)
        feature.data.bodies = indices
        feature.data.points = points
        feature.data.axis = fixed?.normal ?? plane.normal
        feature.data.copies = keepOriginal
        featureRecorder.preview = PendingFeature(feature: feature)
    }

    /// Rechteckmuster (Vorschau).
    func noteLinearPattern(count: Int, spacing: Double, direction: SIMD3<Double>, count2: Int, spacing2: Double,
                           direction2: SIMD3<Double>) {
        var feature = Feature(name: "Muster linear", kind: .pattern)
        feature.parameters = [.count("count", "Anzahl", count), .length("spacing", "Abstand", spacing)]
        if count2 > 1 {
            feature.parameters.append(.count("count2", "Anzahl 2", count2))
            feature.parameters.append(.length("spacing2", "Abstand 2", spacing2))
        }
        feature.data.mode = "linear"
        feature.data.bodies = selectedBodies
        feature.data.axis = direction
        feature.data.axis2 = direction2
        featureRecorder.preview = PendingFeature(feature: feature)
    }

    /// Kreismuster (Vorschau).
    func noteCircularPattern(count: Int, angle: Double, axisOrigin: SIMD3<Double>, axis: SIMD3<Double>) {
        var feature = Feature(name: "Muster kreisförmig", kind: .pattern)
        feature.parameters = [.count("count", "Anzahl", count), .angle("angle", "Winkel", angle)]
        feature.data.mode = "kreis"
        feature.data.bodies = selectedBodies
        feature.data.origin = axisOrigin
        feature.data.axis = axis
        featureRecorder.preview = PendingFeature(feature: feature)
    }

    /// commitPreview: das Feature der Vorschau wird mit dem folgenden commit aufgezeichnet.
    func takePreviewFeature() {
        featureRecorder.pending = featureRecorder.preview
        featureRecorder.preview = nil
    }

    /// Skizze wird gelöscht: Features, die sie verwenden, behalten eine Kopie (Nachbau bleibt möglich).
    func embedSketchCopy(_ sketch: StoredSketch) {
        var list = features
        var changed = false
        for index in list.indices {
            let uses = (list[index].data.regions ?? []).contains { $0.sketchID == sketch.id }
            guard uses else { continue }
            var copies = list[index].data.sketchCopies ?? []
            copies.removeAll { $0.id == sketch.id }
            copies.append(sketch)
            list[index].data.sketchCopies = copies
            changed = true
        }
        if changed { features = list }
    }

    /// Ziel beim Vereinigen wie extrusionResult: Körper der Skizzenfläche, sonst der zuletzt erzeugte.
    private func unionTarget(_ sourceBody: Int?) -> Int? {
        if let sourceBody, bodies.indices.contains(sourceBody) { return sourceBody }
        return bodies.indices.last
    }

    /// Haken in commit: Feature anhängen, Liste des Nachbaus übernehmen oder einen festen Stand speichern.
    /// previous = Körper vor dem Schritt.
    func recordFeature(name: String, previous: [SceneBody]) {
        let recorder = featureRecorder
        defer {
            recorder.pending = nil
            recorder.replacement = nil
        }
        if let replacement = recorder.replacement {
            features = replacement
            return
        }
        if let pending = recorder.pending {
            var feature = pending.feature
            completeSignatures(&feature, pending: pending, previous: previous)
            features.append(feature)
            recorder.cache[feature.id] = bodies
            trimFeatureCache()
            return
        }
        var sameShapes = previous.count == bodies.count
        if sameShapes {
            for index in bodies.indices where previous[index].shape !== bodies[index].shape {
                sameShapes = false
                break
            }
        }
        if sameShapes {
            // Nur Skizzen, Farbe, Ordner … geändert: kein Feature
            if let last = features.last { recorder.cache[last.id] = bodies }
            return
        }
        if bodies.isEmpty, sketches.isEmpty {
            // „Alles löschen“: neuer Anfang
            features = []
            recorder.cache = [:]
            return
        }
        appendSnapshot(name: name, previous: previous)
    }

    /// Fester Stand: nur die geänderten und neuen Körper, bei weniger Körpern alle.
    private func appendSnapshot(name: String, previous: [SceneBody]) {
        let current = bodies
        var info = SnapshotInfo(full: true)
        var stored: [SceneBody] = current
        if current.count >= previous.count, !previous.isEmpty {
            var changed: [Int] = []
            for index in previous.indices where previous[index].shape !== current[index].shape {
                changed.append(index)
            }
            if changed.count < previous.count {
                let replaced: [SceneBody] = changed.map { current[$0] }
                let added: [SceneBody] = Array(current[previous.count...])
                info = SnapshotInfo(full: false, changed: changed)
                stored = replaced + added
            }
        }
        info.metas = stored.map { Self.snapshotMeta($0) }
        var feature = Feature(name: name, kind: .snapshot)
        feature.data.snapshot = info
        featureRecorder.snapshots[feature.id] = stored
        features.append(feature)
        featureRecorder.cache[feature.id] = current
        trimFeatureCache()
    }

    /// Bereiche → Punkte im Bereich, Kanten und Flächen → Signaturen (am Körper vor dem Schritt).
    private func completeSignatures(_ feature: inout Feature, pending: PendingFeature, previous: [SceneBody]) {
        if !pending.regions.isEmpty {
            feature.data.regions = pending.regions.compactMap { probe(for: $0) }
        }
        if !pending.edges.isEmpty {
            var signatures: [EdgeSignature] = []
            for ref in pending.edges where previous.indices.contains(ref.body) {
                if let signature = Self.edgeSignature(previous[ref.body].shape, edge: ref.edge, body: ref.body) {
                    signatures.append(signature)
                }
            }
            feature.data.edges = signatures
        }
        if !pending.faces.isEmpty {
            var tables: [Int: [Int: FaceStats]] = [:]
            var signatures: [FaceSignature] = []
            for ref in pending.faces where previous.indices.contains(ref.body) {
                let table = tables[ref.body] ?? Self.faceTable(previous[ref.body].shape)
                tables[ref.body] = table
                if let stats = table[ref.face] {
                    signatures.append(FaceSignature(body: ref.body, center: stats.center, normal: stats.normal, area: stats.area))
                }
            }
            feature.data.faces = signatures
        }
    }

    /// Punkt, der sicher im Bereich liegt: Polygonmitte oder Mitte eines seiner größten Dreiecke.
    private func probe(for ref: RegionRef) -> RegionProbe? {
        guard sketches.indices.contains(ref.sketch) else { return nil }
        let sketch = sketches[ref.sketch]
        guard sketch.regions.indices.contains(ref.region) else { return nil }
        let polygon = sketch.regions[ref.region].polygon
        var candidates: [Point2] = []
        if !polygon.isEmpty {
            let sum = polygon.reduce(Point2.zero, +)
            candidates.append(sum / Double(polygon.count))
        }
        if sketch.fills.indices.contains(ref.region) {
            let triangles = sketch.fills[ref.region]
            var inner: [(point: Point2, area: Double)] = []
            var t = 0
            while t + 2 < triangles.count {
                let a = sketch.plane.local(SIMD3<Double>(triangles[t]))
                let b = sketch.plane.local(SIMD3<Double>(triangles[t + 1]))
                let c = sketch.plane.local(SIMD3<Double>(triangles[t + 2]))
                let ab = b - a
                let ac = c - a
                let cross = ab.x * ac.y - ac.x * ab.y
                let middle = (a + b + c) / 3
                inner.append((middle, abs(cross) / 2))
                t += 3
            }
            inner.sort { $0.area > $1.area }
            for entry in inner.prefix(12) { candidates.append(entry.point) }
        }
        let inside = candidates.first { sketch.region(containing: $0) == ref.region }
        let point = inside ?? candidates.first ?? Point2.zero
        return RegionProbe(sketchID: sketch.id, point: point, index: ref.region, regionCount: sketch.regions.count)
    }

    private func trimFeatureCache() {
        let recorder = featureRecorder
        guard recorder.cache.count > 80 else { return }
        // Älteste Zwischenstände verwerfen (der Nachbau rechnet sie bei Bedarf neu)
        let keep = Set(features.suffix(40).map(\.id))
        recorder.cache = recorder.cache.filter { keep.contains($0.key) }
    }

    /// Undo/Redo: Zwischenstände passen nicht mehr; der Stand nach dem letzten Feature sind die Körper.
    func featuresRestored() {
        featureRecorder.cache = [:]
        featureRecorder.preview = nil
        if let last = features.last { featureRecorder.cache[last.id] = bodies }
    }
}

// MARK: - Nachbau

extension ModelStore {
    /// Skizzen bzw. Variablen geändert: abhängige Features nachbauen (ein Undo-Schritt). changed = geänderte
    /// Skizzen. false = nichts zu tun (keine neuen Skizzen und kein abhängiges Feature).
    @discardableResult
    func rebuildFeatures(sketches newSketches: [StoredSketch]?, changed ids: Set<UUID>, name: String) -> Bool {
        let values = variableValues
        let list = features
        let affected = list.indices.first { index in
            let feature = list[index]
            guard !feature.isSuppressed else { return false }
            return Self.usesSketch(feature, ids) || Self.formulasChanged(feature, values: values)
        }
        guard let start = affected, PCKShape.kernelAvailable else {
            guard let newSketches else { return false }
            commit(bodies, sketches: newSketches, name: name)
            return true
        }
        replayFeatures(from: start, features: list, sketches: newSketches, name: name)
        return true
    }

    /// Wert(e) eines Features ändern und ab dort nachbauen.
    func updateFeature(_ id: UUID, parameters: [FeatureParameter]) {
        commitPreview()
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        var list = features
        list[index].parameters = parameters
        replayFeatures(from: index, features: list, sketches: nil, name: "„\(list[index].name)“ ändern")
    }

    /// Feature unterdrücken bzw. wieder aktivieren (mit Nachbau).
    func setFeatureSuppressed(_ suppressed: Bool, id: UUID) {
        commitPreview()
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        var list = features
        list[index].isSuppressed = suppressed
        let verb = suppressed ? "unterdrücken" : "aktivieren"
        replayFeatures(from: index, features: list, sketches: nil, name: "„\(list[index].name)“ \(verb)")
    }

    /// Feature aus dem Verlauf löschen (mit Nachbau).
    func deleteFeature(_ id: UUID) {
        commitPreview()
        guard let index = features.firstIndex(where: { $0.id == id }) else { return }
        var list = features
        let removed = list.remove(at: index)
        replayFeatures(from: index, features: list, sketches: nil, name: "„\(removed.name)“ aus Verlauf löschen")
    }

    /// Alle Features ab start neu rechnen und das Ergebnis als ein Schritt übernehmen.
    func replayFeatures(from start: Int, features input: [Feature], sketches newSketches: [StoredSketch]?, name: String) {
        guard PCKShape.kernelAvailable else {
            if let newSketches { commit(bodies, sketches: newSketches, name: name) }
            message = "Der Nachbau des Verlaufs braucht OpenCASCADE (siehe README)."
            return
        }
        var list = input
        let sketchList = newSketches ?? sketches
        guard let run = runFeatures(&list, from: start, sketches: sketchList, values: variableValues) else {
            if let newSketches { commit(bodies, sketches: newSketches, name: name) }
            message = "Nachbau nicht möglich: ein gespeicherter Zwischenstand fehlt."
            return
        }
        var result = run.bodies
        if result.count == bodies.count {
            // Name, Farbe, Sichtbarkeit, Ordner … der Körper bleiben, nur die Geometrie ist neu
            for index in result.indices {
                var body = bodies[index]
                body.shape = result[index].shape
                body.sketchID = result[index].sketchID
                body.componentID = result[index].componentID
                body.placement = result[index].placement
                // Text nach dem Extrudieren geändert: Textkörper neu benennen (SketchTextEdit.swift)
                body = body.takingTextLabel(from: result[index])
                result[index] = body
            }
        }
        featureRecorder.replacement = list
        commit(result, sketches: newSketches, name: name)
        if let note = run.note { message = note }
    }

    /// Rechnet list ab start (bzw. ab dem nächsten bekannten Zwischenstand davor) und markiert Fehlschläge.
    /// nil = ein nötiger fester Stand fehlt.
    private func runFeatures(_ list: inout [Feature], from start: Int, sketches sketchList: [StoredSketch],
                             values: [String: Double]) -> (bodies: [SceneBody], note: String?)? {
        let recorder = featureRecorder
        var state: [SceneBody] = []
        var begin = 0
        var k = min(start, list.count) - 1
        while k >= 0 {
            let feature = list[k]
            if let cached = recorder.cache[feature.id] {
                state = cached
                begin = k + 1
                break
            }
            if feature.kind == .snapshot, !feature.isSuppressed, feature.data.snapshot?.full == true {
                guard let stored = snapshotBodies(feature) else { return nil }
                state = stored
                begin = k + 1
                break
            }
            k -= 1
        }
        var failures: [String] = []
        var fixedStand: String?
        var index = begin
        while index < list.count {
            if list[index].isSuppressed {
                list[index].failed = false
                list[index].problem = nil
            } else {
                do {
                    state = try applyFeature(&list[index], to: state, sketches: sketchList, values: values)
                    list[index].failed = false
                    list[index].problem = nil
                    if index > start, fixedStand == nil, list[index].kind == .snapshot {
                        fixedStand = list[index].name
                    }
                } catch {
                    list[index].failed = true
                    list[index].problem = error.localizedDescription
                    failures.append(list[index].name)
                }
            }
            recorder.cache[list[index].id] = state
            index += 1
        }
        var note: String?
        if !failures.isEmpty {
            let names = failures.prefix(3).map { "„\($0)“" }.joined(separator: ", ")
            let more = failures.count > 3 ? " und \(failures.count - 3) weitere" : ""
            note = "Nachbau: \(names)\(more) fehlgeschlagen – übersprungen (rot in der Zeitleiste)."
        } else if let fixedStand {
            note = "Ab „\(fixedStand)“ gilt ein fester Stand (direkte Änderung); davor geänderte Körper werden dort "
                + "nicht weitergeführt."
        }
        return (state, note)
    }

    /// Ein Feature auf die Körper anwenden (Formeln vorher neu ausrechnen).
    private func applyFeature(_ feature: inout Feature, to state: [SceneBody], sketches list: [StoredSketch],
                              values: [String: Double]) throws -> [SceneBody] {
        try Self.evaluateFormulas(&feature, values: values)
        switch feature.kind {
        case .snapshot: return try replaySnapshot(feature, state)
        case .extrude: return try replayExtrude(feature, state, list)
        case .revolve: return try replayRevolve(feature, state, list)
        case .primitive: return try Self.replayPrimitive(feature, state)
        case .fillet, .chamfer: return try Self.replayBlend(feature, state)
        case .faceExtrude: return try Self.replayFaceExtrude(feature, state)
        case .shell: return try Self.replayShell(feature, state)
        case .boolean: return try Self.replayBoolean(feature, state)
        case .move: return try Self.replayMove(feature, state)
        case .rotate: return try Self.replayRotate(feature, state)
        case .mirror: return try Self.replayMirror(feature, state)
        case .pattern: return try Self.replayPattern(feature, state)
        case .delete: return Self.replayDelete(feature, state)
        }
    }

    private static func evaluateFormulas(_ feature: inout Feature, values: [String: Double]) throws {
        for index in feature.parameters.indices {
            guard let formula = feature.parameters[index].formula else { continue }
            do {
                feature.parameters[index].value = try feature.parameters[index].unit.evaluate(formula, variables: values)
            } catch {
                throw FeatureError("Formel „\(formula)“: \(error.localizedDescription)")
            }
        }
    }

    private static func usesSketch(_ feature: Feature, _ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return false }
        return (feature.data.regions ?? []).contains { ids.contains($0.sketchID) }
    }

    /// Ergibt eine Formel des Features jetzt einen anderen Wert (oder einen Fehler)?
    private static func formulasChanged(_ feature: Feature, values: [String: Double]) -> Bool {
        for parameter in feature.parameters {
            guard let formula = parameter.formula else { continue }
            guard let value = try? parameter.unit.evaluate(formula, variables: values) else { return true }
            if abs(value - parameter.value) > 1e-9 { return true }
        }
        return false
    }

    // MARK: Skizzenbereiche

    private func resolvedRegions(_ feature: Feature, sketches list: [StoredSketch]) throws -> [ResolvedRegion] {
        var result: [ResolvedRegion] = []
        for probe in feature.data.regions ?? [] {
            let live = list.first { $0.id == probe.sketchID }
            let copy = feature.data.sketchCopies?.first { $0.id == probe.sketchID }
            guard let sketch = live ?? copy else { throw FeatureError("Die Skizze fehlt.") }
            var found = sketch.region(containing: probe.point)
            if found == nil, sketch.regions.count == probe.regionCount, sketch.regions.indices.contains(probe.index) {
                found = probe.index
            }
            guard let index = found else { throw FeatureError("Bereich in „\(sketch.name)“ nicht mehr gefunden.") }
            result.append(ResolvedRegion(region: sketch.regions[index], sketch: sketch))
        }
        guard !result.isEmpty else { throw FeatureError("Kein Skizzenbereich.") }
        return result
    }

    /// Wie filledRegions in ModelStore: innere Konturen ignorieren, in Löchern liegende Bereiche entfallen.
    private static func filledForFeature(_ regions: [SketchRegion]) -> [SketchRegion] {
        var filled: [SketchRegion] = []
        for region in regions {
            filled.append(SketchRegion(outer: region.outer, holes: [], polygon: region.polygon,
                                       area: abs(signedArea(region.polygon))))
        }
        var result: [SketchRegion] = []
        for index in filled.indices {
            let polygon = filled[index].polygon
            guard !polygon.isEmpty else { continue }
            let probe = polygon.reduce(Point2.zero, +) / Double(polygon.count)
            var covered = false
            for other in filled.indices where other != index && filled[other].area > filled[index].area {
                if polygonContains(filled[other].polygon, probe) {
                    covered = true
                    break
                }
            }
            if !covered { result.append(filled[index]) }
        }
        return result
    }

    private func replayExtrude(_ feature: Feature, _ state: [SceneBody], _ list: [StoredSketch]) throws -> [SceneBody] {
        let entries = try resolvedRegions(feature, sketches: list)
        let sketch = entries[0].sketch
        var plane = sketch.plane
        if let onFace = feature.data.onFace { plane.isOnFace = onFace }
        let chosen: [SketchRegion] = entries.filter { $0.sketch.id == sketch.id }.map { $0.region }
        let filled = feature.data.throughHoles == true ? Self.filledForFeature(chosen) : chosen
        let separate = feature.data.separateParts == true
        // Ältere Stände: angrenzende Bereiche wie damals zu einem Profil zusammengefasst
        let regions = separate || feature.data.thin == true ? filled : SketchRegionMerge.merged(filled)
        let mode = ExtrudeMode(rawValue: feature.data.mode ?? "") ?? .newBody
        let direction = ExtrudeDirection(rawValue: feature.data.direction ?? "") ?? .oneSide
        let distance = feature.value("distance") ?? 0
        guard distance != 0 else { throw FeatureError("Abstand 0.") }
        let second = feature.value("second") ?? 0
        let solid: PCKShape?
        if feature.data.thin == true {
            let side = ThinSide(rawValue: feature.data.thinSide ?? "") ?? .inside
            solid = Self.thinSolid(regions, plane: plane, distance: distance, mode: mode, direction: direction,
                                   second: second, thickness: feature.value("thickness") ?? 2, side: side)
        } else {
            solid = extrudeRegions(regions, plane: plane, distance: distance, mode: mode, direction: direction,
                                   secondDistance: second, taper: feature.value("taper") ?? 0)
        }
        guard let solid else { throw FeatureError("Bereich lässt sich nicht extrudieren.") }
        var result = try Self.combine(solid, into: state, target: feature.data.target, mode: mode, sketch: sketch.id,
                                      separate: separate)
        // Textkörper mit dem aktuellen Inhalt benennen (SketchTextEdit.swift)
        if mode == .newBody, let content = sketch.textContent(of: filled) {
            SceneBody.labelText(&result, from: state.count, content: content)
        }
        return result
    }

    /// Wie thinExtrudeRegions, mit festen Werten statt der Werkzeugeinstellungen.
    private static func thinSolid(_ regions: [SketchRegion], plane: SketchPlane, distance: Double, mode: ExtrudeMode,
                                  direction: ExtrudeDirection, second: Double, thickness: Double,
                                  side: ThinSide) -> PCKShape? {
        guard !regions.isEmpty, distance != 0, thickness > 0 else { return nil }
        let sign = plane.extrusionSign(mode: mode)
        let main = sign * distance
        let from: Double
        let length: Double
        switch direction {
        case .oneSide:
            from = mode == .cut ? -sign * 0.01 : 0
            length = main - from
        case .symmetric:
            from = -main
            length = 2 * main
        case .twoSides:
            let back = abs(second) * (main >= 0 ? -1 : 1)
            from = back
            length = main - back
        }
        guard length != 0 else { return nil }
        let start: SIMD3<Double> = plane.origin + plane.normal * from
        let vector: SIMD3<Double> = plane.normal * length
        var shapes: [PCKShape] = []
        for region in regions {
            guard let shape = PCKShape.thinPrism(profileWires: profileWires(region, plane: plane, offset: from),
                                                 planeOrigin: start, planeNormal: plane.normal, thickness: thickness,
                                                 side: side.kernelValue, direction: vector) else { return nil }
            shapes.append(shape)
        }
        return shapes.count == 1 ? shapes[0] : PCKShape.compound(shapes)
    }

    private func replayRevolve(_ feature: Feature, _ state: [SceneBody], _ list: [StoredSketch]) throws -> [SceneBody] {
        let entries = try resolvedRegions(feature, sketches: list)
        guard let origin = feature.data.origin, let axis = feature.data.axis, simd_length(axis) > 1e-12 else {
            throw FeatureError("Achse fehlt.")
        }
        let degrees = feature.value("angle") ?? 360
        guard degrees != 0 else { throw FeatureError("Winkel 0.") }
        let radians = max(-360, min(360, degrees)) * .pi / 180
        var shapes: [PCKShape] = []
        for entry in entries {
            guard let shape = PCKShape.revolve(profileWires: profileWires(entry.region, plane: entry.sketch.plane),
                                               axisOrigin: origin, axisDirection: simd_normalize(axis),
                                               angle: radians) else {
                throw FeatureError("Drehen nicht möglich (Achse darf das Profil nicht schneiden).")
            }
            shapes.append(shape)
        }
        let combined: PCKShape? = shapes.count == 1 ? shapes.first : PCKShape.compound(shapes)
        guard let solid = combined else { throw FeatureError("Drehen nicht möglich.") }
        let mode = ExtrudeMode(rawValue: feature.data.mode ?? "") ?? .newBody
        return try Self.combine(solid, into: state, target: feature.data.target, mode: mode, sketch: entries[0].sketch.id,
                                separate: feature.data.separateParts == true)
    }

    /// Wie extrusionResult, aber auf einem Zwischenstand.
    /// separate: jeder Teil des Verbunds ein eigener Körper (sonst berührende verschmolzen, ältere Stände).
    private static func combine(_ solid: PCKShape, into state: [SceneBody], target: Int?, mode: ExtrudeMode,
                                sketch: UUID?, separate: Bool) throws -> [SceneBody] {
        switch mode {
        case .newBody:
            var result = state
            let parts: [PCKShape] = separate ? solid.separatedParts() : solid.separatedSolids()
            for part in parts {
                let color = SceneBody.palette[result.count % SceneBody.palette.count]
                result.append(SceneBody(shape: part, name: "Körper \(result.count + 1)", color: color, sketchID: sketch))
            }
            return result
        case .union:
            var chosen = state.indices.last
            if let target, state.indices.contains(target) { chosen = target }
            guard let index = chosen else {
                let color = SceneBody.palette[state.count % SceneBody.palette.count]
                let body = SceneBody(shape: solid, name: "Körper \(state.count + 1)", color: color, sketchID: sketch)
                return state + [body]
            }
            guard let fused = state[index].shape.fusing(solid) else { throw FeatureError("Vereinigen fehlgeschlagen.") }
            var result = state
            result[index] = result[index].with(fused)
            return result
        case .cut:
            var result: [SceneBody] = []
            for body in state {
                guard let cut = body.shape.cutting(solid) else { throw FeatureError("Abziehen fehlgeschlagen.") }
                result.append(body.with(cut))
            }
            return result
        case .intersect:
            var result: [SceneBody] = []
            var touched = false
            for body in state {
                if let common = body.shape.intersecting(solid), common.volume > 1e-9 {
                    result.append(body.with(common))
                    touched = true
                } else {
                    result.append(body)
                }
            }
            guard touched else { throw FeatureError("Schnittmenge leer – das Profil berührt keinen Körper.") }
            return result
        }
    }

    // MARK: Grundkörper, Kanten, Flächen

    private static func replayPrimitive(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let primitive = feature.data.primitive.flatMap(Primitive.init(rawValue:)) else {
            throw FeatureError("Unbekannter Grundkörper.")
        }
        let base = feature.data.origin ?? SIMD3<Double>(0, 0, 0)
        let x = feature.value("x") ?? 40
        let y = feature.value("y") ?? x
        let z = feature.value("z") ?? x
        guard x > 0, y > 0, z > 0 else { throw FeatureError("Maße müssen größer als 0 sein.") }
        let shape: PCKShape?
        switch primitive {
        case .box:
            shape = PCKShape.box(width: x, depth: y, height: z).translated(by: base)
        case .cylinder:
            shape = PCKShape.cylinder(base: base, axis: [0, 0, 1], radius: x / 2, height: z)
        case .sphere:
            let center: SIMD3<Double> = base + SIMD3<Double>(0, 0, x / 2)
            shape = PCKShape.sphere(center: center, radius: x / 2)
        case .cone:
            shape = PCKShape.cone(base: base, axis: [0, 0, 1], bottomRadius: x / 2, topRadius: 0, height: z)
        case .torus:
            let center: SIMD3<Double> = base + SIMD3<Double>(0, 0, z / 2)
            shape = z < x ? PCKShape.torus(center: center, axis: [0, 0, 1], majorRadius: x / 2, minorRadius: z / 2) : nil
        }
        guard let shape else { throw FeatureError("Maße ungültig.") }
        let color = SceneBody.palette[state.count % SceneBody.palette.count]
        let body = SceneBody(shape: shape, name: "\(primitive.rawValue) \(state.count + 1)", color: color)
        return state + [body]
    }

    private static func replayBlend(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let signatures = feature.data.edges, let first = signatures.first else { throw FeatureError("Keine Kanten.") }
        var body = first.body
        if let target = feature.data.target { body = target }
        guard state.indices.contains(body) else { throw FeatureError("Körper fehlt.") }
        let shape = state[body].shape
        let numbers = try matchEdges(signatures, in: shape).map { NSNumber(value: $0) }
        let result: PCKShape?
        if feature.kind == .fillet {
            let radius = feature.value("radius") ?? 0
            guard radius > 0 else { throw FeatureError("Radius muss größer als 0 sein.") }
            if let end = feature.value("end") {
                result = shape.filleting(edges: numbers, radius: radius, endRadius: max(0.01, end))
            } else {
                result = shape.filleting(edges: numbers, radius: radius)
            }
        } else {
            let distance = feature.value("distance") ?? 0
            guard distance > 0 else { throw FeatureError("Fase muss größer als 0 sein.") }
            if let second = feature.value("second") {
                result = shape.chamfering(edges: numbers, distance: distance, distance2: max(0.01, second))
            } else {
                result = shape.chamfering(edges: numbers, distance: distance)
            }
        }
        guard let result else { throw FeatureError("\(feature.name) an diesen Kanten nicht möglich.") }
        var bodies = state
        bodies[body] = bodies[body].with(result)
        return bodies
    }

    private static func replayFaceExtrude(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let signatures = feature.data.faces, !signatures.isEmpty else { throw FeatureError("Keine Flächen.") }
        let distance = feature.value("distance") ?? 0
        guard distance != 0 else { throw FeatureError("Abstand 0.") }
        var result = state
        var order: [Int] = []
        for signature in signatures where !order.contains(signature.body) { order.append(signature.body) }
        for body in order {
            guard state.indices.contains(body) else { throw FeatureError("Körper fehlt.") }
            let group = signatures.filter { $0.body == body }
            let numbers = try matchFaces(group, in: state[body].shape).map { NSNumber(value: $0) }
            guard let shape = state[body].shape.extruding(faces: numbers, distance: distance) else {
                throw FeatureError("Fläche ziehen nicht möglich.")
            }
            result[body] = result[body].with(shape)
        }
        return result
    }

    private static func replayShell(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let body = feature.data.target, state.indices.contains(body) else { throw FeatureError("Körper fehlt.") }
        let thickness = feature.value("thickness") ?? 0
        guard thickness > 0 else { throw FeatureError("Wandstärke muss größer als 0 sein.") }
        var numbers: [NSNumber] = []
        if feature.data.closed != true, let signatures = feature.data.faces, !signatures.isEmpty {
            numbers = try matchFaces(signatures, in: state[body].shape).map { NSNumber(value: $0) }
        }
        guard let shape = state[body].shape.shelling(removingFaces: numbers, thickness: thickness) else {
            throw FeatureError("Schale mit \(thickness.formatted()) mm nicht möglich.")
        }
        var result = state
        result[body] = result[body].with(shape)
        return result
    }

    // MARK: Kombinieren, Bewegen, Löschen

    private static func replayBoolean(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let kind = feature.data.mode.flatMap(BooleanKind.init(rawValue:)), let target = feature.data.target,
              state.indices.contains(target) else { throw FeatureError("Zielkörper fehlt.") }
        let tools = (feature.data.tools ?? []).filter { state.indices.contains($0) && $0 != target }
        guard !tools.isEmpty else { throw FeatureError("Werkzeugkörper fehlen.") }
        var shape = state[target].shape
        let clearance = feature.value("clearance") ?? 0
        for tool in tools {
            guard let other = booleanTool(state[tool].shape, kind: kind, clearance: clearance) else {
                throw FeatureError(clearanceFailure(clearance))
            }
            let combined: PCKShape?
            switch kind {
            case .union: combined = shape.fusing(other)
            case .subtract: combined = shape.cutting(other)
            case .intersect: combined = shape.intersecting(other)
            }
            guard let combined else { throw FeatureError("\(kind.rawValue) fehlgeschlagen.") }
            shape = combined
        }
        var result = state
        result[target] = result[target].with(shape)
        if feature.data.keepTools != true {
            for tool in tools.sorted(by: >) where result.indices.contains(tool) {
                result.remove(at: tool)
            }
        }
        return result
    }

    private static func replayMove(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        let offset = SIMD3<Double>(feature.value("x") ?? 0, feature.value("y") ?? 0, feature.value("z") ?? 0)
        let copies = feature.data.copies == true
        let wanted = Int((feature.value("count") ?? 1).rounded())
        let count = copies ? max(1, min(wanted, 200)) : 1
        let step: SIMD3<Double> = feature.data.divides == true ? offset / Double(count) : offset
        var result = state
        for index in feature.data.bodies ?? [] where state.indices.contains(index) {
            for k in 1...count {
                let shift: SIMD3<Double> = step * Double(k)
                guard let moved = state[index].shape.translated(by: shift) else { throw FeatureError("Verschieben nicht möglich.") }
                let motion = simd_double4x4.translation(shift)
                if copies {
                    var copy = state[index].with(moved, moving: motion)
                    copy.name += count > 1 ? " (Kopie \(k))" : " (Kopie)"
                    result.append(copy)
                } else {
                    result[index] = result[index].with(moved, moving: motion)
                }
            }
        }
        return result
    }

    private static func replayRotate(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let axis = feature.data.axis, simd_length(axis) > 1e-12 else { throw FeatureError("Achse fehlt.") }
        let radians = (feature.value("angle") ?? 0) * .pi / 180
        let points = feature.data.points ?? []
        let copies = feature.data.copies == true
        var result = state
        for (n, index) in (feature.data.bodies ?? []).enumerated() where state.indices.contains(index) {
            let center = points.indices.contains(n) ? points[n] : (points.last ?? SIMD3<Double>(0, 0, 0))
            guard let rotated = state[index].shape.rotated(origin: center, axis: axis, angle: radians) else {
                throw FeatureError("Drehen nicht möglich.")
            }
            let motion = simd_double4x4.rotation(origin: center, axis: axis, angle: radians)
            if copies {
                var copy = state[index].with(rotated, moving: motion)
                copy.name += " (Kopie)"
                result.append(copy)
            } else {
                result[index] = result[index].with(rotated, moving: motion)
            }
        }
        return result
    }

    private static func replayMirror(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let normal = feature.data.axis, simd_length(normal) > 1e-12 else { throw FeatureError("Ebene fehlt.") }
        let points = feature.data.points ?? []
        let keep = feature.data.copies == true
        var result = state
        for (n, index) in (feature.data.bodies ?? []).enumerated() where state.indices.contains(index) {
            let origin = points.indices.contains(n) ? points[n] : (points.last ?? SIMD3<Double>(0, 0, 0))
            guard let mirrored = state[index].shape.mirrored(planeOrigin: origin, normal: normal) else {
                throw FeatureError("Spiegeln nicht möglich.")
            }
            if keep {
                var copy = state[index].with(mirrored).unlinked()
                copy.name += " (gespiegelt)"
                result.append(copy)
            } else {
                result[index] = result[index].with(mirrored).unlinked()
            }
        }
        return result
    }

    private static func replayPattern(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        let indices = (feature.data.bodies ?? []).filter { state.indices.contains($0) }
        let count = Int((feature.value("count") ?? 1).rounded())
        var result = state
        if feature.data.mode == "kreis" {
            guard count >= 2, count <= 1000, let origin = feature.data.origin, let rawAxis = feature.data.axis,
                  simd_length(rawAxis) > 1e-12 else { throw FeatureError("Anzahl mindestens 2.") }
            let axis = simd_normalize(rawAxis)
            let degrees = feature.value("angle") ?? 360
            let full = abs(abs(degrees) - 360) < 1e-6
            let divisions = Double(full ? count : count - 1)
            let step = degrees / divisions * .pi / 180
            for index in indices {
                for k in 1..<count {
                    let angle = step * Double(k)
                    guard let copy = state[index].shape.rotated(origin: origin, axis: axis, angle: angle) else {
                        throw FeatureError("Muster nicht möglich.")
                    }
                    let motion = simd_double4x4.rotation(origin: origin, axis: axis, angle: angle)
                    var body = state[index].with(copy, moving: motion)
                    body.name += " (\(k + 1))"
                    result.append(body)
                }
            }
            return result
        }
        let rows = max(1, Int((feature.value("count2") ?? 1).rounded()))
        guard count >= 1, count * rows >= 2, count * rows <= 10000, let rawAxis = feature.data.axis,
              simd_length(rawAxis) > 1e-12 else { throw FeatureError("Anzahl mindestens 2.") }
        let d = simd_normalize(rawAxis)
        let rawSecond = feature.data.axis2 ?? SIMD3<Double>(0, 1, 0)
        let d2: SIMD3<Double> = rows > 1 && simd_length(rawSecond) > 1e-12 ? simd_normalize(rawSecond) : SIMD3<Double>(0, 0, 0)
        let spacing = feature.value("spacing") ?? 0
        let spacing2 = feature.value("spacing2") ?? 0
        for index in indices {
            var number = 1
            for row in 0..<rows {
                for k in 0..<count where row > 0 || k > 0 {
                    let along: SIMD3<Double> = d * (spacing * Double(k))
                    let across: SIMD3<Double> = d2 * (spacing2 * Double(row))
                    let offset = along + across
                    guard let copy = state[index].shape.translated(by: offset) else { throw FeatureError("Muster nicht möglich.") }
                    number += 1
                    var body = state[index].with(copy, moving: .translation(offset))
                    body.name += " (\(number))"
                    result.append(body)
                }
            }
        }
        return result
    }

    private static func replayDelete(_ feature: Feature, _ state: [SceneBody]) -> [SceneBody] {
        var result = state
        for index in (feature.data.bodies ?? []).sorted(by: >) where result.indices.contains(index) {
            result.remove(at: index)
        }
        return result
    }

    // MARK: Feste Stände

    private func replaySnapshot(_ feature: Feature, _ state: [SceneBody]) throws -> [SceneBody] {
        guard let info = feature.data.snapshot, let stored = snapshotBodies(feature) else {
            throw FeatureError("Gespeicherter Stand fehlt.")
        }
        if info.full { return stored }
        var result = state
        for (k, index) in info.changed.enumerated() where k < stored.count {
            if result.indices.contains(index) {
                result[index] = stored[k]
            } else {
                result.append(stored[k])
            }
        }
        if stored.count > info.changed.count {
            result += stored[info.changed.count...]
        }
        return result
    }

    /// Körper eines festen Stands (im Speicher oder aus features/<id>.step); nil, wenn die Datei fehlt.
    func snapshotBodies(_ feature: Feature) -> [SceneBody]? {
        if let stored = featureRecorder.snapshots[feature.id] { return stored }
        guard let info = feature.data.snapshot else { return nil }
        if info.metas.isEmpty { return [] }
        guard PCKShape.stepAvailable, let url = snapshotURL(feature.id) else { return nil }
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path), let shapes = PCKShape.readSTEP(path: path),
              shapes.count == info.metas.count else { return nil }
        var restored: [SceneBody] = []
        for (index, shape) in shapes.enumerated() {
            restored.append(Self.snapshotBody(shape, meta: info.metas[index], number: index))
        }
        featureRecorder.snapshots[feature.id] = restored
        return restored
    }

    private static func snapshotMeta(_ body: SceneBody) -> SnapshotBodyMeta {
        SnapshotBodyMeta(name: body.name, color: [body.color.x, body.color.y, body.color.z], isHidden: body.isHidden,
                         sketchID: body.sketchID, folder: body.folder, componentID: body.componentID,
                         placement: body.componentID == nil ? nil : body.placementValues, material: body.material,
                         threads: body.threads, finish: body.finish, textLabel: body.textLabel)
    }

    private static func snapshotBody(_ shape: PCKShape, meta: SnapshotBodyMeta, number: Int) -> SceneBody {
        guard meta.color.count == 3 else {
            let color = SceneBody.palette[number % SceneBody.palette.count]
            return SceneBody(shape: shape, name: meta.name, color: color)
        }
        let color = SIMD3<Float>(meta.color[0], meta.color[1], meta.color[2])
        var body = SceneBody(shape: shape, name: meta.name, color: color, isHidden: meta.isHidden,
                             sketchID: meta.sketchID, folder: meta.folder)
        body.material = meta.material
        body.threads = meta.threads
        body.finish = meta.finish
        body.textLabel = meta.textLabel
        return body.restoringComponent(meta.componentID, placement: meta.placement)
    }

    // MARK: Kanten und Flächen wiederfinden

    static func edgeSignature(_ shape: PCKShape, edge: Int, body: Int) -> EdgeSignature? {
        guard let values = shape.handle(ofEdge: edge)?.map(\.doubleValue), values.count == 6 else { return nil }
        let midpoint = SIMD3<Double>(values[0], values[1], values[2])
        let direction = SIMD3<Double>(values[3], values[4], values[5])
        return EdgeSignature(body: body, midpoint: midpoint, direction: direction, length: shape.length(ofEdge: edge))
    }

    /// Nächstgelegene Kante gleicher Ausrichtung (Richtung ins Material) je Signatur.
    private static func matchEdges(_ signatures: [EdgeSignature], in shape: PCKShape) throws -> [Int] {
        let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
        var numbers: [Int] = []
        for ref in mesh.edgeRefs where ref.edge > 0 && !numbers.contains(ref.edge) {
            numbers.append(ref.edge)
        }
        var candidates: [EdgeSignature] = []
        var candidateNumbers: [Int] = []
        for number in numbers {
            if let signature = edgeSignature(shape, edge: number, body: 0) {
                candidates.append(signature)
                candidateNumbers.append(number)
            }
        }
        var chosen: [Int] = []
        for signature in signatures {
            var best: (edge: Int, score: Double)?
            for (k, candidate) in candidates.enumerated() where !chosen.contains(candidateNumbers[k]) {
                guard simd_dot(candidate.direction, signature.direction) > 0.8 else { continue }
                let distance = simd_distance(candidate.midpoint, signature.midpoint)
                let score = distance + 0.5 * abs(candidate.length - signature.length)
                if score < (best?.score ?? .infinity) { best = (candidateNumbers[k], score) }
            }
            guard let best else { throw FeatureError("Kante nicht mehr gefunden.") }
            chosen.append(best.edge)
        }
        return chosen
    }

    /// Je Flächennummer: Mitte, mittlere Normale und Größe (aus dem Anzeigenetz).
    private static func faceTable(_ shape: PCKShape) -> [Int: FaceStats] {
        let mesh = Mesh(shape.triangulate(deflection: 0.05), body: 0)
        var sums: [Int: FaceStats] = [:]
        for t in 0..<mesh.triangleCount where t < mesh.triangleFaces.count {
            let face = mesh.triangleFaces[t].face
            let ia = Int(mesh.indices[t * 3])
            let ib = Int(mesh.indices[t * 3 + 1])
            let ic = Int(mesh.indices[t * 3 + 2])
            let a = SIMD3<Double>(mesh.vertices[ia].position)
            let b = SIMD3<Double>(mesh.vertices[ib].position)
            let c = SIMD3<Double>(mesh.vertices[ic].position)
            let weight = simd_length(simd_cross(b - a, c - a)) / 2
            let middle: SIMD3<Double> = (a + b + c) / 3
            let na = SIMD3<Double>(mesh.vertices[ia].normal)
            let nb = SIMD3<Double>(mesh.vertices[ib].normal)
            let nc = SIMD3<Double>(mesh.vertices[ic].normal)
            let normal: SIMD3<Double> = (na + nb + nc) / 3
            var entry = sums[face] ?? FaceStats(center: SIMD3<Double>(0, 0, 0), normal: SIMD3<Double>(0, 0, 0), area: 0)
            entry.center += middle * weight
            entry.normal += normal * weight
            entry.area += weight
            sums[face] = entry
        }
        var result: [Int: FaceStats] = [:]
        for (face, entry) in sums where entry.area > 1e-12 {
            let center = entry.center / entry.area
            let average = entry.normal / entry.area
            // Rundum gekrümmte Flächen (Zylindermantel) haben keine Hauptrichtung
            let normal = simd_length(average) > 0.3 ? simd_normalize(average) : SIMD3<Double>(0, 0, 0)
            result[face] = FaceStats(center: center, normal: normal, area: entry.area)
        }
        return result
    }

    private static func sameFacing(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        if simd_length(b) < 0.5 { return simd_length(a) < 0.5 }
        return simd_dot(a, b) > 0.9
    }

    /// Nächstgelegene Fläche gleicher Ausrichtung je Signatur.
    private static func matchFaces(_ signatures: [FaceSignature], in shape: PCKShape) throws -> [Int] {
        let table = faceTable(shape)
        var chosen: [Int] = []
        for signature in signatures {
            var best: (face: Int, score: Double)?
            for (face, stats) in table where !chosen.contains(face) && sameFacing(stats.normal, signature.normal) {
                let distance = simd_distance(stats.center, signature.center)
                let size = abs(stats.area.squareRoot() - signature.area.squareRoot())
                let score = distance + 0.5 * size
                if score < (best?.score ?? .infinity) { best = (face, score) }
            }
            guard let best else { throw FeatureError("Fläche nicht mehr gefunden.") }
            chosen.append(best.face)
        }
        return chosen
    }
}

// MARK: - Speichern

extension ModelStore {
    private var featuresURL: URL? { folder?.appending(path: "features.json") }

    private func snapshotURL(_ id: UUID) -> URL? {
        folder?.appending(path: "features").appending(path: "\(id.uuidString).step")
    }

    /// Nach dem Laden der Körper: features.json lesen. Alte Projekte (bzw. von älteren Versionen geänderte)
    /// beginnen mit einem festen Stand der geladenen Körper.
    func loadFeatures() {
        // Ohne STEP gibt es keine gespeicherten Körper; features.json bleibt dann unangetastet
        guard PCKShape.stepAvailable else { return }
        let recorder = featureRecorder
        var list: [Feature] = []
        var stale = true
        if let url = featuresURL, let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(FeatureFile.self, from: data) {
            list = file.features
            stale = file.bodyCount != bodies.count || modelIsNewer(than: url)
        }
        if stale, !bodies.isEmpty {
            var feature = Feature(name: list.isEmpty ? "Ausgangsstand" : "Stand beim Öffnen", kind: .snapshot)
            feature.data.snapshot = SnapshotInfo(full: true, metas: bodies.map { Self.snapshotMeta($0) })
            recorder.snapshots[feature.id] = bodies
            list.append(feature)
        } else if stale {
            list = []
        }
        features = list
        recorder.cache = [:]
        if let last = list.last { recorder.cache[last.id] = bodies }
        removeUnusedSnapshotFiles()
    }

    /// model.step wurde nach features.json geschrieben (z. B. von einer älteren Version ohne Verlauf).
    private func modelIsNewer(than featuresFile: URL) -> Bool {
        guard let model = folder?.appending(path: "model.step") else { return false }
        let manager = FileManager.default
        guard let modelDate = (try? manager.attributesOfItem(atPath: model.path(percentEncoded: false)))?[.modificationDate] as? Date,
              let featuresDate = (try? manager.attributesOfItem(atPath: featuresFile.path(percentEncoded: false)))?[.modificationDate] as? Date
        else { return false }
        return modelDate.timeIntervalSince(featuresDate) > 2
    }

    /// Beim Öffnen: STEP-Dateien fester Stände entfernen, die kein Feature mehr braucht.
    private func removeUnusedSnapshotFiles() {
        guard let directory = folder?.appending(path: "features") else { return }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let used = Set(features.map { $0.id.uuidString })
        for file in files where file.pathExtension == "step" {
            if !used.contains(file.deletingPathExtension().lastPathComponent) {
                try? manager.removeItem(at: file)
            }
        }
    }

    /// Mit save(): features.json und noch nicht geschriebene feste Stände (features/<id>.step).
    func saveFeatures() {
        guard PCKShape.stepAvailable, let url = featuresURL else { return }
        if let directory = folder?.appending(path: "features") {
            let manager = FileManager.default
            for feature in features where feature.kind == .snapshot {
                guard let stored = featureRecorder.snapshots[feature.id], !stored.isEmpty,
                      let file = snapshotURL(feature.id) else { continue }
                let path = file.path(percentEncoded: false)
                guard !manager.fileExists(atPath: path) else { continue }
                try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
                _ = PCKShape.writeSTEP(stored.map(\.shape), path: path)
            }
        }
        let file = FeatureFile(features: features, bodyCount: bodies.count)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url)
        }
    }
}

// MARK: - Formeln in Skizzenmaßen

extension ModelStore {
    /// Gespeicherter Wert eines Formelmaßes: Längen in der Projekteinheit („10“ im Zollprojekt = 10 in, „10 mm“
    /// bleibt 10 mm), Winkel wie an der Ecke gezeigt und – wie SketchController.storedValue – gespiegelt, wenn die
    /// Einschränkung mit den Linienrichtungen rechnet (180° − gezeigt). nil bei Fehler oder Wert ≤ 0.
    static func formulaDimensionValue(_ formula: String, for variant: SketchConstraint.Variant, entities: [SketchEntity],
                               values: [String: Double]) -> Double? {
        if case .angle(let a, let b, _) = variant {
            guard let shown = try? Formula.evaluate(formula, variables: values), shown > 0 else { return nil }
            return angleIsFlipped(a, b, entities: entities) ? 180 - shown : shown
        }
        guard let value = try? Formula.evaluateLength(formula, variables: values), value > 0 else { return nil }
        return value
    }

    /// Wie cornerAngle in Sketch.swift: Treffen sich die Linien mit gegenläufigen Richtungen an der Ecke, ist der
    /// gezeigte Winkel 180° minus dem gespeicherten.
    private static func angleIsFlipped(_ a: SketchCurveRef, _ b: SketchCurveRef, entities: [SketchEntity]) -> Bool {
        guard case .line(let p1, let p2) = ConstraintSolver.curve(a, entities),
              case .line(let q1, let q2) = ConstraintSolver.curve(b, entities),
              simd_distance(p1, p2) > 1e-9, simd_distance(q1, q2) > 1e-9 else { return false }
        let firstEnds: [(Point2, Double)] = [(p1, 1), (p2, -1)]
        let secondEnds: [(Point2, Double)] = [(q1, 1), (q2, -1)]
        for (vertex, s1) in firstEnds {
            for (other, s2) in secondEnds where simd_distance(vertex, other) < 1e-6 {
                return s1 * s2 < 0
            }
        }
        return false
    }
}
