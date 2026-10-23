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
    case torus = "Torus"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .box: "cube"
        case .cylinder: "cylinder"
        case .sphere: "circle.circle"
        case .cone: "cone"
        case .torus: "circle.dashed"
        }
    }

    /// Startmaße (x = Breite bzw. Durchmesser, y = Tiefe, z = Höhe) in mm.
    var defaultSize: SIMD3<Double> {
        switch self {
        case .box: [40, 40, 40]
        case .cylinder: [40, 40, 40]
        case .sphere: [40, 40, 40]
        case .cone: [40, 40, 40]
        case .torus: [50, 50, 10]
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
    /// Skizze, aus der der Körper extrudiert wurde (Gruppierung im Reiter „Ebenen“)
    var sketchID: UUID? = nil

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
    /// Bleibt beim Bearbeiten gleich; verknüpft die Skizze mit ihren Körpern
    var id = UUID()
    var name: String
    var plane: SketchPlane
    var entities: [SketchEntity]
    var constraints: [SketchConstraint] = []
    /// Indizes der Konstruktionselemente (gehören nicht zum Profil)
    var construction: Set<Int> = []
    var isHidden = false

    // Abgeleitet, nicht gespeichert
    private(set) var regions: [SketchRegion] = []
    /// Linienzüge in Weltkoordinaten
    private(set) var lines: [[SIMD3<Float>]] = []
    /// Konstruktionsgeometrie in Weltkoordinaten (gestrichelt dargestellt)
    private(set) var constructionLines: [[SIMD3<Float>]] = []
    /// Je Bereich: Dreiecke (Weltpunkte, je drei) zum Einfärben
    private(set) var fills: [[SIMD3<Float>]] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, plane, entities, constraints, construction, isHidden
    }

    init(name: String, plane: SketchPlane, entities: [SketchEntity], constraints: [SketchConstraint] = [],
         construction: Set<Int> = []) {
        self.name = name
        self.plane = plane
        self.entities = entities
        self.constraints = constraints
        self.construction = construction
        rebuild()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        plane = try container.decode(SketchPlane.self, forKey: .plane)
        entities = try container.decode([SketchEntity].self, forKey: .entities)
        constraints = (try? container.decodeIfPresent([SketchConstraint].self, forKey: .constraints)) ?? []
        construction = (try? container.decodeIfPresent(Set<Int>.self, forKey: .construction)) ?? []
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        rebuild()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(plane, forKey: .plane)
        try container.encode(entities, forKey: .entities)
        try container.encode(constraints, forKey: .constraints)
        try container.encode(construction, forKey: .construction)
        try container.encode(isHidden, forKey: .isHidden)
    }

    /// Elemente, Ebene oder Konstruktionsart geändert: Bereiche und Linien neu berechnen.
    mutating func rebuild() {
        let profile = entities.indices.filter { !construction.contains($0) }
        regions = findRegions(in: profile.map { entities[$0] }).regions
        let plane = self.plane
        let world = { (line: [Point2]) in line.map { SIMD3<Float>(plane.world($0)) } }
        lines = profile.flatMap { entities[$0].drawing }.map(world)
        constructionLines = construction.sorted().filter { entities.indices.contains($0) }
            .flatMap { entities[$0].drawing }.map(world)
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
    var constructions: [ConstructionItem] = []
    var canvases: [CanvasImage] = []
}

/// Körper, Auswahl, Vorschau, Verlauf und Speichern eines Projekts.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var mesh: Mesh = .empty
    @Published private(set) var revision = 0
    @Published private(set) var bodies: [SceneBody] = []
    @Published private(set) var sketches: [StoredSketch] = []
    /// Konstruktionsebenen, -achsen und -punkte
    @Published private(set) var constructions: [ConstructionItem] = []
    /// Bilder (Canvas) auf Standardebenen
    @Published private(set) var canvases: [CanvasImage] = []
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
    /// Skizze, die mit „Verschieben/Rotieren“ bewegt wird (Übernahme mit „Fertig“).
    @Published var movingSketch: Int?
    /// Extrusion gewählter Skizzenbereiche: Wert in mm entlang der Normale der Skizze.
    @Published private(set) var regionValue: Double = 0
    @Published var regionMode: ExtrudeMode = .newBody {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }
    /// Wie in Fusion 360: eine Seite, symmetrisch oder zwei Seiten mit eigenem Abstand
    @Published var regionDirection: ExtrudeDirection = .oneSide {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }
    @Published var regionSecondValue: Double = 10 {
        didSet {
            if regionValue != 0, regionDirection == .twoSides { setRegionValue(regionValue) }
        }
    }
    /// Verjüngungswinkel in Grad (0 = gerade Wände)
    @Published var regionTaper: Double = 0 {
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
        guard let solid = extrudeRegions(regions, plane: sketch.plane, distance: distance, mode: mode,
                                         direction: regionDirection, secondDistance: regionSecondValue,
                                         taper: regionTaper) else {
            message = regionTaper != 0 ? "Mit diesem Verjüngungswinkel nicht möglich – kleineren Winkel versuchen."
                : "Bereich lässt sich nicht extrudieren."
            return
        }
        guard let result = extrusionResult(solid, sourceBody: sketch.plane.sourceBody, mode: mode, sketch: sketch.id) else { return }
        message = nil
        showPreview(result, name: Self.regionPreviewName)
    }

    /// Gewählte Körper verschieben (Vorschau).
    func setMoveOffset(_ offset: SIMD3<Double>) {
        moveOffset = offset
        if movingSketch != nil {
            // Skizzen werden im Viewport verschoben gezeigt und mit „Fertig“ übernommen
            selectionRevision += 1
            return
        }
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
        case .torus:
            // size.x = Außendurchmesser Mitte Rohr, size.z = Rohrdurchmesser
            size.z < size.x
                ? PCKShape.torus(center: base + [0, 0, size.z / 2], axis: [0, 0, 1], majorRadius: size.x / 2,
                                 minorRadius: size.z / 2)
                : nil
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
        // Die Skizze bleibt sichtbar, damit weitere Bereiche (z. B. bei sich überschneidenden Kreisen)
        // extrudiert werden können; ausblenden über „Sichtbarkeit“ bzw. „Elemente“.
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
        commit([], sketches: [], constructions: [], canvases: [], name: "Alles löschen")
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
    func storeSketch(plane: SketchPlane, entities: [SketchEntity], constraints: [SketchConstraint] = [],
                     construction: Set<Int> = [], replacing index: Int?) {
        commitPreview()
        var result = sketches
        if let index, result.indices.contains(index) {
            var sketch = StoredSketch(name: result[index].name, plane: plane, entities: entities,
                                      constraints: constraints, construction: construction)
            sketch.isHidden = result[index].isHidden
            sketch.id = result[index].id
            result[index] = sketch
            commit(bodies, sketches: result, name: "Skizze bearbeiten")
        } else {
            let number = (sketches.count) + 1
            result.append(StoredSketch(name: "Skizze \(number)", plane: plane, entities: entities,
                                       constraints: constraints, construction: construction))
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

    // MARK: Ebenen (Skizze mit ihren Körpern)

    /// Körper, die aus der Skizze extrudiert wurden.
    func bodies(fromSketch index: Int) -> [Int] {
        guard sketches.indices.contains(index) else { return [] }
        let id = sketches[index].id
        return bodies.indices.filter { bodies[$0].sketchID == id }
    }

    /// Körper ohne (noch vorhandene) Skizze: Grundkörper, STEP-Import, Skizze gelöscht.
    var unassignedBodies: [Int] {
        let ids = Set(sketches.map(\.id))
        return bodies.indices.filter { bodies[$0].sketchID.map { !ids.contains($0) } ?? true }
    }

    /// Ganze Ebene ein- oder ausblenden: Skizze und alle Körper daraus.
    func setLayerHidden(_ hidden: Bool, sketch index: Int) {
        guard sketches.indices.contains(index) else { return }
        commitPreview()
        sketches[index].isHidden = hidden
        for body in bodies(fromSketch: index) {
            bodies[body].isHidden = hidden
        }
        if hidden { clearSelectionState() }
        remesh()
        refreshHighlight()
        save()
    }

    /// Ebene sichtbar, wenn Skizze oder einer ihrer Körper sichtbar ist.
    func isLayerVisible(_ index: Int) -> Bool {
        guard sketches.indices.contains(index) else { return false }
        return !sketches[index].isHidden || bodies(fromSketch: index).contains { !bodies[$0].isHidden }
    }

    /// Mehrere Körper auf einmal ein- oder ausblenden (Ordner „Körper“ im Browser).
    func setBodiesHidden(_ hidden: Bool, bodies indices: [Int]) {
        let valid = indices.filter { bodies.indices.contains($0) }
        guard !valid.isEmpty else { return }
        commitPreview()
        for index in valid { bodies[index].isHidden = hidden }
        if hidden { clearSelectionState() }
        remesh()
        refreshHighlight()
        save()
    }

    /// Skizze im Browser antippen: alle ihre Bereiche wählen (danach z. B. am Pfeil extrudieren).
    func selectSketch(_ index: Int) {
        guard sketches.indices.contains(index) else { return }
        if sketches[index].isHidden { setSketchHidden(false, sketch: index) }
        dropPreview()
        selectRegions(sketches[index].regions.indices.map { RegionRef(sketch: index, region: $0) })
    }

    func rename(sketch index: Int, to name: String) {
        guard sketches.indices.contains(index), !name.isEmpty else { return }
        sketches[index].name = name
        save()
    }

    // MARK: Sichtbarkeit

    var showsSketches: Bool { sketches.contains { !$0.isHidden } }
    var showsCanvases: Bool { canvases.contains { !$0.isHidden } }
    var showsConstructions: Bool { constructions.contains { !$0.isHidden } }

    /// Alle Skizzen ein- oder ausblenden.
    func setSketchesHidden(_ hidden: Bool) {
        guard !sketches.isEmpty else { return }
        commitPreview()
        for index in sketches.indices { sketches[index].isHidden = hidden }
        if hidden, !selectedRegions.isEmpty { clearSelectionState() }
        refreshHighlight()
        save()
    }

    /// Alle Bilder ein- oder ausblenden.
    func setCanvasesHidden(_ hidden: Bool) {
        guard !canvases.isEmpty else { return }
        for index in canvases.indices { canvases[index].isHidden = hidden }
        selectionRevision += 1
        save()
    }

    /// Alle Konstruktionsebenen, -achsen und -punkte ein- oder ausblenden.
    func setConstructionsHidden(_ hidden: Bool) {
        guard !constructions.isEmpty else { return }
        for index in constructions.indices { constructions[index].isHidden = hidden }
        selectionRevision += 1
        save()
    }

    /// Ergebnis einer Extrusion je Modus: neuer Körper, mit dem Flächenkörper vereinigt oder von allen abgezogen.
    private func extrusionResult(_ solid: PCKShape, sourceBody: Int?, mode: ExtrudeMode, sketch: UUID? = nil) -> [SceneBody]? {
        switch mode {
        case .newBody:
            return bodies + [newBody(solid, name: "Körper", sketch: sketch)]
        case .union:
            // Mit dem Körper der Skizzenfläche vereinigen, sonst mit dem zuletzt erzeugten.
            let target = sourceBody.flatMap { bodies.indices.contains($0) ? $0 : nil } ?? bodies.indices.last
            guard let target else { return [newBody(solid, name: "Körper", sketch: sketch)] }
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
        future.append(currentEntry(name: entry.name))
        restore(entry)
    }

    func redo() {
        dropPreview()
        guard let entry = future.popLast() else { return }
        history.append(currentEntry(name: entry.name))
        restore(entry)
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

    /// Körper (nil = alle) im gewählten Format; nil bei Fehler (Meldung in message).
    func exportData(_ format: ExportFormat, bodies indices: [Int]? = nil) -> Data? {
        let chosen = (indices ?? Array(bodies.indices)).filter { bodies.indices.contains($0) }
        guard !chosen.isEmpty else {
            message = "Kein Körper zum Exportieren."
            return nil
        }
        if format == .step {
            return stepData(chosen)
        }
        // Feinere Triangulierung als für die Anzeige, damit Rundungen im Druck glatt werden
        let meshes = chosen.map { index in
            ExportMesh(name: bodies[index].name, color: bodies[index].color,
                       mesh: Mesh(bodies[index].shape.triangulate(deflection: 0.01), body: index))
        }
        switch format {
        case .threeMF: return MeshExport.threeMF(meshes)
        case .stl: return MeshExport.stl(meshes)
        case .obj: return MeshExport.obj(meshes)
        case .step: return nil
        }
    }

    func stepData(_ indices: [Int]? = nil) -> Data? {
        guard PCKShape.stepAvailable else {
            message = "STEP braucht OpenCASCADE (siehe README)."
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: url) }
        let shapes = (indices ?? Array(bodies.indices)).filter { bodies.indices.contains($0) }.map { bodies[$0].shape }
        guard PCKShape.writeSTEP(shapes, path: url.path(percentEncoded: false)),
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

    private func newBody(_ shape: PCKShape, name: String, sketch: UUID? = nil) -> SceneBody {
        let number = bodies.count + 1
        return SceneBody(shape: shape, name: "\(name) \(number)",
                         color: SceneBody.palette[bodies.count % SceneBody.palette.count], sketchID: sketch)
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

    private func commit(_ newBodies: [SceneBody], sketches newSketches: [StoredSketch]? = nil,
                        constructions newConstructions: [ConstructionItem]? = nil,
                        canvases newCanvases: [CanvasImage]? = nil, name: String) {
        history.append(currentEntry(name: name))
        future.removeAll()
        bodies = newBodies
        if let newSketches { sketches = newSketches }
        if let newConstructions { constructions = newConstructions }
        if let newCanvases { canvases = newCanvases }
        afterChange()
    }

    private func currentEntry(name: String) -> HistoryEntry {
        HistoryEntry(name: name, bodies: bodies, sketches: sketches, constructions: constructions, canvases: canvases)
    }

    private func restore(_ entry: HistoryEntry) {
        bodies = entry.bodies
        sketches = entry.sketches
        constructions = entry.constructions
        canvases = entry.canvases
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
        movingSketch = nil
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
        var sketchID: UUID?
    }

    private var modelURL: URL? { folder?.appending(path: "model.step") }
    private var metaURL: URL? { folder?.appending(path: "bodies.json") }
    private var sketchesURL: URL? { folder?.appending(path: "sketches.json") }
    private var constructionsURL: URL? { folder?.appending(path: "constructions.json") }
    private var canvasesURL: URL? { folder?.appending(path: "canvases.json") }

    private func load() {
        if let url = sketchesURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([StoredSketch].self, from: data) {
            sketches = stored
        }
        if let url = constructionsURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([ConstructionItem].self, from: data) {
            constructions = stored
        }
        if let url = canvasesURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([CanvasImage].self, from: data) {
            canvases = stored
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
                                 isHidden: meta.isHidden, sketchID: meta.sketchID)
            }
            return SceneBody(shape: shape, name: "Körper \(index + 1)", color: SceneBody.palette[index % SceneBody.palette.count])
        }
    }

    private func save() {
        if let sketchesURL, let data = try? JSONEncoder().encode(sketches) {
            try? data.write(to: sketchesURL)
        }
        if let constructionsURL, let data = try? JSONEncoder().encode(constructions) {
            try? data.write(to: constructionsURL)
        }
        if let canvasesURL, let data = try? JSONEncoder().encode(canvases) {
            try? data.write(to: canvasesURL)
        }
        guard PCKShape.stepAvailable, let modelURL, let metaURL else { return }
        let path = modelURL.path(percentEncoded: false)
        if bodies.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            _ = PCKShape.writeSTEP(bodies.map(\.shape), path: path)
        }
        let metas = bodies.map {
            BodyMeta(name: $0.name, color: [$0.color.x, $0.color.y, $0.color.z], isHidden: $0.isHidden, sketchID: $0.sketchID)
        }
        if let data = try? JSONEncoder().encode(metas) {
            try? data.write(to: metaURL)
        }
    }
}

// MARK: - Konstruktionsgeometrie, Bilder, Bezüge

enum ConstructionKind: String, CaseIterable, Identifiable, Codable {
    case plane = "Ebene"
    case axis = "Achse"
    case point = "Punkt"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .plane: "square.dashed"
        case .axis: "line.diagonal.arrow"
        case .point: "smallcircle.filled.circle"
        }
    }
}

/// Konstruktionsebene, -achse oder -punkt (wie bei Shapr3D/Fusion 360 als Bezug für Skizzen, Muster, Drehen, Teilen).
struct ConstructionItem: Codable, Identifiable {
    var id = UUID()
    var kind: ConstructionKind
    var name: String
    var origin: SIMD3<Double>
    /// Normale (Ebene) bzw. Richtung (Achse); beim Punkt unbenutzt
    var direction: SIMD3<Double>
    var isHidden = false

    var sketchPlane: SketchPlane { SketchPlane(point: origin, normal: direction, isOnFace: false) }
}

/// Bild (Canvas) auf einer Standardebene, z. B. als Vorlage zum Nachzeichnen.
struct CanvasImage: Codable, Identifiable {
    var id = UUID()
    var name: String
    var fileName: String
    var plane: BasePlane = .top
    /// Breite in mm; die Höhe folgt dem Seitenverhältnis
    var width: Double = 100
    /// Höhe / Breite
    var aspect: Double
    /// Mitte in der Ebene (lokal, mm)
    var offset: Point2 = .zero
    var opacity: Double = 0.85
    var isHidden = false

    /// Ecken (links unten, rechts unten, rechts oben, links oben) in Weltkoordinaten.
    var corners: [SIMD3<Double>] {
        let frame = SketchPlane.base(plane)
        let w = width / 2, h = width * aspect / 2
        return [Point2(-w, -h), Point2(w, -h), Point2(w, h), Point2(-w, h)].map { frame.world(offset + $0) }
    }
}

/// Bezugsebene für Teilen und Schnittansicht.
enum ReferencePlane: Hashable {
    /// Normale entlang X (0), Y (1) oder Z (2)
    case world(Int)
    case construction(UUID)
    case face(FaceRef)
}

/// Bezugsachse für Muster und Drehen.
enum ReferenceAxis: Hashable {
    /// X (0), Y (1) oder Z (2) durch den Ursprung
    case world(Int)
    /// Linie der Skizze des gewählten Bereichs (Index des Elements)
    case sketchLine(Int)
    case construction(UUID)
}

/// Linie einer gespeicherten Skizze (Index des Elements), z. B. als Drehachse.
struct SketchLineRef: Identifiable {
    let index: Int
    let name: String

    var id: Int { index }
}

/// Ausrichten je Achse am ersten gewählten Körper.
enum AlignMode: String, CaseIterable, Identifiable {
    case none = "–"
    case min = "Min"
    case center = "Mitte"
    case max = "Max"

    var id: Self { self }
}

func unitAxis(_ index: Int) -> SIMD3<Double> {
    var v = SIMD3<Double>(0, 0, 0)
    v[index] = 1
    return v
}

extension ModelStore {
    // MARK: Bezüge auflösen

    func resolve(_ plane: ReferencePlane) -> (origin: SIMD3<Double>, normal: SIMD3<Double>)? {
        switch plane {
        case .world(let i):
            return (.zero, unitAxis(i))
        case .construction(let id):
            guard let item = constructions.first(where: { $0.id == id }), item.kind == .plane else { return nil }
            return (item.origin, simd_normalize(item.direction))
        case .face(let face):
            guard let p = self.plane(of: face) else { return nil }
            return (p.anchor, p.normal)
        }
    }

    func resolve(_ axis: ReferenceAxis, sketch: Int? = nil) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        switch axis {
        case .world(let i):
            return (.zero, unitAxis(i))
        case .construction(let id):
            guard let item = constructions.first(where: { $0.id == id }), item.kind == .axis else { return nil }
            return (item.origin, simd_normalize(item.direction))
        case .sketchLine(let entity):
            guard let sketch, sketches.indices.contains(sketch), sketches[sketch].entities.indices.contains(entity),
                  case .line(let a, let b) = sketches[sketch].entities[entity], simd_distance(a, b) > 1e-9 else { return nil }
            let plane = sketches[sketch].plane
            return (plane.world(a), simd_normalize(plane.world(b) - plane.world(a)))
        }
    }

    /// Linien einer Skizze (Index und Name) als mögliche Drehachsen.
    func sketchLines(_ sketch: Int) -> [SketchLineRef] {
        guard sketches.indices.contains(sketch) else { return [] }
        var count = 0
        return sketches[sketch].entities.enumerated().compactMap { index, entity in
            guard case .line = entity else { return nil }
            count += 1
            let kind = sketches[sketch].construction.contains(index) ? "Konstruktionslinie" : "Linie"
            return SketchLineRef(index: index, name: "\(kind) \(count)")
        }
    }

    // MARK: Konstruktionsgeometrie

    func addConstruction(_ kind: ConstructionKind, origin: SIMD3<Double>, direction: SIMD3<Double>) {
        commitPreview()
        let number = constructions.filter { $0.kind == kind }.count + 1
        var result = constructions
        result.append(ConstructionItem(kind: kind, name: "\(kind.rawValue) \(number)", origin: origin,
                                       direction: simd_length(direction) > 1e-12 ? simd_normalize(direction) : [0, 0, 1]))
        commit(bodies, constructions: result, name: "\(kind.rawValue) erstellen")
    }

    func deleteConstruction(_ id: UUID) {
        guard let index = constructions.firstIndex(where: { $0.id == id }) else { return }
        dropPreview()
        var result = constructions
        let name = result.remove(at: index).name
        commit(bodies, constructions: result, name: "\(name) löschen")
    }

    func setConstructionHidden(_ hidden: Bool, id: UUID) {
        guard let index = constructions.firstIndex(where: { $0.id == id }) else { return }
        constructions[index].isHidden = hidden
        selectionRevision += 1
        save()
    }

    // MARK: Bilder

    func canvasURL(_ canvas: CanvasImage) -> URL? {
        folder?.appending(path: canvas.fileName)
    }

    /// Bild (JPEG/PNG-Daten) als Canvas auf der Ebene „Oben“ einfügen.
    func addCanvas(_ data: Data, aspect: Double, name: String = "Bild") {
        guard aspect > 0 else { return }
        commitPreview()
        let fileName = "canvas-\(UUID().uuidString).jpg"
        if let url = folder?.appending(path: fileName) {
            try? data.write(to: url)
        }
        var result = canvases
        result.append(CanvasImage(name: "\(name) \(canvases.count + 1)", fileName: fileName, aspect: aspect))
        commit(bodies, canvases: result, name: "Bild einfügen")
    }

    func updateCanvas(_ canvas: CanvasImage) {
        guard let index = canvases.firstIndex(where: { $0.id == canvas.id }) else { return }
        canvases[index] = canvas
        selectionRevision += 1
        save()
    }

    func deleteCanvas(_ id: UUID) {
        guard let index = canvases.firstIndex(where: { $0.id == id }) else { return }
        var result = canvases
        let name = result.remove(at: index).name
        commit(bodies, canvases: result, name: "\(name) löschen")
    }

    // MARK: Kanten als Linienzüge (Projizieren, Messen, Achsen)

    /// Linienzüge einer Kante in Weltkoordinaten.
    func edgePolylines(_ edge: EdgeRef) -> [[SIMD3<Double>]] {
        var segments: [(SIMD3<Double>, SIMD3<Double>)] = []
        for (i, ref) in mesh.edgeRefs.enumerated() where ref == edge {
            segments.append((SIMD3<Double>(mesh.edges[i * 2]), SIMD3<Double>(mesh.edges[i * 2 + 1])))
        }
        return chain3D(segments)
    }

    /// Linienzüge aller Kanten einer Fläche.
    func edgePolylines(ofFace face: FaceRef) -> [[SIMD3<Double>]] {
        guard bodies.indices.contains(face.body) else { return [] }
        let numbers = bodies[face.body].shape.edgeNumbers(ofFace: face.face).map(\.intValue)
        return numbers.flatMap { edgePolylines(EdgeRef(body: face.body, edge: $0)) }
    }

    private func chain3D(_ segments: [(SIMD3<Double>, SIMD3<Double>)]) -> [[SIMD3<Double>]] {
        var rest = segments
        var result: [[SIMD3<Double>]] = []
        let tolerance = 1e-4
        while let first = rest.popLast() {
            var line = [first.0, first.1]
            var extended = true
            while extended {
                extended = false
                for (i, s) in rest.enumerated() {
                    if simd_distance(s.0, line.last!) < tolerance { line.append(s.1) }
                    else if simd_distance(s.1, line.last!) < tolerance { line.append(s.0) }
                    else if simd_distance(s.1, line.first!) < tolerance { line.insert(s.0, at: 0) }
                    else if simd_distance(s.0, line.first!) < tolerance { line.insert(s.1, at: 0) }
                    else { continue }
                    rest.remove(at: i)
                    extended = true
                    break
                }
            }
            result.append(line)
        }
        return result
    }

    // MARK: Messen

    func length(of edge: EdgeRef) -> Double {
        guard bodies.indices.contains(edge.body) else { return 0 }
        let exact = bodies[edge.body].shape.length(ofEdge: edge.edge)
        if exact > 0 { return exact }
        return edgePolylines(edge).reduce(0) { total, line in
            total + zip(line, line.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        }
    }

    func area(of face: FaceRef) -> Double {
        guard bodies.indices.contains(face.body) else { return 0 }
        let exact = bodies[face.body].shape.area(ofFace: face.face)
        if exact > 0 { return exact }
        var sum: Float = 0
        for (t, ref) in mesh.triangleFaces.enumerated() where ref == face {
            let a = mesh.vertices[Int(mesh.indices[t * 3])].position
            let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])].position
            let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])].position
            sum += simd_length(simd_cross(b - a, c - a)) / 2
        }
        return Double(sum)
    }

    func volume(ofBody body: Int) -> Double {
        bodies.indices.contains(body) ? bodies[body].shape.volume : 0
    }

    // MARK: Ansicht

    /// Nur den gewählten Körper zeigen bzw. alle wieder einblenden.
    func isolate(_ body: Int?) {
        commitPreview()
        if let body, bodies.indices.contains(body) {
            for index in bodies.indices { bodies[index].isHidden = index != body }
        } else {
            for index in bodies.indices { bodies[index].isHidden = false }
        }
        remesh()
        refreshHighlight()
        save()
    }

    var isIsolated: Bool { bodies.contains(where: \.isHidden) }

    // MARK: Auswahl für Werkzeuge

    /// Bereiche erneut wählen (z. B. beim Wechsel ins Werkzeug „Drehen“).
    func selectRegions(_ refs: [RegionRef]) {
        clearSelectionState()
        selectedRegions = refs.filter { sketches.indices.contains($0.sketch) }
        refreshHighlight()
    }

    /// Bereich hinzufügen/entfernen, auch aus verschiedenen Skizzen (Loft).
    func toggleRegionAcrossSketches(_ ref: RegionRef) {
        dropPreview()
        var chosen = selectedRegions
        if let index = chosen.firstIndex(of: ref) {
            chosen.remove(at: index)
        } else {
            chosen.append(ref)
        }
        clearSelectionState()
        selectedRegions = chosen
        refreshHighlight()
    }

    private func regions(_ refs: [RegionRef]) -> [(region: SketchRegion, plane: SketchPlane, sketch: Int)] {
        refs.compactMap { ref in
            guard sketches.indices.contains(ref.sketch), sketches[ref.sketch].regions.indices.contains(ref.region) else {
                return nil
            }
            return (sketches[ref.sketch].regions[ref.region], sketches[ref.sketch].plane, ref.sketch)
        }
    }

    // MARK: Muster, Skalieren, Ausrichten

    func previewLinearPattern(count: Int, spacing: Double, direction: SIMD3<Double>) {
        guard requireKernel(), !selectedBodies.isEmpty, count >= 2 else {
            dropPreview()
            return
        }
        var preview = bodies
        let d = simd_normalize(direction)
        for index in selectedBodies where bodies.indices.contains(index) {
            for k in 1..<count {
                guard let copy = bodies[index].shape.translated(by: d * spacing * Double(k)) else {
                    message = "Muster nicht möglich."
                    return
                }
                var body = bodies[index].with(copy)
                body.name += " (\(k + 1))"
                preview.append(body)
            }
        }
        message = nil
        showPreview(preview, name: "Muster linear")
    }

    func previewCircularPattern(count: Int, angle degrees: Double, axisOrigin: SIMD3<Double>, axis: SIMD3<Double>) {
        guard requireKernel(), !selectedBodies.isEmpty, count >= 2 else {
            dropPreview()
            return
        }
        // Voller Kreis: Kopien gleichmäßig verteilt, sonst bis zum Endwinkel
        let full = abs(abs(degrees) - 360) < 1e-6
        let step = degrees / Double(full ? count : count - 1) * .pi / 180
        var preview = bodies
        for index in selectedBodies where bodies.indices.contains(index) {
            for k in 1..<count {
                guard let copy = bodies[index].shape.rotated(origin: axisOrigin, axis: simd_normalize(axis),
                                                             angle: step * Double(k)) else {
                    message = "Muster nicht möglich."
                    return
                }
                var body = bodies[index].with(copy)
                body.name += " (\(k + 1))"
                preview.append(body)
            }
        }
        message = nil
        showPreview(preview, name: "Muster kreisförmig")
    }

    /// Gewählte Körper um ihre Mitte skalieren.
    func previewScale(factors: SIMD3<Double>) {
        guard requireKernel(), !selectedBodies.isEmpty else { return }
        guard factors.x > 0, factors.y > 0, factors.z > 0, factors != SIMD3<Double>(1, 1, 1) else {
            dropPreview()
            return
        }
        var preview = bodies
        for index in selectedBodies where bodies.indices.contains(index) {
            guard let center = center(ofBody: index),
                  let scaled = bodies[index].shape.scaled(center: center, factors: factors) else {
                message = "Skalieren nicht möglich."
                return
            }
            preview[index] = preview[index].with(scaled)
        }
        message = nil
        showPreview(preview, name: "Skalieren")
    }

    /// Weitere gewählte Körper am ersten ausrichten (je Achse Min, Mitte oder Max).
    func previewAlign(_ modes: [AlignMode]) {
        guard selectedBodies.count >= 2, let reference = mesh.bounds(ofBody: selectedBodies[0]) else {
            dropPreview()
            return
        }
        var preview = bodies
        var moved = false
        for index in selectedBodies.dropFirst() where bodies.indices.contains(index) {
            guard let bounds = mesh.bounds(ofBody: index) else { continue }
            var offset = SIMD3<Double>(0, 0, 0)
            for axis in 0..<3 {
                let r = (Double(reference.min[axis]), Double(reference.max[axis]))
                let b = (Double(bounds.min[axis]), Double(bounds.max[axis]))
                switch modes[axis] {
                case .none: break
                case .min: offset[axis] = r.0 - b.0
                case .center: offset[axis] = (r.0 + r.1) / 2 - (b.0 + b.1) / 2
                case .max: offset[axis] = r.1 - b.1
                }
            }
            guard offset != .zero else { continue }
            guard let shape = bodies[index].shape.translated(by: offset) else {
                message = "Ausrichten nicht möglich."
                return
            }
            preview[index] = preview[index].with(shape)
            moved = true
        }
        guard moved else {
            dropPreview()
            return
        }
        message = nil
        showPreview(preview, name: "Ausrichten")
    }

    // MARK: Drehen, Sweep, Loft

    func previewRevolve(axisOrigin: SIMD3<Double>, axis: SIMD3<Double>, degrees: Double, mode: ExtrudeMode) {
        let chosen = regions(selectedRegions)
        guard requireKernel(), !chosen.isEmpty, degrees != 0 else {
            dropPreview()
            return
        }
        var shapes: [PCKShape] = []
        for entry in chosen {
            guard let shape = PCKShape.revolve(profileWires: profileWires(entry.region, plane: entry.plane),
                                               axisOrigin: axisOrigin, axisDirection: simd_normalize(axis),
                                               angle: max(-360, min(360, degrees)) * .pi / 180) else {
                message = "Drehen nicht möglich (Achse darf das Profil nicht schneiden)."
                dropPreview()
                return
            }
            shapes.append(shape)
        }
        showSolid(shapes, sourceBody: chosen[0].plane.sourceBody, mode: mode, name: "Drehen")
    }

    /// Offene Kurven einer Skizze als Pfad (Kernel-Kodierung), in Reihenfolge verkettet.
    func sweepPath(fromSketch index: Int) -> [NSNumber]? {
        guard sketches.indices.contains(index) else { return nil }
        let sketch = sketches[index]
        var segments = sketch.entities.indices.filter { !sketch.construction.contains($0) }
            .flatMap { sketch.entities[$0].openSegments }
        guard var path = segments.popLast().map({ [$0] }) else { return nil }
        var extended = true
        while extended {
            extended = false
            for (i, s) in segments.enumerated() {
                if simd_distance(s.start, path.last!.end) < 1e-6 { path.append(s) }
                else if simd_distance(s.end, path.last!.end) < 1e-6 { path.append(s.reversed) }
                else if simd_distance(s.end, path.first!.start) < 1e-6 { path.insert(s, at: 0) }
                else if simd_distance(s.start, path.first!.start) < 1e-6 { path.insert(s.reversed, at: 0) }
                else { continue }
                segments.remove(at: i)
                extended = true
                break
            }
        }
        let plane = sketch.plane
        let world = { (p: Point2) -> [NSNumber] in
            let w = plane.world(p)
            return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
        }
        return path.flatMap { $0.code(world) }
    }

    /// Skizzen mit offenen Kurven (mögliche Sweep-Pfade).
    var pathSketches: [Int] {
        sketches.indices.filter { index in
            sketches[index].entities.contains { !$0.openSegments.isEmpty }
        }
    }

    func previewSweep(pathSketch: Int?, mode: ExtrudeMode) {
        let chosen = regions(selectedRegions)
        guard requireKernel(), !chosen.isEmpty, let pathSketch, let path = sweepPath(fromSketch: pathSketch) else {
            dropPreview()
            return
        }
        var shapes: [PCKShape] = []
        for entry in chosen {
            guard let shape = PCKShape.sweep(profileWires: profileWires(entry.region, plane: entry.plane), path: path) else {
                message = "Sweep nicht möglich (Pfad muss am Profil beginnen und darf sich nicht zu eng krümmen)."
                dropPreview()
                return
            }
            shapes.append(shape)
        }
        showSolid(shapes, sourceBody: chosen[0].plane.sourceBody, mode: mode, name: "Sweep")
    }

    /// Loft durch die gewählten Bereiche in Auswahlreihenfolge (je Skizze ein Querschnitt).
    func previewLoft(mode: ExtrudeMode) {
        let chosen = regions(selectedRegions)
        guard requireKernel(), chosen.count >= 2 else {
            dropPreview()
            return
        }
        let sections = chosen.compactMap { profileWires($0.region, plane: $0.plane).first }
        guard let shape = PCKShape.loft(sections: sections) else {
            message = "Loft nicht möglich."
            dropPreview()
            return
        }
        showSolid([shape], sourceBody: chosen[0].plane.sourceBody, mode: mode, name: "Loft")
    }

    private func showSolid(_ shapes: [PCKShape], sourceBody: Int?, mode: ExtrudeMode, name: String) {
        let combined: PCKShape? = shapes.count == 1 ? shapes.first : PCKShape.compound(shapes)
        guard let solid = combined,
              let result = extrusionResult(solid, sourceBody: sourceBody, mode: mode,
                                           sketch: selectedRegions.first.flatMap { sketches.indices.contains($0.sketch) ? sketches[$0.sketch].id : nil }) else {
            dropPreview()
            return
        }
        message = nil
        // Bereichsauswahl bleibt für weitere Änderungen erhalten
        let keep = selectedRegions
        showPreview(result, name: name)
        selectedRegions = keep
        refreshHighlight()
    }

    // MARK: Teilen

    func previewSplit(origin: SIMD3<Double>, normal: SIMD3<Double>) {
        guard requireKernel(), let body = selectedBodies.first, bodies.indices.contains(body) else { return }
        guard let parts = bodies[body].shape.split(planeOrigin: origin, normal: simd_normalize(normal)),
              parts.count == 2 else {
            message = "Die Ebene schneidet den Körper nicht."
            dropPreview()
            return
        }
        message = nil
        var preview = bodies
        preview[body] = preview[body].with(parts[0])
        var second = bodies[body].with(parts[1])
        second.name += " (Teil 2)"
        second.color = SceneBody.palette[(bodies.count + 1) % SceneBody.palette.count]
        preview.append(second)
        showPreview(preview, name: "Körper teilen")
    }

    // MARK: Skizzen bewegen

    /// Mitte der Bereiche bzw. Linien einer Skizze (Welt).
    func center(ofSketch index: Int) -> SIMD3<Double>? {
        guard sketches.indices.contains(index) else { return nil }
        let points = sketches[index].entities.flatMap { $0.drawing.flatMap { $0 } }
        guard let first = points.first else { return nil }
        let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
        return sketches[index].plane.world((lo + hi) / 2)
    }

    func translateSketch(_ index: Int, by offset: SIMD3<Double>) {
        guard sketches.indices.contains(index), offset != .zero else { return }
        var result = sketches
        var plane = result[index].plane
        plane.origin += offset
        plane.anchor += offset
        plane.base = nil
        plane.isOnFace = false
        plane.sourceBody = nil
        result[index].plane = plane
        result[index].rebuild()
        commit(bodies, sketches: result, name: "Skizze verschieben")
    }

    func rotateSketch(_ index: Int, axis: SIMD3<Double>, degrees: Double) {
        guard sketches.indices.contains(index), let center = center(ofSketch: index) else { return }
        commitPreview()
        let rotation = simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis))
        var result = sketches
        var plane = result[index].plane
        plane.origin = center + rotation.act(plane.origin - center)
        plane.anchor = center + rotation.act(plane.anchor - center)
        plane.u = rotation.act(plane.u)
        plane.v = rotation.act(plane.v)
        plane.normal = rotation.act(plane.normal)
        plane.base = nil
        plane.isOnFace = false
        plane.sourceBody = nil
        result[index].plane = plane
        result[index].rebuild()
        commit(bodies, sketches: result, name: "Skizze drehen")
        movingSketch = index
    }

    /// „Skizze skalieren“: alle Elemente um die Mitte der Skizze.
    func scaleSketch(_ index: Int, by factor: Double) {
        guard sketches.indices.contains(index), factor > 0, factor != 1 else { return }
        let sketch = sketches[index]
        let points = sketch.entities.flatMap { $0.drawing.flatMap { $0 } }
        guard let first = points.first else { return }
        let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
        let center = (lo + hi) / 2
        var result = sketches
        result[index].entities = sketch.entities.map { $0.scaled(about: center, by: factor) }
        result[index].constraints = sketch.constraints.map { constraint in
            guard case .lock(let ref, let at) = constraint.variant else { return constraint }
            return SketchConstraint(variant: .lock(ref, at: center + (at - center) * factor))
        }
        result[index].rebuild()
        commit(bodies, sketches: result, name: "Skizze skalieren")
    }
}
