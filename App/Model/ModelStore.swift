import Foundation
import simd

enum ExtrudeMode: String, CaseIterable, Identifiable {
    case newBody = "Neuer Körper"
    case union = "Vereinigen"
    case cut = "Abziehen"

    var id: Self { self }
}

enum EdgeOperation: String, CaseIterable, Identifiable {
    case fillet = "Abrunden"
    case chamfer = "Fase"

    var id: Self { self }
}

enum Primitive: String, CaseIterable, Identifiable {
    case box = "Quader"
    case cylinder = "Zylinder"
    case sphere = "Kugel"
    case cone = "Kegel"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .box: "cube"
        case .cylinder: "cylinder"
        case .sphere: "circle.circle"
        case .cone: "cone"
        }
    }

    /// Startmaße (x = Breite bzw. Durchmesser, y = Tiefe, z = Höhe) in mm.
    var defaultSize: SIMD3<Double> {
        switch self {
        case .box: [40, 40, 40]
        case .cylinder: [40, 40, 40]
        case .sphere: [40, 40, 40]
        case .cone: [40, 40, 40]
        }
    }
}

enum BooleanKind: String, CaseIterable, Identifiable {
    case union = "Vereinigen"
    case subtract = "Abziehen"
    case intersect = "Schneiden"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .union: "square.on.square.squareshape.controlhandles"
        case .subtract: "square.on.square.dashed"
        case .intersect: "square.on.square.intersection.dashed"
        }
    }
}

enum MirrorPlane: String, CaseIterable, Identifiable {
    case yz = "YZ"
    case xz = "XZ"
    case xy = "XY"

    var id: Self { self }

    var normal: SIMD3<Double> {
        switch self {
        case .yz: [1, 0, 0]
        case .xz: [0, 1, 0]
        case .xy: [0, 0, 1]
        }
    }
}

/// Ein Körper der Szene mit Darstellungseigenschaften.
struct SceneBody {
    var shape: PCKShape
    var name: String
    var color: SIMD3<Float>
    var isHidden = false

    func with(_ shape: PCKShape) -> SceneBody {
        var body = self
        body.shape = shape
        return body
    }

    static let palette: [SIMD3<Float>] = [
        [0.86, 0.87, 0.89], [0.36, 0.55, 0.85], [0.85, 0.52, 0.30], [0.40, 0.70, 0.45],
        [0.80, 0.38, 0.45], [0.62, 0.48, 0.80], [0.85, 0.75, 0.35], [0.30, 0.30, 0.33],
    ]
}

/// Fertige Skizze im Modell. Ihre geschlossenen Bereiche lassen sich antippen und extrudieren.
struct StoredSketch: Codable {
    var name: String
    var plane: SketchPlane
    var entities: [SketchEntity]
    var isHidden = false

    // Abgeleitet, nicht gespeichert
    private(set) var regions: [SketchRegion] = []
    /// Linienzüge in Weltkoordinaten
    private(set) var lines: [[SIMD3<Float>]] = []
    /// Je Bereich: Dreiecke (Weltpunkte, je drei) zum Einfärben
    private(set) var fills: [[SIMD3<Float>]] = []

    private enum CodingKeys: String, CodingKey {
        case name, plane, entities, isHidden
    }

    init(name: String, plane: SketchPlane, entities: [SketchEntity]) {
        self.name = name
        self.plane = plane
        self.entities = entities
        rebuild()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        entities = try container.decode([SketchEntity].self, forKey: .entities)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        rebuild()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(plane, forKey: .plane)
        try container.encode(entities, forKey: .entities)
        try container.encode(isHidden, forKey: .isHidden)
    }

    private mutating func rebuild() {
        regions = findRegions(in: entities).regions
        let plane = self.plane
        lines = entities.flatMap(\.drawing).map { $0.map { SIMD3<Float>(plane.world($0)) } }
        fills = regions.map { regionTriangles($0, plane: plane) }
    }

    /// Kleinster Bereich, der den lokalen Punkt enthält (Löcher ausgenommen).
    func region(containing p: Point2) -> Int? {
        var best: (index: Int, area: Double)?
        for (index, region) in regions.enumerated() where polygonContains(region.polygon, p) {
            guard !region.holes.contains(where: { polygonContains($0.polygon, p) }) else { continue }
            if region.area < (best?.area ?? .infinity) { best = (index, region.area) }
        }
        return best?.index
    }
}

/// Bereich einer gespeicherten Skizze.
struct RegionRef: Hashable {
    var sketch: Int
    var region: Int
}

/// Ein Schritt im Verlauf: Name der Operation und der Zustand davor.
struct HistoryEntry {
    let name: String
    let bodies: [SceneBody]
    var sketches: [StoredSketch] = []
}

/// Körper, Auswahl, Vorschau, Verlauf und Speichern eines Projekts.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var mesh: Mesh = .empty
    @Published private(set) var revision = 0
    @Published private(set) var bodies: [SceneBody] = []
    @Published private(set) var sketches: [StoredSketch] = []
    @Published var message: String?

    // Auswahl
    @Published private(set) var selection: FaceRef?
    @Published private(set) var selectedEdges: [EdgeRef] = []
    @Published private(set) var selectedBodies: [Int] = []
    /// Gewählte Skizzenbereiche (alle aus derselben Skizze).
    @Published private(set) var selectedRegions: [RegionRef] = []
    @Published private(set) var selectionIndices: [UInt32] = []
    @Published private(set) var edgeHighlight: [SIMD3<Float>] = []
    @Published private(set) var selectionRevision = 0

    // Ziehpfeile
    @Published var edgeOperation: EdgeOperation = .fillet {
        didSet {
            if edgeValue > 0 { setEdgeValue(edgeValue) }
        }
    }
    /// Radius bzw. Fasenbreite in mm; 0 = nichts angewendet.
    @Published private(set) var edgeValue: Double = 0
    /// Kantenmitte und Richtung ins Material.
    @Published private(set) var edgeHandle: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// Flächenmitte und Normale der gewählten ebenen Fläche (Extrudieren per Pfeil).
    @Published private(set) var faceHandle: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    @Published private(set) var faceValue: Double = 0
    @Published private(set) var moveOffset: SIMD3<Double> = .zero
    /// Extrusion gewählter Skizzenbereiche: Wert in mm entlang der Normale der Skizze.
    @Published private(set) var regionValue: Double = 0
    @Published var regionMode: ExtrudeMode = .newBody {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }

    // Vorschau und Verlauf
    @Published private(set) var previewName: String?
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var future: [HistoryEntry] = []
    private var previewBodies: [SceneBody]?

    /// Projektordner (model.step + bodies.json); nil = nichts speichern.
    let folder: URL?

    var canUndo: Bool { !history.isEmpty || previewBodies != nil }
    var canRedo: Bool { !future.isEmpty }
    var isEmpty: Bool { bodies.isEmpty && sketches.isEmpty }
    var hasPreview: Bool { previewBodies != nil }

    /// Körper der aktuellen Auswahl (Fläche, Kanten oder Körper).
    var selectedBody: Int? { selection?.body ?? selectedEdges.first?.body ?? selectedBodies.first }
    var hasSelection: Bool { selectedBody != nil }

    /// Ansatz und Richtung des Pfeils für gewählte Skizzenbereiche.
    var regionHandle: (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        guard let first = selectedRegions.first, sketches.indices.contains(first.sketch) else { return nil }
        let sketch = sketches[first.sketch]
        let points = selectedRegions.compactMap { ref -> Point2? in
            guard sketch.regions.indices.contains(ref.region) else { return nil }
            let polygon = sketch.regions[ref.region].polygon
            return polygon.isEmpty ? nil : polygon.reduce(.zero, +) / Double(polygon.count)
        }
        guard !points.isEmpty else { return nil }
        let center = points.reduce(.zero, +) / Double(points.count)
        return (sketch.plane.world(center), sketch.plane.normal * sketch.plane.extrusionSign(mode: regionMode))
    }

    init(folder: URL?) {
        self.folder = folder
        load()
        remesh()
    }

    // MARK: Auswahl

    /// Wählt eine Fläche (nil = nichts). Eine offene Vorschau wird vorher übernommen.
    func select(face: FaceRef?) {
        commitPreview()
        clearSelectionState()
        selection = face
        if let face, let plane = plane(of: face), let center = mesh.centroid(of: face) {
            faceHandle = (SIMD3<Double>(center), plane.normal)
        }
        refreshHighlight()
    }

    /// Kante antippen: zur Auswahl hinzufügen bzw. wieder entfernen.
    /// Kanten eines anderen Körpers beginnen eine neue Auswahl.
    func toggleEdge(_ edge: EdgeRef) {
        commitPreview()
        var edges = selectedEdges
        if edges.first?.body != edge.body {
            edges = []
        }
        if let index = edges.firstIndex(of: edge) {
            edges.remove(at: index)
        } else {
            edges.append(edge)
        }
        clearSelectionState()
        selectedEdges = edges
        if let last = edges.last, bodies.indices.contains(last.body),
           let values = bodies[last.body].shape.handle(ofEdge: last.edge)?.map(\.doubleValue), values.count == 6 {
            edgeHandle = (SIMD3(values[0], values[1], values[2]), SIMD3(values[3], values[4], values[5]))
        }
        refreshHighlight()
        if !edges.isEmpty, !PCKShape.kernelAvailable {
            message = "Abrunden braucht OpenCASCADE (siehe README)."
        }
    }

    /// Körper zur Auswahl hinzufügen bzw. entfernen (für Boolesch, Verschieben, Spiegeln, Farbe).
    func toggleBody(_ body: Int, exclusive: Bool = false) {
        dropPreview()
        var chosen = exclusive ? [] : selectedBodies
        if let index = chosen.firstIndex(of: body) {
            chosen.remove(at: index)
        } else if bodies.indices.contains(body) {
            chosen.append(body)
        }
        clearSelectionState()
        selectedBodies = chosen
        refreshHighlight()
    }

    func clearSelection() {
        commitPreview()
        clearSelectionState()
        refreshHighlight()
    }

    /// Wie clearSelection, verwirft aber eine offene Vorschau.
    func resetSelection() {
        dropPreview()
        clearSelectionState()
        refreshHighlight()
    }

    func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (face: FaceRef, point: SIMD3<Float>)? {
        mesh.pick(origin: origin, direction: direction)
    }

    /// Skizzenbereich unter dem Sehstrahl; t = Abstand entlang des Strahls.
    func pickRegion(origin: SIMD3<Float>, direction: SIMD3<Float>, skipping skipped: Int? = nil) -> (ref: RegionRef, t: Float)? {
        var best: (ref: RegionRef, t: Float)?
        for (index, sketch) in sketches.enumerated() where !sketch.isHidden && index != skipped {
            let normal = SIMD3<Float>(sketch.plane.normal)
            let denominator = simd_dot(direction, normal)
            guard abs(denominator) > 1e-6 else { continue }
            let t = simd_dot(SIMD3<Float>(sketch.plane.origin) - origin, normal) / denominator
            guard t > 0, t < (best?.t ?? .infinity) else { continue }
            let local = sketch.plane.local(SIMD3<Double>(origin + t * direction))
            if let region = sketch.region(containing: local) {
                best = (RegionRef(sketch: index, region: region), t)
            }
        }
        return best
    }

    /// Bereich antippen: zur Auswahl hinzufügen bzw. entfernen. Bereiche einer anderen Skizze beginnen neu.
    func toggleRegion(_ ref: RegionRef) {
        var chosen = selectedRegions
        if chosen.first?.sketch != ref.sketch { chosen = [] }
        if let index = chosen.firstIndex(of: ref) {
            chosen.remove(at: index)
        } else {
            chosen.append(ref)
        }
        let value = regionValue
        let keepPreview = previewName == Self.regionPreviewName && !selectedRegions.isEmpty && !chosen.isEmpty
        if !keepPreview { commitPreview() }
        clearSelectionState()
        selectedRegions = chosen
        if sketches.indices.contains(ref.sketch), sketches[ref.sketch].plane.isOnFace, !keepPreview {
            // Auf einer Fläche: Herausziehen vereinigt, Hineindrücken zieht ab (wie bei Shapr3D)
            regionMode = .union
        }
        if keepPreview {
            setRegionValue(value)
        } else {
            refreshHighlight()
        }
    }

    /// Skizzenebene auf einer planaren Fläche; nil bei gekrümmten Flächen.
    func plane(of face: FaceRef) -> SketchPlane? {
        guard bodies.indices.contains(face.body),
              let values = bodies[face.body].shape.plane(ofFace: face.face)?.map(\.doubleValue),
              values.count == 6 else { return nil }
        return SketchPlane(point: SIMD3(values[0], values[1], values[2]),
                           normal: SIMD3(values[3], values[4], values[5]), isOnFace: true, sourceBody: face.body)
    }

    /// Mittelpunkt des Hüllquaders eines Körpers.
    func center(ofBody body: Int) -> SIMD3<Double>? {
        mesh.bounds(ofBody: body).map { SIMD3<Double>(($0.min + $0.max) / 2) }
    }

    // MARK: Ziehpfeile

    /// Radius bzw. Fasenbreite der gewählten Kanten setzen und als Vorschau zeigen.
    func setEdgeValue(_ newValue: Double) {
        let value = max(0, newValue)
        edgeValue = value
        guard let body = selectedEdges.first?.body, bodies.indices.contains(body) else { return }
        guard value > 0 else {
            dropPreview()
            return
        }
        guard requireKernel() else { return }
        let numbers = selectedEdges.map { NSNumber(value: $0.edge) }
        let result = switch edgeOperation {
        case .fillet: bodies[body].shape.filleting(edges: numbers, radius: value)
        case .chamfer: bodies[body].shape.chamfering(edges: numbers, distance: value)
        }
        guard let result else {
            message = "\(edgeOperation.rawValue) mit \(value.formatted()) mm nicht möglich (zu groß?)."
            return
        }
        message = nil
        var preview = bodies
        preview[body] = preview[body].with(result)
        showPreview(preview, name: edgeOperation.rawValue)
    }

    /// Gewählte ebene Fläche um value mm herausziehen (> 0) oder hineindrücken (< 0).
    func setFaceValue(_ value: Double) {
        faceValue = value
        guard let face = selection, bodies.indices.contains(face.body) else { return }
        guard value != 0 else {
            dropPreview()
            return
        }
        guard requireKernel() else { return }
        guard let result = bodies[face.body].shape.extruding(face: face.face, distance: value) else {
            message = "Extrudieren der Fläche nicht möglich."
            return
        }
        message = nil
        var preview = bodies
        preview[face.body] = preview[face.body].with(result)
        showPreview(preview, name: "Extrudieren")
    }

    private static let regionPreviewName = "Extrudieren"

    /// Gewählte Skizzenbereiche um value mm entlang der Skizzennormale extrudieren (Vorschau).
    func setRegionValue(_ value: Double) {
        regionValue = value
        guard let first = selectedRegions.first, sketches.indices.contains(first.sketch) else { return }
        guard value != 0 else {
            dropPreview()
            refreshHighlight()
            return
        }
        let sketch = sketches[first.sketch]
        let regions = selectedRegions.compactMap { sketch.regions.indices.contains($0.region) ? sketch.regions[$0.region] : nil }
        var mode = regionMode
        var distance = value
        // Auf einer Fläche ins Material gedrückt: abziehen
        if sketch.plane.isOnFace, mode == .union, value < 0 {
            mode = .cut
            distance = -value
        }
        guard mode == .newBody || requireKernel() else { return }
        guard let solid = extrudeRegions(regions, plane: sketch.plane, distance: distance, mode: mode) else {
            message = "Bereich lässt sich nicht extrudieren."
            return
        }
        guard let result = extrusionResult(solid, sourceBody: sketch.plane.sourceBody, mode: mode) else { return }
        message = nil
        showPreview(result, name: Self.regionPreviewName)
    }

    /// Gewählte Körper verschieben (Vorschau).
    func setMoveOffset(_ offset: SIMD3<Double>) {
        moveOffset = offset
        guard !selectedBodies.isEmpty else { return }
        guard offset != .zero else {
            dropPreview()
            return
        }
        var preview = bodies
        for index in selectedBodies where preview.indices.contains(index) {
            guard let moved = bodies[index].shape.translated(by: offset) else {
                message = "Verschieben nicht möglich."
                return
            }
            preview[index] = preview[index].with(moved)
        }
        message = nil
        showPreview(preview, name: "Verschieben")
    }

    /// Gewählte Körper um ihre Mitte drehen (sofort übernommen).
    func rotateSelected(axis: SIMD3<Double>, degrees: Double) {
        guard requireKernel() else { return }
        commitPreview()
        let chosen = selectedBodies
        guard !chosen.isEmpty else { return }
        var result = bodies
        for index in chosen where result.indices.contains(index) {
            guard let center = center(ofBody: index),
                  let rotated = bodies[index].shape.rotated(origin: center, axis: axis, angle: degrees * .pi / 180) else {
                message = "Drehen nicht möglich."
                return
            }
            result[index] = result[index].with(rotated)
        }
        commit(result, name: "Drehen")
        selectedBodies = chosen.filter { bodies.indices.contains($0) }
        refreshHighlight()
    }

    // MARK: Werkzeuge mit Vorschau

    /// Grundkörper einfügen (Vorschau, Übernahme mit commitPreview).
    func previewInsert(_ primitive: Primitive, size: SIMD3<Double>, at base: SIMD3<Double>) {
        let shape: PCKShape? = switch primitive {
        case .box:
            PCKShape.box(width: size.x, depth: size.y, height: size.z).translated(by: base)
        case .cylinder:
            PCKShape.cylinder(base: base, axis: [0, 0, 1], radius: size.x / 2, height: size.z)
        case .sphere:
            PCKShape.sphere(center: base + [0, 0, size.x / 2], radius: size.x / 2)
        case .cone:
            PCKShape.cone(base: base, axis: [0, 0, 1], bottomRadius: size.x / 2, topRadius: 0, height: size.z)
        }
        guard let shape else {
            message = PCKShape.kernelAvailable ? "Maße ungültig." : "\(primitive.rawValue) braucht OpenCASCADE (siehe README)."
            dropPreview()
            return
        }
        message = nil
        showPreview(bodies + [newBody(shape, name: primitive.rawValue)], name: "\(primitive.rawValue) einfügen")
    }

    /// Gewählte Körper spiegeln, Ebene durch die Körpermitte (Vorschau).
    func previewMirror(_ plane: MirrorPlane, keepOriginal: Bool) {
        guard requireKernel(), !selectedBodies.isEmpty else { return }
        var preview = bodies
        for index in selectedBodies where bodies.indices.contains(index) {
            guard let center = center(ofBody: index),
                  let mirrored = bodies[index].shape.mirrored(planeOrigin: center, normal: plane.normal) else {
                message = "Spiegeln nicht möglich."
                return
            }
            if keepOriginal {
                var copy = bodies[index].with(mirrored)
                copy.name += " (gespiegelt)"
                preview.append(copy)
            } else {
                preview[index] = preview[index].with(mirrored)
            }
        }
        message = nil
        showPreview(preview, name: "Spiegeln")
    }

    /// Schale: gewählte Fläche entfernen, Wandstärke thickness (Vorschau).
    func previewShell(thickness: Double) {
        guard requireKernel(), let face = selection, bodies.indices.contains(face.body) else { return }
        guard thickness > 0, let result = bodies[face.body].shape.shelling(removingFace: face.face, thickness: thickness) else {
            message = "Schale mit \(thickness.formatted()) mm nicht möglich."
            dropPreview()
            return
        }
        message = nil
        var preview = bodies
        preview[face.body] = preview[face.body].with(result)
        showPreview(preview, name: "Schale")
    }

    /// Boolesche Operation: target bleibt, die anderen Körper werden verbraucht.
    func applyBoolean(_ kind: BooleanKind, target: Int, tools: [Int]) {
        guard requireKernel(), bodies.indices.contains(target), !tools.isEmpty else { return }
        commitPreview()
        var shape = bodies[target].shape
        for tool in tools where bodies.indices.contains(tool) && tool != target {
            let other = bodies[tool].shape
            let result = switch kind {
            case .union: shape.fusing(other)
            case .subtract: shape.cutting(other)
            case .intersect: shape.intersecting(other)
            }
            guard let result else {
                message = "\(kind.rawValue) fehlgeschlagen."
                return
            }
            shape = result
        }
        var result = bodies
        result[target] = result[target].with(shape)
        for tool in tools.filter({ $0 != target && result.indices.contains($0) }).sorted(by: >) {
            result.remove(at: tool)
        }
        commit(result, name: kind.rawValue)
    }

    func commitPreview() {
        guard let preview = previewBodies, let name = previewName else { return }
        previewBodies = nil
        previewName = nil
        commit(preview, name: name)
    }

    func cancelPreview() {
        dropPreview()
        edgeValue = 0
        faceValue = 0
        regionValue = 0
        moveOffset = .zero
        message = nil
    }

    // MARK: Körper

    func deleteSelected() {
        let chosen = selectedBodies.isEmpty ? selectedBody.map { [$0] } ?? [] : selectedBodies
        guard !chosen.isEmpty else { return }
        dropPreview()
        var result = bodies
        for index in chosen.sorted(by: >) where result.indices.contains(index) {
            result.remove(at: index)
        }
        commit(result, name: chosen.count == 1 ? "Löschen" : "\(chosen.count) Körper löschen")
    }

    func clear() {
        dropPreview()
        commit([], sketches: [], name: "Alles löschen")
    }

    func setColor(_ color: SIMD3<Float>, of indices: [Int]) {
        commitPreview()
        var result = bodies
        for index in indices where result.indices.contains(index) {
            result[index].color = color
        }
        commit(result, name: "Farbe")
        selectedBodies = indices.filter { bodies.indices.contains($0) }
        refreshHighlight()
    }

    func setHidden(_ hidden: Bool, body: Int) {
        guard bodies.indices.contains(body) else { return }
        commitPreview()
        bodies[body].isHidden = hidden
        if hidden {
            clearSelectionState()
        }
        remesh()
        refreshHighlight()
        save()
    }

    func rename(body: Int, to name: String) {
        guard bodies.indices.contains(body), !name.isEmpty else { return }
        bodies[body].name = name
        save()
    }

    // MARK: Skizzen

    /// Fertige Skizze ins Modell übernehmen (index = bestehende Skizze ersetzen).
    func storeSketch(plane: SketchPlane, entities: [SketchEntity], replacing index: Int?) {
        commitPreview()
        var result = sketches
        if let index, result.indices.contains(index) {
            var sketch = StoredSketch(name: result[index].name, plane: plane, entities: entities)
            sketch.isHidden = result[index].isHidden
            result[index] = sketch
            commit(bodies, sketches: result, name: "Skizze bearbeiten")
        } else {
            let number = (sketches.count) + 1
            result.append(StoredSketch(name: "Skizze \(number)", plane: plane, entities: entities))
            commit(bodies, sketches: result, name: "Skizze \(number)")
        }
    }

    func deleteSketch(_ index: Int) {
        guard sketches.indices.contains(index) else { return }
        dropPreview()
        var result = sketches
        let name = result.remove(at: index).name
        commit(bodies, sketches: result, name: "\(name) löschen")
    }

    func setSketchHidden(_ hidden: Bool, sketch index: Int) {
        guard sketches.indices.contains(index) else { return }
        commitPreview()
        sketches[index].isHidden = hidden
        if hidden, selectedRegions.first?.sketch == index {
            clearSelectionState()
        }
        refreshHighlight()
        save()
    }

    /// Ergebnis einer Extrusion je Modus: neuer Körper, mit dem Flächenkörper vereinigt oder von allen abgezogen.
    private func extrusionResult(_ solid: PCKShape, sourceBody: Int?, mode: ExtrudeMode) -> [SceneBody]? {
        switch mode {
        case .newBody:
            return bodies + [newBody(solid, name: "Körper")]
        case .union:
            // Mit dem Körper der Skizzenfläche vereinigen, sonst mit dem zuletzt erzeugten.
            let target = sourceBody.flatMap { bodies.indices.contains($0) ? $0 : nil } ?? bodies.indices.last
            guard let target else { return [newBody(solid, name: "Körper")] }
            guard let fused = bodies[target].shape.fusing(solid) else {
                message = "Vereinigen fehlgeschlagen."
                return nil
            }
            var result = bodies
            result[target] = result[target].with(fused)
            return result
        case .cut:
            var result: [SceneBody] = []
            for body in bodies {
                guard let cut = body.shape.cutting(solid) else {
                    message = "Abziehen fehlgeschlagen."
                    return nil
                }
                result.append(body.with(cut))
            }
            return result
        }
    }

    // MARK: Verlauf

    func undo() {
        if previewBodies != nil {
            cancelPreview()
            return
        }
        guard let entry = history.popLast() else { return }
        future.append(HistoryEntry(name: entry.name, bodies: bodies, sketches: sketches))
        bodies = entry.bodies
        sketches = entry.sketches
        afterChange()
    }

    func redo() {
        dropPreview()
        guard let entry = future.popLast() else { return }
        history.append(HistoryEntry(name: entry.name, bodies: bodies, sketches: sketches))
        bodies = entry.bodies
        sketches = entry.sketches
        afterChange()
    }

    /// Springt im Verlauf zu dem Zustand nach step Schritten (0 = Anfang).
    func jump(toStep step: Int) {
        dropPreview()
        while history.count > step, !history.isEmpty { undo() }
        while history.count < step, !future.isEmpty { redo() }
    }

    // MARK: Dateien

    func stlData() -> Data {
        mesh.binarySTL()
    }

    func stepData() -> Data? {
        guard PCKShape.stepAvailable else {
            message = "STEP braucht OpenCASCADE (siehe README)."
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: url) }
        guard PCKShape.writeSTEP(bodies.map(\.shape), path: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url) else {
            message = "STEP-Export fehlgeschlagen."
            return nil
        }
        return data
    }

    func importSTEP(from url: URL) {
        guard PCKShape.stepAvailable else {
            message = "STEP braucht OpenCASCADE (siehe README)."
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let shapes = PCKShape.readSTEP(path: url.path(percentEncoded: false)) else {
            message = "STEP-Datei konnte nicht gelesen werden."
            return
        }
        commitPreview()
        let name = url.deletingPathExtension().lastPathComponent
        commit(bodies + shapes.map { newBody($0, name: name) }, name: "STEP importieren")
    }

    // MARK: Intern

    private func newBody(_ shape: PCKShape, name: String) -> SceneBody {
        let number = bodies.count + 1
        return SceneBody(shape: shape, name: "\(name) \(number)",
                         color: SceneBody.palette[bodies.count % SceneBody.palette.count])
    }

    private func requireKernel() -> Bool {
        if !PCKShape.kernelAvailable {
            message = "Diese Funktion braucht OpenCASCADE (siehe README)."
        }
        return PCKShape.kernelAvailable
    }

    private func showPreview(_ preview: [SceneBody], name: String) {
        previewBodies = preview
        previewName = name
        remesh()
        refreshHighlight()
    }

    private func dropPreview() {
        guard previewBodies != nil else { return }
        previewBodies = nil
        previewName = nil
        remesh()
        refreshHighlight()
    }

    private func commit(_ newBodies: [SceneBody], sketches newSketches: [StoredSketch]? = nil, name: String) {
        history.append(HistoryEntry(name: name, bodies: bodies, sketches: sketches))
        future.removeAll()
        bodies = newBodies
        if let newSketches { sketches = newSketches }
        afterChange()
    }

    private func afterChange() {
        message = nil
        previewBodies = nil
        previewName = nil
        remesh()
        clearSelectionState()
        refreshHighlight()
        save()
    }

    private func clearSelectionState() {
        selection = nil
        selectedEdges = []
        selectedBodies = []
        selectedRegions = []
        regionValue = 0
        edgeHandle = nil
        faceHandle = nil
        edgeValue = 0
        faceValue = 0
        moveOffset = .zero
    }

    /// Hervorhebung passend zu Auswahl und Vorschau. Während einer Vorschau ändern sich Flächen- und
    /// Kantennummern, daher werden dann nur ganze Körper hervorgehoben.
    private func refreshHighlight() {
        if previewBodies == nil, let selection {
            selectionIndices = mesh.triangleIndices(of: selection)
        } else {
            selectionIndices = selectedBodies.flatMap { mesh.triangleIndices(ofBody: $0) }
        }
        edgeHighlight = previewBodies == nil ? mesh.edgeSegments(of: selectedEdges) : []
        selectionRevision += 1
    }

    private func remesh() {
        var combined = Mesh()
        for (index, body) in (previewBodies ?? bodies).enumerated() where !body.isHidden {
            combined.append(Mesh(body.shape.triangulate(deflection: 0.05), body: index, color: body.color))
        }
        mesh = combined
        revision += 1
    }

    // MARK: Speichern

    private struct BodyMeta: Codable {
        var name: String
        var color: [Float]
        var isHidden: Bool
    }

    private var modelURL: URL? { folder?.appending(path: "model.step") }
    private var metaURL: URL? { folder?.appending(path: "bodies.json") }
    private var sketchesURL: URL? { folder?.appending(path: "sketches.json") }

    private func load() {
        if let url = sketchesURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([StoredSketch].self, from: data) {
            sketches = stored
        }
        guard PCKShape.stepAvailable, let modelURL,
              FileManager.default.fileExists(atPath: modelURL.path(percentEncoded: false)),
              let shapes = PCKShape.readSTEP(path: modelURL.path(percentEncoded: false)) else { return }
        let metas = metaURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([BodyMeta].self, from: $0) } ?? []
        bodies = shapes.enumerated().map { index, shape in
            if index < metas.count, metas[index].color.count == 3 {
                let meta = metas[index]
                return SceneBody(shape: shape, name: meta.name, color: SIMD3(meta.color[0], meta.color[1], meta.color[2]),
                                 isHidden: meta.isHidden)
            }
            return SceneBody(shape: shape, name: "Körper \(index + 1)", color: SceneBody.palette[index % SceneBody.palette.count])
        }
    }

    private func save() {
        if let sketchesURL, let data = try? JSONEncoder().encode(sketches) {
            try? data.write(to: sketchesURL)
        }
        guard PCKShape.stepAvailable, let modelURL, let metaURL else { return }
        let path = modelURL.path(percentEncoded: false)
        if bodies.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            _ = PCKShape.writeSTEP(bodies.map(\.shape), path: path)
        }
        let metas = bodies.map { BodyMeta(name: $0.name, color: [$0.color.x, $0.color.y, $0.color.z], isHidden: $0.isHidden) }
        if let data = try? JSONEncoder().encode(metas) {
            try? data.write(to: metaURL)
        }
    }
}
