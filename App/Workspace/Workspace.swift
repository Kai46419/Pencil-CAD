import SwiftUI
import simd

enum PatternKind: String, CaseIterable, Identifiable {
    case linear = "Muster linear"
    case circular = "Muster kreisförmig"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .linear: "square.grid.3x1.below.line.grid.1x2"
        case .circular: "circle.grid.cross"
        }
    }
}

/// Schnittansicht: Ebene, Versatz entlang der Normale, Seite.
struct SectionSettings: Equatable {
    var plane: ReferencePlane = .world(1)
    var offset: Double = 0
    var flipped = false
}

/// Achse aus einer Kante oder Flächennormale (für „Achse“ im Konstruieren-Werkzeug).
struct AxisSpec: Equatable {
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>
    var name: String
}

/// Aktives Werkzeug im Modellierbereich (der Skizzenmodus läuft über SketchController.isActive).
enum ModelTool: Equatable {
    /// Antippen wählt Flächen und Kanten; Ziehpfeile erscheinen automatisch.
    case select
    case insert(Primitive)
    case boolean(BooleanKind)
    case move
    case mirror
    case shell
    case color
    case pattern(PatternKind)
    case scale
    case align
    case revolve
    case sweep
    case loft
    case split
    case section
    case measure
    case construct(ConstructionKind)
    case canvas(UUID)
    case scaleSketch
    /// 3D „Kante versetzen“: ebene Fläche antippen, ihre Kanten werden in einer Skizze versetzt
    case offsetEdges

    var title: String {
        switch self {
        case .select: "Auswahl"
        case .insert(let primitive): "\(primitive.rawValue) einfügen"
        case .boolean(let kind): kind.rawValue
        case .move: "Verschieben/Rotieren"
        case .mirror: "Spiegeln"
        case .shell: "Schale"
        case .color: "Farbe"
        case .pattern(let kind): kind.rawValue
        case .scale: "Skalieren"
        case .align: "Ausrichten"
        case .revolve: "Achsendrehung"
        case .sweep: "Sweep"
        case .loft: "Loft"
        case .split: "Körper teilen"
        case .section: "Schnittansicht"
        case .measure: "Messen"
        case .construct(let kind): "\(kind.rawValue) erstellen"
        case .canvas: "Bild"
        case .scaleSketch: "Skizze skalieren"
        case .offsetEdges: "Kante versetzen"
        }
    }

    /// Werkzeuge, die Körper antippen und mehrere sammeln.
    var collectsBodies: Bool {
        switch self {
        case .boolean, .move, .mirror, .color, .pattern, .scale, .align, .split: true
        default: false
        }
    }

    /// Werkzeuge, die Skizzenbereiche verwenden.
    var usesRegions: Bool {
        switch self {
        case .revolve, .sweep, .loft, .scaleSketch: true
        default: false
        }
    }
}

/// Welcher Ziehpfeil gerade gezogen wird.
enum HandleKind: Equatable {
    case region
    case face
    case edge
    case move(axis: Int)
    case offset
}

/// Ziehpfeil: Achse (Ursprung + Richtung), aktueller Wert in mm entlang der Achse.
struct DragHandle {
    var kind: HandleKind
    var axisOrigin: SIMD3<Float>
    var direction: SIMD3<Float>
    var value: Double
    var color: SIMD3<Float>

    /// Fuß des Pfeils: wandert mit dem Wert entlang der Achse.
    var base: SIMD3<Float> { axisOrigin + direction * Float(value) }
    /// Zeigt bei negativen Werten in Gegenrichtung.
    var pointing: SIMD3<Float> { value < 0 ? -direction : direction }
}

/// Einmalige Kamerabefehle aus der Oberfläche. Eine neue id löst den Befehl aus.
struct ViewCommand: Equatable {
    enum Kind: Equatable {
        case alignToSketchPlane
        case fitAll
        /// Blick entgegen der Normale (Kamera auf der Seite von normal)
        case look(SIMD3<Float>)
    }

    var id = 0
    var kind: Kind = .fitAll
}

/// Blickrichtung der Kamera (Winkel wie OrbitCamera).
@MainActor
final class CameraState: ObservableObject {
    @Published var yaw: Float = -.pi / 4
    @Published var pitch: Float = 0.5
}

/// Zustand des Arbeitsbereichs eines geöffneten Projekts.
@MainActor
final class Workspace: ObservableObject {
    let project: Project
    let model: ModelStore
    let sketch = SketchController()
    /// Kamerawinkel für den ViewCube (eigenes Objekt, damit Drehen nicht die ganze Oberfläche neu aufbaut).
    let camera = CameraState()

    @Published var tool: ModelTool = .select
    @Published var displayMode: DisplayMode = .shaded
    @Published var isOrthographic = false
    @Published private(set) var viewCommand = ViewCommand()
    @Published private(set) var sketchNumber = 0
    /// Gespeicherte Skizze, die gerade bearbeitet wird (nil = neue Skizze).
    @Published private(set) var editingSketchIndex: Int?
    /// Werkzeugrad (Stift drücken bzw. doppeltippen) an dieser Stelle des Viewports.
    @Published var quickToolsLocation: CGPoint?

    // Werkzeugparameter
    @Published var insertSize: SIMD3<Double> = Primitive.box.defaultSize
    @Published var mirrorPlane: MirrorPlane = .yz
    @Published var mirrorKeepsOriginal = true
    @Published var shellThickness: Double = 2
    @Published var patternCount = 4
    @Published var patternSpacing: Double = 20
    @Published var patternAngle: Double = 360
    @Published var patternAxis: ReferenceAxis = .world(0)
    @Published var scaleFactors: SIMD3<Double> = [1.5, 1.5, 1.5]
    @Published var scaleUniform = true
    @Published var alignModes: [AlignMode] = [.center, .center, .none]
    @Published var revolveAxis: ReferenceAxis = .world(2)
    @Published var revolveAngle: Double = 360
    /// Ergebnis von Drehen, Sweep und Loft
    @Published var solidMode: ExtrudeMode = .newBody
    @Published var sweepPath: Int?
    @Published var splitPlane: ReferencePlane = .world(2)
    @Published var splitOffset: Double = 0
    /// Schnittansicht im 3D-Modus (nil = aus)
    @Published var section: SectionSettings?
    /// Schnittansicht im Skizzenmodus: alles vor der Skizzenebene ausblenden
    @Published var sketchSection = false
    @Published private(set) var measureLines: [String] = []
    @Published private(set) var measurePoints: [SIMD3<Double>] = []
    @Published var constructReference: ReferencePlane = .world(2)
    @Published var constructOffset: Double = 10
    @Published var constructAxis: ReferenceAxis = .world(2)
    @Published var constructCustomAxis: AxisSpec?
    @Published var constructPoint: SIMD3<Double> = .zero
    @Published var sketchScaleFactor: Double = 2
    /// Fotoauswahl für „Bild einfügen“
    @Published var isPickingImage = false
    /// Kontextleiste: alle Werkzeuggruppen zeigen („Mehr“)
    @Published var showsAllTools = false
    /// Ursprung (Achsen) zeigen – im Browser „Ebenen“ ein- und ausblendbar
    @Published var showsOrigin = true
    /// Browser „Ebenen“ links (wie in Fusion 360)
    @Published var showsLayers = false
    /// Rahmenauswahl: auch der Finger zieht einen Rahmen auf (Drehen mit einem Finger ist dann aus).
    /// Mit dem Stift geht der Rahmen immer: ins Leere ziehen.
    @Published var boxSelects = false
    /// Körper wählen: Antippen wählt ganze Körper (mehrere) statt Flächen und Kanten.
    @Published var selectsBodies = false

    /// Liefert ein Bild der Ansicht (vom Viewport gesetzt).
    var snapshot: ((CGSize) -> UIImage?)?

    init(project: Project) {
        self.project = project
        model = ModelStore(folder: project.folder)
    }

    // MARK: Kamera

    func send(_ kind: ViewCommand.Kind) {
        viewCommand = ViewCommand(id: viewCommand.id + 1, kind: kind)
    }

    func cameraChanged(yaw: Float, pitch: Float) {
        if abs(yaw - camera.yaw) > 1e-4 || abs(pitch - camera.pitch) > 1e-4 {
            camera.yaw = yaw
            camera.pitch = pitch
        }
    }

    // MARK: Skizze

    /// Neue Skizze direkt auf einer Ebene (Konstruktionsebene, Fläche).
    func startSketch(on plane: SketchPlane) {
        tool = .select
        editingSketchIndex = nil
        model.commitPreview()
        model.resetSelection()
        sketch.plane = plane
        sketch.isActive = true
        sketch.isChoosingPlane = false
        send(.alignToSketchPlane)
        sketchNumber += 1
    }

    /// 3D „Kante versetzen“: Kanten der ebenen Fläche in eine neue Skizze übernehmen, dann versetzen.
    func offsetFaceEdges(_ face: FaceRef) {
        guard let plane = model.plane(of: face) else {
            model.message = "Kante versetzen geht nur auf ebenen Flächen."
            return
        }
        let polylines = model.edgePolylines(ofFace: face)
        startSketch(on: plane)
        sketch.addProjected(polylines.map { $0.map(plane.local) })
        sketch.tool = .offset
    }

    /// Neue Skizze: auf der gewählten ebenen Fläche, sonst zuerst eine Standardebene antippen lassen.
    func startSketch() {
        tool = .select
        editingSketchIndex = nil
        model.commitPreview()
        if let face = model.selection, let plane = model.plane(of: face) {
            sketch.plane = plane
            sketch.isActive = true
            send(.alignToSketchPlane)
        } else {
            sketch.isActive = true
            sketch.isChoosingPlane = true
            // Schräge Ansicht, damit alle drei Ebenen antippbar sind
            send(.look(SIMD3<Float>(1, -1, 0.85)))
        }
        model.resetSelection()
        sketchNumber += 1
    }

    /// Standardebene wählen; die Ansicht dreht sich senkrecht darauf (Oben = Draufsicht).
    func chooseSketchPlane(_ side: BasePlane) {
        sketch.choose(side)
        send(.alignToSketchPlane)
    }

    /// Ebene Fläche eines Körpers als Skizzenebene.
    func chooseSketchPlane(_ plane: SketchPlane) {
        sketch.isChoosingPlane = false
        sketch.plane = plane
        send(.alignToSketchPlane)
    }

    /// Skizze verlassen, ohne zu speichern; danach wieder 3D-Ansicht.
    func endSketch() {
        sketch.isActive = false
        editingSketchIndex = nil
        send(.look(SIMD3<Float>(1, -1, 0.85)))
    }

    /// „Fertig“ im Skizzenmodus: Skizze bleibt im Modell, Bereiche lassen sich danach antippen und extrudieren.
    func finishSketch() {
        let entities = sketch.entities
        let hasRegions = sketch.hasProfile
        if !entities.isEmpty {
            model.storeSketch(plane: sketch.plane, entities: entities, constraints: sketch.constraints,
                              construction: sketch.construction, replacing: editingSketchIndex)
        }
        endSketch()
        if hasRegions {
            model.message = "Bereich antippen und am Pfeil ziehen zum Extrudieren."
        }
    }

    /// Gespeicherte Skizze wieder öffnen.
    func editSketch(_ index: Int) {
        guard model.sketches.indices.contains(index) else { return }
        tool = .select
        model.commitPreview()
        model.resetSelection()
        let stored = model.sketches[index]
        sketch.isActive = true
        sketch.load(plane: stored.plane, entities: stored.entities, constraints: stored.constraints,
                    construction: stored.construction)
        editingSketchIndex = index
        send(.alignToSketchPlane)
    }

    // MARK: Werkzeuge

    func activate(_ newTool: ModelTool) {
        if sketch.isActive {
            endSketch()
        }
        let previousBody = model.selectedBody
        let previousBodies = model.selectedBodies
        let previousFace = model.selection
        let previousRegions = model.selectedRegions
        model.cancelPreview()
        tool = newTool
        measureLines = []
        measurePoints = []
        switch newTool {
        case .move where previousBody == nil && !previousRegions.isEmpty:
            // Skizze verschieben/drehen
            model.resetSelection()
            model.movingSketch = previousRegions[0].sketch
            return
        case .pattern, .scale, .align, .split:
            model.resetSelection()
            if previousBodies.count > 1, newTool != .split {
                model.selectBodies(previousBodies)
            } else if let previousBody {
                model.toggleBody(previousBody, exclusive: true)
            }
            updatePreview()
            return
        case .revolve, .sweep, .loft, .scaleSketch:
            model.resetSelection()
            if !previousRegions.isEmpty { model.selectRegions(previousRegions) }
            if newTool == .sweep, sweepPath == nil {
                sweepPath = model.pathSketches.first { $0 != previousRegions.first?.sketch }
            }
            if newTool == .revolve, let first = previousRegions.first,
               let line = model.sketchLines(first.sketch).first {
                // Wie Shapr3D: eine Linie der Skizze als Achse vorschlagen
                revolveAxis = .sketchLine(line.index)
            }
            updatePreview()
            return
        case .measure, .canvas:
            model.resetSelection()
            return
        case .section:
            if section == nil { section = SectionSettings() }
            if let previousFace { section?.plane = .face(previousFace) }
            model.resetSelection()
            return
        case .construct(let kind):
            model.resetSelection()
            constructCustomAxis = nil
            if let previousFace {
                switch kind {
                case .plane: constructReference = .face(previousFace)
                case .axis: setCustomAxis(normalOf: previousFace)
                case .point: break
                }
            }
            return
        case .offsetEdges:
            model.resetSelection()
            if let previousFace { offsetFaceEdges(previousFace) }
            return
        default:
            break
        }
        switch newTool {
        case .select:
            model.resetSelection()
        case .insert(let primitive):
            model.resetSelection()
            insertSize = primitive.defaultSize
            updateInsertPreview()
        case .boolean, .move, .mirror, .color:
            model.resetSelection()
            if previousBodies.count > 1, newTool != .move {
                model.selectBodies(previousBodies)
            } else if let previousBody {
                model.toggleBody(previousBody, exclusive: true)
            }
            if newTool == .mirror {
                updateMirrorPreview()
            }
        case .shell:
            if let previousFace {
                model.select(face: previousFace)
                model.previewShell(thickness: shellThickness)
            } else {
                model.resetSelection()
            }
        default:
            break
        }
    }

    /// Abrunden/Fase aus dem Tools-Menü: Auswahlwerkzeug, Kanten antippen.
    func startEdgeOperation(_ operation: EdgeOperation) {
        if tool != .select || sketch.isActive {
            activate(.select)
        }
        model.edgeOperation = operation
        if model.selectedEdges.isEmpty {
            model.message = "Kanten antippen (mehrere möglich), dann am Pfeil ziehen."
        }
    }

    func updateInsertPreview() {
        guard case .insert(let primitive) = tool else { return }
        model.previewInsert(primitive, size: insertSize, at: .zero)
    }

    func updateMirrorPreview() {
        guard tool == .mirror, !model.selectedBodies.isEmpty else { return }
        model.previewMirror(mirrorPlane, keepOriginal: mirrorKeepsOriginal)
    }

    func updateShellPreview() {
        guard tool == .shell, model.selection != nil else { return }
        model.previewShell(thickness: shellThickness)
    }

    /// „Fertig“: aktuelles Werkzeug bzw. Vorschau übernehmen.
    func done() {
        if sketch.isActive {
            if sketch.isChoosingPlane {
                chooseSketchPlane(.top)
            } else if sketch.hasOffsetTarget {
                sketch.applyOffset()
            } else {
                finishSketch()
            }
            return
        }
        switch tool {
        case .boolean(let kind):
            let chosen = model.selectedBodies
            if let target = chosen.first, chosen.count > 1 {
                model.applyBoolean(kind, target: target, tools: Array(chosen.dropFirst()))
            }
        case .move where model.movingSketch != nil:
            if let index = model.movingSketch { model.translateSketch(index, by: model.moveOffset) }
        case .construct(let kind):
            createConstruction(kind)
        case .scaleSketch:
            if let index = model.selectedRegions.first?.sketch { model.scaleSketch(index, by: sketchScaleFactor) }
        default:
            model.commitPreview()
        }
        tool = .select
        model.resetSelection()
    }

    /// „Abbrechen“: Vorschau verwerfen, zurück zur Auswahl.
    func cancel() {
        if sketch.isActive {
            if sketch.hasOffsetTarget {
                sketch.cancelOffset()
            } else if !sketch.isEmpty, editingSketchIndex == nil {
                // Neue Skizze: erst leeren, ein zweites „Abbrechen“ verlässt den Skizzenmodus
                sketch.reset()
            } else {
                endSketch()
            }
            return
        }
        if tool == .section { section = nil }
        model.cancelPreview()
        model.resetSelection()
        tool = .select
    }

    /// Ob „Abbrechen/Fertig“ angezeigt werden.
    var showsDoneBar: Bool {
        if sketch.isActive { return true }
        return tool != .select || model.hasPreview
    }

    var canFinish: Bool {
        if sketch.isActive { return true }
        switch tool {
        case .boolean: return model.selectedBodies.count > 1
        case .color, .construct, .measure, .section, .canvas, .offsetEdges: return true
        case .move where model.movingSketch != nil: return model.moveOffset != .zero
        case .scaleSketch: return !model.selectedRegions.isEmpty
        default: return model.hasPreview
        }
    }

    // MARK: Antippen im Viewport

    /// Tippen im Modellierbereich (nicht im Skizzenmodus).
    func tapped(face: FaceRef?, edge: EdgeRef?, region: RegionRef? = nil, point: SIMD3<Float>? = nil) {
        model.message = nil
        switch tool {
        case .pattern, .scale, .align:
            guard let body = face?.body ?? edge?.body else { return }
            model.toggleBody(body)
            updatePreview()
        case .split:
            guard let body = face?.body ?? edge?.body else { return }
            model.toggleBody(body, exclusive: true)
            updatePreview()
        case .revolve, .sweep, .scaleSketch:
            guard let region else { return }
            if tool == .scaleSketch || model.selectedRegions.first?.sketch != region.sketch {
                model.selectRegions([region])
            } else {
                model.toggleRegionAcrossSketches(region)
            }
            updatePreview()
        case .loft:
            guard let region else { return }
            model.toggleRegionAcrossSketches(region)
            updatePreview()
        case .measure:
            measure(face: face, edge: edge, point: point)
        case .construct(let kind):
            switch kind {
            case .plane:
                if let face, model.plane(of: face) != nil {
                    constructReference = .face(face)
                } else if face != nil {
                    model.message = "Für eine Ebene eine ebene Fläche antippen."
                }
            case .axis:
                if let edge {
                    let points = model.edgePolylines(edge).flatMap { $0 }
                    if let a = points.first, let b = points.last, simd_distance(a, b) > 1e-6 {
                        constructCustomAxis = AxisSpec(origin: a, direction: simd_normalize(b - a), name: "Kante")
                    }
                } else if let face {
                    setCustomAxis(normalOf: face)
                }
            case .point:
                if let point { constructPoint = SIMD3<Double>(point) }
            }
        case .section:
            if let face, model.plane(of: face) != nil { section?.plane = .face(face) }
        case .offsetEdges:
            if let face { offsetFaceEdges(face) }
        case .canvas:
            break
        case .select:
            if extrudeToTapped(point, face: face, region: region) { return }
            if selectsBodies || !model.selectedBodies.isEmpty, let body = face?.body ?? edge?.body {
                // Körperauswahl (z. B. per Rahmen): Antippen nimmt Körper hinzu bzw. heraus
                model.toggleBody(body)
            } else if let edge {
                model.toggleEdge(edge)
            } else if let region {
                model.toggleRegion(region)
            } else if let face {
                model.select(face: face)
            } else {
                model.clearSelection()
            }
        case .boolean, .move, .mirror, .color:
            guard let body = face?.body ?? edge?.body else { return }
            model.toggleBody(body, exclusive: tool == .move)
            updateMirrorPreview()
        case .shell:
            guard let face else { return }
            model.cancelPreview()
            model.select(face: face)
            updateShellPreview()
        case .insert:
            break
        }
    }

    // MARK: Vorschau der neuen Werkzeuge

    /// Vorschau des aktiven Werkzeugs mit den aktuellen Einstellungen neu berechnen.
    func updatePreview() {
        switch tool {
        case .pattern(.linear):
            guard let axis = model.resolve(patternAxis) else { return }
            model.previewLinearPattern(count: patternCount, spacing: patternSpacing, direction: axis.direction)
        case .pattern(.circular):
            guard let axis = model.resolve(patternAxis) else { return }
            model.previewCircularPattern(count: patternCount, angle: patternAngle, axisOrigin: axis.origin,
                                         axis: axis.direction)
        case .scale:
            let factors = scaleUniform ? SIMD3(repeating: scaleFactors.x) : scaleFactors
            model.previewScale(factors: factors)
        case .align:
            model.previewAlign(alignModes)
        case .revolve:
            guard let axis = model.resolve(revolveAxis, sketch: model.selectedRegions.first?.sketch) else {
                if !model.selectedRegions.isEmpty { model.message = "Drehachse wählen." }
                return
            }
            model.previewRevolve(axisOrigin: axis.origin, axis: axis.direction, degrees: revolveAngle, mode: solidMode)
        case .sweep:
            model.previewSweep(pathSketch: sweepPath, mode: solidMode)
        case .loft:
            model.previewLoft(mode: solidMode)
        case .split:
            guard let body = model.selectedBodies.first, let plane = model.resolve(splitPlane) else { return }
            var origin = plane.origin
            if case .world = splitPlane, let center = model.center(ofBody: body) { origin = center }
            model.previewSplit(origin: origin + plane.normal * splitOffset, normal: plane.normal)
        default:
            break
        }
    }

    /// Clip-Ebene der Schnittansicht: Normale und Abstand (alles mit dot(n, p) > d wird ausgeblendet).
    var clipPlane: (normal: SIMD3<Double>, distance: Double)? {
        if sketch.isActive, !sketch.isChoosingPlane {
            guard sketchSection else { return nil }
            let plane = sketch.plane
            return (plane.normal, simd_dot(plane.normal, plane.origin) + 1e-3)
        }
        guard let section, let plane = model.resolve(section.plane) else { return nil }
        let normal = section.flipped ? -plane.normal : plane.normal
        let origin = plane.origin + plane.normal * section.offset
        return (normal, simd_dot(normal, origin))
    }

    // MARK: Rahmenauswahl und Vereinigen

    /// Werkzeuge, in denen ein Rahmen Körper wählt.
    var acceptsBoxSelection: Bool {
        !sketch.isActive && (tool == .select || tool.collectsBodies)
    }

    /// Ergebnis eines Auswahlrahmens.
    func boxSelected(_ bodies: [Int], crossing: Bool) {
        guard acceptsBoxSelection else { return }
        guard !bodies.isEmpty else {
            model.resetSelection()
            model.message = crossing ? "Kein Körper berührt den Rahmen."
                : "Kein Körper ganz im Rahmen. Von rechts nach links ziehen wählt auch angeschnittene Körper."
            return
        }
        model.selectBodies(bodies)
        model.message = nil
        updatePreview()
        updateMirrorPreview()
    }

    /// Alle gewählten Körper zu einem verschmelzen (boolesche Vereinigung).
    func mergeSelectedBodies() {
        combineSelectedBodies(.union)
    }

    /// Boolesche Verknüpfung der gewählten Körper: der zuerst gewählte ist das Ziel, die übrigen die Werkzeuge
    /// (Vereinigen verschmilzt alle, Abziehen schneidet die übrigen heraus, Schneiden behält die Überlappung).
    func combineSelectedBodies(_ kind: BooleanKind) {
        let chosen = model.selectedBodies
        guard let target = chosen.first, chosen.count > 1 else {
            model.message = "Mindestens zwei Körper wählen: Rahmen aufziehen, „Körper wählen“ einschalten oder im Ebenen-Browser antippen."
            return
        }
        let before = model.bodies.count
        model.applyBoolean(kind, target: target, tools: Array(chosen.dropFirst()))
        guard model.bodies.count < before else { return }
        let result = target - chosen.dropFirst().filter { $0 < target }.count
        model.resetSelection()
        model.selectBodies([result])
        switch kind {
        case .union: model.message = "\(chosen.count) Körper zu einem vereinigt."
        case .subtract: model.message = "\(chosen.count - 1) Körper vom ersten abgezogen."
        case .intersect: model.message = "Nur die Überlappung der \(chosen.count) Körper bleibt."
        }
    }

    /// Wie „Bis Objekt“ in Fusion 360: Sind Skizzenbereiche gewählt, setzt Antippen einer parallelen ebenen
    /// Fläche (z. B. der Deckfläche eines extrudierten Körpers) die Höhe genau bis dorthin – auch ohne vorher
    /// am Pfeil zu ziehen. Läuft schon eine Extrusion, zählt jede angetippte Fläche oder Kante.
    private func extrudeToTapped(_ point: SIMD3<Float>?, face: FaceRef?, region: RegionRef?) -> Bool {
        guard let point else { return false }
        // Ein Bereich in derselben Ebene wird wie gewohnt dazugewählt; liegt er (bzw. eine Skizze auf der
        // angetippten Fläche) höher oder tiefer, gibt er die Höhe vor. Früher schluckte jeder getroffene
        // Skizzenbereich das Antippen, sobald auf Körperflächen skizziert worden war.
        if let region, model.selectedRegions.contains(region) { return false }
        let target = SIMD3<Double>(point)
        func extent(from handle: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> Double? {
            guard simd_length(handle.direction) > 1e-12 else { return nil }
            let raw = simd_dot(target - handle.origin, simd_normalize(handle.direction))
            let rounded = (raw * 10_000).rounded() / 10_000
            return abs(rounded) > 1e-4 ? rounded : nil
        }
        func report(_ value: Double) {
            model.message = "Bis zur angetippten Stelle: \(value.formatted(.number.precision(.fractionLength(0...3)))) mm"
        }
        if !model.selectedRegions.isEmpty, let handle = model.regionHandle, model.regionExtent == .toObject {
            // Fusion 360 „Bis Objekt“: jede angetippte Fläche, Kante oder Skizze gibt die Höhe vor (plus Versatz)
            if let region, model.selectedRegions.first?.sketch == region.sketch { return false }
            guard let value = extent(from: handle) else { return false }
            let target = value + (value >= 0 ? 1 : -1) * model.regionExtentOffset
            model.setRegionValue(target)
            report(target)
            return true
        }
        if !model.selectedRegions.isEmpty, let handle = model.regionHandle {
            if let region {
                // Bereich einer parallelen Skizze in anderer Höhe
                guard model.sketches.indices.contains(region.sketch),
                      abs(simd_dot(simd_normalize(model.sketches[region.sketch].plane.normal),
                                   simd_normalize(handle.direction))) > 0.999 else { return false }
            } else if model.regionValue == 0 {
                // Noch nicht gezogen: nur parallele ebene Flächen, sonst wählt Antippen wie gewohnt
                guard let face, let plane = model.plane(of: face),
                      abs(simd_dot(simd_normalize(plane.normal), simd_normalize(handle.direction))) > 0.999 else {
                    return false
                }
            }
            guard let value = extent(from: handle) else { return false }
            model.setRegionValue(value)
            report(value)
            return true
        }
        if region == nil, model.faceValue != 0, let handle = model.faceHandle, face != model.selection,
           let value = extent(from: handle) {
            model.setFaceValue(value)
            report(value)
            return true
        }
        return false
    }

    /// „Achse senkrecht“ aus der Kontextleiste: Achse sofort durch die Flächenmitte entlang der Normale.
    func createNormalAxis() {
        guard let face = model.selection, let plane = model.plane(of: face) else {
            model.message = "Für „Achse senkrecht“ eine ebene Fläche antippen."
            return
        }
        let center = model.mesh.centroid(of: face).map { SIMD3<Double>($0) } ?? plane.anchor
        model.addConstruction(.axis, origin: center, direction: plane.normal)
        let name = model.constructions.last?.name ?? "Achse"
        model.message = "\(name) erstellt (senkrecht durch die Flächenmitte) – zu finden unter Ebenen › Konstruktion."
    }

    /// Achse, die „Fertig“ im Konstruieren-Werkzeug erstellen würde (Vorschau im Viewport).
    var pendingAxis: (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        guard tool == .construct(.axis) else { return nil }
        if let custom = constructCustomAxis { return (custom.origin, custom.direction) }
        return model.resolve(constructAxis)
    }

    /// Ebene, die „Fertig“ im Konstruieren-Werkzeug erstellen würde (Vorschau im Viewport).
    var pendingPlane: (origin: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard tool == .construct(.plane), let reference = model.resolve(constructReference) else { return nil }
        return (reference.origin + reference.normal * constructOffset, reference.normal)
    }

    private func setCustomAxis(normalOf face: FaceRef) {
        guard let plane = model.plane(of: face) else { return }
        let center = model.mesh.centroid(of: face).map { SIMD3<Double>($0) } ?? plane.anchor
        constructCustomAxis = AxisSpec(origin: center, direction: plane.normal, name: "Flächennormale")
    }

    private func createConstruction(_ kind: ConstructionKind) {
        switch kind {
        case .plane:
            guard let reference = model.resolve(constructReference) else { return }
            model.addConstruction(.plane, origin: reference.origin + reference.normal * constructOffset,
                                  direction: reference.normal)
        case .axis:
            if let custom = constructCustomAxis {
                model.addConstruction(.axis, origin: custom.origin, direction: custom.direction)
            } else if let axis = model.resolve(constructAxis) {
                model.addConstruction(.axis, origin: axis.origin, direction: axis.direction)
            }
        case .point:
            model.addConstruction(.point, origin: constructPoint, direction: [0, 0, 1])
        }
    }

    /// Messen: Kantenlänge, Flächeninhalt und Volumen, Abstand zweier angetippter Punkte.
    private func measure(face: FaceRef?, edge: EdgeRef?, point: SIMD3<Float>?) {
        var lines: [String] = []
        func mm(_ value: Double, _ unit: String = "mm") -> String {
            "\(value.formatted(.number.precision(.fractionLength(0...3)))) \(unit)"
        }
        if let edge {
            model.resetSelection()
            model.toggleEdge(edge)
            lines.append("Kantenlänge: \(mm(model.length(of: edge)))")
        } else if let face {
            model.select(face: face)
            lines.append("Fläche: \(mm(model.area(of: face), "mm²"))")
            let volume = model.volume(ofBody: face.body)
            if volume > 0, model.bodies.indices.contains(face.body) {
                lines.append("Volumen \(model.bodies[face.body].name): \(mm(volume / 1000, "cm³"))")
            }
        } else {
            model.resetSelection()
        }
        if let point {
            measurePoints = measurePoints.count >= 2 ? [SIMD3<Double>(point)] : measurePoints + [SIMD3<Double>(point)]
        } else {
            measurePoints = []
        }
        if measurePoints.count == 2 {
            let d = measurePoints[1] - measurePoints[0]
            lines.append("Abstand: \(mm(simd_length(d)))")
            lines.append("ΔX \(mm(abs(d.x)))  ΔY \(mm(abs(d.y)))  ΔZ \(mm(abs(d.z)))")
        } else if measurePoints.count == 1 {
            lines.append("Zweiten Punkt antippen für den Abstand")
        }
        measureLines = lines
    }

    /// Isolieren: nur den gewählten Körper zeigen bzw. alles wieder einblenden.
    func toggleIsolate() {
        if model.isIsolated {
            model.isolate(nil)
        } else if let body = model.selectedBody {
            model.isolate(body)
        } else {
            model.message = "Erst einen Körper antippen, dann „Isolieren“."
        }
    }

    // MARK: Ziehpfeile

    var handles: [DragHandle] {
        // Wie bei Shapr3D: ein schlichter grauer Zugpfeil
        let blue = SIMD3<Float>(0.3, 0.32, 0.36)
        if sketch.isActive {
            let plane = sketch.plane
            if sketch.tool == .offset, let handle = sketch.offsetHandle {
                return [DragHandle(kind: .offset, axisOrigin: SIMD3<Float>(plane.world(handle.anchor)),
                                   direction: SIMD3<Float>(simd_normalize(plane.world(direction: handle.direction))),
                                   value: sketch.offsetDistance, color: blue)]
            }
            return []
        }
        switch tool {
        case .select:
            if let handle = model.regionHandle {
                return [DragHandle(kind: .region, axisOrigin: SIMD3<Float>(handle.origin),
                                   direction: simd_normalize(SIMD3<Float>(handle.direction)),
                                   value: model.regionValue, color: blue)]
            }
            if let handle = model.edgeHandle {
                return [DragHandle(kind: .edge, axisOrigin: SIMD3<Float>(handle.origin),
                                   direction: simd_normalize(SIMD3<Float>(handle.direction)),
                                   value: model.edgeValue, color: blue)]
            }
            if let handle = model.faceHandle {
                return [DragHandle(kind: .face, axisOrigin: SIMD3<Float>(handle.origin),
                                   direction: simd_normalize(SIMD3<Float>(handle.direction)),
                                   value: model.faceValue, color: blue)]
            }
            return []
        case .move:
            let offset = model.moveOffset
            let sketchCenter = model.movingSketch.flatMap { model.center(ofSketch: $0) }
            guard let center = sketchCenter.map({ $0 + offset })
                    ?? model.selectedBodies.first.flatMap({ model.center(ofBody: $0) }) else { return [] }
            let axes: [(SIMD3<Double>, SIMD3<Float>)] = [
                ([1, 0, 0], SIMD3(0.9, 0.25, 0.25)), ([0, 1, 0], SIMD3(0.25, 0.7, 0.3)), ([0, 0, 1], SIMD3(0.2, 0.4, 0.95)),
            ]
            return axes.enumerated().map { index, axis in
                let value = offset[index]
                let origin = center - axis.0 * value
                return DragHandle(kind: .move(axis: index), axisOrigin: SIMD3<Float>(origin),
                                  direction: SIMD3<Float>(axis.0), value: value, color: axis.1)
            }
        default:
            return []
        }
    }

    func apply(_ kind: HandleKind, value: Double) {
        switch kind {
        case .region:
            if value != model.regionValue { model.setRegionValue(value) }
        case .offset:
            if value != sketch.offsetDistance { sketch.offsetDistance = value }
        case .face:
            if value != model.faceValue { model.setFaceValue(value) }
        case .edge:
            let clamped = max(0, value)
            if clamped != model.edgeValue { model.setEdgeValue(clamped) }
        case .move(let axis):
            var offset = model.moveOffset
            guard offset[axis] != value else { return }
            offset[axis] = value
            model.setMoveOffset(offset)
        }
    }

    // MARK: Hinweise

    var hint: String? {
        if sketch.isActive {
            return sketchHint
        }
        switch tool {
        case .select:
            if model.regionValue != 0 || model.faceValue != 0 {
                return "Pfeil ziehen · andere Fläche antippen extrudiert bis dorthin"
            }
            if model.selectedBodies.count > 1 { return "„Vereinigen“ verschmilzt die Körper · Antippen nimmt hinzu/heraus" }
            if !model.selectedBodies.isEmpty { return "Weitere Körper antippen oder Rahmen aufziehen" }
            if !model.selectedEdges.isEmpty { return "Pfeil ziehen · weitere Kanten antippen" }
            if !model.selectedRegions.isEmpty { return "Pfeil ziehen · weitere Bereiche antippen · Körperfläche antippen = Höhe bis dorthin" }
            if model.selection != nil {
                return model.faceHandle != nil ? "Pfeil ziehen zum Extrudieren" : "Fläche gewählt"
            }
            if boxSelects { return "Rahmen aufziehen: nach rechts ganz umschlossene, nach links auch angeschnittene Körper" }
            if selectsBodies { return "Körper antippen – mehrere möglich, dann Vereinigen, Abziehen oder Schneiden" }
            return nil
        case .insert: return "Maße eingeben, dann „Fertig“"
        case .boolean(let kind):
            switch model.selectedBodies.count {
            case 0: return "Zielkörper antippen"
            case 1: return kind == .union ? "Körper zum Vereinigen antippen" : "Werkzeugkörper antippen"
            default: return "„Fertig“ tippen"
            }
        case .move:
            if model.movingSketch != nil { return "Skizze: Achsenpfeil ziehen oder Werte eingeben, dann „Fertig“" }
            return model.selectedBodies.isEmpty ? "Körper antippen" : "Achsenpfeil ziehen oder Werte eingeben"
        case .mirror: return model.selectedBodies.isEmpty ? "Körper antippen" : "Ebene wählen, dann „Fertig“"
        case .shell: return model.selection == nil ? "Fläche antippen, die offen sein soll" : "Wandstärke eingeben"
        case .color: return model.selectedBodies.isEmpty ? "Körper antippen" : "Farbe wählen"
        case .pattern: return model.selectedBodies.isEmpty ? "Körper antippen" : "Anzahl und Abstand einstellen"
        case .scale: return model.selectedBodies.isEmpty ? "Körper antippen" : "Faktor eingeben"
        case .align:
            return model.selectedBodies.count < 2 ? "Bezugskörper, dann weitere Körper antippen" : "Achsen wählen"
        case .revolve:
            return model.selectedRegions.isEmpty ? "Skizzenbereich antippen" : "Achse und Winkel wählen"
        case .sweep:
            return model.selectedRegions.isEmpty ? "Profil (Skizzenbereich) antippen" : "Pfad-Skizze wählen"
        case .loft:
            return model.selectedRegions.count < 2 ? "Querschnitte nacheinander antippen (je Skizze einen)"
                : "Weitere Querschnitte antippen oder „Fertig“"
        case .split: return model.selectedBodies.isEmpty ? "Körper antippen" : "Teilungsebene wählen"
        case .section: return "Ebene wählen oder ebene Fläche antippen"
        case .measure: return "Kante, Fläche oder zwei Punkte antippen"
        case .construct(.plane): return "Bezug wählen oder ebene Fläche antippen, Abstand eingeben"
        case .construct(.axis): return "Achse wählen, Kante oder Fläche antippen"
        case .construct(.point): return "Punkt auf einem Körper antippen oder Koordinaten eingeben"
        case .canvas: return "Größe und Lage des Bilds einstellen"
        case .scaleSketch: return model.selectedRegions.isEmpty ? "Skizzenbereich antippen" : "Faktor eingeben"
        case .offsetEdges: return "Ebene Fläche antippen"
        }
    }

    private var sketchHint: String {
        if sketch.isChoosingPlane { return "Skizzenebene antippen – oder eine ebene Fläche eines Körpers" }
        switch sketch.tool {
        case .select:
            if !sketch.selection.isEmpty {
                return "\(sketch.selection.count) gewählt · Ecke oder Kante ziehen ändert die Größe · rechts Einschränkung wählen"
            }
            return "Antippen wählt · Ecke/Ende ziehen ändert die Größe · über einem Punkt Stift drücken merkt ihn (zwei → Mitte)"
        case .polyline where sketch.hasOpenChain:
            if sketch.arcModifier { return "Tangentialer Bogen: Stift zum Endpunkt, dann Finger heben (oder Stift heben)" }
            return "Nächsten Punkt setzen · Finger auflegen: tangentialer Bogen · zurück zum Start schließt"
        case .polyline:
            return "Ziehen: Linie · rund ziehen: Kreis oder Bogen · Kritzeln über Elemente löscht sie"
        case .arc where sketch.arcMode == .center:
            return sketch.isWaitingForSecondStep ? "Zum Ende ziehen – der Bogen folgt dem Stift (auch über 180°)"
                : "Vom Mittelpunkt zum Startpunkt ziehen"
        case .arc:
            return sketch.isWaitingForArcBulge ? "Wölbung ziehen" : "Von einem Ende zum anderen ziehen"
        case .circle where sketch.circleMode == .twoPoint:
            return "Durchmesser ziehen: von einem Randpunkt zum gegenüberliegenden"
        case .circle where sketch.circleMode == .threePoint:
            return sketch.isWaitingForSecondStep ? "Dritten Punkt ziehen bzw. antippen" : "Ersten und zweiten Punkt ziehen"
        case .slot:
            if sketch.isWaitingForSecondStep { return "Breite ziehen" }
            switch sketch.slotMode {
            case .centerToCenter: return "Von einem Bogenmittelpunkt zum anderen ziehen"
            case .overall: return "Gesamtlänge von Ende zu Ende ziehen"
            case .centerPoint: return "Von der Mitte zu einem Bogenmittelpunkt ziehen"
            }
        case .chamfer:
            return "Ecke antippen, an der zwei Linien zusammenstoßen – Abstand unten eingeben"
        case .extend:
            return "Linie nahe dem Ende antippen – sie wächst bis zur nächsten Kurve"
        case .breakCurve:
            return "Kurve antippen – sie wird an den nächsten Schnittpunkten geteilt"
        case .mirror, .rectPattern, .circPattern:
            return sketch.transformStatus
        case .spline where sketch.hasOpenSpline:
            return "Punkte setzen · auf dem Start schließen · letzten Punkt erneut antippen beendet"
        case .spline:
            return "Ersten Punkt setzen"
        case .point:
            return "Punkt antippen"
        case .text:
            return "Position des Textes antippen"
        case .offset:
            return sketch.hasOffsetTarget ? "Pfeil ziehen, dann „Fertig“" : "Kontur oder Kurve antippen"
        case .trim:
            return "Stück einer Kurve antippen – es wird bis zu den Schnittpunkten entfernt"
        case .fillet:
            return "Ecke antippen, an der zwei Linien zusammenstoßen – Radius unten eingeben"
        case .project:
            return "Körperkante oder Fläche antippen, um sie in die Skizze zu übernehmen"
        case .scale:
            return sketch.selection.isEmpty ? "Faktor eingeben – skaliert alles (oder vorher Elemente antippen)"
                : "Faktor eingeben – skaliert die Auswahl"
        case .rectangle where sketch.rectangleMode == .threePoint:
            return sketch.isWaitingForRectangleHeight ? "Höhe ziehen" : "Erste Kante ziehen"
        default:
            break
        }
        if !sketch.selection.isEmpty {
            return "\(sketch.selection.count) gewählt · rechts eine Einschränkung antippen"
        }
        if sketch.hasProfile { return "„Fertig“ übernimmt die Skizze · Kritzeln über Elemente löscht sie" }
        return "Zeichnen auf \(sketch.plane.isOnFace ? "der Fläche" : "der Ebene „\(sketch.plane.name)“")"
    }

    // MARK: Speichern

    /// Vorschaubild für die Projektübersicht.
    func saveThumbnail() {
        guard let image = snapshot?(CGSize(width: 480, height: 360)), let data = image.pngData() else { return }
        try? data.write(to: project.thumbnailURL)
    }
}
