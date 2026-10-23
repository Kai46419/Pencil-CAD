import SwiftUI
import simd

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

    var title: String {
        switch self {
        case .select: "Auswahl"
        case .insert(let primitive): "\(primitive.rawValue) einfügen"
        case .boolean(let kind): kind.rawValue
        case .move: "Verschieben/Rotieren"
        case .mirror: "Spiegeln"
        case .shell: "Schale"
        case .color: "Farbe"
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
            model.storeSketch(plane: sketch.plane, entities: entities, replacing: editingSketchIndex)
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
        sketch.load(plane: stored.plane, entities: stored.entities)
        editingSketchIndex = index
        send(.alignToSketchPlane)
    }

    // MARK: Werkzeuge

    func activate(_ newTool: ModelTool) {
        if sketch.isActive {
            endSketch()
        }
        model.cancelPreview()
        let previousBody = model.selectedBody
        let previousFace = model.selection
        tool = newTool
        switch newTool {
        case .select:
            model.resetSelection()
        case .insert(let primitive):
            model.resetSelection()
            insertSize = primitive.defaultSize
            updateInsertPreview()
        case .boolean, .move, .mirror, .color:
            model.resetSelection()
            if let previousBody {
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
        case .color: return true
        default: return model.hasPreview
        }
    }

    // MARK: Antippen im Viewport

    /// Tippen im Modellierbereich (nicht im Skizzenmodus).
    func tapped(face: FaceRef?, edge: EdgeRef?, region: RegionRef? = nil) {
        model.message = nil
        switch tool {
        case .select:
            if let edge {
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

    // MARK: Ziehpfeile

    var handles: [DragHandle] {
        let blue = SIMD3<Float>(0.1, 0.42, 0.98)
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
            guard let body = model.selectedBodies.first, let center = model.center(ofBody: body) else { return [] }
            let offset = model.moveOffset
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
            if !model.selectedEdges.isEmpty { return "Pfeil ziehen · weitere Kanten antippen" }
            if !model.selectedRegions.isEmpty { return "Pfeil ziehen · weitere Bereiche antippen" }
            if model.selection != nil {
                return model.faceHandle != nil ? "Pfeil ziehen zum Extrudieren" : "Fläche gewählt"
            }
            return nil
        case .insert: return "Maße eingeben, dann „Fertig“"
        case .boolean(let kind):
            switch model.selectedBodies.count {
            case 0: return "Zielkörper antippen"
            case 1: return kind == .union ? "Körper zum Vereinigen antippen" : "Werkzeugkörper antippen"
            default: return "„Fertig“ tippen"
            }
        case .move: return model.selectedBodies.isEmpty ? "Körper antippen" : "Achsenpfeil ziehen oder Werte eingeben"
        case .mirror: return model.selectedBodies.isEmpty ? "Körper antippen" : "Ebene wählen, dann „Fertig“"
        case .shell: return model.selection == nil ? "Fläche antippen, die offen sein soll" : "Wandstärke eingeben"
        case .color: return model.selectedBodies.isEmpty ? "Körper antippen" : "Farbe wählen"
        }
    }

    private var sketchHint: String {
        if sketch.isChoosingPlane { return "Skizzenebene antippen – oder eine ebene Fläche eines Körpers" }
        switch sketch.tool {
        case .polyline where sketch.hasOpenChain:
            return "Nächsten Punkt setzen · zurück zum Start schließt"
        case .arc:
            return sketch.isWaitingForArcBulge ? "Wölbung ziehen" : "Von einem Ende zum anderen ziehen"
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
        default:
            break
        }
        if sketch.hasProfile { return "„Fertig“ übernimmt die Skizze – danach Bereich antippen und extrudieren" }
        return "Zeichnen auf \(sketch.plane.isOnFace ? "der Fläche" : "der Ebene „\(sketch.plane.name)“")"
    }

    // MARK: Speichern

    /// Vorschaubild für die Projektübersicht.
    func saveThumbnail() {
        guard let image = snapshot?(CGSize(width: 480, height: 360)), let data = image.pngData() else { return }
        try? data.write(to: project.thumbnailURL)
    }
}
