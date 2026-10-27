import Foundation
import simd

enum ExtrudeMode: String, CaseIterable, Identifiable {
    case newBody = "Neuer Körper"
    case union = "Vereinigen"
    case cut = "Abziehen"
    /// Nur was Werkzeug und Körper gemeinsam haben (Fusion 360 „Intersect“)
    case intersect = "Schnittmenge"

    var id: Self { self }
}

/// Wie weit extrudiert wird (Fusion 360 „Extent“).
enum ExtrudeExtent: String, CaseIterable, Identifiable {
    /// Wert bzw. Pfeil
    case distance = "Abstand"
    /// Bis zu einer angetippten Fläche (plus Versatz)
    case toObject = "Bis Objekt"
    /// Durch alle Körper
    case all = "Alle"

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
        case .box: "sc.box"
        case .cylinder: "sc.cylinder"
        case .sphere: "sc.sphere"
        case .cone: "sc.cone"
        case .torus: "sc.torus"
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
        case .union: "sc.combine"
        case .subtract: "square.on.square.dashed"
        case .intersect: "sc.intersect"
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
    /// Ordner im Browser „Ebenen“ (nil = oberste Ebene)
    var folder: String? = nil
    /// Komponente (verknüpfte Kopien): Instanzen mit derselben ID teilen ihre Geometrie (ModelComponents.swift)
    var componentID: UUID? = nil
    /// Lage dieser Instanz, nur starre Bewegungen: Welt = placement · gemeinsame Geometrie
    var placement: simd_double4x4 = matrix_identity_double4x4
    /// Material (Kurzname aus BodyMaterial.all, Materials.swift); nil = keins
    var material: String? = nil
    /// Gewinde am Körper, modelliert oder kosmetisch (ThreadNotes.swift); nil = keine
    var threads: [ThreadNote]? = nil
    /// Oberfläche (Kurzname aus SurfaceFinish.all oder „Eigene:…“, SurfaceFinish.swift); nil = nach Werkstoff
    var finish: String? = nil
    /// Aus Text extrudiert: dessen Inhalt (Textkörper im Browser, SketchTextEdit.swift); nil = kein Text
    var textLabel: String? = nil

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

/// Ordner im Browser „Ebenen“ mit seinen Körpern.
struct BodyFolder: Identifiable {
    var name: String
    var bodies: [Int]
    var id: String { name }
}

/// Körpergeometrie, auf eine Skizzenebene projiziert: Fangpunkte (Ecken, Kantenmitten) und Kanten.
struct SketchGuides {
    var points: [Point2] = []
    var curves: [[Point2]] = []
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
    /// Parametrischer Verlauf (FeatureHistory.swift)
    var features: [Feature] = []
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
    /// Projektvariablen (Einfügen › Variable), nutzbar in jedem Zahlenfeld und in Skizzenmaßen
    @Published private(set) var variables: [ProjectVariable] = []
    @Published var message: String?

    // Auswahl
    @Published private(set) var selection: FaceRef?
    /// Weitere gewählte Flächen (Mehrfachauswahl zum gemeinsamen Extrudieren bzw. Versetzen)
    @Published private(set) var extraFaces: [FaceRef] = []
    /// Alle gewählten Flächen, die zuerst gewählte vorn
    var selectedFaces: [FaceRef] { (selection.map { [$0] } ?? []) + extraFaces }
    @Published private(set) var selectedEdges: [EdgeRef] = []
    @Published private(set) var selectedBodies: [Int] = []
    /// Gewählte Skizzenbereiche (alle aus derselben Skizze).
    @Published private(set) var selectedRegions: [RegionRef] = []
    @Published private(set) var selectionIndices: [UInt32] = []
    @Published private(set) var edgeHighlight: [SIMD3<Float>] = []
    @Published private(set) var selectionRevision = 0
    /// Ganze Körper hervorgehoben (nicht einzelne Flächen): dann nur leicht getönt, damit die Oberfläche
    /// (Chrom, Gold, Lack …) sichtbar bleibt (Renderer.updateSelection)
    @Published private(set) var selectionTintsBodies = false
    /// Vorschau „Oberfläche für alle Körper“ (Sichtbarkeit): Kurzname aus SurfaceFinish.all, nil = aus.
    /// Nur Darstellung, wird nicht gespeichert; die Oberflächen der Körper bleiben unverändert.
    @Published var previewFinishAll: String? = nil {
        didSet {
            if previewFinishAll != oldValue { remesh() }
        }
    }

    // Ziehpfeile
    @Published var edgeOperation: EdgeOperation = .fillet {
        didSet {
            if edgeValue > 0 { setEdgeValue(edgeValue) }
        }
    }
    /// Radius bzw. Fasenbreite in mm; 0 = nichts angewendet.
    @Published private(set) var edgeValue: Double = 0
    /// Zweiter Fasenabstand (auf der anderen Nachbarfläche); nil = gleich breite Fase
    @Published private(set) var edgeSecondValue: Double?
    /// Variable Rundung: Radius am Kantenende (edgeValue gilt am Anfang); nil = gleichbleibender Radius
    @Published private(set) var edgeEndValue: Double?
    /// Kantenmitte und Richtung ins Material.
    @Published private(set) var edgeHandle: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    /// Flächenmitte und Normale der gewählten ebenen Fläche (Extrudieren per Pfeil).
    @Published private(set) var faceHandle: (origin: SIMD3<Double>, direction: SIMD3<Double>)?
    @Published private(set) var faceValue: Double = 0
    @Published private(set) var moveOffset: SIMD3<Double> = .zero
    /// Verschieben, Drehen und Übersetzen erzeugen Kopien; die Originale bleiben stehen
    @Published var moveCopies = false
    /// Kopieren als Reihe (Shapr3D „×5“ bzw. „÷5“): Anzahl der Kopien
    @Published var moveArrayCount = 1
    /// true = Kopien gleichmäßig zwischen Original und Ziel verteilen (÷), false = Abstand je Kopie (×)
    @Published var moveArrayDivides = false
    /// Zuletzt übernommene Extrusionshöhe (Doppeltippen auf Bereich bzw. Fläche wiederholt sie)
    @Published private(set) var lastExtrudeValue: Double?
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
    /// Innere Konturen (z. B. ein Kreis im Rechteck): false = aussparen (Loch bleibt), true = durchgehend
    /// über die ganze Außenkontur extrudieren.
    @Published var regionThroughHoles = false {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }
    /// Ob ein gewählter Bereich innere Konturen hat (dann gibt es die Wahl „Aussparen/Durchgehend“).
    var selectedRegionsHaveHoles: Bool {
        selectedRegions.contains { ref in
            sketches.indices.contains(ref.sketch) && sketches[ref.sketch].regions.indices.contains(ref.region)
                && !sketches[ref.sketch].regions[ref.region].holes.isEmpty
        }
    }
    /// Ausmaß wie in Fusion 360: Abstand, bis zu einer Fläche oder durch alles
    @Published var regionExtent: ExtrudeExtent = .distance {
        didSet {
            if regionExtent == .all { extrudeThroughAll() }
            if regionExtent == .toObject { message = "Fläche oder Kante antippen, bis zu der extrudiert wird." }
        }
    }
    /// Abstand zur angetippten Fläche bei „Bis Objekt“ (positiv = darüber hinaus)
    @Published var regionExtentOffset: Double = 0
    /// Verjüngungswinkel in Grad (0 = gerade Wände)
    @Published var regionTaper: Double = 0 {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }
    /// Dünn extrudieren (Fusion 360 „Dünn“): nur eine Wand entlang der Konturen, Stärke und Seite
    @Published var regionThin = false {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }
    @Published var regionThinThickness: Double = 2 {
        didSet {
            if regionValue != 0, regionThin { setRegionValue(regionValue) }
        }
    }
    @Published var regionThinSide: ThinSide = .inside {
        didSet {
            if regionValue != 0, regionThin { setRegionValue(regionValue) }
        }
    }
    /// Dünn „Zwei Seiten“ (SolidCraft): Stärke der äußeren Wand; nil = eine Wand nach regionThinSide
    @Published var regionThinThickness2: Double? {
        didSet {
            if regionValue != 0, regionThin { setRegionValue(regionValue) }
        }
    }
    /// Start versetzt (SolidCraft „Start: Versatz“): Profil um diesen Wert entlang der Skizzennormale verschoben
    @Published var regionStartOffset: Double = 0 {
        didSet {
            if regionValue != 0 { setRegionValue(regionValue) }
        }
    }
    /// Symmetrisch als Gesamtabstand (SolidCraft, neue Extrusionen aus dem Eigenschaften-Panel): je Seite die
    /// Hälfte des Werts. false = alter PencilCAD-Weg (Wert je Seite)
    @Published var regionSymmetricTotal = false {
        didSet {
            if regionValue != 0, regionDirection == .symmetric { setRegionValue(regionValue) }
        }
    }
    /// Offener Modellbefehl (Workspace.command): eine neue Auswahl übernimmt die Vorschau nicht still, sondern
    /// verwirft sie (übernommen wird nur mit OK). Vom Workspace gesetzt.
    var commitsOnSelect = true

    // Vorschau und Verlauf
    @Published private(set) var previewName: String?
    /// Skizze des Körpers, der gerade abgerundet bzw. gefast wird: ihre (eckige) Kontur passt nicht mehr zum
    /// Körper und wird während der Vorschau ausgeblendet, beim Übernehmen dauerhaft (Kai: „die Außenlinie muss weg“).
    @Published var previewHiddenSketch: UUID?
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var future: [HistoryEntry] = []
    private var previewBodies: [SceneBody]?
    /// Vorschau ohne flächige Hervorhebung der gewählten Körper (Boolesch: Ergebnis bleibt erkennbar). Eine solche
    /// Vorschau wird nie mit commitPreview übernommen (Werkzeuge nur ausgeblendet, kein Verlaufseintrag), sondern
    /// mit applyBoolean (MoldTools.swift)
    private var plainPreview = false
    /// Parametrischer Verlauf: Features in Reihenfolge, Zeitleiste unten (FeatureHistory.swift, TimelineBar.swift)
    @Published var features: [Feature] = []
    let featureRecorder = FeatureRecorder()

    /// Projektordner (model.step + bodies.json); nil = nichts speichern.
    let folder: URL?

    var canUndo: Bool { !history.isEmpty || previewBodies != nil }
    var canRedo: Bool { !future.isEmpty }
    var isEmpty: Bool { bodies.isEmpty && sketches.isEmpty }
    var hasPreview: Bool { previewBodies != nil }
    /// Angezeigte Körper (Vorschau bzw. Stand)
    var shownBodies: [SceneBody] { previewBodies ?? bodies }

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

    /// safeOpen: übrig gebliebene Hänger-Marke (HangGuard.swift) – dann sicherer Modus: Verlauf ohne model.step
    /// bis vor das hängende Feature nachbauen, dieses und alle folgenden unterdrücken.
    init(folder: URL?, safeOpen: HangGuard.Marker? = nil) {
        self.folder = folder
        let plan = safeOpen.flatMap { self.safeOpenPlan(for: $0) }
        load(skipModel: plan != nil)
        remesh()
        if let plan {
            openSafely(plan)
            // Rückgängig darf nicht zum leeren Stand vor dem Nachbau zurück (würde model.step leeren)
            history.removeAll()
        }
    }

    // MARK: Auswahl

    /// Wählt eine Fläche (nil = nichts). Eine offene Vorschau wird vorher übernommen.
    func select(face: FaceRef?) {
        if commitsOnSelect { commitPreview() } else { dropPreview() }
        clearSelectionState()
        selection = face
        if let face, let plane = plane(of: face), let center = mesh.centroid(of: face) {
            faceHandle = (SIMD3<Double>(center), plane.normal)
        }
        refreshHighlight()
    }

    /// Weitere Fläche zur Auswahl nehmen bzw. wieder herausnehmen (wie Shapr3D: mehrere Flächen zugleich ziehen).
    /// commitsPreview false: eine offene Vorschau des Werkzeugs wird verworfen (es rechnet danach neu).
    func toggleFace(_ face: FaceRef, commitsPreview: Bool = true) {
        guard selection != nil else {
            if commitsPreview { select(face: face) } else { selectForTool(face) }
            return
        }
        if commitsPreview, commitsOnSelect { commitPreview() } else { dropPreview() }
        var faces = selectedFaces
        if let index = faces.firstIndex(of: face) {
            faces.remove(at: index)
        } else {
            faces.append(face)
        }
        let handle = faceHandle
        let primary = selection
        clearSelectionState()
        selection = faces.first
        extraFaces = Array(faces.dropFirst())
        if let first = faces.first {
            if first == primary, let handle {
                faceHandle = handle
            } else if let plane = plane(of: first), let center = mesh.centroid(of: first) {
                faceHandle = (SIMD3<Double>(center), plane.normal)
            }
        }
        refreshHighlight()
    }

    /// Fläche für ein Werkzeug wählen (Versetzen, Ersetzen …): Vorschau verwerfen statt übernehmen.
    func selectForTool(_ face: FaceRef?) {
        dropPreview()
        clearSelectionState()
        selection = face
        refreshHighlight()
    }

    /// Kante antippen: zur Auswahl hinzufügen bzw. wieder entfernen.
    /// Kanten eines anderen Körpers beginnen eine neue Auswahl.
    func toggleEdge(_ edge: EdgeRef) {
        if commitsOnSelect { commitPreview() } else { dropPreview() }
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

    /// Mehrere Körper auf einmal wählen (Rahmenauswahl).
    func selectBodies(_ list: [Int]) {
        if commitsOnSelect { commitPreview() } else { dropPreview() }
        var chosen: [Int] = []
        for body in list where bodies.indices.contains(body) && !chosen.contains(body) {
            chosen.append(body)
        }
        clearSelectionState()
        selectedBodies = chosen
        refreshHighlight()
    }

    func clearSelection() {
        if commitsOnSelect { commitPreview() } else { dropPreview() }
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
        if !keepPreview {
            if commitsOnSelect { commitPreview() } else { dropPreview() }
        }
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

    /// Fase mit zwei Abständen ein- (Wert) bzw. ausschalten (nil) und die Vorschau erneuern.
    func setEdgeSecondValue(_ value: Double?) {
        edgeSecondValue = value.map { max(0.01, $0) }
        if edgeValue > 0 { setEdgeValue(edgeValue) }
    }

    /// Variable Rundung ein- (Endradius) bzw. ausschalten (nil) und die Vorschau erneuern.
    func setEdgeEndValue(_ value: Double?) {
        edgeEndValue = value.map { max(0.01, $0) }
        if edgeValue > 0 { setEdgeValue(edgeValue) }
    }

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
        // Rundung vor Schnitt (BlendBeforeCuts.swift): Wurde die Kante erst durch einen späteren Schnitt (z. B.
        // eine Text-Tasche) zerteilt, wird sie im Verlauf vor diesem Schnitt ganz verrundet und der Schnitt
        // schneidet danach wieder hinein
        if previewBlendBeforeCuts(value: value) { return }
        // Sonst direkt am Körper, mit allen Teilstücken derselben geraden Kante (keine Stückelung)
        let blendEdges = completedEdgeChain(selectedEdges, body: body)
        let numbers = blendEdges.map { NSNumber(value: $0.edge) }
        let shape = bodies[body].shape
        let operation = edgeOperation
        // Fase mit zwei Abständen (Fusion 360 „Zwei Abstände“); nil = gleich breit
        let second = operation == .chamfer ? edgeSecondValue : nil
        func blend(_ amount: Double) -> PCKShape? {
            if operation == .fillet { return shape.filleting(edges: numbers, radius: amount) }
            if let second { return shape.chamfering(edges: numbers, distance: amount, distance2: second) }
            return shape.chamfering(edges: numbers, distance: amount)
        }
        // Variable Rundung (Fusion 360): Anfangsradius value, Endradius edgeEndValue
        if operation == .fillet, let end = edgeEndValue {
            guard let result = shape.filleting(edges: numbers, radius: value, endRadius: end) else {
                message = "Rundung \(value.formatted()) → \(end.formatted()) mm an dieser Kante nicht möglich."
                dropPreview()
                return
            }
            message = nil
            var preview = bodies
            preview[body] = preview[body].with(result)
            previewHiddenSketch = bodies[body].sketchID
            showPreview(preview, name: "Variabel abrunden")
            noteBlend(.fillet, value: value, end: end, edges: blendEdges)
            return
        }
        if second != nil {
            guard let result = blend(value) else {
                message = "Fase \(value.formatted()) × \((second ?? 0).formatted()) mm an dieser Kante nicht möglich."
                dropPreview()
                return
            }
            message = nil
            var preview = bodies
            preview[body] = preview[body].with(result)
            previewHiddenSketch = bodies[body].sketchID
            showPreview(preview, name: operation.rawValue)
            noteBlend(operation, value: value, second: second, edges: blendEdges)
            return
        }
        // Zu groß: nicht einfach nichts zeigen, sondern den größten möglichen Wert (einmal je Auswahl gesucht)
        let key = EdgeLimitKey(edges: blendEdges, operation: operation, shape: ObjectIdentifier(shape))
        var amount = value
        var result: PCKShape?
        if let limit = edgeLimit, limit.key == key, value > limit.value {
            amount = limit.value
        } else {
            result = blend(value)
        }
        if result == nil {
            if edgeLimit?.key != key || value <= (edgeLimit?.value ?? 0) {
                let found = shape.maximumBlend(edges: numbers, upTo: value, chamfer: operation == .chamfer)
                edgeLimit = (key, (found * 100).rounded(.down) / 100)
            }
            amount = edgeLimit?.value ?? 0
            result = amount > 0 ? blend(amount) : nil
        }
        guard let result else {
            message = "\(operation.rawValue) an dieser Kante nicht möglich."
            dropPreview()
            return
        }
        message = amount < value - 1e-9
            ? "\(operation.rawValue): größter möglicher Wert hier \(amount.formatted()) mm." : nil
        var preview = bodies
        preview[body] = preview[body].with(result)
        previewHiddenSketch = bodies[body].sketchID
        showPreview(preview, name: operation.rawValue)
        noteBlend(operation, value: amount, edges: blendEdges)
    }

    /// Wie in Fusion 360: Während Kanten zum Abrunden bzw. Fasen gewählt sind, übernimmt das Antippen einer
    /// vorhandenen Rundungs- bzw. Fasenfläche deren Radius bzw. Breite (samt Art). false = keine solche Fläche.
    func adoptBlend(from face: FaceRef) -> Bool {
        guard !selectedEdges.isEmpty else { return false }
        // Während der Vorschau zeigt das Netz die Vorschaukörper: deren Flächennummern gelten
        let shown = previewBodies ?? bodies
        guard shown.indices.contains(face.body),
              let values = shown[face.body].shape.blend(ofFace: face.face)?.map(\.doubleValue),
              values.count == 2, values[1] > 1e-6 else { return false }
        let operation: EdgeOperation = values[0] == 1 ? .fillet : .chamfer
        let value = (values[1] * 100).rounded() / 100
        if edgeOperation != operation { edgeOperation = operation }
        setEdgeValue(value)
        if message == nil {
            message = "\(operation == .fillet ? "Radius" : "Fase") übernommen: \(value.formatted()) mm"
        }
        return true
    }

    /// Größter möglicher Radius bzw. Fasenbreite für die aktuelle Kantenauswahl (Halbierungssuche, gemerkt)
    private struct EdgeLimitKey: Equatable {
        var edges: [EdgeRef]
        var operation: EdgeOperation
        var shape: ObjectIdentifier
    }
    private var edgeLimit: (key: EdgeLimitKey, value: Double)?

    /// Gewählte ebene Fläche um value mm herausziehen (> 0) oder hineindrücken (< 0).
    func setFaceValue(_ value: Double) {
        faceValue = value
        guard let face = selection, bodies.indices.contains(face.body) else { return }
        guard value != 0 else {
            dropPreview()
            return
        }
        guard requireKernel() else { return }
        // Mehrere Flächen: je Körper alle zugleich, jede entlang ihrer eigenen Normale
        var preview = bodies
        let faces = selectedFaces.filter { bodies.indices.contains($0.body) }
        for body in Set(faces.map(\.body)) {
            let numbers = faces.filter { $0.body == body }.map { NSNumber(value: $0.face) }
            guard let result = bodies[body].shape.extruding(faces: numbers, distance: value) else {
                message = faces.count > 1 ? "Diese Flächen lassen sich nicht zusammen extrudieren."
                    : "Extrudieren der Fläche nicht möglich."
                return
            }
            preview[body] = preview[body].with(result)
        }
        message = nil
        showPreview(preview, name: faces.count > 1 ? "Flächen extrudieren" : "Extrudieren")
        noteFaceExtrude(distance: value)
    }

    private static let regionPreviewName = "Extrudieren"

    /// „Durchgehend“: innere Konturen ignorieren und die Außenkontur voll extrudieren. Mitgewählte Bereiche,
    /// die in einem solchen Loch liegen, entfallen, weil sie schon enthalten sind.
    private static func filledRegions(_ regions: [SketchRegion]) -> [SketchRegion] {
        let filled = regions.map { region in
            SketchRegion(outer: region.outer, holes: [], polygon: region.polygon, area: abs(signedArea(region.polygon)))
        }
        return filled.indices.filter { index in
            let polygon = filled[index].polygon
            guard !polygon.isEmpty else { return false }
            let probe = polygon.reduce(.zero, +) / Double(polygon.count)
            return !filled.indices.contains { other in
                other != index && filled[other].area > filled[index].area && Self.polygon(filled[other].polygon, contains: probe)
            }
        }.map { filled[$0] }
    }

    /// Punkt im Polygon (Strahlverfahren).
    private static func polygon(_ polygon: [Point2], contains point: Point2) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// „Alle“: so weit, dass das Profil durch alle sichtbaren Körper reicht (in Pfeilrichtung, sonst dagegen).
    func extrudeThroughAll() {
        guard let handle = regionHandle, simd_length(handle.direction) > 1e-12 else { return }
        let direction = simd_normalize(handle.direction)
        var ahead = 0.0, behind = 0.0
        for body in bodies.indices where !bodies[body].isHidden {
            guard let box = mesh.bounds(ofBody: body) else { continue }
            for k in 0..<8 {
                let corner = SIMD3<Double>(Double(k & 1 == 0 ? box.min.x : box.max.x),
                                           Double(k & 2 == 0 ? box.min.y : box.max.y),
                                           Double(k & 4 == 0 ? box.min.z : box.max.z))
                let t = simd_dot(corner - handle.origin, direction)
                ahead = max(ahead, t)
                behind = min(behind, t)
            }
        }
        // Toleranz 1e-3: Hüllquader kommen als Float aus dem Netz; eine Skizze auf der Körperfläche läge sonst um
        // Rundungsreste „vor“ dem Körper und bekäme 1 mm Aufsatz statt Loch
        let value = ahead > 1e-3 ? ahead + 1 : behind < -1e-3 ? behind - 1 : 0
        guard value != 0 else {
            message = "Kein Körper in Richtung des Profils."
            return
        }
        setRegionValue((value * 1000).rounded() / 1000)
    }

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
        let chosen = selectedRegions.compactMap { sketch.regions.indices.contains($0.region) ? sketch.regions[$0.region] : nil }
        let regions = regionThroughHoles ? Self.filledRegions(chosen) : chosen
        var mode = regionMode
        var distance = value
        // Auf einer Fläche ins Material gedrückt: abziehen
        if sketch.plane.isOnFace, mode == .union, value < 0 {
            mode = .cut
            distance = -value
        }
        // Symmetrisch als Gesamtabstand (SolidCraft): je Seite die Hälfte
        if regionDirection == .symmetric, regionSymmetricTotal { distance /= 2 }
        // Start versetzt: Profil entlang der Normale verschoben (Bereiche bleiben in Skizzenkoordinaten)
        var plane = sketch.plane
        if regionStartOffset != 0 {
            plane.origin += plane.normal * regionStartOffset
            plane.anchor += plane.normal * regionStartOffset
        }
        guard mode == .newBody || requireKernel() else { return }
        // Kai: Loch „bis hinten“ – endet das Abziehen an (oder knapp vor/hinter) der Rückseite, durchgehend schneiden,
        // statt eine hauchdünne Haut bzw. eine koplanare Bodenfläche stehen zu lassen
        var throughNote: String?
        if mode == .cut, regionDirection == .oneSide,
           let through = cutThroughDistance(regions, plane: plane, distance: distance) {
            distance = through
            throughNote = "Durchgehend: das Loch reicht bis zur Rückseite."
        }
        if regionThin {
            let thinSolid: PCKShape? = regionThinThickness2.map {
                thinBothSides(regions, plane: plane, distance: distance, mode: mode, outer: $0)
            } ?? thinExtrudeRegions(regions, plane: plane, distance: distance, mode: mode)
            guard let solid = thinSolid else {
                message = "Dünne Wand mit \(regionThinThickness.formatted()) mm hier nicht möglich."
                return
            }
            guard var result = extrusionResult(solid, sourceBody: sketch.plane.sourceBody, mode: mode, sketch: sketch.id) else { return }
            labelTextBodies(&result, regions: regions, sketch: sketch, mode: mode)
            message = nil
            showPreview(result, name: Self.regionPreviewName)
            noteExtrude(mode: mode, distance: distance)
            return
        }
        guard let solid = extrudeRegions(regions, plane: plane, distance: distance, mode: mode,
                                         direction: regionDirection, secondDistance: regionSecondValue,
                                         taper: regionTaper) else {
            message = regionTaper != 0 ? "Mit diesem Verjüngungswinkel nicht möglich – kleineren Winkel versuchen."
                : "Bereich lässt sich nicht extrudieren."
            return
        }
        guard var result = extrusionResult(solid, sourceBody: sketch.plane.sourceBody, mode: mode, sketch: sketch.id) else { return }
        // Abziehen ohne Wirkung (Werkzeug zeigt aus dem Material heraus): melden statt stillschweigend nichts zu tun
        if mode == .cut, !cutChangedBodies(result) {
            dropPreview()
            message = "Abziehen trifft keinen Körper – Abstand ins Material (negativ) ziehen oder Richtung umkehren."
            return
        }
        labelTextBodies(&result, regions: regions, sketch: sketch, mode: mode)
        message = throughNote ?? SketchRegionMerge.newBodyNote(regions, mode: mode)
        // Kai: nach dem Loch lag die halbtransparente Bereichsfüllung der Flächenskizze noch über der Öffnung
        // („ich sehe den Kreis noch“). Sind alle Bereiche der Flächenskizze abgezogen, blendet OK sie aus
        // (rückgängig machbar); mit weiteren Bereichen bleibt sie zum Weiterarbeiten sichtbar.
        let consumed = Set(selectedRegions.filter { $0.sketch == first.sketch }.map(\.region))
        previewHiddenSketch = mode == .cut && sketch.plane.isOnFace && !sketch.regions.isEmpty
            && consumed.count >= sketch.regions.count ? sketch.id : nil
        showPreview(result, name: Self.regionPreviewName)
        noteExtrude(mode: mode, distance: distance)
    }

    /// Hat das Abziehen mindestens einen Körper verändert (Volumen)?
    private func cutChangedBodies(_ result: [SceneBody]) -> Bool {
        guard PCKShape.kernelAvailable, result.count == bodies.count else { return true }
        for index in bodies.indices {
            let before = bodies[index].shape.volume
            let after = result[index].shape.volume
            if abs(before - after) > max(1e-6, abs(before) * 1e-9) { return true }
        }
        return false
    }

    /// Abziehen „bis hinten“: liegt die Rückseite des Materials höchstens eine Toleranz vor bzw. hinter dem
    /// Werkzeugende, wird der Abstand über die Rückseite hinaus verlängert (OpenCASCADE lässt sonst bei koplanarem
    /// bzw. knapp verfehltem Ende eine Haut stehen). distance wie in setRegionValue; nil = nichts ändern.
    /// in: Körperstand (Nachbau im Verlauf), sonst die aktuellen Körper.
    func cutThroughDistance(_ regions: [SketchRegion], plane: SketchPlane, distance: Double,
                            in state: [SceneBody]? = nil) -> Double? {
        guard PCKShape.kernelAvailable, distance != 0, distance.isFinite else { return nil }
        let shapes: [PCKShape] = (state ?? bodies).filter { !$0.isHidden }.map(\.shape)
        guard !shapes.isEmpty else { return nil }
        let depth = abs(distance)
        let main = plane.extrusionSign(mode: .cut) * distance
        let axis: SIMD3<Double> = simd_normalize(plane.normal) * (main >= 0 ? 1.0 : -1.0)
        // 2,5 % der Tiefe, mindestens 0,05 mm, höchstens 0,5 mm
        let tolerance = min(0.5, max(0.05, depth * 0.025))
        guard depth > tolerance else { return nil }
        func inside(_ p: SIMD3<Double>) -> Bool { shapes.contains { $0.contains(point: p) } }
        for region in regions {
            for probe in Self.interiorProbes(region) {
                let start: SIMD3<Double> = plane.world(probe)
                let before: SIMD3<Double> = start + axis * (depth - tolerance)
                let after: SIMD3<Double> = start + axis * (depth + tolerance)
                // Kurz vor dem Ende noch Material, kurz dahinter keines: die Rückseite liegt am Werkzeugende
                if inside(before), !inside(after) {
                    let longer = depth + 2 * tolerance
                    return distance >= 0 ? longer : -longer
                }
            }
        }
        return nil
    }

    /// Einige Punkte sicher im Inneren eines Bereichs (außerhalb seiner Löcher): Schwerpunkt und zur Mitte
    /// gerückte Eckpunkte.
    private static func interiorProbes(_ region: SketchRegion) -> [Point2] {
        let polygon = region.polygon
        guard polygon.count >= 3 else { return [] }
        let center = polygon.reduce(Point2.zero, +) / Double(polygon.count)
        var candidates: [Point2] = [center]
        let step = max(1, polygon.count / 6)
        for index in stride(from: 0, to: polygon.count, by: step) {
            candidates.append(polygon[index] + (center - polygon[index]) * 0.1)
        }
        return candidates.filter { p in
            polygonContains(polygon, p) && !region.holes.contains { polygonContains($0.polygon, p) }
        }
    }

    /// Dünn „Zwei Seiten“ (SolidCraft): innen die Wandstärke, außen eine eigene Stärke – zwei Wände vereinigt.
    private func thinBothSides(_ regions: [SketchRegion], plane: SketchPlane, distance: Double, mode: ExtrudeMode,
                               outer: Double) -> PCKShape? {
        guard !regions.isEmpty, distance != 0, regionThinThickness > 0, outer > 0, PCKShape.kernelAvailable else { return nil }
        let sign = plane.extrusionSign(mode: mode)
        let main = sign * distance
        let from: Double
        let length: Double
        switch regionDirection {
        case .oneSide:
            from = mode == .cut ? -sign * 0.01 : 0
            length = main - from
        case .symmetric:
            from = -main
            length = 2 * main
        case .twoSides:
            let second = abs(regionSecondValue) * (main >= 0 ? -1 : 1)
            from = second
            length = main - second
        }
        guard length != 0 else { return nil }
        let start: SIMD3<Double> = plane.origin + plane.normal * from
        let vector: SIMD3<Double> = plane.normal * length
        var shapes: [PCKShape] = []
        for region in regions {
            let wires = profileWires(region, plane: plane, offset: from)
            guard let inner = PCKShape.thinPrism(profileWires: wires, planeOrigin: start, planeNormal: plane.normal,
                                                 thickness: regionThinThickness, side: ThinSide.inside.kernelValue,
                                                 direction: vector),
                  let outerWall = PCKShape.thinPrism(profileWires: wires, planeOrigin: start, planeNormal: plane.normal,
                                                     thickness: outer, side: ThinSide.outside.kernelValue,
                                                     direction: vector),
                  let wall = inner.fusing(outerWall) else { return nil }
            shapes.append(wall)
        }
        return shapes.count == 1 ? shapes[0] : PCKShape.compound(shapes)
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
        // Reihe: × = jede Kopie um den vollen Versatz weiter, ÷ = Versatz auf die Kopien aufgeteilt
        let count = moveCopies ? max(1, min(moveArrayCount, 200)) : 1
        let step = moveArrayDivides ? offset / Double(count) : offset
        for index in selectedBodies where preview.indices.contains(index) {
            for k in 1...count {
                guard let moved = bodies[index].shape.translated(by: step * Double(k)) else {
                    message = "Verschieben nicht möglich."
                    return
                }
                if moveCopies {
                    var copy = bodies[index].with(moved, moving: .translation(step * Double(k)))
                    copy.name += count > 1 ? " (Kopie \(k))" : " (Kopie)"
                    preview.append(copy)
                } else {
                    preview[index] = preview[index].with(moved, moving: .translation(step * Double(k)))
                }
            }
        }
        message = nil
        showPreview(preview, name: count > 1 ? "Reihe kopieren" : moveCopies ? "Kopieren" : "Verschieben")
        noteMove(offset: offset, copies: moveCopies, count: count, divides: moveArrayDivides)
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
            result[index] = result[index].with(rotated, moving: .rotation(origin: center, axis: axis,
                                                                          angle: degrees * .pi / 180))
        }
        let valid = chosen.filter { bodies.indices.contains($0) }
        noteRotate(valid, centers: valid.map { center(ofBody: $0) ?? .zero }, axis: axis, degrees: degrees, copies: false,
                   direct: true)
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
        notePrimitive(primitive, size: size, base: base)
    }

    /// Gewählte Körper spiegeln (Vorschau): an fixed (Fläche bzw. Konstruktionsebene) oder an der Ebene plane
    /// durch die Körpermitte.
    func previewMirror(_ plane: MirrorPlane, keepOriginal: Bool,
                       at fixed: (origin: SIMD3<Double>, normal: SIMD3<Double>)? = nil) {
        guard requireKernel(), !selectedBodies.isEmpty else { return }
        var preview = bodies
        for index in selectedBodies where bodies.indices.contains(index) {
            guard let origin = fixed?.origin ?? center(ofBody: index),
                  let mirrored = bodies[index].shape.mirrored(planeOrigin: origin, normal: fixed?.normal ?? plane.normal) else {
                message = "Spiegeln nicht möglich."
                return
            }
            if keepOriginal {
                var copy = bodies[index].with(mirrored).unlinked()
                copy.name += " (gespiegelt)"
                preview.append(copy)
            } else {
                preview[index] = preview[index].with(mirrored).unlinked()
            }
        }
        message = nil
        showPreview(preview, name: "Spiegeln")
        noteMirror(plane, keepOriginal: keepOriginal, fixed: fixed)
    }

    /// Schale (Vorschau): alle gewählten Flächen des Körpers werden offen, Wandstärke thickness nach innen.
    /// closed = keine Fläche offen, der Körper wird ein geschlossener Hohlkörper.
    func previewShell(thickness: Double, closed: Bool = false) {
        guard requireKernel(), let face = selection, bodies.indices.contains(face.body) else { return }
        let faces = closed ? [] : selectedFaces.filter { $0.body == face.body }.map { NSNumber(value: $0.face) }
        guard thickness > 0,
              let result = bodies[face.body].shape.shelling(removingFaces: faces, thickness: thickness) else {
            message = "Schale mit \(thickness.formatted()) mm nicht möglich."
            dropPreview()
            return
        }
        message = closed ? "Hohlkörper: innen geschlossen, von außen nicht sichtbar (Schnittansicht zeigt ihn)." : nil
        var preview = bodies
        preview[face.body] = preview[face.body].with(result)
        showPreview(preview, name: "Schale")
        noteShell(thickness: thickness, closed: closed)
    }

    /// Boolesche Operation: target bleibt, die anderen Körper werden verbraucht (keepTools: bleiben stehen).
    /// clearance: Spiel in mm, um das die Werkzeuge beim Abziehen aufgedickt werden (MoldTools.swift).
    func applyBoolean(_ kind: BooleanKind, target: Int, tools: [Int], keepTools: Bool = false, clearance: Double = 0) {
        guard requireKernel(), bodies.indices.contains(target), !tools.isEmpty else { return }
        commitPreview()
        var shape = bodies[target].shape
        for tool in tools where bodies.indices.contains(tool) && tool != target {
            guard let other = Self.booleanTool(bodies[tool].shape, kind: kind, clearance: clearance) else {
                message = Self.clearanceFailure(clearance)
                return
            }
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
        if !keepTools {
            for tool in tools.filter({ $0 != target && result.indices.contains($0) }).sorted(by: >) {
                result.remove(at: tool)
            }
        }
        noteBoolean(kind, target: target, tools: tools, keepTools: keepTools, clearance: clearance)
        commit(result, name: kind.rawValue)
    }

    func commitPreview() {
        // Boolesche Vorschau (plain): verwerfen statt mit ausgeblendeten Werkzeugen und ohne Verlauf übernehmen
        // (z. B. beim Schließen des Projekts); „Fertig“ rechnet sie mit applyBoolean neu
        if plainPreview, previewBodies != nil {
            dropPreview()
            return
        }
        guard let preview = previewBodies, let name = previewName else { return }
        previewBodies = nil
        previewName = nil
        if regionValue != 0 {
            lastExtrudeValue = regionValue
        } else if faceValue != 0 {
            lastExtrudeValue = faceValue
        }
        // Die Skizze bleibt sichtbar, damit weitere Bereiche (z. B. bei sich überschneidenden Kreisen)
        // extrudiert werden können; ausblenden über „Sichtbarkeit“ bzw. „Elemente“. Nur nach Abrunden/Fase
        // verschwindet sie, weil ihre eckige Kontur sonst neben der Rundung stehen bleibt (rückgängig machbar).
        var newSketches: [StoredSketch]?
        if let id = previewHiddenSketch, let index = sketches.firstIndex(where: { $0.id == id }),
           !sketches[index].isHidden {
            var list = sketches
            list[index].isHidden = true
            newSketches = list
        }
        previewHiddenSketch = nil
        takePreviewFeature()
        commit(preview, sketches: newSketches, name: name)
    }

    func cancelPreview() {
        dropPreview()
        edgeValue = 0
        // Variable Rundung gilt nur für die eine Rundung, nicht für die nächste Auswahl bzw. das nächste Werkzeug
        edgeEndValue = nil
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
        noteDelete(chosen.filter { bodies.indices.contains($0) })
        commit(result, name: chosen.count == 1 ? "Löschen" : "\(chosen.count) Körper löschen")
    }

    /// Körper aus mehreren Teilen (ältere Projekte, Importe) in Einzelkörper zerlegen – auch sich berührende Teile,
    /// solange sie noch eigene Solids sind (nicht verschmolzen).
    func separateBody(_ index: Int) {
        guard bodies.indices.contains(index) else { return }
        let parts = bodies[index].shape.solidParts()
        guard parts.count > 1 else {
            message = "„\(bodies[index].name)“ ist ein einziger Volumenkörper. Berührende Teile sind verschmolzen – "
                + "zum Zerlegen das Werkzeug „Körper teilen“ nutzen."
            return
        }
        dropPreview()
        clearSelectionState()
        var result = bodies
        let source = result.remove(at: index)
        for (offset, part) in parts.enumerated() {
            var piece = source.with(part)
            if offset > 0 {
                piece.name = "\(source.name).\(offset + 1)"
                piece.color = SceneBody.palette[(result.count + offset) % SceneBody.palette.count]
            }
            result.insert(piece, at: index + offset)
        }
        commit(result, name: "In Einzelkörper trennen")
        message = "\(parts.count) Einzelkörper – jeder ist jetzt einzeln wählbar."
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
            // Fertige Oberfläche wird zur eigenen Farbe mit ähnlichem Glanz (SurfaceFinish.swift)
            result[index].finish = SurfaceFinish.recolored(result[index].finish)
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
            // Parametrischer Verlauf: Körper aus dieser Skizze folgen (FeatureHistory.swift)
            rebuildFeatures(sketches: result, changed: [sketch.id], name: "Skizze bearbeiten")
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
        embedSketchCopy(result[index])
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
        return bodies.indices.filter { bodies[$0].sketchID == id && bodies[$0].folder == nil }
    }

    /// Ordner des Browsers (alphabetisch) und ihre Körper.
    var bodyFolders: [BodyFolder] {
        let grouped = Dictionary(grouping: bodies.indices.filter { bodies[$0].folder != nil }) { bodies[$0].folder ?? "" }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { BodyFolder(name: $0, bodies: grouped[$0] ?? []) }
    }

    /// Körper ohne (noch vorhandene) Skizze: Grundkörper, STEP-Import, Skizze gelöscht.
    var unassignedBodies: [Int] {
        let ids = Set(sketches.map(\.id))
        return bodies.indices.filter { bodies[$0].folder == nil && (bodies[$0].sketchID.map { !ids.contains($0) } ?? true) }
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
    /// joinTouching: bei „Neuer Körper“ sich berührende Teile zu einem Körper verschmelzen (Wände aus Linien).
    func extrusionResult(_ solid: PCKShape, sourceBody: Int?, mode: ExtrudeMode, sketch: UUID? = nil,
                         joinTouching: Bool = false) -> [SceneBody]? {
        switch mode {
        case .newBody:
            // Kai: jeder Bereich einer Skizze wird ein eigener Körper (einzeln wählbar), auch wenn Bereiche sich
            // berühren; nur getrennte Stücke innerhalb eines Bereichs werden ebenfalls einzeln
            var result = bodies
            let parts: [PCKShape] = joinTouching ? solid.separatedSolids() : solid.separatedParts()
            for part in parts {
                result.append(SceneBody(shape: part, name: "Körper \(result.count + 1)",
                                        color: SceneBody.palette[result.count % SceneBody.palette.count], sketchID: sketch))
            }
            return result
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
        case .intersect:
            // Körper, die das Werkzeug berührt, behalten nur den gemeinsamen Teil; die übrigen bleiben
            var result: [SceneBody] = []
            var touched = false
            for body in bodies {
                if let common = body.shape.intersecting(solid), common.volume > 1e-9 {
                    result.append(body.with(common))
                    touched = true
                } else {
                    result.append(body)
                }
            }
            guard touched else {
                message = "Schnittmenge leer – das Profil berührt keinen Körper."
                return nil
            }
            return result
        }
    }

    // MARK: Verlauf

    /// Name des Schritts, den Rückgängig zurücknimmt bzw. Wiederholen wiederholt (für die Meldung).
    var lastStepName: String? { previewBodies == nil ? history.last?.name : nil }
    var nextStepName: String? { future.last?.name }

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
        if format == .usdz {
            guard let url = usdzFile(chosen), let data = try? Data(contentsOf: url) else { return nil }
            return data
        }
        // Feinere Triangulierung als für die Anzeige, damit Rundungen im Druck glatt werden
        let meshes = chosen.map { index in
            ExportMesh(name: bodies[index].name, color: bodies[index].displayColor,
                       mesh: Mesh(bodies[index].shape.triangulate(deflection: 0.01), body: index))
        }
        switch format {
        case .threeMF: return MeshExport.threeMF(meshes)
        case .stl: return MeshExport.stl(meshes)
        case .obj: return MeshExport.obj(meshes)
        case .step, .usdz: return nil
        }
    }

    /// USDZ-Datei im temporären Ordner (für AR Quick Look und den Export); nil bei Fehler.
    func usdzFile(_ indices: [Int]? = nil) -> URL? {
        let chosen = (indices ?? Array(bodies.indices)).filter { bodies.indices.contains($0) && (indices != nil || !bodies[$0].isHidden) }
        guard !chosen.isEmpty else {
            message = "Kein sichtbarer Körper."
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "PencilCAD-AR.usdz")
        let list = chosen.map { index in
            (name: bodies[index].name, appearance: bodies[index].appearance,
             mesh: Mesh(bodies[index].shape.triangulate(deflection: 0.05), body: index))
        }
        guard USDZExport.write(list, to: url) else {
            message = "USDZ konnte nicht geschrieben werden."
            return nil
        }
        return url
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

    func newBody(_ shape: PCKShape, name: String, sketch: UUID? = nil) -> SceneBody {
        let number = bodies.count + 1
        return SceneBody(shape: shape, name: "\(name) \(number)",
                         color: SceneBody.palette[bodies.count % SceneBody.palette.count], sketchID: sketch)
    }

    func requireKernel() -> Bool {
        if !PCKShape.kernelAvailable {
            message = "Diese Funktion braucht OpenCASCADE (siehe README)."
        }
        return PCKShape.kernelAvailable
    }

    func showPreview(_ preview: [SceneBody], name: String, plain: Bool = false) {
        featureRecorder.preview = nil
        featureRecorder.orderedPreview = nil
        previewBodies = preview
        previewName = name
        plainPreview = plain
        remesh()
        refreshHighlight()
    }

    func dropPreview() {
        featureRecorder.preview = nil
        featureRecorder.orderedPreview = nil
        guard previewBodies != nil else { return }
        previewBodies = nil
        previewName = nil
        previewHiddenSketch = nil
        remesh()
        refreshHighlight()
    }

    /// Netz bearbeiten (MeshSculpt.swift): angezeigtes Netz während eines Pinselstrichs, ohne Kernel.
    func showSculptMesh(_ sculpted: Mesh) {
        mesh = sculpted
        revision += 1
    }

    /// Wieder die echten Körper zeigen (Pinselstriche verworfen).
    func endSculptMesh() {
        remesh()
        refreshHighlight()
    }

    func commit(_ newBodies: [SceneBody], sketches newSketches: [StoredSketch]? = nil,
                        constructions newConstructions: [ConstructionItem]? = nil,
                        canvases newCanvases: [CanvasImage]? = nil, name: String) {
        history.append(currentEntry(name: name))
        future.removeAll()
        let previous = bodies
        // Komponenten: Änderung einer Instanz auf alle übertragen (ModelComponents.swift)
        let synced = syncedComponents(newBodies)
        bodies = synced.bodies
        if let newSketches { sketches = newSketches }
        if let newConstructions { constructions = newConstructions }
        if let newCanvases { canvases = newCanvases }
        recordFeature(name: name, previous: previous)
        afterChange()
        if let note = synced.note { message = note }
    }

    private func currentEntry(name: String) -> HistoryEntry {
        HistoryEntry(name: name, bodies: bodies, sketches: sketches, constructions: constructions, canvases: canvases,
                     features: features)
    }

    private func restore(_ entry: HistoryEntry) {
        bodies = entry.bodies
        sketches = entry.sketches
        constructions = entry.constructions
        canvases = entry.canvases
        features = entry.features
        featuresRestored()
        afterChange()
    }

    private func afterChange() {
        message = nil
        previewBodies = nil
        previewName = nil
        previewHiddenSketch = nil
        remesh()
        clearSelectionState()
        refreshHighlight()
        save()
    }

    private func clearSelectionState() {
        selection = nil
        extraFaces = []
        selectedEdges = []
        selectedBodies = []
        selectedRegions = []
        regionValue = 0
        edgeHandle = nil
        faceHandle = nil
        edgeValue = 0
        edgeEndValue = nil
        faceValue = 0
        moveOffset = .zero
        movingSketch = nil
    }

    /// Hervorhebung passend zu Auswahl und Vorschau. Während einer Vorschau ändern sich Flächen- und
    /// Kantennummern, daher werden dann nur ganze Körper hervorgehoben.
    private func refreshHighlight() {
        if previewBodies == nil, selection != nil {
            selectionIndices = selectedFaces.flatMap { mesh.triangleIndices(of: $0) }
        } else if previewBodies != nil, plainPreview {
            selectionIndices = []
        } else {
            selectionIndices = selectedBodies.flatMap { mesh.triangleIndices(ofBody: $0) }
        }
        selectionTintsBodies = !(previewBodies == nil && selection != nil)
        edgeHighlight = previewBodies == nil ? mesh.edgeSegments(of: selectedEdges) : []
        selectionRevision += 1
    }

    private func remesh() {
        var combined = Mesh()
        // Vorschau „Oberfläche für alle Körper“ überdeckt die eigene Oberfläche nur in der Darstellung
        let override: SIMD3<Float>? = previewFinishAll.flatMap { SurfaceFinish.named($0)?.appearance.encoded }
        for (index, body) in (previewBodies ?? bodies).enumerated() where !body.isHidden {
            combined.append(Mesh(body.shape.triangulate(deflection: 0.05), body: index,
                                 color: override ?? body.renderColor))
        }
        mesh = combined
        revision += 1
    }

    // MARK: Messen

    func centerOfMass(ofBody body: Int) -> SIMD3<Double>? {
        guard bodies.indices.contains(body), let values = bodies[body].shape.centerOfMass?.map(\.doubleValue),
              values.count == 3 else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    /// Kürzester Abstand zwischen zwei Körpern samt den beiden nächsten Punkten.
    func minimumDistance(between first: Int, and second: Int)
        -> (distance: Double, a: SIMD3<Double>, b: SIMD3<Double>)? {
        guard first != second, bodies.indices.contains(first), bodies.indices.contains(second),
              let v = bodies[first].shape.minimumDistance(to: bodies[second].shape)?.map(\.doubleValue),
              v.count == 7 else { return nil }
        return (v[0], SIMD3(v[1], v[2], v[3]), SIMD3(v[4], v[5], v[6]))
    }

    // MARK: Flächen während einer Vorschau

    /// Während einer Vorschau zeigt das Netz die Vorschaukörper, deren Flächennummern von denen der echten
    /// Körper abweichen. Liefert die Fläche des echten Körpers, die dem angetippten Punkt am nächsten liegt
    /// (nil = den Körper gibt es nur in der Vorschau).
    func originalFace(_ face: FaceRef, near point: SIMD3<Float>?) -> FaceRef? {
        guard let preview = previewBodies else { return face }
        guard bodies.indices.contains(face.body) else { return nil }
        if preview.indices.contains(face.body), preview[face.body].shape === bodies[face.body].shape { return face }
        guard let point else { return nil }
        let shape = bodies[face.body].shape
        let original: Mesh
        if let cached = originalMesh, cached.shape === shape, cached.body == face.body {
            original = cached.mesh
        } else {
            original = Mesh(shape.triangulate(deflection: 0.05), body: face.body)
            originalMesh = (shape, face.body, original)
        }
        var best: (distance: Float, face: FaceRef)?
        for t in 0..<original.triangleCount {
            let a = original.vertices[Int(original.indices[t * 3])].position
            let b = original.vertices[Int(original.indices[t * 3 + 1])].position
            let c = original.vertices[Int(original.indices[t * 3 + 2])].position
            let d = Mesh.distance(from: point, toTriangle: a, b, c)
            if best.map({ d < $0.distance }) ?? true { best = (d, original.triangleFaces[t]) }
        }
        return best?.face
    }
    private var originalMesh: (shape: PCKShape, body: Int, mesh: Mesh)?

    // MARK: Fläche versetzen, ersetzen, umhüllen, abdrücken

    /// Gewählte Flächen (auch auf mehreren Körpern) um distance versetzen (Vorschau). Wie Shapr3D „Offset Face“:
    /// Nachbarflächen wachsen bzw. schrumpfen mit; Zylinderflächen werden dicker bzw. Bohrungen enger.
    /// explainsFailure: bei Fehler Grund und größten möglichen Wert suchen (nur bei Eingabe, nicht beim Ziehen).
    func previewOffsetFaces(distance: Double, explainsFailure: Bool = false) {
        guard requireKernel() else { return }
        let faces = selectedFaces
        guard !faces.isEmpty else { return }
        guard abs(distance) > 1e-9 else {
            dropPreview()
            return
        }
        var preview = bodies
        for (body, group) in Dictionary(grouping: faces, by: \.body) where bodies.indices.contains(body) {
            let numbers = group.map(\.face)
            guard let result = offsetShape(bodies[body].shape, faces: numbers, distance: distance) else {
                message = explainsFailure ? offsetFailureMessage(bodies[body].shape, faces: numbers, distance: distance)
                    : "Versetzen um \(LengthUnit.current.format(abs(distance))) nicht möglich – Wert eingeben zeigt den Grund."
                dropPreview()
                return
            }
            preview[body] = preview[body].with(result)
        }
        message = nil
        showPreview(preview, name: faces.count > 1 ? "\(faces.count) Flächen versetzen" : "Fläche versetzen")
    }

    /// Zylinder einer Fläche: Achse, Radius und ob sie nach außen gewölbt ist (Zapfen) oder nach innen (Bohrung).
    func cylinder(of face: FaceRef) -> (origin: SIMD3<Double>, axis: SIMD3<Double>, radius: Double, convex: Bool)? {
        guard bodies.indices.contains(face.body),
              let v = bodies[face.body].shape.cylinder(ofFace: face.face)?.map(\.doubleValue), v.count == 7 else { return nil }
        let origin = SIMD3(v[0], v[1], v[2]), axis = simd_normalize(SIMD3(v[3], v[4], v[5]))
        let points = mesh.trianglePoints(of: face)
        var convex = true
        if points.count >= 3 {
            let a = SIMD3<Double>(points[0]), b = SIMD3<Double>(points[1]), c = SIMD3<Double>(points[2])
            var radial = (a + b + c) / 3 - origin
            radial -= simd_dot(radial, axis) * axis
            convex = simd_dot(simd_cross(b - a, c - a), radial) >= 0
        }
        return (origin, axis, v[6], convex)
    }

    /// Ausdehnung eines Körpers entlang einer Richtung (für „Gesamt“ beim Versetzen).
    func extent(ofBody body: Int, along direction: SIMD3<Double>) -> Double? {
        let indices = mesh.triangleIndices(ofBody: body)
        guard !indices.isEmpty, simd_length(direction) > 1e-12 else { return nil }
        let n = simd_normalize(direction)
        var low = Double.infinity, high = -Double.infinity
        for index in indices where Int(index) < mesh.vertices.count {
            let d = simd_dot(SIMD3<Double>(mesh.vertices[Int(index)].position), n)
            low = min(low, d)
            high = max(high, d)
        }
        return high >= low ? high - low : nil
    }

    /// Fläche ersetzen: gewählte ebene Flächen bis an die Ebene der Zielfläche verlängern bzw. kürzen (Vorschau).
    func previewReplaceFaces(target: FaceRef) {
        guard requireKernel() else { return }
        guard let plane = plane(of: target) else {
            message = "Die Zielfläche muss eben sein."
            return
        }
        let faces = selectedFaces.filter { $0 != target }
        guard !faces.isEmpty else {
            message = "Erst die Flächen antippen, die ersetzt werden sollen."
            return
        }
        var preview = bodies
        for (body, group) in Dictionary(grouping: faces, by: \.body) where bodies.indices.contains(body) {
            guard let result = bodies[body].shape.replacing(faces: group.map { NSNumber(value: $0.face) },
                                                            planeOrigin: plane.origin, planeNormal: plane.normal) else {
                message = "Fläche ersetzen nicht möglich – geht mit ebenen Flächen, die die Zielebene schneiden würden."
                dropPreview()
                return
            }
            preview[body] = preview[body].with(result)
        }
        message = nil
        showPreview(preview, name: "Fläche ersetzen")
    }

    /// Umhüllen und Prägen (Shapr3D „Wrap and Emboss“): gewählte Skizzenbereiche auf die Zylinderfläche legen und
    /// um depth herausheben (> 0) bzw. eingravieren (< 0); rotation dreht das Motiv um die Achse (Grad).
    func previewWrap(onto face: FaceRef, depth: Double, rotation: Double) {
        guard requireKernel(), abs(depth) > 1e-6 else {
            dropPreview()
            return
        }
        guard let cylinder = cylinder(of: face) else {
            message = "Umhüllen geht auf Zylinderflächen – eine runde Fläche antippen."
            return
        }
        guard let first = selectedRegions.first, sketches.indices.contains(first.sketch) else {
            message = "Erst Skizzenbereiche antippen (Text, Logo …), dann die Zylinderfläche."
            return
        }
        let sketch = sketches[first.sketch]
        let regions = selectedRegions.filter { $0.sketch == first.sketch && sketch.regions.indices.contains($0.region) }
            .map { sketch.regions[$0.region] }
        let o = cylinder.origin, d = cylinder.axis, r = cylinder.radius
        let world = regions.flatMap(\.polygon).map { sketch.plane.world($0) }
        guard !world.isEmpty else { return }
        var radial = world.reduce(.zero, +) / Double(world.count) - o
        radial -= simd_dot(radial, d) * d
        guard simd_length(radial) > 1e-9 else {
            message = "Die Skizze liegt auf der Achse – auf einer Ebene neben dem Zylinder skizzieren."
            return
        }
        let e = simd_normalize(radial), w = simd_cross(d, e)
        let turn = rotation * .pi / 180
        // Bei einer Bohrung zeigt „heraus“ zur Achse hin
        let outward = cylinder.convex ? 1.0 : -1.0
        let overlap = 0.02
        let embossing = depth > 0
        let innerRadius = embossing ? r - outward * overlap : r - outward * abs(depth)
        let outerRadius = embossing ? r + outward * depth : r + outward * overlap
        guard innerRadius > 0, outerRadius > 0 else {
            message = "Gravur tiefer als der Radius."
            return
        }
        let maxStep = r * 3 * .pi / 180
        func dense(_ polygon: [Point2]) -> [Point2] {
            var result: [Point2] = []
            for k in polygon.indices {
                let a = polygon[k], b = polygon[(k + 1) % polygon.count]
                let n = max(1, min(64, Int((simd_distance(a, b) / maxStep).rounded(.up))))
                for i in 0..<n { result.append(a + (b - a) * (Double(i) / Double(n))) }
            }
            return result
        }
        func wrapped(_ polygon: [Point2], radius: Double) -> [NSNumber] {
            polygon.flatMap { p -> [NSNumber] in
                let q = sketch.plane.world(p) - o
                let angle = simd_dot(q, w) / r + turn
                let point = o + d * simd_dot(q, d) + (e * cos(angle) + w * sin(angle)) * radius
                return [NSNumber(value: point.x), NSNumber(value: point.y), NSNumber(value: point.z)]
            }
        }
        func solid(_ polygon: [Point2]) -> PCKShape? {
            let points = dense(polygon)
            guard points.count >= 3 else { return nil }
            return PCKShape.ruledSolid(between: wrapped(points, radius: innerRadius), and: wrapped(points, radius: outerRadius))
        }
        var tools: [PCKShape] = []
        for region in regions {
            guard var shape = solid(region.outer.polygon) else { continue }
            for hole in region.holes {
                if let cut = solid(hole.polygon), let result = shape.cutting(cut) { shape = result }
            }
            tools.append(shape)
        }
        guard bodies.indices.contains(face.body), !tools.isEmpty else {
            message = "Umhüllen nicht möglich."
            return
        }
        var shape = bodies[face.body].shape
        for tool in tools {
            guard let result = embossing ? shape.fusing(tool) : shape.cutting(tool) else {
                message = "Umhüllen nicht möglich – Motiv kleiner machen oder Tiefe ändern."
                dropPreview()
                return
            }
            shape = result
        }
        var preview = bodies
        preview[face.body] = preview[face.body].with(shape)
        message = nil
        previewHiddenSketch = sketch.id
        showPreview(preview, name: embossing ? "Prägen" : "Gravieren")
    }

    /// Kante abdrücken (Imprint): gewählte Skizzenbereiche als neue Kanten auf den Körper übertragen, z. B. um
    /// danach nur einen Teil einer Fläche zu ziehen.
    func previewImprint(onto body: Int) {
        guard requireKernel(), bodies.indices.contains(body) else { return }
        guard let first = selectedRegions.first, sketches.indices.contains(first.sketch) else {
            message = "Erst Skizzenbereiche antippen, dann den Körper."
            return
        }
        let sketch = sketches[first.sketch]
        let faces = selectedRegions.filter { $0.sketch == first.sketch && sketch.regions.indices.contains($0.region) }
            .compactMap { PCKShape.face(profileWires: profileWires(sketch.regions[$0.region], plane: sketch.plane)) }
        guard let tool = faces.count == 1 ? faces.first : PCKShape.compound(faces),
              let result = bodies[body].shape.imprinting(tool) else {
            message = "Abdrücken nicht möglich – die Skizze muss auf einer Fläche des Körpers liegen."
            return
        }
        var preview = bodies
        preview[body] = preview[body].with(result)
        message = nil
        previewHiddenSketch = sketch.id
        showPreview(preview, name: "Kante abdrücken")
    }

    /// Körperecken und Kantenmitten (3D), z. B. als Fangpunkte für „Übersetzen“.
    func modelKeyPoints() -> [SIMD3<Double>] {
        var byEdge: [EdgeRef: [(SIMD3<Double>, SIMD3<Double>)]] = [:]
        for (i, ref) in mesh.edgeRefs.enumerated() where i * 2 + 1 < mesh.edges.count {
            byEdge[ref, default: []].append((SIMD3<Double>(mesh.edges[i * 2]), SIMD3<Double>(mesh.edges[i * 2 + 1])))
        }
        var points: [SIMD3<Double>] = []
        for segments in byEdge.values {
            for line in chain3D(segments) where line.count >= 2 {
                points += [line[0], line[line.count - 1]]
                if line.count == 2 { points.append((line[0] + line[1]) / 2) }
                if let center = Self.circleCenter(line) { points.append(center) }
            }
        }
        return points
    }

    /// Mittelpunkt einer geschlossenen, kreisförmigen Kante (Bohrungen, Zylinder); nil bei anderen Kanten.
    static func circleCenter(_ line: [SIMD3<Double>]) -> SIMD3<Double>? {
        guard line.count >= 8, let first = line.first, let last = line.last,
              simd_distance(first, last) < 1e-4 else { return nil }
        let points = Array(line.dropLast())
        let center = points.reduce(SIMD3<Double>(repeating: 0), +) / Double(points.count)
        let radii = points.map { simd_distance($0, center) }
        let mean = radii.reduce(0, +) / Double(radii.count)
        guard mean > 1e-6, radii.allSatisfy({ abs($0 - mean) < mean * 0.03 }) else { return nil }
        return center
    }

    /// Nächster Fangpunkt (Ecke, Kantenmitte, Kreismitte) innerhalb tolerance, sonst point selbst.
    func snappedModelPoint(_ point: SIMD3<Double>, tolerance: Double) -> SIMD3<Double> {
        var best = point, distance = tolerance
        for candidate in modelKeyPoints() {
            let d = simd_distance(candidate, point)
            if d < distance {
                distance = d
                best = candidate
            }
        }
        return best
    }

    /// Körper in einen Ordner des Browsers legen (nil = heraus).
    func setFolder(_ folder: String?, bodies indices: [Int]) {
        let chosen = indices.filter { bodies.indices.contains($0) }
        guard !chosen.isEmpty else { return }
        commitPreview()
        var result = bodies
        for index in chosen { result[index].folder = folder }
        commit(result, name: folder.map { "In Ordner „\($0)“" } ?? "Aus Ordner")
    }

    /// Einfügen › Projekt: Körper eines anderen Projekts als Kopie übernehmen.
    func insertProject(from otherFolder: URL, name: String) {
        guard PCKShape.stepAvailable else {
            message = "Projekt einfügen braucht OpenCASCADE (siehe README)."
            return
        }
        let step = otherFolder.appending(path: "model.step").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: step), let shapes = PCKShape.readSTEP(path: step), !shapes.isEmpty else {
            message = "„\(name)“ enthält keine Körper."
            return
        }
        let metas = (try? Data(contentsOf: otherFolder.appending(path: "bodies.json")))
            .flatMap { try? JSONDecoder().decode([BodyMeta].self, from: $0) } ?? []
        commitPreview()
        let inserted = shapes.enumerated().map { index, shape -> SceneBody in
            var body = newBody(shape, name: name)
            if index < metas.count, metas[index].color.count == 3 {
                body.name = metas[index].name
                body.color = SIMD3(metas[index].color[0], metas[index].color[1], metas[index].color[2])
                body.material = metas[index].material
                body.threads = metas[index].threads
                body.finish = metas[index].finish
            }
            body.folder = name
            return body
        }
        commit(bodies + inserted, name: "Projekt „\(name)“ einfügen")
        message = "\(inserted.count) Körper aus „\(name)“ eingefügt (Ordner „\(name)“)."
    }

    // MARK: Variablen

    /// Werte aller Projektvariablen (Name → mm bzw. Grad).
    var variableValues: [String: Double] { Formula.resolve(variables) }

    /// Variablen ersetzen; Skizzenmaße, die eine Variable verwenden, folgen sofort. Körper folgen über den
    /// parametrischen Verlauf (Nachbau ab dem ersten betroffenen Feature, FeatureHistory.swift).
    func setVariables(_ list: [ProjectVariable]) {
        commitPreview()
        variables = list
        let values = variableValues
        var result = sketches
        var changedSketches: Set<UUID> = []
        for index in result.indices {
            if let updated = Self.reevaluated(result[index], values: values) {
                result[index] = updated
                changedSketches.insert(updated.id)
            }
        }
        let newSketches: [StoredSketch]? = changedSketches.isEmpty ? nil : result
        if !rebuildFeatures(sketches: newSketches, changed: changedSketches, name: "Variablen ändern") {
            save()
        }
    }

    /// Skizze mit neu berechneten Formelmaßen; nil, wenn sich nichts ändert oder der Löser scheitert.
    private static func reevaluated(_ sketch: StoredSketch, values: [String: Double]) -> StoredSketch? {
        var constraints = sketch.constraints
        var touched = false
        for index in constraints.indices {
            // Projekteinheit und Winkel wie an der Ecke gezeigt (FeatureHistory.swift)
            guard let expression = constraints[index].expression, let old = constraints[index].dimensionValue,
                  let value = Self.formulaDimensionValue(expression, for: constraints[index].variant,
                                                         entities: sketch.entities, values: values),
                  abs(value - old) > 1e-9 else { continue }
            constraints[index] = constraints[index].withDimensionValue(value)
            touched = true
        }
        guard touched, let solved = ConstraintSolver.solve(sketch.entities, constraints: constraints) else { return nil }
        var result = sketch
        result.entities = solved
        result.constraints = constraints
        result.rebuild()
        return result
    }

    // MARK: 3D-Leitpunkte für Skizzen

    /// Ecken, Kantenmitten und Kanten der sichtbaren Körper, auf eine Skizzenebene projiziert
    /// (Shapr3D „3D-Leitpunkte“ und „Entfernte Kanten“).
    func sketchGuides(on plane: SketchPlane) -> SketchGuides {
        var byEdge: [EdgeRef: [(SIMD3<Double>, SIMD3<Double>)]] = [:]
        for (i, ref) in mesh.edgeRefs.enumerated() where i * 2 + 1 < mesh.edges.count {
            guard bodies.indices.contains(ref.body), !bodies[ref.body].isHidden else { continue }
            byEdge[ref, default: []].append((SIMD3<Double>(mesh.edges[i * 2]), SIMD3<Double>(mesh.edges[i * 2 + 1])))
        }
        var guides = SketchGuides()
        for segments in byEdge.values {
            for line in chain3D(segments) where line.count >= 2 {
                let local = line.map(plane.local)
                guides.curves.append(local)
                guides.points += [local[0], local[local.count - 1]]
                // Mitte entlang der Kante
                var lengths = [0.0]
                for k in 1..<local.count { lengths.append(lengths[k - 1] + simd_distance(local[k - 1], local[k])) }
                let half = lengths[lengths.count - 1] / 2
                if half > 1e-6, let k = lengths.firstIndex(where: { $0 >= half }), k > 0 {
                    let piece = lengths[k] - lengths[k - 1]
                    let f = piece > 1e-12 ? (half - lengths[k - 1]) / piece : 0
                    guides.points.append(local[k - 1] + (local[k] - local[k - 1]) * f)
                }
            }
        }
        var unique: [Point2] = []
        for p in guides.points where !unique.contains(where: { simd_distance($0, p) < 1e-4 }) {
            unique.append(p)
            if unique.count >= 1500 { break }
        }
        guides.points = unique
        if guides.curves.count > 3000 { guides.curves = Array(guides.curves.prefix(3000)) }
        return guides
    }

    // MARK: Speichern

    private struct BodyMeta: Codable {
        var name: String
        var color: [Float]
        var isHidden: Bool
        var sketchID: UUID?
        /// Ordner im Browser „Ebenen“ (nil = oberste Ebene)
        var folder: String?
        /// Komponente und Lage der Instanz (16 Werte, spaltenweise); fehlen in älteren Projekten
        var componentID: UUID?
        var placement: [Double]?
        /// Material (Materials.swift); fehlt in älteren Projekten
        var material: String?
        /// Gewinde (ThreadNotes.swift); fehlt in älteren Projekten
        var threads: [ThreadNote]?
        /// Oberfläche (SurfaceFinish.swift); fehlt in älteren Projekten
        var finish: String?
        /// Inhalt des Texts bei Textkörpern (SketchTextEdit.swift); fehlt in älteren Projekten
        var textLabel: String?
    }

    private var modelURL: URL? { folder?.appending(path: "model.step") }
    private var metaURL: URL? { folder?.appending(path: "bodies.json") }
    private var sketchesURL: URL? { folder?.appending(path: "sketches.json") }
    private var constructionsURL: URL? { folder?.appending(path: "constructions.json") }
    private var canvasesURL: URL? { folder?.appending(path: "canvases.json") }
    private var variablesURL: URL? { folder?.appending(path: "variables.json") }

    /// skipModel: sicherer Modus (HangGuard.swift) – model.step und Verlauf nicht laden, openSafely baut nach.
    private func load(skipModel: Bool = false) {
        // Verlauf erst nach den Körpern lesen (FeatureHistory.swift)
        defer { if !skipModel { loadFeatures() } }
        if let url = variablesURL, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([ProjectVariable].self, from: data) {
            variables = stored
        }
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
        guard !skipModel, PCKShape.stepAvailable, let modelURL,
              FileManager.default.fileExists(atPath: modelURL.path(percentEncoded: false)),
              let shapes = PCKShape.readSTEP(path: modelURL.path(percentEncoded: false)) else { return }
        let metas = metaURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([BodyMeta].self, from: $0) } ?? []
        bodies = shapes.enumerated().map { index, shape in
            if index < metas.count, metas[index].color.count == 3 {
                let meta = metas[index]
                var body = SceneBody(shape: shape, name: meta.name, color: SIMD3(meta.color[0], meta.color[1], meta.color[2]),
                                     isHidden: meta.isHidden, sketchID: meta.sketchID, folder: meta.folder)
                    .restoringComponent(meta.componentID, placement: meta.placement)
                body.material = meta.material
                body.threads = meta.threads
                body.finish = meta.finish
                body.textLabel = meta.textLabel
                return body
            }
            return SceneBody(shape: shape, name: "Körper \(index + 1)", color: SceneBody.palette[index % SceneBody.palette.count])
        }
    }

    private func save() {
        // features.json nach model.step schreiben (FeatureHistory.swift)
        defer { saveFeatures() }
        if let sketchesURL, let data = try? JSONEncoder().encode(sketches) {
            try? data.write(to: sketchesURL)
        }
        if let constructionsURL, let data = try? JSONEncoder().encode(constructions) {
            try? data.write(to: constructionsURL)
        }
        if let canvasesURL, let data = try? JSONEncoder().encode(canvases) {
            try? data.write(to: canvasesURL)
        }
        if let variablesURL, let data = try? JSONEncoder().encode(variables) {
            try? data.write(to: variablesURL)
        }
        guard PCKShape.stepAvailable, let modelURL, let metaURL else { return }
        let path = modelURL.path(percentEncoded: false)
        if bodies.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            _ = PCKShape.writeSTEP(bodies.map(\.shape), path: path)
        }
        let metas = bodies.map {
            BodyMeta(name: $0.name, color: [$0.color.x, $0.color.y, $0.color.z], isHidden: $0.isHidden, sketchID: $0.sketchID,
                     folder: $0.folder, componentID: $0.componentID,
                     placement: $0.componentID == nil ? nil : $0.placementValues, material: $0.material,
                     threads: $0.threads, finish: $0.finish, textLabel: $0.textLabel)
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
        case .plane: "sc.plane"
        case .axis: "sc.axis"
        case .point: "sc.point"
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
    /// Nach dem Kalibrieren gesperrt (Kai): Größe, Lage und Ebene bleiben, bis man es wieder entsperrt.
    /// Optional, damit ältere Projekte ohne dieses Feld lesbar bleiben.
    var isLocked: Bool? = nil

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

    /// Bild ändern als eigener Schritt im Verlauf (rückgängig machbar), z. B. nach dem Kalibrieren des Maßstabs.
    func commitCanvas(_ canvas: CanvasImage, name: String) {
        guard let index = canvases.firstIndex(where: { $0.id == canvas.id }) else { return }
        commitPreview()
        var result = canvases
        result[index] = canvas
        commit(bodies, canvases: result, name: name)
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

    func regions(_ refs: [RegionRef]) -> [(region: SketchRegion, plane: SketchPlane, sketch: Int)] {
        refs.compactMap { ref in
            guard sketches.indices.contains(ref.sketch), sketches[ref.sketch].regions.indices.contains(ref.region) else {
                return nil
            }
            return (sketches[ref.sketch].regions[ref.region], sketches[ref.sketch].plane, ref.sketch)
        }
    }

    // MARK: Muster, Skalieren, Ausrichten

    /// Rechteckmuster der gewählten Körper: Richtung 1 (z. B. X) und Richtung 2 (z. B. Y) mit eigener Anzahl
    /// und eigenem Abstand; Anzahl 1 in Richtung 2 ergibt eine einfache Reihe.
    func previewLinearPattern(count: Int, spacing: Double, direction: SIMD3<Double>,
                              count2: Int = 1, spacing2: Double = 0, direction2: SIMD3<Double> = [0, 1, 0]) {
        let rows = max(1, count2)
        guard requireKernel(), !selectedBodies.isEmpty, count >= 1, count * rows >= 2,
              simd_length(direction) > 1e-12, rows == 1 || simd_length(direction2) > 1e-12 else {
            dropPreview()
            return
        }
        var preview = bodies
        let d = simd_normalize(direction)
        let d2 = rows > 1 ? simd_normalize(direction2) : SIMD3<Double>(0, 0, 0)
        for index in selectedBodies where bodies.indices.contains(index) {
            var number = 1
            for row in 0..<rows {
                for k in 0..<max(1, count) where row > 0 || k > 0 {
                    let offset = d * spacing * Double(k) + d2 * spacing2 * Double(row)
                    guard let copy = bodies[index].shape.translated(by: offset) else {
                        message = "Muster nicht möglich."
                        return
                    }
                    number += 1
                    var body = bodies[index].with(copy, moving: .translation(offset))
                    body.name += " (\(number))"
                    preview.append(body)
                }
            }
        }
        message = nil
        showPreview(preview, name: "Muster linear")
        noteLinearPattern(count: count, spacing: spacing, direction: direction, count2: rows, spacing2: spacing2,
                          direction2: direction2)
    }

    /// Drehscheibe im Verschieben-Werkzeug: gewählte Körper um eine Achse durch center drehen (Vorschau,
    /// Übernahme mit commitPreview).
    func previewRotation(degrees: Double, center: SIMD3<Double>, axis: SIMD3<Double> = [0, 0, 1]) {
        guard requireKernel(), !selectedBodies.isEmpty else { return }
        guard abs(degrees) > 1e-9 else {
            dropPreview()
            return
        }
        var preview = bodies
        for index in selectedBodies where bodies.indices.contains(index) {
            guard let rotated = bodies[index].shape.rotated(origin: center, axis: axis, angle: degrees * .pi / 180) else {
                message = "Drehen nicht möglich."
                return
            }
            let motion = simd_double4x4.rotation(origin: center, axis: axis, angle: degrees * .pi / 180)
            if moveCopies {
                var copy = bodies[index].with(rotated, moving: motion)
                copy.name += " (Kopie)"
                preview.append(copy)
            } else {
                preview[index] = preview[index].with(rotated, moving: motion)
            }
        }
        message = nil
        showPreview(preview, name: moveCopies ? "Gedreht kopieren" : "Drehen")
        let rotated = selectedBodies.filter { bodies.indices.contains($0) }
        noteRotate(rotated, centers: rotated.map { _ in center }, axis: axis, degrees: degrees, copies: moveCopies,
                   direct: false)
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
                var body = bodies[index].with(copy, moving: .rotation(origin: axisOrigin, axis: simd_normalize(axis),
                                                                      angle: step * Double(k)))
                body.name += " (\(k + 1))"
                preview.append(body)
            }
        }
        message = nil
        showPreview(preview, name: "Muster kreisförmig")
        noteCircularPattern(count: count, angle: degrees, axisOrigin: axisOrigin, axis: axis)
    }

    /// Gewählte Körper um ihre Mitte skalieren. Schlägt es fehl, bleibt die bisherige Vorschau bzw. der
    /// Körper sichtbar (Kai: „bei ca. 4× verschwindet er einfach“).
    func previewScale(factors: SIMD3<Double>) {
        guard requireKernel() else { return }
        guard !selectedBodies.isEmpty else {
            dropPreview()
            return
        }
        guard factors.x > 0, factors.y > 0, factors.z > 0, factors != SIMD3<Double>(1, 1, 1) else {
            dropPreview()
            return
        }
        guard factors.x.isFinite, factors.y.isFinite, factors.z.isFinite else {
            message = "Skalieren nicht möglich."
            return
        }
        var preview = bodies
        for index in selectedBodies where bodies.indices.contains(index) {
            // Mitte aus dem echten Körper, nicht aus dem angezeigten Netz: das zeigt während der Vorschau schon
            // die skalierten Körper (und ist leer, wenn deren Vernetzung fehlschlug)
            let shape = bodies[index].shape
            guard let box = Mesh(shape.triangulate(deflection: 0.05), body: index).bounds else {
                message = "Skalieren nicht möglich."
                return
            }
            let center = SIMD3<Double>((box.min + box.max) / 2)
            // Ohne Dreiecke wäre der Körper in der Vorschau unsichtbar: dann lieber nicht skalieren
            guard let scaled = shape.scaled(center: center, factors: factors),
                  !scaled.triangulate(deflection: 0.05).indexData.isEmpty else {
                message = "Skalieren nicht möglich."
                return
            }
            preview[index] = preview[index].scaledInstance(scaled)
        }
        message = scaledComponentNote(selectedBodies)
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
            preview[index] = preview[index].with(shape, moving: .translation(offset))
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
        noteRevolve(axisOrigin: axisOrigin, axis: axis, degrees: degrees, mode: mode)
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

    func showSolid(_ shapes: [PCKShape], sourceBody: Int?, mode: ExtrudeMode, name: String) {
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

    /// Teilen mit einem Werkzeug (anderer Körper bzw. Prisma aus Skizzenbereichen); alle Teile werden Körper.
    func previewSplit(tool: PCKShape) {
        guard requireKernel(), let body = selectedBodies.first, bodies.indices.contains(body) else { return }
        guard let parts = bodies[body].shape.split(by: tool), parts.count >= 2 else {
            message = "Das Werkzeug teilt den Körper nicht."
            dropPreview()
            return
        }
        message = nil
        var preview = bodies
        preview[body] = preview[body].with(parts[0])
        for (k, part) in parts.dropFirst().enumerated() {
            var piece = bodies[body].with(part)
            piece.name += " (Teil \(k + 2))"
            piece.color = SceneBody.palette[(bodies.count + k + 1) % SceneBody.palette.count]
            preview.append(piece)
        }
        showPreview(preview, name: "Körper teilen")
    }

    /// Prisma aus Skizzenbereichen, das jeden Körper ganz durchdringt (Werkzeug zum Teilen).
    func throughPrism(regions refs: [RegionRef]) -> PCKShape? {
        guard let first = refs.first, sketches.indices.contains(first.sketch) else { return nil }
        let sketch = sketches[first.sketch]
        let regions = refs.filter { $0.sketch == first.sketch && sketch.regions.indices.contains($0.region) }
            .map { sketch.regions[$0.region] }
        let reach = sceneExtent * 2 + 10
        let prisms = regions.compactMap { region in
            PCKShape.prism(profileWires: profileWires(region, plane: sketch.plane, offset: -reach),
                           direction: sketch.plane.normal * (2 * reach))
        }
        guard !prisms.isEmpty else { return nil }
        return prisms.count == 1 ? prisms[0] : PCKShape.compound(prisms)
    }

    /// Größte Ausdehnung der Szene vom Ursprung (für Werkzeuge „durch alles“).
    var sceneExtent: Double {
        guard let box = mesh.bounds else { return 1000 }
        return Double(max(simd_length(box.min), simd_length(box.max)))
    }

    // MARK: Druckausrichtung

    /// Körper so drehen, dass up nach +Z zeigt, und auf das Druckbett (Z = 0) stellen.
    func orientForPrint(_ body: Int, up: SIMD3<Double>) {
        guard requireKernel(), bodies.indices.contains(body), let center = center(ofBody: body),
              simd_length(up) > 1e-9 else { return }
        commitPreview()
        let u = simd_normalize(up)
        let dot = simd_dot(u, [0, 0, 1])
        var shape = bodies[body].shape
        var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        if dot < 1 - 1e-9 {
            let axis: SIMD3<Double> = dot < -1 + 1e-9 ? [1, 0, 0] : simd_normalize(simd_cross(u, [0, 0, 1]))
            let angle = acos(max(-1, min(1, dot)))
            guard let rotated = shape.rotated(origin: center, axis: axis, angle: angle) else {
                message = "Drehen nicht möglich."
                return
            }
            shape = rotated
            rotation = simd_quatd(angle: angle, axis: axis)
        }
        // Tiefster Punkt nach dem Drehen (aus dem Anzeigenetz) kommt auf Z = 0
        var lowest = Double.infinity
        for (t, ref) in mesh.triangleFaces.enumerated() where ref.body == body {
            for k in 0..<3 {
                let p = SIMD3<Double>(mesh.vertices[Int(mesh.indices[t * 3 + k])].position)
                lowest = min(lowest, (center + rotation.act(p - center)).z)
            }
        }
        if lowest.isFinite, abs(lowest) > 1e-6, let placed = shape.translated(by: [0, 0, -lowest]) {
            shape = placed
        }
        var result = bodies
        result[body] = result[body].with(shape)
        commit(result, name: "Druckausrichtung")
        message = "\(bodies[body].name) liegt jetzt druckfertig auf dem Bett."
    }

    // MARK: Bohrungen

    /// Bohrungen (wie Fusion 360 „Bohrung“): je angetippter Punkt eine Bohrung senkrecht in die Fläche.
    func previewHoles(_ holes: [(face: FaceRef, point: SIMD3<Double>)], spec: HoleSpec) {
        guard requireKernel(), !holes.isEmpty else {
            dropPreview()
            return
        }
        var preview = bodies
        for hole in holes {
            let body = hole.face.body
            // Eben oder gewölbt: Punkt und Normale am Tippunkt (SurfaceHoles.swift)
            guard bodies.indices.contains(body), let spot = surfacePoint(of: hole.face, near: hole.point) else {
                message = "An dieser Stelle der Fläche ist keine Bohrung möglich."
                dropPreview()
                return
            }
            // Normale zeigt aus dem Körper heraus; gebohrt wird entgegen
            let n = spot.normal
            let point = spot.point
            // Gewindebohrung: nur so lang wie nötig (jede Umdrehung kostet Rechenzeit)
            let reach = spec.thread == nil ? sceneExtent * 2 + 10 : threadReach(body: body, from: point, direction: -n)
            // Gewindebohrung: Werkzeug ist ein Verbund (Gänge, Kernloch, Senkung) – in einem Schritt mit Fuzzy-Wert
            let shape = preview[body].shape
            // Nach innen gewölbte Flächen: Werkzeug beginnt so hoch, dass es sauber aus der Fläche austritt
            let lift = holeLift(shape, at: point, outward: n, radius: spec.toolRadius, planar: spot.planar)
            guard let tool = spec.tool(at: point, outward: n, through: reach, lift: lift),
                  let cut = spec.thread == nil ? shape.cutting(tool) : shape.cutting(tool, fuzzy: threadCutFuzzy) else {
                message = "Bohrung an dieser Stelle nicht möglich."
                dropPreview()
                return
            }
            preview[body] = preview[body].with(cut)
            // Gewinde als Eigenschaft am Körper (ThreadNotes.swift)
            if let note = spec.threadNote(at: point, outward: n, reach: reach) { preview[body].addThread(note) }
        }
        message = holes.count == 1 ? spec.summary : "\(holes.count) Bohrungen · \(spec.summary)"
        let kind: String = spec.thread == nil ? "Bohrung" : "Gewindebohrung"
        showPreview(preview, name: holes.count == 1 ? kind : "\(kind)en")
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
        rebuildFeatures(sketches: result, changed: [result[index].id], name: "Skizze verschieben")
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
        rebuildFeatures(sketches: result, changed: [result[index].id], name: "Skizze drehen")
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
        rebuildFeatures(sketches: result, changed: [result[index].id], name: "Skizze skalieren")
    }
}

// MARK: Bohrungen

enum HoleKind: String, CaseIterable, Identifiable {
    case simple = "Einfach"
    case counterbore = "Senkbohrung"
    case countersink = "Kegelsenkung"

    var id: Self { self }
}

/// Maße einer Bohrung (mm, Grad). Für den 3D-Druck kommt die Druckzugabe auf alle Durchmesser.
struct HoleSpec: Equatable {
    var kind: HoleKind = .simple
    var diameter: Double = 3.4
    var depth: Double = 10
    var through = true
    var counterDiameter: Double = 6.5
    var counterDepth: Double = 3.3
    var sinkAngle: Double = 90
    /// Spitze am Grund einer Sackbohrung (118°)
    var drillPoint = false
    var clearance: Double = 0.2
    /// Gewindebohrung: Kernloch nach Norm, Innengewinde modelliert (Threads.swift)
    var thread: HoleThread? = nil

    var summary: String {
        if let thread { return thread.summary(clearance: clearance, through: through, depth: depth) }
        let d = (diameter + clearance).formatted(.number.precision(.fractionLength(0...2)))
        let depthText = through ? "durch" : "\(depth.formatted()) mm tief"
        switch kind {
        case .simple: return "Ø \(d) mm, \(depthText)"
        case .counterbore:
            return "Ø \(d) mm, \(depthText), Senkung Ø \((counterDiameter + clearance).formatted()) × \(counterDepth.formatted()) mm"
        case .countersink:
            return "Ø \(d) mm, \(depthText), Kegelsenkung Ø \((counterDiameter + clearance).formatted()) mm \(sinkAngle.formatted())°"
        }
    }

    /// Werkzeugkörper der Bohrung: beginnt knapp über der Fläche bei point und geht entgegen outward.
    /// lift: Abstand über der Fläche (Tangentialebene), an nach innen gewölbten Flächen größer (holeLift).
    func tool(at point: SIMD3<Double>, outward n: SIMD3<Double>, through reach: Double,
              lift: Double = 0.05) -> PCKShape? {
        let top = point + n * lift
        let r = (diameter + clearance) / 2
        guard r > 0 else { return nil }
        let length = (through ? reach : depth) + lift
        // Kosmetisches Gewinde: nur das Kernloch (diameter = Kernlochbohrer)
        if let thread, !thread.cosmetic {
            return threadedTool(thread, top: top, axis: -n, length: length, lift: lift)
        }
        guard var shape = PCKShape.cylinder(base: top, axis: -n, radius: r, height: length) else { return nil }
        if drillPoint, !through {
            let tipHeight = r / tan(59 * .pi / 180)
            if let tip = PCKShape.cone(base: top - n * length, axis: -n, bottomRadius: r, topRadius: 0, height: tipHeight),
               let joined = shape.fusing(tip) {
                shape = joined
            }
        }
        let R = (counterDiameter + clearance) / 2
        switch kind {
        case .simple:
            break
        case .counterbore:
            guard R > r, counterDepth > 0,
                  let bore = PCKShape.cylinder(base: top, axis: -n, radius: R, height: counterDepth + lift),
                  let joined = shape.fusing(bore) else { return nil }
            shape = joined
        case .countersink:
            let half = max(1, min(89, sinkAngle / 2)) * .pi / 180
            // Kegel von Ø R an der Fläche bis Ø r, dazu der Abschnitt über der Fläche
            let height = (R - r) / tan(half)
            guard R > r, height > 0,
                  let sink = PCKShape.cone(base: top, axis: -n, bottomRadius: R + lift * tan(half), topRadius: r,
                                           height: height + lift),
                  let joined = shape.fusing(sink) else { return nil }
            shape = joined
        }
        return shape
    }

    /// Name und Maße einer Bohrungsvorlage
    typealias Preset = (name: String, spec: HoleSpec)

    private static func preset(_ name: String, _ kind: HoleKind, _ d: Double, through: Bool = true, depth: Double = 10,
                               cd: Double = 0, cdepth: Double = 0, clearance: Double = 0.2) -> Preset {
        (name, HoleSpec(kind: kind, diameter: d, depth: depth, through: through, counterDiameter: cd,
                        counterDepth: cdepth, sinkAngle: 90, drillPoint: false, clearance: clearance))
    }

    private static let throughPresets: [Preset] = [
        preset("M2", .simple, 2.4), preset("M2,5", .simple, 2.9), preset("M3", .simple, 3.4),
        preset("M4", .simple, 4.5), preset("M5", .simple, 5.5), preset("M6", .simple, 6.6), preset("M8", .simple, 9.0),
    ]
    private static let counterborePresets: [Preset] = [
        preset("M3", .counterbore, 3.4, cd: 6.5, cdepth: 3.3), preset("M4", .counterbore, 4.5, cd: 8, cdepth: 4.4),
        preset("M5", .counterbore, 5.5, cd: 10, cdepth: 5.4), preset("M6", .counterbore, 6.6, cd: 11, cdepth: 6.4),
    ]
    private static let countersinkPresets: [Preset] = [
        preset("M3", .countersink, 3.4, cd: 6.4), preset("M4", .countersink, 4.5, cd: 8.6),
        preset("M5", .countersink, 5.5, cd: 10.4), preset("M6", .countersink, 6.6, cd: 12.4),
    ]
    private static let corePresets: [Preset] = [
        preset("M2", .simple, 1.6, through: false, depth: 6, clearance: 0),
        preset("M2,5", .simple, 2.0, through: false, depth: 7, clearance: 0),
        preset("M3", .simple, 2.5, through: false, depth: 8, clearance: 0),
        preset("M4", .simple, 3.3, through: false, depth: 10, clearance: 0),
        preset("M5", .simple, 4.2, through: false, depth: 12, clearance: 0),
    ]
    private static let insertPresets: [Preset] = [
        preset("M2", .simple, 3.2, through: false, depth: 4.5, clearance: 0),
        preset("M2,5", .simple, 3.6, through: false, depth: 6.2, clearance: 0),
        preset("M3", .simple, 4.0, through: false, depth: 6.2, clearance: 0),
        preset("M4", .simple, 5.6, through: false, depth: 8.6, clearance: 0),
        preset("M5", .simple, 6.4, through: false, depth: 10, clearance: 0),
    ]

    /// Vorlagen für den 3D-Druck (Richtwerte; Durchgang nach ISO 273 mittel, Kernloch für selbstschneidende
    /// Schrauben in Kunststoff, Gewindeeinsätze nach Herstellerangabe ruthex – vor dem Druck prüfen).
    static let presets: [(group: String, items: [Preset])] = [
        (group: "Durchgang", items: throughPresets),
        (group: "Zylinderkopf (ISO 4762)", items: counterborePresets),
        (group: "Senkkopf (90°)", items: countersinkPresets),
        (group: "Kernloch Kunststoff", items: corePresets),
        (group: "Gewindeeinsatz (ruthex)", items: insertPresets),
    ]
}

