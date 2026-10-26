import MetalKit
import SwiftUI

/// 3D-Ansicht. Finger navigieren (1 Finger drehen, 2 Finger verschieben, Pinch zoomen, tippen wählt).
/// Der Apple Pencil skizziert im Skizzenmodus; Ziehpfeile lassen sich mit Pencil und Finger ziehen.
struct Viewport: UIViewRepresentable {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController

    final class Coordinator {
        var renderer: Renderer?
        var meshRevision = -1
        var selectionRevision = -1
        var commandID = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ViewportView {
        let view = ViewportView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        if let renderer = Renderer(view: view) {
            view.delegate = renderer
            view.renderer = renderer
            context.coordinator.renderer = renderer
            renderer.willDraw = { [weak view] in view?.syncIfNeeded() }
        }
        view.workspace = workspace
        workspace.snapshot = { [weak view] size in view?.snapshot(size: size) }
        workspace.currentCamera = { [weak view] in view?.renderer?.camera }
        return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
        let coordinator = context.coordinator
        let renderer = coordinator.renderer
        if coordinator.meshRevision != model.revision {
            coordinator.meshRevision = model.revision
            renderer?.update(mesh: model.mesh)
            coordinator.selectionRevision = -1
        }
        if coordinator.selectionRevision != model.selectionRevision {
            coordinator.selectionRevision = model.selectionRevision
            renderer?.updateSelection(indices: model.selectionIndices, edges: model.edgeHighlight)
        }
        renderer?.displayMode = workspace.displayMode
        // Im Skizzenmodus flach: Parallelprojektion, kein Drehen
        let orthographic = workspace.isOrthographic || (sketch.isActive && !sketch.isChoosingPlane)
        if renderer?.camera.isOrthographic != orthographic {
            renderer?.camera.isOrthographic = orthographic
        }
        if coordinator.commandID != workspace.viewCommand.id {
            coordinator.commandID = workspace.viewCommand.id
            view.run(workspace.viewCommand.kind)
        }
        view.refresh()
    }
}

final class ViewportView: MTKView {
    weak var renderer: Renderer?
    weak var workspace: Workspace?

    private var orbitGesture: UIPanGestureRecognizer?
    private var panGesture: UIPanGestureRecognizer?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var tapGesture: UITapGestureRecognizer?
    private var undoGesture: UITapGestureRecognizer?
    private var redoGesture: UITapGestureRecognizer?
    private var sketchTouch: UITouch?
    private var handleDrag: HandleDragState?
    /// Drehscheibe im Verschieben-Werkzeug
    private var ringDrag: RingDragState?
    private let ringLabel = PaddedLabel()
    private let valueLabel = PaddedLabel()
    /// Einrasthinweis am Stift (Endpunkt, Mittelpunkt …)
    private let snapHintLabel = PaddedLabel()
    private var lastSnapKey: String?
    private lazy var selectionFeedback = UISelectionFeedbackGenerator()
    private var canvasFeedbackStorage: UIFeedbackGenerator?
    /// Ab iPadOS 17.5: Haptik auch im Apple Pencil Pro
    @available(iOS 17.5, *)
    private var canvasFeedback: UICanvasFeedbackGenerator {
        if let existing = canvasFeedbackStorage as? UICanvasFeedbackGenerator { return existing }
        let generator = UICanvasFeedbackGenerator(view: self)
        canvasFeedbackStorage = generator
        return generator
    }
    private var planeLabels: [PaddedLabel] = []
    private var dimensionFields: [String: DimensionField] = [:]
    /// Kleines Ziffernfeld am gerade bearbeiteten Maß (statt der Bildschirmtastatur, die die Maße verdeckt)
    private lazy var keypad: DimensionKeypad = {
        let keypad = DimensionKeypad()
        keypad.isHidden = true
        keypad.onKey = { [weak self] key in self?.keypadPressed(key) }
        self.addSubview(keypad)
        return keypad
    }()
    /// Kurzzeichen der Einschränkungen am Element
    private var badgeLabels: [PaddedLabel] = []
    /// Geladene Bilder (Canvas) je Datei
    private var canvasTextures: [String: MTLTexture] = [:]
    /// Bereichsfüllungen der aktuellen Skizze, neu berechnet nur bei geänderter Geometrie.
    private var sketchFillRevision = -1
    private var sketchFills: [[SIMD3<Float>]] = []
    private var needsSync = true
    /// Letzte Position des schwebenden Stifts (für Drücken/Doppeltippen ohne eigene Position)
    private var lastHoverLocation: CGPoint?
    /// Punkt merken durch ruhiges Schweben (1 s)
    private var hoverDwell: DispatchWorkItem?
    private var hoverDwellOrigin: CGPoint?
    /// Was der schwebende Stift im Modell treffen würde (Hervorhebung vor dem Antippen, wie Shapr3D)
    private enum HoverPick: Equatable {
        case face(FaceRef)
        case edge(EdgeRef)
        case region(RegionRef)
        case point(SIMD3<Double>)
    }
    private var hoverPick: HoverPick?
    /// Aufgelegte Finger beim Skizzieren mit dem Stift (Finger auflegen = tangentialer Bogen)
    private var heldFingers = Set<UITouch>()
    /// Der aufgelegte Finger hat als Bogen-Taste gedient: sein Loslassen ist kein Antippen
    private var suppressFingerTap = false
    /// Ende des letzten Stiftstrichs: Drücken/Doppeltippen direkt danach war meist ein festerer Griff, kein Merken
    private var strokeEndedAt: TimeInterval = 0
    /// Beginn des laufenden Skizzenstrichs (festes Zugreifen beim Ansetzen zählt nicht als Drücken)
    private var strokeBeganAt: TimeInterval = 0

    private func updateHeldFingers(began: Set<UITouch> = [], ended: Set<UITouch> = []) {
        guard let sketch else { return }
        // Im Skizzenmodus nehmen Verschieben/Zoomen dem Viewport den Finger nicht weg: lag der Finger vor dem
        // Stift auf und verrutschte leicht, begann das Verschieben, der Finger galt als abgehoben und der
        // Bogen wurde zur Geraden (der Schlussbogen zum Linienanfang).
        let sketching = sketch.isActive && !sketch.isChoosingPlane
        for gesture in [orbitGesture, panGesture, pinchGesture] as [UIGestureRecognizer?] {
            gesture?.cancelsTouchesInView = !sketching
        }
        if sketch.isActive, !sketch.isChoosingPlane, !sketch.fingerDraws {
            heldFingers.formUnion(began.filter { $0.type == .direct })
        }
        let wasHeld = !heldFingers.isEmpty
        heldFingers.subtract(ended)
        // Finger los, während der Stift noch aufliegt: der Bogen endet sofort an der Stiftspitze
        // (wie Shapr3D: Stift zum Endpunkt, Finger heben)
        if wasHeld, heldFingers.isEmpty, let touch = sketchTouch, sketch.tool == .polyline, sketch.arcActive {
            suppressFingerTap = true
            sketchTouch = nil
            strokeEndedAt = CACurrentMediaTime()
            if let point = sketchPoint(for: touch) {
                sketch.ended(at: point, tolerance: snapTolerance)
            } else {
                sketch.cancelStroke()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if heldFingers.isEmpty, suppressFingerTap, !ended.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.suppressFingerTap = false }
        }
        let held = !heldFingers.isEmpty && sketch.isActive
        if sketch.arcModifier != held {
            sketch.arcModifier = held
            refresh()
        }
    }
    /// Rahmenauswahl: Berührung, Startpunkt und gezeichneter Rahmen
    private var boxTouch: UITouch?
    private var boxStart: CGPoint = .zero
    private let boxView = SelectionBoxView()
    /// Lasso: gezogene Kurve (Bildschirmpunkte); boxInSketch: Rahmen bzw. Lasso wählt Skizzenelemente
    private var lassoPath: [CGPoint] = []
    private var boxInSketch = false
    private let lassoView = SelectionLassoView()

    private struct HandleDragState {
        let touch: UITouch
        let handle: DragHandle
        let startParameter: Float
        let step: Double
    }

    /// Drehen am Ring: Ring wie beim Ansetzen (dreht nicht mit), Winkel des Ansatzpunkts, aufsummierter
    /// Drehwinkel (Bogenmaß) und der gezeigte, gerastete Wert in ganzen Grad.
    private struct RingDragState {
        let touch: UITouch
        let center: SIMD3<Double>
        let radius: Double
        let startAngle: Double
        var lastAngle: Double
        var sweep: Double = 0
        var degrees: Double = 0
        var axis: Int = 2
    }

    /// Ziehen am Ebenengriff: Ebene (Normale), Ansatzpunkt und Verschiebung beim Ansetzen.
    private struct PlaneDragState {
        let touch: UITouch
        let normal: Int
        let origin: SIMD3<Double>
        let start: SIMD3<Double>
        let startOffset: SIMD3<Double>
        let step: Double
    }
    private var planeDrag: PlaneDragState?

    private let fingersOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    private let fingersAndPencil = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                    NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    private var model: ModelStore? { workspace?.model }
    private var sketch: SketchController? { workspace?.sketch }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setUp()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        // Ohne das erhält die Ansicht nur die erste Berührung: ein zum Stift aufgelegter Finger (Bogen-Taste)
        // kam in touchesBegan nie an, der Strich blieb gerade.
        isMultipleTouchEnabled = true
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit))
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = fingersOnly

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 2
        pan.allowedTouchTypes = fingersOnly

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.allowedTouchTypes = fingersOnly

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = fingersAndPencil

        // Schwebender Stift (iPad Pro mit Apple Pencil Pro / 2. Gen.)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))

        // Punkt merken: Finger doppeltippen (Stift: 1 s schweben). Ein 1-s-Halten mit aufgesetztem Stift hatte
        // beim langsamen Zeichnen ungewollt Punkte gemerkt – darum nur schwebend.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = fingersOnly

        // Wie Shapr3D: mit zwei Fingern tippen = Rückgängig, mit drei Fingern = Wiederholen
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = fingersOnly
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = fingersOnly
        undoGesture = undoTap
        redoGesture = redoTap

        for recognizer in [orbit, pan, pinch, tap, hover, doubleTap, undoTap, redoTap] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        // Drücken (Apple Pencil Pro) bzw. Doppeltippen öffnet das Werkzeugrad
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        orbitGesture = orbit
        panGesture = pan
        pinchGesture = pinch
        tapGesture = tap

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .black
        valueLabel.backgroundColor = .white
        valueLabel.layer.cornerRadius = 9
        valueLabel.layer.borderWidth = 1.5
        valueLabel.layer.borderColor = UIColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1).cgColor
        valueLabel.layer.masksToBounds = true
        valueLabel.isHidden = true
        addSubview(valueLabel)
        ringLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        ringLabel.textColor = .white
        ringLabel.backgroundColor = UIColor(red: 0.1, green: 0.36, blue: 0.88, alpha: 1)
        ringLabel.layer.cornerRadius = 9
        ringLabel.layer.masksToBounds = true
        ringLabel.isHidden = true
        addSubview(ringLabel)
        boxView.isHidden = true
        addSubview(boxView)
        lassoView.isHidden = true
        addSubview(lassoView)
    }

    // MARK: Kamera

    func run(_ command: ViewCommand.Kind) {
        guard let renderer else { return }
        switch command {
        case .alignToSketchPlane:
            guard let plane = sketch?.plane else { return }
            let normal = SIMD3<Float>(plane.normal)
            let origin = SIMD3<Float>(plane.origin)
            // Ziel auf die Ebene projizieren, damit der sichtbare Ausschnitt erhalten bleibt
            let target = renderer.camera.target - simd_dot(renderer.camera.target - origin, normal) * normal
            // Skizzenebene gerade: u waagerecht nach rechts, keine schräge Draufsicht
            renderer.camera.look(along: normal, at: target, right: SIMD3<Float>(plane.u))
        case .fitAll:
            if let bounds = model?.mesh.bounds {
                renderer.camera.frame(min: bounds.min, max: bounds.max)
            }
        case .look(let normal):
            // Drauf- und Untersicht gerade ausrichten (X waagerecht)
            let flat = abs(simd_normalize(normal).z) > 0.999
            renderer.camera.look(along: normal, at: renderer.camera.target, right: flat ? SIMD3(1, 0, 0) : nil)
        case .restore(let saved):
            guard saved.target.count == 3 else { return }
            renderer.camera.yaw = saved.yaw
            renderer.camera.pitch = saved.pitch
            renderer.camera.distance = saved.distance
            renderer.camera.target = SIMD3<Float>(saved.target[0], saved.target[1], saved.target[2])
        }
        cameraMoved()
    }

    /// Meldet die Kamerawinkel an den ViewCube. Asynchron, weil run() aus updateUIView aufgerufen wird
    /// und SwiftUI während eines Updates keine Änderungen veröffentlichen darf.
    private func cameraMoved() {
        if let camera = renderer?.camera {
            DispatchQueue.main.async { [weak self] in
                self?.workspace?.cameraChanged(yaw: camera.yaw, pitch: camera.pitch)
            }
        }
        refresh()
    }

    func snapshot(size: CGSize) -> UIImage? {
        renderer?.snapshot(width: Int(size.width * 2), height: Int(size.height * 2), viewHeight: size.height)
    }

    // MARK: Abgleich mit dem Zustand

    /// Zustand hat sich geändert: beim nächsten Bild abgleichen. So wird auch bei bis zu 240 Stiftpunkten
    /// pro Sekunde höchstens einmal je Bildschirmbild gerechnet und gezeichnet.
    func refresh() {
        needsSync = true
        setNeedsDisplay()
    }

    func syncIfNeeded() {
        guard needsSync else { return }
        needsSync = false
        sync()
    }

    /// Gleicht Renderer, Gesten, Linien, Ziehpfeile und Maße mit dem Zustand ab.
    private func sync() {
        guard let renderer, let sketch, let workspace else { return }
        let choosing = sketch.isActive && sketch.isChoosingPlane
        let sketching = sketch.isActive && !choosing
        let fingerSketching = sketching && sketch.fingerDraws
        // Rahmenauswahl: ein Finger zieht den Rahmen statt zu drehen. Beim Skizzieren mit dem Stift verschiebt
        // ein Finger nicht: er ist die Bogen-Taste (verschieben und zoomen mit zwei Fingern).
        orbitGesture?.isEnabled = !sketching && !(workspace.boxSelects && workspace.acceptsBoxSelection)
        tapGesture?.isEnabled = !fingerSketching
        tapGesture?.allowedTouchTypes = sketching ? fingersOnly : fingersAndPencil

        let plane = sketch.plane
        renderer.gridTransform = sketching && !sketch.showsGrid ? nil : sketching
            ? float4x4(origin: SIMD3<Float>(plane.origin), u: SIMD3<Float>(plane.u),
                       v: SIMD3<Float>(plane.v), n: SIMD3<Float>(plane.normal))
            : matrix_identity_float4x4
        // Angezeigtes Raster = Fangraster (bzw. gröberes Vielfaches, wenn es im Bild zu eng wird)
        renderer.gridBase = sketching && sketch.snapEnabled && sketch.snapKinds.contains(.grid) ? Float(sketch.gridStep) : 0
        renderer.clipPlane = workspace.clipPlane.map {
            SIMD4<Float>(Float($0.normal.x), Float($0.normal.y), Float($0.normal.z), Float($0.distance))
        } ?? .zero
        updateLines()
        refreshPlanes()
        updateCanvases()
        updateBadges()

        let handles = workspace.handles
        // Ein Pfeil, der knapp über dem Objekt schwebt; Ziehen in Gegenrichtung ergibt negative Werte
        renderer.handles = handles.map { handle in
            HandleGraphic(base: arrowBase(handle), direction: handle.pointing, color: handle.color, scale: handle.scale)
        }
        updateValueLabel(handles)
        updateDimensionFields()
        updateSnapHint()
        workspace.pickTolerance = snapTolerance
    }

    // MARK: Einrasthinweis

    /// Shapr3D „Einrasthinweise“: Art des Fangs als kleines Schild neben dem Stift.
    private func updateSnapHint() {
        snapFeedback()
        guard let renderer, let sketch, sketch.isActive, !sketch.isChoosingPlane, sketch.showsSnapHints,
              let snap = sketch.currentSnap, let kind = snap.kind, kind != .grid,
              let point = renderer.camera.project(SIMD3<Float>(sketch.plane.world(snap.point)), viewSize: bounds.size) else {
            snapHintLabel.isHidden = true
            return
        }
        if snapHintLabel.superview == nil {
            snapHintLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            snapHintLabel.textColor = .white
            snapHintLabel.backgroundColor = UIColor(red: 0.98, green: 0.45, blue: 0.05, alpha: 0.92)
            snapHintLabel.layer.cornerRadius = 8
            snapHintLabel.layer.masksToBounds = true
            snapHintLabel.isUserInteractionEnabled = false
            addSubview(snapHintLabel)
        }
        if snapHintLabel.text != kind.hint {
            snapHintLabel.text = kind.hint
            snapHintLabel.sizeToFit()
        }
        snapHintLabel.center = CGPoint(x: point.x + snapHintLabel.bounds.width / 2 + 14,
                                       y: point.y - snapHintLabel.bounds.height / 2 - 12)
        snapHintLabel.isHidden = false
    }

    /// Haptik beim Einrasten: einmal je neuem Fangpunkt (nicht beim Raster, nicht wiederholt am selben Punkt).
    private func snapFeedback() {
        guard let sketch, sketch.isActive, !sketch.isChoosingPlane,
              let snap = sketch.currentSnap, let kind = snap.kind, kind != .grid else {
            lastSnapKey = nil
            return
        }
        // Punktfänge (Ende, Mitte, Zentrum, Schnitt, 3D-Punkt) klicken immer. Entlang von Leitlinien, Winkeln und
        // Kurven tickt es wie ein Maßband – nur mit „Haptik beim Zeichnen“; sonst ein Klick beim Einrasten.
        let pointSnap: Set<SnapKind> = [.endpoint, .midpoint, .center, .intersection, .modelPoint]
        let ticks = pointSnap.contains(kind) || sketch.drawHaptics || sketchTouch == nil
        let key = ticks ? "\(kind)|\((snap.point.x * 100).rounded())|\((snap.point.y * 100).rounded())" : "\(kind)"
        guard key != lastSnapKey else { return }
        lastSnapKey = key
        guard sketch.snapHaptics else { return }
        if #available(iOS 17.5, *) {
            canvasFeedback.alignmentOccurred(at: snapHintAnchor(snap.point))
        } else {
            selectionFeedback.selectionChanged()
        }
    }

    private func snapHintAnchor(_ point: Point2) -> CGPoint {
        guard let renderer, let sketch,
              let p = renderer.camera.project(SIMD3<Float>(sketch.plane.world(point)), viewSize: bounds.size) else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        return p
    }

    // MARK: Linien und Bereiche

    private static let sketchInk = SIMD3<Float>(0.05, 0.06, 0.09)
    private static let definedGreen = SIMD3<Float>(0.08, 0.55, 0.22)
    private static let previewBlue = SIMD3<Float>(0.05, 0.4, 0.98)
    private static let snapOrange = SIMD3<Float>(0.98, 0.45, 0.05)
    private static let constructionGray = SIMD3<Float>(0.4, 0.42, 0.48)
    private static let selectionOrange = SIMD3<Float>(0.98, 0.5, 0.06)
    private static let helperOrange = SIMD3<Float>(0.93, 0.55, 0.16)
    private static let dimensionInk = SIMD3<Float>(0.18, 0.2, 0.26)
    private static let axes: [(SIMD3<Float>, SIMD3<Float>)] = [
        ([1, 0, 0], [0.78, 0.16, 0.11]),
        ([0, 1, 0], [0.17, 0.52, 0.2]),
        ([0, 0, 1], [0.1, 0.36, 0.88]),
    ]

    /// Skizzenlinien (dick, immer sichtbar), gespeicherte Skizzen, Konstruktionsgeometrie, Auswahl,
    /// Maßlinien, Fangsymbole, Knoten und Bereichsfüllungen.
    private func updateLines() {
        guard let renderer, let sketch, let model, let workspace else { return }
        let sketching = sketch.isActive && !sketch.isChoosingPlane
        var groups: [LineGroup] = []
        var fills: [FillGroup] = []
        let perPoint = Double(renderer.camera.worldUnitsPerPoint(viewHeight: Float(bounds.height)))

        // Achsen wie bei Shapr3D: X rot, Y grün, Z blau, vom Ursprung in positiver Richtung bis zum Horizont
        if !sketching, workspace.showsOrigin {
            let reach = max(renderer.camera.distance * 10, planeHalfSize * 20)
            for (axis, color) in Self.axes {
                groups.append(LineGroup(polylines: [[.zero, axis * reach]], color: color, width: 1, onTop: false))
            }
        }
        // Skizze (Kai): Achsen, die in der Skizzenebene liegen, dezent durchgehend – X rot, Y grün, Z blau
        if sketching, workspace.showsOrigin {
            let reach = max(renderer.camera.distance * 10, planeHalfSize * 20)
            let normal = SIMD3<Float>(sketch.plane.normal)
            let origin = SIMD3<Float>(sketch.plane.origin)
            for (axis, color) in Self.axes where abs(simd_dot(axis, normal)) < 1e-4 && abs(simd_dot(origin, normal)) < 1e-3 {
                // Aufgehellt zum Hintergrund hin, damit die Linien nicht mit Skizzenlinien verwechselt werden
                let soft = color * 0.55 + SIMD3<Float>(repeating: 0.845) * 0.45
                groups.append(LineGroup(polylines: [[-axis * reach, axis * reach]], color: soft, width: 1, onTop: false))
            }
        }
        // Ebenenwahl: drei kleine graue Felder neben dem Ursprung
        if sketch.isActive, sketch.isChoosingPlane {
            for square in basePlaneSquares {
                let h = square.half
                let corners = [square.center - square.u * h - square.v * h, square.center + square.u * h - square.v * h,
                               square.center + square.u * h + square.v * h, square.center - square.u * h + square.v * h]
                fills.append(FillGroup(triangles: [0, 1, 2, 0, 2, 3].map { corners[$0] },
                                       color: SIMD4(0.28, 0.28, 0.29, 0.38)))
            }
        }

        for (index, stored) in model.sketches.enumerated() where !stored.isHidden && stored.id != model.previewHiddenSketch {
            if sketch.isActive, index == workspace.editingSketchIndex { continue }
            // Skizze, die gerade verschoben wird, an der neuen Stelle zeigen
            let shift = !sketch.isActive && workspace.tool == .move && model.movingSketch == index
                ? SIMD3<Float>(model.moveOffset) : SIMD3<Float>(0, 0, 0)
            let move = { (line: [SIMD3<Float>]) in line.map { $0 + shift } }
            groups.append(LineGroup(polylines: stored.lines.map(move),
                                    color: sketching ? SIMD3(0.36, 0.38, 0.44) : SIMD3(0.12, 0.14, 0.2),
                                    width: 1.8, onTop: false))
            if !stored.constructionLines.isEmpty {
                groups.append(LineGroup(polylines: stored.constructionLines.flatMap { dashed(move($0), dash: Float(4 * perPoint)) },
                                        color: Self.constructionGray, width: 1.2, onTop: false))
            }
            guard !sketch.isActive else { continue }
            for (region, triangles) in stored.fills.enumerated() {
                let selected = model.selectedRegions.contains(RegionRef(sketch: index, region: region))
                fills.append(FillGroup(triangles: triangles.map { $0 + shift },
                                       color: selected ? SIMD4(0.98, 0.55, 0.15, 0.55) : SIMD4(0.2, 0.45, 0.95, 0.14)))
            }
        }

        addConstructionItems(to: &groups, perPoint: perPoint, sketching: sketching)
        if !sketching {
            addRotationRing(to: &groups)
            addPlaneHandles(to: &fills, groups: &groups)
        }
        if !sketch.isActive { addHoverHighlight(to: &groups, fills: &fills) }
        if !sketch.isActive, workspace.tool == .measure, !workspace.measurePoints.isEmpty {
            let points = workspace.measurePoints.map { SIMD3<Float>($0) }
            groups.append(LineGroup(polylines: points.count == 2 ? [points] : [], color: Self.previewBlue, width: 2,
                                    dots: points, dotRadius: 5))
        }
        if !sketch.isActive { addToolOverlays(to: &groups, fills: &fills) }
        // Bild kalibrieren: angetippte Punkte und ihre Verbindung
        if !sketch.isActive, let calibration = workspace.calibrationWorldPoints {
            let points = calibration.map { SIMD3<Float>($0) }
            groups.append(LineGroup(polylines: points.count == 2 ? [points] : [], color: Self.snapOrange, width: 2.4,
                                    dots: points, dotRadius: 6, onTop: true))
        }
        // Übersetzen: Start- und Zielpunkt mit Verbindung
        if !sketch.isActive, workspace.tool == .translate, let start = workspace.translateStart {
            let points = ([start] + (workspace.translateEnd.map { [$0] } ?? [])).map { SIMD3<Float>($0) }
            groups.append(LineGroup(polylines: points.count == 2 ? [points] : [], color: Self.snapOrange, width: 2.4,
                                    dots: points, dotRadius: 6, onTop: true))
        }

        if sketching {
            let plane = sketch.plane
            let world = { (p: Point2) in SIMD3<Float>(plane.world(p)) }
            if sketchFillRevision != sketch.geometryRevision {
                sketchFillRevision = sketch.geometryRevision
                sketchFills = sketch.regions.map { regionTriangles($0, plane: plane) }
            }
            if sketch.showsProfiles {
                fills += sketchFills.map { FillGroup(triangles: $0, color: SIMD4(0.2, 0.45, 0.95, 0.16)) }
            }
            // Wie Shapr3D: vollständig bestimmte Elemente grün, freie in Tinte
            let states = sketch.entityPolylinesByState
            groups.append(LineGroup(polylines: states.free.map { $0.map(world) }, color: Self.sketchInk,
                                    width: 2.6))
            if !states.determined.isEmpty {
                groups.append(LineGroup(polylines: states.determined.map { $0.map(world) }, color: Self.definedGreen,
                                        width: 2.6))
            }
            // Punkte wie in Fusion 360: Enden und Ecken als kleine Punkte
            if sketch.showsPoints {
                let points = sketch.entityPoints
                if !points.isEmpty {
                    groups.append(LineGroup(polylines: [], color: Self.sketchInk, width: 0,
                                            dots: points.map(world), dotRadius: 2.6))
                }
            }
            let construction = sketch.showsConstruction
                ? sketch.constructionPolylines.flatMap { dashed($0, dash: 5 * perPoint) } : []
            if !construction.isEmpty {
                groups.append(LineGroup(polylines: construction.map { $0.map(world) }, color: Self.constructionGray,
                                        width: 1.8))
            }
            let selected = sketch.selectionPolylines
            let selectedPoints = sketch.selectionPoints
            if !selected.isEmpty || !selectedPoints.isEmpty {
                groups.append(LineGroup(polylines: selected.map { $0.map(world) }, color: Self.selectionOrange,
                                        width: 4.2, dots: selectedPoints.map(world), dotRadius: 6))
            }
            // Spline-Tangentengriffe (SketchSplineHandles.swift): automatische blau, eigene orange
            let tangentHandles = sketch.splineTangentHandleGeometry(unit: perPoint)
            if !tangentHandles.automatic.isEmpty {
                groups.append(LineGroup(polylines: tangentHandles.automatic.map { $0.map(world) }, color: Self.previewBlue,
                                        width: 1.4, dots: tangentHandles.automaticKnobs.map(world), dotRadius: 4))
            }
            if !tangentHandles.custom.isEmpty {
                groups.append(LineGroup(polylines: tangentHandles.custom.map { $0.map(world) }, color: Self.helperOrange,
                                        width: 1.8, dots: tangentHandles.customKnobs.map(world), dotRadius: 4.5))
            }
            let preview = sketch.previewPolylines
            if !preview.isEmpty {
                groups.append(LineGroup(polylines: preview.map { $0.map(world) }, color: Self.previewBlue, width: 2.6))
            }
            let dimensionLines = sketch.visibleDimensions.flatMap { dimensionGeometry($0, perPoint: perPoint).lines }
            if !dimensionLines.isEmpty {
                groups.append(LineGroup(polylines: dimensionLines.map { $0.map(world) }, color: Self.dimensionInk,
                                        width: 1.2))
            }
            // Hilfspunkte (Mitten gewählter Punkte) als kleine Dreiecke, gewählte orange
            if !sketch.marks.isEmpty {
                let size = 5 * perPoint
                let triangle = { (p: Point2) -> [Point2] in
                    [p + Point2(0, size), p + Point2(-0.87 * size, -0.5 * size), p + Point2(0.87 * size, -0.5 * size),
                     p + Point2(0, size)]
                }
                let selectedMarks = Set(sketch.selectedMarks)
                let plain = sketch.marks.indices.filter { !selectedMarks.contains($0) }.map { triangle(sketch.marks[$0]) }
                let chosen = sketch.selectedMarkPoints.map(triangle)
                groups.append(LineGroup(polylines: plain.map { $0.map(world) }, color: Self.previewBlue, width: 1.6))
                if !chosen.isEmpty {
                    groups.append(LineGroup(polylines: chosen.map { $0.map(world) }, color: Self.selectionOrange, width: 2.4))
                }
            }
            // Mittellinien gemerkter Punktpaare (Verbindung und Mittelsenkrechte), gestrichelt
            if !sketch.guideLines.isEmpty {
                let guides = sketch.guideLines.flatMap { $0.lines }.flatMap { dashed($0, dash: 4 * perPoint) }
                groups.append(LineGroup(polylines: guides.map { $0.map(world) }, color: Self.helperOrange, width: 1.3))
            }
            // Messen: gemessene Elemente orange, kürzeste Verbindung gestrichelt mit Endpunkten
            if sketch.tool == .measure, !sketch.measureRefs.isEmpty {
                let measured = sketch.measuredPolylines
                if !measured.isEmpty {
                    groups.append(LineGroup(polylines: measured.map { $0.map(world) }, color: Self.selectionOrange, width: 3.2))
                }
                let span = sketch.measurement.span
                let spanLines = span.count == 2 ? dashed(span, dash: 4 * perPoint) : []
                groups.append(LineGroup(polylines: spanLines.map { $0.map(world) }, color: Self.snapOrange, width: 1.5,
                                        dots: (sketch.measuredPoints + span).map(world), dotRadius: 3))
            }
            // Gleicher Winkel wie eine vorhandene Linie: diese leuchtet grün
            if !sketch.parallelLines.isEmpty {
                groups.append(LineGroup(polylines: sketch.parallelLines.map { $0.map(world) },
                                        color: SIMD3(0.08, 0.62, 0.2), width: 4))
            }
            // Gemerkte Punkte (Stift gedrückt) als orange Kreuze
            if !sketch.capturedPoints.isEmpty {
                let s = 5 * perPoint
                let crosses = sketch.capturedPoints.flatMap { p -> [[Point2]] in
                    [[p - Point2(s, s), p + Point2(s, s)], [p - Point2(s, -s), p + Point2(s, -s)]]
                }
                groups.append(LineGroup(polylines: crosses.map { $0.map(world) }, color: Self.selectionOrange, width: 2.4))
            }
            // Schwebender Stift: Fadenkreuz am (gefangenen) Punkt, damit man sieht, wo der Strich ansetzt
            if let hoverSnap = sketch.hoverSnap {
                let hover = hoverSnap.point
                // Kai: Größe wie gehabt, Strich so fein wie die rote/grüne Skizzenachse; orange, sobald ein Fangpunkt greift
                let arm = 15 * perPoint, gap = 3.5 * perPoint
                let cross: [[Point2]] = [
                    [hover + Point2(gap, 0), hover + Point2(arm, 0)], [hover - Point2(gap, 0), hover - Point2(arm, 0)],
                    [hover + Point2(0, gap), hover + Point2(0, arm)], [hover - Point2(0, gap), hover - Point2(0, arm)],
                ]
                let snapped = hoverSnap.kind != nil && hoverSnap.kind != .grid
                groups.append(LineGroup(polylines: cross.map { $0.map(world) }, color: snapped ? Self.snapOrange : Self.sketchInk,
                                        width: 1, dots: [world(hover)], dotRadius: 1.2))
            }
            // Vorschläge für die Mitte (Rechteck-, Kreis- und Linienmitten), dezent
            let suggestions = sketch.suggestionNodes
            if !suggestions.isEmpty {
                let markers = suggestions.flatMap { snapMarker($0.kind, at: $0.point, size: 4 * perPoint) }
                groups.append(LineGroup(polylines: markers.map { $0.map(world) }, color: Self.constructionGray, width: 1.2))
            }
            if !sketch.hoverNodes.isEmpty {
                groups.append(LineGroup(polylines: [], color: Self.previewBlue, width: 0,
                                        dots: sketch.hoverNodes.map(world), dotRadius: 3.5))
            }
            if let snap = sketch.currentSnap, let kind = snap.kind {
                let guides = snap.guides.flatMap { dashed([$0.0, $0.1], dash: 5 * perPoint) }
                if !guides.isEmpty {
                    groups.append(LineGroup(polylines: guides.map { $0.map(world) }, color: Self.snapOrange, width: 1.3))
                }
                groups.append(LineGroup(polylines: snapMarker(kind, at: snap.point, size: 6 * perPoint).map { $0.map(world) },
                                        color: Self.snapOrange, width: 2.2))
            }
        } else {
            sketchFillRevision = -1
            sketchFills = []
        }
        renderer.lineGroups = groups
        renderer.fills = fills
    }

    // MARK: Schweben im Modell

    private static let hoverBlue = SIMD3<Float>(0.2, 0.55, 1)

    /// Fläche, Kante oder Skizzenbereich unter dem schwebenden Stift: hellblau, bevor getippt wird. So sieht man
    /// vorher, ob das Antippen eine Fläche zum Extrudieren oder eine Kante zum Abrunden trifft.
    private func addHoverHighlight(to groups: inout [LineGroup], fills: inout [FillGroup]) {
        guard let hoverPick, let model else { return }
        switch hoverPick {
        case .edge(let edge):
            let lines = model.edgePolylines(edge).map { $0.map { SIMD3<Float>($0) } }
            groups.append(LineGroup(polylines: lines, color: Self.hoverBlue, width: 4.5))
        case .face(let face):
            fills.append(FillGroup(triangles: model.mesh.trianglePoints(of: face), color: SIMD4(0.2, 0.55, 1, 0.3)))
            let outline = model.edgePolylines(ofFace: face).map { $0.map { SIMD3<Float>($0) } }
            groups.append(LineGroup(polylines: outline, color: Self.hoverBlue, width: 2.2, onTop: false))
        case .region(let region):
            guard model.sketches.indices.contains(region.sketch),
                  model.sketches[region.sketch].fills.indices.contains(region.region) else { return }
            fills.append(FillGroup(triangles: model.sketches[region.sketch].fills[region.region],
                                   color: SIMD4(0.2, 0.55, 1, 0.35)))
        case .point(let point):
            groups.append(LineGroup(polylines: [], color: Self.snapOrange, width: 0, dots: [SIMD3<Float>(point)],
                                    dotRadius: 6, onTop: true))
        }
    }

    /// Bohrungen, angetippte Konstruktionspunkte und -kanten, Druckprüfung (Überhang rot, dünne Wände orange).
    private func addToolOverlays(to groups: inout [LineGroup], fills: inout [FillGroup]) {
        guard let workspace, let model else { return }
        switch workspace.tool {
        case .hole where !workspace.holePoints.isEmpty:
            groups.append(LineGroup(polylines: [], color: Self.snapOrange, width: 0,
                                    dots: workspace.holePoints.map { SIMD3<Float>($0.point) }, dotRadius: 5, onTop: true))
        case .construct:
            let points = workspace.constructPoints.map { SIMD3<Float>($0) }
            if !points.isEmpty {
                groups.append(LineGroup(polylines: points.count > 1 ? [points] : [], color: Self.snapOrange, width: 1.6,
                                        dots: points, dotRadius: 5, onTop: true))
            }
            if let edge = workspace.constructEdge {
                groups.append(LineGroup(polylines: [[SIMD3<Float>(edge.a), SIMD3<Float>(edge.b)]], color: Self.snapOrange,
                                        width: 4, onTop: true))
            }
            for plane in workspace.constructPlanes {
                groups.append(LineGroup(polylines: [], color: Self.snapOrange, width: 0, dots: [SIMD3<Float>(plane.origin)],
                                        dotRadius: 6, onTop: true))
            }
        case .printCheck:
            guard let report = workspace.printReport else { return }
            if !report.overhang.isEmpty {
                fills.append(FillGroup(triangles: report.overhang, color: SIMD4(0.92, 0.12, 0.1, 0.6)))
            }
            if !report.thin.isEmpty {
                fills.append(FillGroup(triangles: report.thin, color: SIMD4(1, 0.6, 0.05, 0.65)))
            }
            // Pfeil „oben beim Drucken“ von der Körpermitte aus (grün)
            if let body = workspace.printBody, let box = model.mesh.bounds(ofBody: body) {
                let center = (box.min + box.max) / 2
                let reach = max(simd_length(box.max - box.min) * 0.75, 10)
                let tip = center + simd_normalize(workspace.printUp) * reach
                groups.append(LineGroup(polylines: [[center, tip]], color: Self.definedGreen, width: 3, dots: [tip],
                                        dotRadius: 6, onTop: true))
            }
        case .sweep where !workspace.parts.sweepEdgeLines.isEmpty:
            // Pfad aus Körperkanten (Sweep entlang Kanten)
            groups.append(LineGroup(polylines: workspace.parts.sweepEdgeLines.map { $0.map { SIMD3<Float>($0) } },
                                    color: Self.snapOrange, width: 4, onTop: true))
        default:
            break
        }
    }

    /// Was ein Antippen an dieser Stelle treffen würde (gleiche Regeln wie handleTap): Kante vor Fläche,
    /// Skizzenbereich vor der Fläche, auf der er liegt. Nur ebene Flächen (extrudierbar) werden gezeigt.
    private func updateHoverPick(at location: CGPoint?) {
        var pick: HoverPick?
        if let location, let renderer, let model, let workspace, let sketch, !sketch.isActive, handleDrag == nil,
           ringDrag == nil, Self.hoverTools(workspace.tool),
           let ray = renderer.camera.ray(through: location, viewSize: bounds.size) {
            let hit = model.pick(origin: ray.origin, direction: ray.direction)
            if let edge = pickEdge(at: location, ray: ray, faceHit: hit)?.edge, workspace.tool == .select {
                if !model.selectedEdges.contains(edge) { pick = .edge(edge) }
            } else if let regionHit = model.pickRegion(origin: ray.origin, direction: ray.direction),
                      regionHit.t <= (hit.map { simd_dot($0.point - ray.origin, ray.direction) } ?? .infinity) + 0.05 {
                if !model.selectedRegions.contains(regionHit.ref) { pick = .region(regionHit.ref) }
            } else if let face = hit?.face, !model.selectedFaces.contains(face),
                      workspace.tool != .select || model.hasPreview || model.plane(of: face) != nil {
                pick = .face(face)
            }
        } else if let location, let renderer, let model, let workspace, let sketch, !sketch.isActive,
                  workspace.picksModelPoints, let ray = renderer.camera.ray(through: location, viewSize: bounds.size),
                  let hit = model.pick(origin: ray.origin, direction: ray.direction) {
            // Übersetzen, Bohrung, Konstruktion aus Punkten: Fangpunkt unter dem Stift zeigen
            pick = .point(model.snappedModelPoint(SIMD3<Double>(hit.point), tolerance: snapTolerance))
        }
        if pick != hoverPick {
            hoverPick = pick
            refresh()
        }
    }

    /// Werkzeuge, in denen Antippen Flächen bzw. Kanten wählt.
    private static func hoverTools(_ tool: ModelTool) -> Bool {
        switch tool {
        case .select, .shell, .offsetFace, .replaceFace, .wrap, .imprint: true
        default: false
        }
    }

    // MARK: Drehscheibe und Drehbögen

    /// Ring zum Drehen: Mitte, Radius und Achse (0 = X, 1 = Y, 2 = Z).
    private typealias Ring = (center: SIMD3<Double>, radius: Double, axis: Int)

    /// Ringe des Verschieben-Werkzeugs: beim Drehen nur der gegriffene (wie beim Ansetzen gemerkt), sonst die
    /// Drehscheibe am Boden (Z) und die Drehbögen um X und Y.
    private var currentRings: [Ring] {
        if let ringDrag { return [(ringDrag.center, ringDrag.radius, ringDrag.axis)] }
        guard let workspace else { return [] }
        var rings: [Ring] = workspace.rotationArcs.map { ($0.center, $0.radius, $0.axis) }
        if let ring = workspace.rotationRing { rings.append((ring.center, ring.radius, 2)) }
        return rings
    }

    private static let ringBlue = SIMD3<Float>(0.1, 0.36, 0.88)
    private static let ringColors: [SIMD3<Float>] = [SIMD3(0.88, 0.2, 0.2), SIMD3(0.2, 0.66, 0.28), ringBlue]

    /// Zwei Richtungen in der Ringebene (Winkel 0 entlang der ersten).
    private static func ringBasis(_ axis: Int) -> (SIMD3<Double>, SIMD3<Double>) {
        switch axis {
        case 0: ([0, 1, 0], [0, 0, 1])
        case 1: ([0, 0, 1], [1, 0, 0])
        default: ([1, 0, 0], [0, 1, 0])
        }
    }

    private static func axisVector(_ axis: Int) -> SIMD3<Double> {
        var vector = SIMD3<Double>(0, 0, 0)
        vector[min(max(axis, 0), 2)] = 1
        return vector
    }

    /// Punkt auf dem Ring zum Winkel (Bogenmaß).
    private static func ringPoint(_ ring: Ring, angle: Double, scale: Double = 1) -> SIMD3<Float> {
        let (e1, e2) = ringBasis(ring.axis)
        return SIMD3<Float>(ring.center + (e1 * cos(angle) + e2 * sin(angle)) * ring.radius * scale)
    }

    /// Drehscheibe wie in Bambu Studio / PrusaSlicer (blau, Z) und Drehbögen um X (rot) und Y (grün) wie bei
    /// Shapr3D: Striche alle 15°, Griffpunkt; beim Drehen der überstrichene Bogen orange.
    private func addRotationRing(to groups: inout [LineGroup]) {
        for ring in currentRings {
            let color = Self.ringColors[ring.axis]
            let segments = 120
            let circle = (0...segments).map { Self.ringPoint(ring, angle: Double($0) / Double(segments) * 2 * .pi) }
            let ticks = (0..<24).map { k -> [SIMD3<Float>] in
                let angle = Double(k) * .pi / 12
                let inner = k % 6 == 0 ? 0.86 : 0.93
                return [Self.ringPoint(ring, angle: angle, scale: inner), Self.ringPoint(ring, angle: angle)]
            }
            let start = ringDrag?.startAngle ?? -.pi / 2
            let turned = (ringDrag?.degrees ?? 0) * .pi / 180
            let knob = Self.ringPoint(ring, angle: start + turned)
            groups.append(LineGroup(polylines: [circle], color: color, width: ring.axis == 2 ? 3.2 : 2.4))
            groups.append(LineGroup(polylines: ring.axis == 2 || ringDrag != nil ? ticks : [], color: color, width: 1.4,
                                    dots: [knob], dotRadius: ring.axis == 2 ? 8 : 6.5))
            if abs(turned) > 1e-9 {
                let steps = max(2, Int(abs(turned) / (.pi / 90)))
                let arc = (0...steps).map { Self.ringPoint(ring, angle: start + turned * Double($0) / Double(steps)) }
                groups.append(LineGroup(polylines: [arc], color: Self.snapOrange, width: 4.5,
                                        dots: [Self.ringPoint(ring, angle: start)], dotRadius: 3.5))
            }
        }
    }

    /// Winkel (Bogenmaß) des Bildschirmpunkts in der Ringebene um die Ringmitte.
    private func ringAngle(at location: CGPoint, ring: Ring) -> Double? {
        guard let renderer,
              let hit = renderer.camera.intersect(screenPoint: location, viewSize: bounds.size,
                                                  planeOrigin: SIMD3<Float>(ring.center),
                                                  planeNormal: SIMD3<Float>(Self.axisVector(ring.axis))) else {
            return nil
        }
        let d = SIMD3<Double>(hit) - ring.center
        let (e1, e2) = Self.ringBasis(ring.axis)
        let x = simd_dot(d, e1), y = simd_dot(d, e2)
        guard x * x + y * y > 1e-18 else { return nil }
        return atan2(y, x)
    }

    /// Ring nah an der Berührung (höchstens 24 pt), der nächste zuerst.
    private func ringHit(at location: CGPoint) -> Ring? {
        guard let renderer else { return nil }
        var best: (ring: Ring, distance: CGFloat)?
        for ring in currentRings {
            let points = (0...72).compactMap {
                renderer.camera.project(Self.ringPoint(ring, angle: Double($0) / 72 * 2 * .pi), viewSize: bounds.size)
            }
            guard points.count > 1 else { continue }
            let distance = (1..<points.count).map { location.distance(toSegment: points[$0 - 1], points[$0]) }.min() ?? .infinity
            if distance <= 24, distance < (best?.distance ?? .infinity) { best = (ring, distance) }
        }
        return best?.ring
    }

    /// Ganze Grad, nahe einem Vielfachen von 15° rastet es dort ein.
    private static func ringDegrees(_ sweep: Double) -> Double {
        let degrees = sweep * 180 / .pi
        let detent = (degrees / 15).rounded() * 15
        return abs(degrees - detent) < 3 ? detent : degrees.rounded()
    }

    private func updateRingLabel() {
        guard let ringDrag, let renderer,
              let point = renderer.camera.project(Self.ringPoint((ringDrag.center, ringDrag.radius, ringDrag.axis),
                                                                 angle: ringDrag.startAngle + ringDrag.degrees * .pi / 180,
                                                                 scale: 1.18),
                                                  viewSize: bounds.size) else {
            ringLabel.isHidden = true
            return
        }
        ringLabel.text = "\(["X", "Y", "Z"][ringDrag.axis]) \(Int(ringDrag.degrees))°"
        ringLabel.backgroundColor = UIColor(red: CGFloat(Self.ringColors[ringDrag.axis].x),
                                            green: CGFloat(Self.ringColors[ringDrag.axis].y),
                                            blue: CGFloat(Self.ringColors[ringDrag.axis].z), alpha: 1)
        ringLabel.sizeToFit()
        ringLabel.center = CGPoint(x: point.x, y: point.y - 22)
        ringLabel.isHidden = false
    }

    // MARK: Ebenengriffe

    /// Quadrate in den Ebenen XY, YZ und XZ an der Mitte der Auswahl (Shapr3D): Ziehen verschiebt in der Ebene.
    /// normal = Achse senkrecht zur Ebene.
    private var planeHandles: [(normal: Int, corners: [SIMD3<Double>])] {
        guard let workspace, workspace.tool == .move, !(sketch?.isActive ?? false),
              let center = workspace.moveCenter else { return [] }
        let size = workspace.handleSize * 0.22
        let offset = workspace.handleSize * 0.18
        return (0..<3).map { normal in
            let (e1, e2) = Self.ringBasis(normal)
            let base = center + (e1 + e2) * offset
            return (normal, [base, base + e1 * size, base + (e1 + e2) * size, base + e2 * size])
        }
    }

    private func addPlaneHandles(to fills: inout [FillGroup], groups: inout [LineGroup]) {
        for handle in planeHandles {
            let corners = handle.corners.map { SIMD3<Float>($0) }
            let color = Self.ringColors[handle.normal]
            let active = planeDrag?.normal == handle.normal
            fills.append(FillGroup(triangles: [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]],
                                   color: SIMD4(color.x, color.y, color.z, active ? 0.75 : 0.4)))
            groups.append(LineGroup(polylines: [corners + [corners[0]]], color: color, width: 1.6))
        }
    }

    /// Ebenengriff unter der Berührung.
    private func planeHandleHit(at location: CGPoint) -> Int? {
        guard let renderer else { return nil }
        for handle in planeHandles {
            let projected = handle.corners.compactMap { renderer.camera.project(SIMD3<Float>($0), viewSize: bounds.size) }
            guard projected.count == 4 else { continue }
            let polygon = projected.map { Point2(Double($0.x), Double($0.y)) }
            let center = polygon.reduce(.zero, +) / 4
            // Etwas größer als gezeichnet, damit der Finger trifft
            let grown = polygon.map { center + ($0 - center) * 1.35 }
            if polygonContains(grown, Point2(Double(location.x), Double(location.y))) { return handle.normal }
        }
        return nil
    }

    /// Punkt der Ebene (durch die Mitte der Auswahl, senkrecht zu normal) unter dem Bildschirmpunkt.
    private func planePoint(at location: CGPoint, normal: Int, origin: SIMD3<Double>) -> SIMD3<Double>? {
        guard let renderer,
              let hit = renderer.camera.intersect(screenPoint: location, viewSize: bounds.size,
                                                  planeOrigin: SIMD3<Float>(origin),
                                                  planeNormal: SIMD3<Float>(Self.axisVector(normal))) else { return nil }
        return SIMD3<Double>(hit)
    }

    /// Konstruktionsachsen (gestrichelt) und -punkte; Ebenen zeichnet refreshPlanes.
    private func addConstructionItems(to groups: inout [LineGroup], perPoint: Double, sketching: Bool) {
        guard let model else { return }
        let reach = Double(planeHalfSize) * 1.6
        var axes: [[SIMD3<Float>]] = []
        var points: [SIMD3<Float>] = []
        for item in model.constructions where !item.isHidden {
            switch item.kind {
            case .axis:
                let a = SIMD3<Float>(item.origin - item.direction * reach)
                let b = SIMD3<Float>(item.origin + item.direction * reach)
                axes += dashed([a, b], dash: Float(6 * perPoint))
            case .point:
                points.append(SIMD3<Float>(item.origin))
            case .plane:
                break
            }
        }
        if !axes.isEmpty || !points.isEmpty {
            groups.append(LineGroup(polylines: axes, color: Self.helperOrange, width: 1.6, dots: points,
                                    dotRadius: 4.5, onTop: !sketching))
        }
        // Vorschau im Konstruieren-Werkzeug: was „Fertig“ erstellt (blau)
        guard let workspace, !sketching else { return }
        if let axis = workspace.pendingAxis, simd_length(axis.direction) > 1e-9 {
            let direction = simd_normalize(axis.direction)
            let a = SIMD3<Float>(axis.origin - direction * reach)
            let b = SIMD3<Float>(axis.origin + direction * reach)
            groups.append(LineGroup(polylines: dashed([a, b], dash: Float(6 * perPoint)), color: Self.previewBlue,
                                    width: 2.2, dots: [SIMD3<Float>(axis.origin)], dotRadius: 4.5, onTop: true))
        }
        if workspace.tool == .construct(.point) {
            groups.append(LineGroup(polylines: [], color: Self.previewBlue, width: 1,
                                    dots: [SIMD3<Float>(workspace.constructPoint)], dotRadius: 6, onTop: true))
        }
    }

    /// Gestrichelter Linienzug (lokal) als einzelne Striche entlang der Länge.
    private func dashed(_ points: [Point2], dash: Double) -> [[Point2]] {
        guard points.count >= 2, dash > 0 else { return [] }
        var result: [[Point2]] = []
        var current: [Point2] = [points[0]]
        var drawing = true
        var left = dash
        for i in 0..<(points.count - 1) {
            var a = points[i]
            let b = points[i + 1]
            var length = simd_distance(a, b)
            while length > 1e-12 {
                let step = min(left, length)
                let p = a + (b - a) / length * step
                if drawing { current.append(p) }
                left -= step
                length -= step
                a = p
                if left <= 1e-12 {
                    if drawing, current.count >= 2 { result.append(current) }
                    drawing.toggle()
                    current = drawing ? [a] : []
                    left = dash
                    if result.count > 2000 { return result }
                }
            }
        }
        if drawing, current.count >= 2 { result.append(current) }
        return result
    }

    private func dashed(_ points: [SIMD3<Float>], dash: Float) -> [[SIMD3<Float>]] {
        guard points.count >= 2, dash > 0 else { return [] }
        var result: [[SIMD3<Float>]] = []
        var drawing = true
        var left = dash
        var current: [SIMD3<Float>] = [points[0]]
        for i in 0..<(points.count - 1) {
            var a = points[i]
            let b = points[i + 1]
            var length = simd_distance(a, b)
            while length > 1e-9 {
                let step = min(left, length)
                let p = a + (b - a) / length * step
                if drawing { current.append(p) }
                left -= step
                length -= step
                a = p
                if left <= 1e-9 {
                    if drawing, current.count >= 2 { result.append(current) }
                    drawing.toggle()
                    current = drawing ? [a] : []
                    left = dash
                    if result.count > 2000 { return result }
                }
            }
        }
        if drawing, current.count >= 2 { result.append(current) }
        return result
    }

    /// Maßlinie mit Hilfslinien und Pfeilen (lokal) und Lage des Maßfelds.
    private func dimensionGeometry(_ dimension: SketchDimension, perPoint: Double)
        -> (lines: [[Point2]], label: Point2, onLine: Bool) {
        let arrow = 8 * perPoint, wing = 3 * perPoint
        func arrowHead(at tip: Point2, from tail: Point2) -> [Point2] {
            let t = simd_normalize(tip - tail), n = Point2(-t.y, t.x)
            return [tip - t * arrow + n * wing, tip, tip - t * arrow - n * wing]
        }
        guard dimension.span.count == 2, simd_distance(dimension.span[0], dimension.span[1]) > 1e-9 else {
            return ([], dimension.position + dimension.direction * 10 * perPoint, false)
        }
        let a = dimension.span[0], b = dimension.span[1]
        switch dimension.kind {
        case .width, .height, .length, .distance:
            let n = dimension.direction
            let offset = 28 * perPoint
            let a2 = a + n * offset, b2 = b + n * offset
            let lines = [[a + n * 3 * perPoint, a2 + n * 5 * perPoint], [b + n * 3 * perPoint, b2 + n * 5 * perPoint],
                         [a2, b2], arrowHead(at: a2, from: b2), arrowHead(at: b2, from: a2)]
            return (lines, (a2 + b2) / 2, true)
        case .diameter:
            // Außen: Führungslinie von außen mit Pfeil auf den Rand, gegenüber ein zweiter Pfeil von außen
            let n = simd_normalize(b - a), leader = 24 * perPoint
            let outB = b + n * leader, outA = a - n * arrow * 1.6
            return ([[b, outB], arrowHead(at: b, from: outB), [a, outA], arrowHead(at: a, from: outA)],
                    outB, false)
        case .radius:
            return ([[a, b], arrowHead(at: b, from: a)], b + dimension.direction * 6 * perPoint, false)
        case .angle:
            // Winkel beim Zeichnen: auf der Winkelhalbierenden, mindestens 70 pt vom Linienanfang entfernt
            // (bei kurzen Linien lag das Etikett sonst auf der Linie)
            let bisector = dimension.position - a
            guard simd_length(bisector) > 1e-9 else { return ([], dimension.position, true) }
            let radius = max(simd_length(bisector), 70 * perPoint)
            var lines: [[Point2]] = []
            if abs(dimension.sweep) > 1e-6 {
                let start = atan2(dimension.reference.y, dimension.reference.x)
                let u = Point2(cos(start), sin(start))
                let v = Point2(cos(start + dimension.sweep), sin(start + dimension.sweep))
                if abs(abs(dimension.sweep) - .pi / 2) < 0.05 * .pi / 180 {
                    // Rechter Winkel: kleines Quadrat im Scheitel (Kai)
                    let size = 12 * perPoint
                    lines.append([a + u * size, a + (u + v) * size, a + v * size])
                } else {
                    // Winkelbogen zwischen den Schenkeln
                    let arcRadius = 30 * perPoint
                    let steps = max(6, Int(abs(dimension.sweep) / (.pi / 36)))
                    lines.append((0...steps).map { k in
                        let angle = start + dimension.sweep * Double(k) / Double(steps)
                        return a + Point2(cos(angle), sin(angle)) * arcRadius
                    })
                }
            }
            return (lines, a + simd_normalize(bisector) * radius, true)
        }
    }

    // MARK: Maße am Element

    /// Maße des Elements beim Aufziehen (nur Anzeige) und danach als Eingabefelder direkt am Element.
    private func updateDimensionFields() {
        guard let renderer, let sketch else { return }
        let dimensions = sketch.isActive && !sketch.isChoosingPlane ? sketch.visibleDimensions : []
        let plane = sketch.plane
        let perPoint = Double(renderer.camera.worldUnitsPerPoint(viewHeight: Float(bounds.height)))
        var shown = Set<String>()
        for dimension in dimensions {
            let field = dimensionFields[dimension.id] ?? makeDimensionField(dimension.id)
            let geometry = dimensionGeometry(dimension, perPoint: perPoint)
            let anchorWorld = SIMD3<Float>(plane.world(geometry.label))
            let tipWorld = SIMD3<Float>(plane.world(geometry.label + dimension.direction * perPoint * 10))
            guard let anchor = renderer.camera.project(anchorWorld, viewSize: bounds.size),
                  let tip = renderer.camera.project(tipWorld, viewSize: bounds.size) else { continue }
            shown.insert(dimension.id)
            field.allowsEditing = dimension.isEditable
            field.isFine = dimension.id.hasPrefix("mark-")
            field.expression = sketch.expression(of: dimension)
            // Mit einer Variable verknüpft: ƒ vor dem Wert (wie Fusion 360 „fx“)
            field.prefix = field.expression == nil ? dimension.prefix : "ƒ " + dimension.prefix
            if !field.isFirstResponder {
                if dimension.kind == .angle {
                    // Winkel nur in ganzen Grad (Kai)
                    let degrees = Int(dimension.value.rounded())
                    field.text = dimension.isEditable ? "\(degrees)" : "\(degrees)°"
                } else {
                    // Länge in der Projekteinheit (mm, cm oder Zoll)
                    field.text = LengthUnit.current.number(dimension.value)
                }
                // Kai: 15°-Schritte (15, 30, 45 …) rot zeigen; einrasten erst nach kurzem Verweilen
                let isStepAngle = dimension.id == "live-angle" && dimension.value.isFinite
                    && abs(dimension.value) < 1e6 && Int(dimension.value.rounded()) % 15 == 0
                field.textColor = isStepAngle || (dimension.id == "live-angle" && sketch.angleCandidate)
                    ? .systemRed : .black
            }
            field.lockState = dimension.lockState
            let id = dimension.id
            field.onLockTap = { [weak self] in
                self?.sketch?.toggleDimensionLock(id: id)
                self?.refresh()
            }
            field.sizeToFit()
            var dx = tip.x - anchor.x, dy = tip.y - anchor.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1e-6)
            dx /= length
            dy /= length
            // Auf der Maßlinie mittig, sonst neben das Element, Abstand passend zur Größe des Felds
            let extent = abs(dx) * field.bounds.width / 2 + abs(dy) * field.bounds.height / 2
            var distance = geometry.onLine ? 0 : extent
            // Nie auf der gemessenen Linie: beim Zeichnen lag das Feld sonst teils über der Linie (Kai sah die
            // Länge nicht). Abstand Feldmitte–Linie mindestens halbe Feldgröße plus Luft.
            if geometry.onLine, dimension.span.count == 2,
               let a = renderer.camera.project(SIMD3<Float>(plane.world(dimension.span[0])), viewSize: bounds.size),
               let b = renderer.camera.project(SIMD3<Float>(plane.world(dimension.span[1])), viewSize: bounds.size) {
                let gap = anchor.distance(toSegment: a, b)
                distance = max(0, extent + 6 - gap)
            }
            field.center = CGPoint(x: anchor.x + dx * distance, y: anchor.y + dy * distance)
            field.isHidden = false
        }
        for (id, field) in dimensionFields where !shown.contains(id) {
            if field.isFirstResponder {
                field.appliesOnEnd = false
                field.resignFirstResponder()
            }
            field.isHidden = true
        }
        placeKeypad()
    }

    /// Ziffernfeld neben das bearbeitete Maß: darunter, sonst darüber, immer ganz im Bild.
    private func placeKeypad() {
        guard let field = dimensionFields.values.first(where: { $0.isFirstResponder && !$0.isHidden }) else {
            keypad.isHidden = true
            return
        }
        let size = keypad.sizeThatFits(.zero)
        let gap: CGFloat = 12
        var y = field.frame.maxY + gap
        if y + size.height > bounds.height - safeAreaInsets.bottom - 90 {
            y = field.frame.minY - gap - size.height
        }
        let margin: CGFloat = 8
        let x = min(max(field.center.x - size.width / 2, margin), max(bounds.width - size.width - margin, margin))
        y = min(max(y, safeAreaInsets.top + margin), max(bounds.height - size.height - margin, margin))
        keypad.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        bringSubviewToFront(keypad)
        keypad.isHidden = false
    }

    private func keypadPressed(_ key: DimensionKeypad.Key) {
        guard let field = dimensionFields.values.first(where: { $0.isFirstResponder }) else { return }
        switch key {
        case .text(let text):
            field.insertText(text)
        case .delete:
            field.deleteBackward()
        case .clear:
            field.text = ""
        case .negate:
            let text = (field.text ?? "").trimmingCharacters(in: .whitespaces)
            field.text = text.hasPrefix("-") || text.hasPrefix("−") ? String(text.dropFirst()) : "-" + text
        case .lock:
            field.onLockTap?()
        case .keyboard:
            // Umschalten zwischen Rechner-Tastatur und Bildschirmtastatur (für Variablennamen und Formeln)
            if field.inputView == nil {
                field.inputView = UIView(frame: .zero)
                field.keyboardType = .decimalPad
            } else {
                field.inputView = nil
                field.keyboardType = .asciiCapable
            }
            field.reloadInputViews()
        case .createVariable:
            field.appliesOnEnd = false
            field.resignFirstResponder()
            workspace?.showsVariables = true
        case .cancel:
            field.appliesOnEnd = false
            field.resignFirstResponder()
        case .done:
            field.resignFirstResponder()
        }
        field.sizeToFit()
        keypad.lockState = field.lockState
    }

    private func makeDimensionField(_ id: String) -> DimensionField {
        let field = DimensionField(dimensionID: id)
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        dimensionFields[id] = field
        return field
    }

    /// Eingabe übernehmen: Zahl oder Formel (z. B. „2 × wand + 5“, „1,5 cm“); verwendet sie Projektvariablen,
    /// bleibt das Maß mit ihnen verknüpft.
    private func apply(_ field: DimensionField) {
        let text = (field.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let sketch else { return }
        let values = model?.variableValues ?? [:]
        do {
            // Winkel in Grad, Längen in der Projekteinheit
            let isAngle = sketch.visibleDimensions.first { $0.id == field.dimensionID }?.kind == .angle
            let value = try isAngle ? Formula.evaluate(text, variables: values)
                : Formula.evaluateLength(text, variables: values)
            guard value > 0 else {
                sketch.notice = "Das Maß muss größer als 0 sein."
                return
            }
            let linked = Formula.names(in: text).contains { values[$0] != nil } ? text : nil
            sketch.setDimension(id: field.dimensionID, to: value, expression: linked)
        } catch {
            sketch.notice = "Formel „\(text)“: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: Ebenenscheiben

    /// Die drei Standardebenen durch den Ursprung (Normale, u, v).
    private static let basePlanes: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
        ([0, 0, 1], [1, 0, 0], [0, 1, 0]),
        ([0, 1, 0], [1, 0, 0], [0, 0, 1]),
        ([1, 0, 0], [0, 1, 0], [0, 0, 1]),
    ]

    /// Halbe Kantenlänge der Scheiben, passend zur Modellgröße.
    private var planeHalfSize: Float {
        guard let bounds = model?.mesh.bounds else { return 30 }
        let extent = max(simd_reduce_max(simd_abs(bounds.min)), simd_reduce_max(simd_abs(bounds.max)))
        return max(30, extent * 1.1)
    }

    /// Welche Seite der Standardebene index die Kamera sieht.
    private func facingSide(ofBasePlane index: Int) -> BasePlane {
        let eye = renderer?.camera.position ?? SIMD3<Float>(1, -1, 1)
        switch index {
        case 0: return eye.z >= 0 ? .top : .bottom
        case 1: return eye.y <= 0 ? .front : .back
        default: return eye.x >= 0 ? .right : .left
        }
    }

    /// Antippbare Felder der Standardebenen bei der Ebenenwahl, wie bei Shapr3D klein und neben dem Ursprung:
    /// XY vorn rechts, XZ rechts oben, YZ vorn oben (Mittelpunkt, Richtungen, halbe Kantenlänge).
    /// Die Größe richtet sich nach dem Bildschirm (etwa 80 Punkte), damit die Felder bei jedem Zoom gut zu treffen sind.
    private var basePlaneSquares: [(index: Int, center: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, half: Float)] {
        let perPoint = renderer?.camera.worldUnitsPerPoint(at: .zero, viewHeight: Float(max(bounds.height, 1))) ?? 0.3
        let half = 40 * perPoint
        let offset = half * 1.8
        let sides: [SIMD2<Float>] = [[1, -1], [1, 1], [-1, 1]]
        return Self.basePlanes.indices.map { index -> (index: Int, center: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, half: Float) in
            let plane = Self.basePlanes[index]
            let center = plane.u * sides[index].x * offset + plane.v * sides[index].y * offset
            return (index, center, plane.u, plane.v, half)
        }
    }

    /// Konstruktionsebenen zum Antippen; die Standardebenen zeichnet updateLines als Felder.
    private func refreshPlanes() {
        guard let renderer, let sketch else { return }
        let half = planeHalfSize
        var graphics: [PlaneGraphic] = []
        var labels: [(text: String, position: SIMD3<Float>)] = []
        // Konstruktionsebenen (beim Skizzieren ausgeblendet, bei der Ebenenwahl antippbar)
        if !sketch.isActive || sketch.isChoosingPlane, let model {
            for item in model.constructions where item.kind == .plane && !item.isHidden {
                let frame = item.sketchPlane
                graphics.append(PlaneGraphic(center: SIMD3<Float>(item.origin), u: SIMD3<Float>(frame.u),
                                             v: SIMD3<Float>(frame.v), halfSize: half * 0.6,
                                             color: SIMD3(0.95, 0.6, 0.2)))
                labels.append((item.name, SIMD3<Float>(item.origin + (frame.u + frame.v) * Double(half) * 0.5)))
            }
        }
        // Vorschau der Konstruktionsebene, die „Fertig“ erstellt
        if !sketch.isActive, let pending = workspace?.pendingPlane {
            let frame = SketchPlane(point: pending.origin, normal: pending.normal, isOnFace: false)
            graphics.append(PlaneGraphic(center: SIMD3<Float>(pending.origin), u: SIMD3<Float>(frame.u),
                                         v: SIMD3<Float>(frame.v), halfSize: half * 0.6,
                                         color: SIMD3(0.2, 0.5, 0.98)))
            labels.append(("Neue Ebene", SIMD3<Float>(pending.origin + (frame.u + frame.v) * Double(half) * 0.5)))
        }
        // Beim Skizzieren keine Scheibe: die ganze Ebene ist Zeichenfläche
        renderer.planes = graphics

        while planeLabels.count < labels.count {
            let label = PaddedLabel()
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            addSubview(label)
            planeLabels.append(label)
        }
        for (index, label) in planeLabels.enumerated() {
            guard index < labels.count,
                  let point = renderer.camera.project(labels[index].position, viewSize: bounds.size) else {
                label.isHidden = true
                continue
            }
            label.text = labels[index].text
            label.sizeToFit()
            label.center = point
            label.isHidden = false
        }
    }

    /// Getroffene Standardebene (vorderstes Feld unter dem Finger) und Abstand entlang des Sehstrahls.
    /// Die Trefferfläche ist etwas größer als das Feld, damit es sich mit dem Finger leicht treffen lässt.
    private func basePlaneHit(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> (side: BasePlane, t: Float)? {
        var best: (side: BasePlane, t: Float)?
        for square in basePlaneSquares {
            let normal = Self.basePlanes[square.index].normal
            let denominator = simd_dot(ray.direction, normal)
            guard abs(denominator) > 1e-6 else { continue }
            let t = -simd_dot(ray.origin, normal) / denominator
            guard t > 0, t < (best?.t ?? .infinity) else { continue }
            let d = ray.origin + t * ray.direction - square.center
            let reach = square.half * 1.25
            guard abs(simd_dot(d, square.u)) <= reach, abs(simd_dot(d, square.v)) <= reach else { continue }
            best = (facingSide(ofBasePlane: square.index), t)
        }
        return best
    }

    /// Konstruktionsebene unter dem Sehstrahl (für die Skizzenebenen-Wahl).
    private func constructionPlaneHit(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> (plane: SketchPlane, t: Float)? {
        guard let model else { return nil }
        let half = planeHalfSize * 0.6
        var best: (plane: SketchPlane, t: Float)?
        for item in model.constructions where item.kind == .plane && !item.isHidden {
            let frame = item.sketchPlane
            let normal = SIMD3<Float>(frame.normal)
            let denominator = simd_dot(ray.direction, normal)
            guard abs(denominator) > 1e-6 else { continue }
            let t = simd_dot(SIMD3<Float>(item.origin) - ray.origin, normal) / denominator
            guard t > 0, t < (best?.t ?? .infinity) else { continue }
            let d = ray.origin + t * ray.direction - SIMD3<Float>(item.origin)
            guard abs(simd_dot(d, SIMD3<Float>(frame.u))) <= half, abs(simd_dot(d, SIMD3<Float>(frame.v))) <= half else {
                continue
            }
            best = (frame, t)
        }
        return best
    }

    // MARK: Bilder und Kurzzeichen

    /// Bilder (Canvas) als Texturen an den Renderer geben.
    private func updateCanvases() {
        guard let renderer, let model, let device else { return }
        var graphics: [CanvasGraphic] = []
        for canvas in model.canvases where !canvas.isHidden {
            var texture = canvasTextures[canvas.fileName]
            if texture == nil, let url = model.canvasURL(canvas) {
                texture = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [
                    .SRGB: true, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                ])
                canvasTextures[canvas.fileName] = texture
            }
            guard let texture else { continue }
            graphics.append(CanvasGraphic(texture: texture, corners: canvas.corners.map { SIMD3<Float>($0) },
                                          opacity: Float(canvas.opacity)))
        }
        renderer.canvases = graphics
    }

    /// Kurzzeichen der Einschränkungen neben den Elementen.
    private func updateBadges() {
        guard let renderer, let sketch else { return }
        let badges = sketch.isActive && !sketch.isChoosingPlane && sketch.showsConstraintBadges ? sketch.constraintBadges : []
        while badgeLabels.count < badges.count {
            let label = PaddedLabel()
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = UIColor(white: 0.25, alpha: 1)
            label.backgroundColor = UIColor(white: 1, alpha: 0.9)
            label.layer.cornerRadius = 7
            label.layer.borderWidth = 1
            label.layer.borderColor = UIColor(white: 0.7, alpha: 1).cgColor
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            addSubview(label)
            badgeLabels.append(label)
        }
        let plane = sketch.plane
        for (index, label) in badgeLabels.enumerated() {
            guard index < badges.count,
                  let point = renderer.camera.project(SIMD3<Float>(plane.world(badges[index].position)),
                                                      viewSize: bounds.size) else {
                label.isHidden = true
                continue
            }
            label.text = badges[index].text
            label.sizeToFit()
            label.center = CGPoint(x: point.x + 14, y: point.y - 14)
            label.isHidden = false
        }
    }

    /// Maß-Etikett an der Pfeilspitze des ersten Ziehpfeils.
    private func updateValueLabel(_ handles: [DragHandle]) {
        guard let renderer, let handle = handles.first(where: { $0.value != 0 }) ?? handles.first,
              !handle.isMove || handles.count == 3 else {
            valueLabel.isHidden = true
            return
        }
        let shown = handleDrag?.handle.kind ?? handle.kind
        let active = handles.first { $0.kind == shown } ?? handle
        let base = arrowBase(active)
        let length = Renderer.handleLength * active.scale * renderer.camera.worldUnitsPerPoint(at: base, viewHeight: Float(bounds.height))
        guard let foot = renderer.camera.project(base, viewSize: bounds.size),
              let tip = renderer.camera.project(base + active.pointing * length, viewSize: bounds.size) else {
            valueLabel.isHidden = true
            return
        }
        valueLabel.text = LengthUnit.current.format(active.value)
        valueLabel.sizeToFit()
        // Wie in Fusion 360: Wertfeld neben dem Pfeil (seitlich auf Höhe der Spitze), nicht auf der Spitze
        var dx = tip.x - foot.x, dy = tip.y - foot.y
        let screenLength = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        dx /= screenLength
        dy /= screenLength
        // Seite rechts vom Pfeil auf dem Bildschirm (nach oben zeigend: rechts daneben)
        let side = CGPoint(x: -dy, y: dx)
        let sideways = abs(side.x) * valueLabel.bounds.width / 2 + abs(side.y) * valueLabel.bounds.height / 2 + 14
        let along = CGPoint(x: foot.x + (tip.x - foot.x) * 0.75, y: foot.y + (tip.y - foot.y) * 0.75)
        valueLabel.center = CGPoint(x: along.x + (side.x >= 0 ? side.x : -side.x) * sideways,
                                    y: along.y + (side.x >= 0 ? side.y : -side.y) * sideways)
        valueLabel.isHidden = false
    }

    // MARK: Ziehpfeile

    private func handleHit(at point: CGPoint) -> DragHandle? {
        guard let renderer, let workspace else { return nil }
        var best: (distance: CGFloat, handle: DragHandle)?
        for handle in workspace.handles {
            let base = arrowBase(handle)
            let length = Renderer.handleLength * handle.scale * renderer.camera.worldUnitsPerPoint(at: base, viewHeight: Float(bounds.height))
            guard let a = renderer.camera.project(base, viewSize: bounds.size),
                  let b = renderer.camera.project(base + handle.pointing * length, viewSize: bounds.size) else {
                continue
            }
            let distance = point.distance(toSegment: a, b)
            if distance <= 30, distance < (best?.distance ?? .infinity) {
                best = (distance, handle)
            }
        }
        return best?.handle
    }

    /// Fuß des gezeichneten Pfeils: wie in Fusion 360 direkt auf dem Profil bzw. der Fläche (Mitte); der
    /// Kantenpfeil setzt knapp neben der Kante an, Verschiebe-Pfeile am Mittelpunkt.
    private func arrowBase(_ handle: DragHandle) -> SIMD3<Float> {
        guard handle.kind == .edge || handle.kind == .offset, let renderer else { return handle.base }
        let gap = 6 * renderer.camera.worldUnitsPerPoint(at: handle.base, viewHeight: Float(bounds.height))
        return handle.base + handle.pointing * gap
    }

    /// Parameter entlang der Pfeilachse: nächster Punkt zwischen Sehstrahl und Achse.
    private func axisParameter(at point: CGPoint, handle: DragHandle) -> Float? {
        guard let renderer, let ray = renderer.camera.ray(through: point, viewSize: bounds.size) else { return nil }
        let d = handle.direction, r = ray.direction
        let w = handle.axisOrigin - ray.origin
        let b = simd_dot(d, r)
        let denominator = 1 - b * b
        // Zeigt der Pfeil fast genau zur Kamera, ist die Lage entlang der Achse nicht bestimmbar.
        guard denominator > 1e-4 else { return nil }
        return (b * simd_dot(r, w) - simd_dot(d, w)) / denominator
    }

    /// Rastweite beim Ziehen, passend zum Zoom.
    private func dragStep(at point: SIMD3<Float>) -> Double {
        guard let renderer else { return 0.5 }
        let perPoint = Double(renderer.camera.worldUnitsPerPoint(at: point, viewHeight: Float(bounds.height)))
        return [0.001, 0.01, 0.1, 0.5, 1, 5, 10].first { $0 >= perPoint * 3 } ?? 10
    }

    // MARK: Skizze

    // MARK: Rahmenauswahl

    /// Ab dieser Größe (Punkte) ist ein Zug ein Rahmen, darunter ein Tippen.
    private static let boxMinimum: CGFloat = 8

    /// Stift immer, Finger nur mit eingeschalteter „Rahmenauswahl“ (Modellmodus, Auswahl bzw. Körperwerkzeuge).
    private func acceptsForBox(_ touch: UITouch) -> Bool {
        guard let workspace, workspace.acceptsBoxSelection else { return false }
        return touch.type == .pencil || (workspace.boxSelects && touch.type == .direct)
    }

    /// Skizze, Werkzeug „Auswählen“: Stift (bzw. zeichnender Finger) setzt ins Leere – Rahmen bzw. Lasso
    /// wählt Skizzenelemente (auf einem Element bleibt es beim Ziehen).
    private func acceptsForSketchBox(_ touch: UITouch) -> Bool {
        guard acceptsForSketch(touch), let sketch, sketch.tool == .select, sketch.pendingAction == nil,
              let point = sketchPoint(for: touch) else { return false }
        return sketch.pick(at: point, tolerance: snapTolerance) == nil
            && !sketch.hitsSplineHandle(at: point, tolerance: snapTolerance)  // Spline-Tangentengriffe
    }

    /// Rahmen bzw. Lasso fertig: Skizzenelemente oder Körper wählen.
    private func finishBox(at end: CGPoint) {
        let lasso = LassoSelection.isOn && lassoPath.count >= 3
        let rect = lasso ? RegionSelection.bounds(lassoPath + [end]) : boxRect(to: end)
        // Kurzer Zug bleibt ein Tippen (im Modell übernimmt das die Tipp-Geste)
        guard max(rect.width, rect.height) >= Self.boxMinimum else {
            if boxInSketch, let sketch, let point = sketchPoint(at: boxStart) {
                sketch.began(at: point, tolerance: snapTolerance)
                sketch.ended(at: point, tolerance: snapTolerance)
            }
            return
        }
        let crossing = !lasso && end.x < boxStart.x
        if boxInSketch {
            guard let renderer, let sketch else { return }
            let area: RegionSelection.Area = lasso ? .lasso(lassoPath + [end]) : crossing ? .crossing(rect) : .window(rect)
            let refs = RegionSelection.sketchRefs(in: area, sketch: sketch, camera: renderer.camera, viewSize: bounds.size)
            sketch.addToSelection(refs)
            if refs.isEmpty {
                sketch.notice = lasso ? "Kein Element ganz im Lasso."
                    : crossing ? "Kein Element berührt den Rahmen."
                    : "Kein Element ganz im Rahmen. Von rechts nach links ziehen wählt auch angeschnittene."
            }
        } else if lasso {
            guard let renderer, let model else { return }
            let found = RegionSelection.bodies(inLasso: lassoPath + [end], mesh: model.mesh, camera: renderer.camera,
                                               viewSize: bounds.size)
            workspace?.boxSelected(found, crossing: false)
            if found.isEmpty { model.message = "Kein Körper ganz im Lasso." }
        } else {
            workspace?.boxSelected(bodies(in: rect, crossing: crossing), crossing: crossing)
        }
    }

    private func boxRect(to point: CGPoint) -> CGRect {
        CGRect(x: min(boxStart.x, point.x), y: min(boxStart.y, point.y),
               width: abs(point.x - boxStart.x), height: abs(point.y - boxStart.y))
    }

    /// Körper im Rahmen wie in Fusion 360: von links nach rechts nur ganz umschlossene,
    /// von rechts nach links (crossing) auch angeschnittene.
    private func bodies(in rect: CGRect, crossing: Bool) -> [Int] {
        guard let renderer, let model else { return [] }
        let mesh = model.mesh
        var vertexBody = [Int](repeating: -1, count: mesh.vertices.count)
        for t in 0..<min(mesh.triangleCount, mesh.triangleFaces.count) {
            let body = mesh.triangleFaces[t].body
            for k in 0..<3 {
                let index = Int(mesh.indices[t * 3 + k])
                if index < vertexBody.count { vertexBody[index] = body }
            }
        }
        var allInside: [Int: Bool] = [:]
        var touched = Set<Int>()
        for (index, vertex) in mesh.vertices.enumerated() {
            let body = vertexBody[index]
            guard body >= 0 else { continue }
            let isInside = renderer.camera.project(vertex.position, viewSize: bounds.size).map { rect.contains($0) } ?? false
            if isInside { touched.insert(body) }
            allInside[body] = (allInside[body] ?? true) && isInside
        }
        guard crossing else {
            return allInside.filter { $0.value }.map { $0.key }.sorted()
        }
        // Rahmen mitten auf einem großen Körper (keine Ecke darin): der Körper unter der Rahmenmitte zählt mit
        if let ray = renderer.camera.ray(through: CGPoint(x: rect.midX, y: rect.midY), viewSize: bounds.size),
           let hit = model.pick(origin: ray.origin, direction: ray.direction) {
            touched.insert(hit.face.body)
        }
        return touched.sorted()
    }

    private func acceptsForSketch(_ touch: UITouch) -> Bool {
        guard let sketch, sketch.isActive, !sketch.isChoosingPlane else { return false }
        return touch.type == .pencil || (sketch.fingerDraws && touch.type == .direct)
    }

    private func sketchPoint(for touch: UITouch) -> SIMD2<Double>? {
        sketchPoint(at: touch.location(in: self))
    }

    /// Punkt der (unbegrenzten) Skizzenebene unter einem Bildschirmpunkt.
    private func sketchPoint(at location: CGPoint) -> SIMD2<Double>? {
        guard let renderer, let sketch else { return nil }
        let plane = sketch.plane
        let hit = renderer.camera.intersect(screenPoint: location, viewSize: bounds.size,
                                            planeOrigin: SIMD3<Float>(plane.origin),
                                            planeNormal: SIMD3<Float>(plane.normal))
        return hit.map { plane.local(SIMD3<Double>($0)) }
    }

    /// Fangradius: etwa 20 Bildschirmpunkte in Weltmaß.
    private var snapTolerance: Double {
        Double((renderer?.camera.worldUnitsPerPoint(viewHeight: Float(bounds.height)) ?? 0.1) * 20)
    }

    // MARK: Berührungen

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateHeldFingers(began: touches)
        // Ziehpfeil und Rahmen nur mit der ersten Berührung (nicht der zweite Finger beim Zoomen)
        let alone = (event?.allTouches?.count ?? touches.count) == touches.count && touches.count == 1
        if handleDrag == nil, alone,
           let touch = touches.first(where: { $0.type == .pencil || $0.type == .direct }),
           let handle = handleHit(at: touch.location(in: self)),
           let parameter = axisParameter(at: touch.location(in: self), handle: handle) {
            handleDrag = HandleDragState(touch: touch, handle: handle, startParameter: parameter,
                                         step: dragStep(at: handle.base))
            return
        }
        if planeDrag == nil, ringDrag == nil, handleDrag == nil, alone,
           let touch = touches.first(where: { $0.type == .pencil || $0.type == .direct }),
           let normal = planeHandleHit(at: touch.location(in: self)), let workspace, let model,
           let center = workspace.moveCenter,
           let start = planePoint(at: touch.location(in: self), normal: normal, origin: center) {
            planeDrag = PlaneDragState(touch: touch, normal: normal, origin: center, start: start,
                                       startOffset: model.moveOffset, step: dragStep(at: SIMD3<Float>(center)))
            refresh()
            return
        }
        if ringDrag == nil, handleDrag == nil, alone,
           let touch = touches.first(where: { $0.type == .pencil || $0.type == .direct }),
           let ring = ringHit(at: touch.location(in: self)),
           let angle = ringAngle(at: touch.location(in: self), ring: ring) {
            workspace?.beginRingRotation()
            ringDrag = RingDragState(touch: touch, center: ring.center, radius: ring.radius, startAngle: angle,
                                     lastAngle: angle, axis: ring.axis)
            updateRingLabel()
            refresh()
            return
        }
        if boxTouch == nil, alone, let touch = touches.first(where: acceptsForBox) {
            boxTouch = touch
            boxStart = touch.location(in: self)
            boxInSketch = false
            lassoPath = [boxStart]
            return
        }
        if boxTouch == nil, sketchTouch == nil, alone, let touch = touches.first(where: acceptsForSketchBox) {
            boxTouch = touch
            boxStart = touch.location(in: self)
            boxInSketch = true
            lassoPath = [boxStart]
            sketch?.endHover()
            return
        }
        guard sketchTouch == nil, let touch = touches.first(where: acceptsForSketch),
              let point = sketchPoint(for: touch) else {
            super.touchesBegan(touches, with: event)
            return
        }
        sketchTouch = touch
        strokeBeganAt = CACurrentMediaTime()
        // Ein schon laufendes Verschieben/Zoomen durch den aufgelegten Finger abbrechen: der Finger ist
        // jetzt nur die Bogen-Taste
        for gesture in [orbitGesture, panGesture, pinchGesture] as [UIGestureRecognizer?] {
            guard let gesture, gesture.state == .began || gesture.state == .changed else { continue }
            gesture.isEnabled = false
            gesture.isEnabled = true
        }
        // Ein offenes Maßfeld gehört zum vorigen Element: verwerfen statt auf das neue anwenden
        for field in dimensionFields.values where field.isFirstResponder {
            field.appliesOnEnd = false
            field.resignFirstResponder()
        }
        sketch?.began(at: point, tolerance: snapTolerance)
        latchArcIfFingerDown(event)
        refresh()
    }

    /// Liegt beim Stiftstrich irgendwo ein Finger auf, wird der Strich ein Bogen – auch wenn der Viewport den
    /// Finger nicht selbst bekommen hat (z. B. von einer Geste übernommen). Handballen (große Fläche) zählen nicht.
    private func latchArcIfFingerDown(_ event: UIEvent?) {
        guard let sketch, !sketch.fingerDraws, sketch.tool == .polyline, !sketch.arcActive,
              let touches = event?.allTouches,
              touches.contains(where: { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
                  && $0.majorRadius < 40 }) else { return }
        sketch.latchArc()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let drag = planeDrag, touches.contains(drag.touch) {
            if let point = planePoint(at: drag.touch.location(in: self), normal: drag.normal, origin: drag.origin) {
                var offset = drag.startOffset + (point - drag.start)
                for k in 0..<3 where k != drag.normal {
                    offset[k] = (offset[k] / drag.step).rounded() * drag.step
                }
                offset[drag.normal] = drag.startOffset[drag.normal]
                if offset != model?.moveOffset { model?.setMoveOffset(offset) }
                refresh()
            }
            return
        }
        if var drag = ringDrag, touches.contains(drag.touch) {
            if let angle = ringAngle(at: drag.touch.location(in: self), ring: (drag.center, drag.radius, drag.axis)) {
                drag.sweep += remainder(angle - drag.lastAngle, 2 * .pi)
                drag.lastAngle = angle
                let degrees = Self.ringDegrees(drag.sweep)
                if degrees != drag.degrees {
                    if Int(degrees) % 15 == 0 { UISelectionFeedbackGenerator().selectionChanged() }
                    drag.degrees = degrees
                    ringDrag = drag
                    workspace?.ringRotation(degrees: degrees, center: drag.center, axis: drag.axis)
                } else {
                    ringDrag = drag
                }
                updateRingLabel()
                refresh()
            }
            return
        }
        if let drag = handleDrag, touches.contains(drag.touch) {
            if let parameter = axisParameter(at: drag.touch.location(in: self), handle: drag.handle) {
                let raw = drag.handle.value + Double(parameter - drag.startParameter)
                var snapped = (raw / drag.step).rounded() * drag.step
                // Skizze versetzen: rastet an Punkten und gekreuzten Linien ein
                if drag.handle.kind == .offset, let sketch, let hit = sketch.snapOffset(raw, tolerance: snapTolerance) {
                    snapped = hit
                }
                workspace?.apply(drag.handle.kind, value: snapped)
                refresh()
            }
            return
        }
        if let touch = boxTouch, touches.contains(touch) {
            let location = touch.location(in: self)
            if LassoSelection.isOn {
                if lassoPath.count < 3000 { lassoPath.append(location) }
                let extent = RegionSelection.bounds(lassoPath)
                if max(extent.width, extent.height) >= Self.boxMinimum { lassoView.show(lassoPath, in: bounds) }
                return
            }
            let rect = boxRect(to: location)
            if max(rect.width, rect.height) >= Self.boxMinimum {
                boxView.show(rect, crossing: location.x < boxStart.x)
            }
            return
        }
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        latchArcIfFingerDown(event)
        if let point = sketchPoint(for: touch) {
            sketch?.moved(to: point, tolerance: snapTolerance)
            refresh()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateHeldFingers(ended: touches)
        if let drag = planeDrag, touches.contains(drag.touch) {
            planeDrag = nil
            refresh()
            return
        }
        if let drag = ringDrag, touches.contains(drag.touch) {
            finishRingDrag()
            return
        }
        if let drag = handleDrag, touches.contains(drag.touch) {
            handleDrag = nil
            if drag.handle.kind == .offset { sketch?.endOffsetSnap() }
            refresh()
            return
        }
        if let touch = boxTouch, touches.contains(touch) {
            boxTouch = nil
            boxView.isHidden = true
            lassoView.isHidden = true
            finishBox(at: touch.location(in: self))
            lassoPath = []
            boxInSketch = false
            refresh()
            return
        }
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        sketchTouch = nil
        strokeEndedAt = CACurrentMediaTime()
        if sketch?.arcActive == true || !heldFingers.isEmpty { suppressFingerTap = true }
        if let point = sketchPoint(for: touch) {
            sketch?.ended(at: point, tolerance: snapTolerance)
            if sketch?.tool == .project { project(at: touch.location(in: self)) }
        } else {
            sketch?.cancelStroke()
        }
        refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateHeldFingers(ended: touches)
        if let drag = planeDrag, touches.contains(drag.touch) {
            planeDrag = nil
            refresh()
            return
        }
        if let drag = ringDrag, touches.contains(drag.touch) {
            finishRingDrag()
            return
        }
        if let drag = handleDrag, touches.contains(drag.touch) {
            handleDrag = nil
            if drag.handle.kind == .offset { sketch?.endOffsetSnap() }
            refresh()
            return
        }
        if let touch = boxTouch, touches.contains(touch) {
            boxTouch = nil
            boxView.isHidden = true
            lassoView.isHidden = true
            lassoPath = []
            boxInSketch = false
            return
        }
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        sketchTouch = nil
        strokeEndedAt = CACurrentMediaTime()
        sketch?.cancelStroke()
        refresh()
    }

    /// Ring losgelassen: gedrehte Lage übernehmen (0° = nichts geändert).
    private func finishRingDrag() {
        guard let drag = ringDrag else { return }
        ringDrag = nil
        ringLabel.isHidden = true
        if drag.degrees != 0 { workspace?.endRingRotation() }
        refresh()
    }

    // MARK: Gesten

    /// Tippen wählt Kanten (nah an einer Kante), Flächen oder Körper. Im Skizzenmodus wird eine ebene
    /// Fläche zur Skizzenebene, Tippen ins Leere setzt die Skizze auf die Bodenebene zurück.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        guard handleHit(at: location) == nil,
              let renderer, let model, let sketch, let workspace,
              let ray = renderer.camera.ray(through: location, viewSize: bounds.size) else { return }
        let hit = model.pick(origin: ray.origin, direction: ray.direction)

        if sketch.isActive {
            if sketch.isChoosingPlane {
                chooseSketchPlane(ray: ray, faceHit: hit)
                return
            }
            if suppressFingerTap { return }
            switch sketch.tool {
            case .project:
                project(at: location)
                refresh()
                return
            case .trim:
                if let point = sketchPoint(at: location) { sketch.trim(at: point, tolerance: snapTolerance) }
                refresh()
                return
            case .fillet, .chamfer:
                if let point = sketchPoint(at: location) {
                    sketch.filletCorner(at: point, tolerance: snapTolerance, chamfer: sketch.tool == .chamfer)
                }
                refresh()
                return
            case .extend:
                if let point = sketchPoint(at: location) { sketch.extendLine(at: point, tolerance: snapTolerance) }
                refresh()
                return
            case .breakCurve:
                if let point = sketchPoint(at: location) { sketch.breakCurve(at: point, tolerance: snapTolerance) }
                refresh()
                return
            case .measure:
                if let point = sketchPoint(at: location) { sketch.measure(at: point, tolerance: snapTolerance) }
                refresh()
                return
            default:
                break
            }
            // Finger tippt Elemente an (Auswahl für Einschränkungen, Löschen, Konstruktion)
            if !sketch.entities.isEmpty, let point = sketchPoint(at: location) {
                sketch.select(at: point, tolerance: snapTolerance)
                refresh()
                return
            }
            // Ebene nur wechseln, solange noch nichts gezeichnet ist (der Wechsel leert die Skizze)
            guard sketch.isEmpty else { return }
            guard let hit else {
                if sketch.plane.isOnFace { sketch.useBasePlane() }
                refresh()
                return
            }
            if let plane = model.plane(of: hit.face) {
                workspace.chooseSketchPlane(plane)
                model.message = nil
            } else {
                model.message = "Auf gekrümmten Flächen kann nicht skizziert werden."
            }
            refresh()
            return
        }
        // Bild kalibrieren: Punkte auf der Bildebene antippen
        if workspace.canvasCalibration != nil {
            workspace.calibrationTapped(origin: SIMD3<Double>(ray.origin), direction: SIMD3<Double>(ray.direction))
            refresh()
            return
        }
        let edgeHit = pickEdge(at: location, ray: ray, faceHit: hit)
        // Skizzenbereich vor der Fläche, auf der er liegt
        var region: RegionRef?
        var regionPoint: SIMD3<Float>?
        if edgeHit == nil, let regionHit = model.pickRegion(origin: ray.origin, direction: ray.direction) {
            let faceT = hit.map { simd_dot($0.point - ray.origin, ray.direction) } ?? .infinity
            if regionHit.t <= faceT + max(faceT * 0.002, 0.05) {
                region = regionHit.ref
                regionPoint = ray.origin + ray.direction * regionHit.t
            }
        }
        workspace.tapped(face: hit?.face, edge: edgeHit?.edge, region: region,
                         point: edgeHit?.point ?? hit?.point ?? regionPoint)
    }

    /// Projizieren: Körperkante (bzw. alle Kanten der Fläche) unter dem Punkt in die Skizze übernehmen.
    private func project(at location: CGPoint) {
        guard let renderer, let model, let sketch,
              let ray = renderer.camera.ray(through: location, viewSize: bounds.size) else { return }
        let hit = model.pick(origin: ray.origin, direction: ray.direction)
        var polylines: [[SIMD3<Double>]] = []
        if let edge = pickEdge(at: location, ray: ray, faceHit: hit)?.edge {
            polylines = model.edgePolylines(edge)
        } else if let hit {
            polylines = model.edgePolylines(ofFace: hit.face)
        }
        guard !polylines.isEmpty else {
            sketch.notice = "Eine Körperkante oder Fläche antippen."
            return
        }
        let plane = sketch.plane
        sketch.addProjected(polylines.map { $0.map(plane.local) })
    }

    /// Ebenenwahl: vorderste Standardebene oder ebene Körperfläche unter dem Finger.
    private func chooseSketchPlane(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                   faceHit: (face: FaceRef, point: SIMD3<Float>)?) {
        guard let model, let workspace else { return }
        let planeHit = basePlaneHit(ray: ray)
        if let construction = constructionPlaneHit(ray: ray),
           construction.t < (planeHit?.t ?? .infinity),
           construction.t < faceHit.map({ simd_dot($0.point - ray.origin, ray.direction) }) ?? .infinity {
            workspace.chooseSketchPlane(construction.plane)
            return
        }
        if let faceHit {
            let faceT = simd_dot(faceHit.point - ray.origin, ray.direction)
            if planeHit == nil || faceT < planeHit!.t {
                if let plane = model.plane(of: faceHit.face) {
                    model.message = nil
                    workspace.chooseSketchPlane(plane)
                } else {
                    model.message = "Auf gekrümmten Flächen kann nicht skizziert werden."
                }
                return
            }
        }
        if let planeHit {
            workspace.chooseSketchPlane(planeHit.side)
        }
    }

    /// Kante in Fingernähe, die nicht von einer Fläche verdeckt ist.
    private func pickEdge(at location: CGPoint, ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                          faceHit: (face: FaceRef, point: SIMD3<Float>)?) -> (edge: EdgeRef, point: SIMD3<Float>)? {
        guard let renderer, let model else { return nil }
        let size = bounds.size
        let camera = renderer.camera
        // 28 pt: mit 16 pt traf der Finger oft die Fläche statt der Kante (Kai: Abrunden zeigte den
        // Extrudieren-Pfeil der Fläche, Ziehen rundete nichts)
        guard let found = model.mesh.nearestEdge(to: location, tolerance: 28,
                                                 project: { camera.project($0, viewSize: size) }) else { return nil }
        if let faceHit {
            let edgeDepth = simd_dot(found.point - ray.origin, ray.direction)
            let faceDepth = simd_dot(faceHit.point - ray.origin, ray.direction)
            if edgeDepth > faceDepth + max(faceDepth * 0.01, 0.5) {
                return nil
            }
        }
        return found
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let sketch else { return }
        switch gesture.state {
        case .began, .changed:
            lastHoverLocation = gesture.location(in: self)
            updateHoverPick(at: sketch.isActive ? nil : gesture.location(in: self))
            guard sketch.isActive, !sketch.isChoosingPlane, sketchTouch == nil,
                  let point = sketchPoint(at: gesture.location(in: self)) else {
                updateHoverDwell(at: nil)
                return
            }
            updateHoverDwell(at: gesture.location(in: self))
            if gesture.state == .began, #available(iOS 17.5, *) {
                // Haptik auch beim Schweben (Kai): Generator vorab bereitmachen, damit der erste Fang klickt
                canvasFeedback.prepare()
            }
            sketch.hover(at: point, tolerance: snapTolerance)
        default:
            lastHoverLocation = nil
            updateHoverDwell(at: nil)
            updateHoverPick(at: nil)
            sketch.endHover()
        }
        refresh()
    }

    /// Stift drücken bzw. doppeltippen öffnet das Werkzeugrad – in der Skizze mit „Bogen“ (tangential ohne
    /// Finger). Punkte merken: Stift 1 s über dem Punkt schweben lassen oder mit dem Finger doppeltippen.
    /// Während und kurz nach einem Strich wird nichts ausgelöst (fester Griff beim Zeichnen zählt als Drücken).
    fileprivate func pencilAction(at location: CGPoint?) {
        if let sketch, sketch.isActive {
            // Kai: Drücken während des Zeichnens schaltet den Fang für diesen Strich aus bzw. wieder an
            if sketchTouch != nil, sketch.tool != .select {
                guard CACurrentMediaTime() - strokeBeganAt > 0.25 else { return }
                sketch.snapSuspended.toggle()
                sketch.notice = sketch.snapSuspended ? "Fang aus – nur für diesen Strich" : "Fang wieder an"
                if #available(iOS 17.5, *), let location = location ?? lastHoverLocation {
                    canvasFeedback.alignmentOccurred(at: location)
                }
                refresh()
                return
            }
            guard sketchTouch == nil, heldFingers.isEmpty, CACurrentMediaTime() - strokeEndedAt > 0.8 else { return }
        }
        showQuickTools(at: location ?? lastHoverLocation)
    }

    /// Stift schwebt 1 s ruhig (innerhalb weniger Punkte) über einem Fangpunkt: Punkt merken.
    private func updateHoverDwell(at location: CGPoint?) {
        guard let location else {
            hoverDwell?.cancel()
            hoverDwell = nil
            return
        }
        if let origin = hoverDwellOrigin, hypot(location.x - origin.x, location.y - origin.y) <= 6, hoverDwell != nil {
            return
        }
        hoverDwell?.cancel()
        hoverDwellOrigin = location
        let work = DispatchWorkItem { [weak self] in
            guard let self, let sketch = self.sketch, sketch.isActive, !sketch.isChoosingPlane,
                  self.sketchTouch == nil, let hover = self.lastHoverLocation,
                  hypot(hover.x - location.x, hover.y - location.y) <= 6,
                  let point = self.sketchPoint(at: hover) else { return }
            if sketch.captureHovered(at: point, tolerance: self.snapTolerance) {
                if #available(iOS 17.5, *) {
                    UICanvasFeedbackGenerator(view: self).alignmentOccurred(at: hover)
                }
                self.refresh()
            }
        }
        hoverDwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Doppeltippen mit dem Finger auf einen Fangpunkt: Punkt merken (wie 1 s Schweben mit dem Stift).
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if let sketch, !sketch.isActive {
            repeatLastExtrude(at: gesture.location(in: self))
            return
        }
        guard let sketch, sketch.isActive, !sketch.isChoosingPlane,
              let point = sketchPoint(at: gesture.location(in: self)) else { return }
        if !sketch.captureHovered(at: point, tolerance: snapTolerance) {
            sketch.notice = "Kein Punkt zum Merken – auf ein Ende, eine Mitte, ein Zentrum oder einen Schnittpunkt doppeltippen."
        }
        refresh()
    }

    /// Während ein Ziehpfeil gezogen wird, drehen und wählen die Finger nicht. Während der Stift zeichnet,
    /// verschiebt, dreht, zoomt und tippt kein Finger: ein aufgelegter Finger ist dann nur die Bogen-Taste
    /// (mit einem Finger begann sonst bei kleinster Bewegung das Verschieben).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if handleDrag != nil || ringDrag != nil, gestureRecognizer === orbitGesture || gestureRecognizer === tapGesture {
            return false
        }
        if sketchTouch != nil,
           gestureRecognizer === orbitGesture || gestureRecognizer === panGesture
            || gestureRecognizer === pinchGesture || gestureRecognizer === tapGesture
            || gestureRecognizer === undoGesture || gestureRecognizer === redoGesture {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleUndoTap(_ gesture: UITapGestureRecognizer) {
        guard handleDrag == nil, ringDrag == nil else { return }
        workspace?.undo()
        refresh()
    }

    @objc private func handleRedoTap(_ gesture: UITapGestureRecognizer) {
        guard handleDrag == nil, ringDrag == nil else { return }
        workspace?.redo()
        refresh()
    }

    /// Doppeltippen auf einen Skizzenbereich bzw. eine ebene Fläche: zuletzt verwendete Höhe extrudieren
    /// (Shapr3D). Die beiden Einzeltipps davor haben die Auswahl schon umgeschaltet; hier wird sie neu gesetzt.
    private func repeatLastExtrude(at location: CGPoint) {
        guard let renderer, let model, let workspace, workspace.tool == .select, handleDrag == nil,
              let ray = renderer.camera.ray(through: location, viewSize: bounds.size) else { return }
        let hit = model.pick(origin: ray.origin, direction: ray.direction)
        var region: RegionRef?
        if let regionHit = model.pickRegion(origin: ray.origin, direction: ray.direction),
           regionHit.t <= (hit.map { simd_dot($0.point - ray.origin, ray.direction) } ?? .infinity) + 0.05 {
            region = regionHit.ref
        }
        workspace.repeatLastExtrude(region: region, face: region == nil ? hit?.face : nil)
        refresh()
    }

    /// Werkzeugrad an der Stiftspitze (bzw. in der Mitte, wenn der Stift nicht schwebt).
    fileprivate func showQuickTools(at location: CGPoint?) {
        guard let workspace else { return }
        let point = location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        workspace.quickToolsLocation = workspace.quickToolsLocation == nil ? point : nil
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        // Im Skizzenmodus keine 3D-Ansicht: ein Finger verschiebt nur
        if let sketch, sketch.isActive, !sketch.isChoosingPlane {
            renderer?.camera.pan(dx: Float(t.x), dy: Float(t.y), viewHeight: Float(bounds.height))
            gesture.setTranslation(.zero, in: self)
            refresh()
            return
        }
        renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
        gesture.setTranslation(.zero, in: self)
        cameraMoved()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        renderer?.camera.pan(dx: Float(t.x), dy: Float(t.y), viewHeight: Float(bounds.height))
        gesture.setTranslation(.zero, in: self)
        refresh()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        renderer?.camera.zoom(by: Float(gesture.scale))
        gesture.scale = 1
        refresh()
    }
}

extension ViewportView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Antippen eines Maßfelds öffnet nur das Feld.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return !(view is UITextField) && !view.isDescendant(of: keypad)
    }
}

extension ViewportView: UITextFieldDelegate {
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        (textField as? DimensionField)?.allowsEditing ?? false
    }

    /// Cursor hinter die letzte Ziffer (nicht davor, nicht alles markiert) und das Ziffernfeld daneben öffnen.
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let field = textField as? DimensionField {
            field.appliesOnEnd = true
            // Verknüpftes Maß: Formel zum Bearbeiten zeigen
            if let expression = field.expression { field.text = expression }
            field.inputView = UIView(frame: .zero)
            field.keyboardType = .decimalPad
            keypad.lockState = field.lockState
            keypad.variableNames = model?.variables.map(\.name) ?? []
        }
        let toEnd = { [weak textField] in
            guard let textField else { return }
            textField.selectedTextRange = textField.textRange(from: textField.endOfDocument, to: textField.endOfDocument)
        }
        toEnd()
        // Das Antippen setzt den Cursor erst nach diesem Aufruf – darum gleich danach nochmal ans Ende
        DispatchQueue.main.async(execute: toEnd)
        placeKeypad()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        keypad.isHidden = true
        guard let field = textField as? DimensionField, field.appliesOnEnd else { return }
        apply(field)
    }
}

extension ViewportView: UIPencilInteractionDelegate {
    /// Apple Pencil Pro: Drücken öffnet das Werkzeugrad (sofern in den Einstellungen nicht abgeschaltet).
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        pencilAction(at: squeeze.hoverPose?.location)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        pencilAction(at: tap.hoverPose?.location)
    }

    /// Ältere Systeme: Doppeltippen auf den Apple Pencil (2. Gen.).
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        pencilAction(at: nil)
    }
}

/// Auswahlrahmen: durchgezogen blau (nach rechts, nur ganz umschlossene Körper),
/// gestrichelt grün (nach links, auch angeschnittene).
final class SelectionBoxView: UIView {
    private let outline = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        outline.lineWidth = 1.5
        layer.addSublayer(outline)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        outline.lineWidth = 1.5
        layer.addSublayer(outline)
    }

    func show(_ rect: CGRect, crossing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        outline.frame = bounds
        outline.path = UIBezierPath(rect: bounds).cgPath
        let tint = crossing ? UIColor.systemGreen : UIColor.systemBlue
        outline.strokeColor = tint.cgColor
        outline.fillColor = tint.withAlphaComponent(0.12).cgColor
        outline.lineDashPattern = crossing ? [6, 4] : nil
        CATransaction.commit()
        isHidden = false
    }
}

private extension DragHandle {
    var isMove: Bool {
        if case .move = kind { return true }
        return false
    }
}

private extension CGPoint {
    func distance(toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        var t: CGFloat = 0
        if lengthSquared > 0 {
            t = min(max(((x - a.x) * ab.x + (y - a.y) * ab.y) / lengthSquared, 0), 1)
        }
        let dx = a.x + t * ab.x - x, dy = a.y + t * ab.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Etikett mit Innenabstand für das Maß am Ziehpfeil.
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(width: fitted.width + insets.left + insets.right, height: fitted.height + insets.top + insets.bottom)
    }
}

/// Maß direkt am Skizzenelement; antippen zum Ändern, Return übernimmt.
final class DimensionField: UITextField {
    /// Kennung des Maßes (SketchDimension.id)
    let dimensionID: String
    /// Formel, mit der das Maß verknüpft ist
    var expression: String?
    /// false, wenn das Feld geschlossen wird, weil sein Element nicht mehr das aktuelle ist.
    var appliesOnEnd = true
    var allowsEditing = false {
        didSet { updateStyle() }
    }
    var prefix = "" {
        didSet { prefixLabel.text = prefix.isEmpty ? nil : prefix }
    }
    /// Feine, dünne Schrift (Maß zwischen gemerkten Punkten)
    var isFine = false {
        didSet {
            guard isFine != oldValue else { return }
            font = .monospacedDigitSystemFont(ofSize: isFine ? 13 : 15, weight: isFine ? .light : .semibold)
            updateStyle()
        }
    }
    private let prefixLabel = UILabel()
    /// Schloss am treibenden Maß: true = fest (grün), false = gelöst (rot), nil = keins
    var lockState: Bool? {
        didSet {
            guard lockState != oldValue else { return }
            updateLock()
        }
    }
    var onLockTap: (() -> Void)?
    private lazy var lockButton: UIButton = {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 26, height: 30)
        button.addAction(UIAction { [weak self] _ in self?.onLockTap?() }, for: .touchUpInside)
        return button
    }()

    init(dimensionID: String) {
        self.dimensionID = dimensionID
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        textAlignment = .center
        keyboardType = .decimalPad
        returnKeyType = .done
        autocorrectionType = .no
        // Keine Bildschirmtastatur (sie verdeckte die Maße): der Viewport zeigt ein kleines Ziffernfeld daneben
        inputView = UIView(frame: .zero)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        backgroundColor = .white
        textColor = .black
        layer.cornerRadius = 8
        layer.borderWidth = 1.5
        prefixLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        prefixLabel.textColor = .darkGray
        leftView = prefixLabel
        leftViewMode = .always
        updateStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    /// Grünes geschlossenes bzw. rotes offenes Schloss rechts im Feld; antippen schaltet um.
    private func updateLock() {
        guard let lockState else {
            rightView = nil
            rightViewMode = .never
            return
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        lockButton.setImage(UIImage(systemName: lockState ? "lock.fill" : "lock.open.fill", withConfiguration: configuration),
                            for: .normal)
        lockButton.tintColor = lockState ? .systemGreen : .systemRed
        lockButton.accessibilityLabel = lockState ? "Maß fest – antippen löst es" : "Maß gelöst – antippen macht es fest"
        rightView = lockButton
        rightViewMode = .always
        updateStyle()
    }

    private func updateStyle() {
        layer.borderWidth = isFine ? 0.75 : 1.5
        backgroundColor = isFine ? UIColor.white.withAlphaComponent(0.85) : .white
        layer.borderColor = (lockState == false ? UIColor.systemRed
            : allowsEditing ? UIColor.systemBlue : UIColor.systemGray3).cgColor
        isUserInteractionEnabled = allowsEditing || lockState != nil
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = (self.text ?? "") as NSString
        let width = text.size(withAttributes: [.font: font ?? UIFont.systemFont(ofSize: 15)]).width
        let prefixWidth = prefix.isEmpty ? 0 : prefixLabel.intrinsicContentSize.width + 2
        let lockWidth: CGFloat = lockState == nil ? 0 : 24
        return CGSize(width: max(width + prefixWidth + lockWidth + 22, 46), height: 30)
    }

    override func sizeToFit() {
        bounds.size = sizeThatFits(.zero)
    }

    override func leftViewRect(forBounds bounds: CGRect) -> CGRect {
        guard !prefix.isEmpty else { return .zero }
        let width = prefixLabel.intrinsicContentSize.width
        return CGRect(x: 9, y: 0, width: width, height: bounds.height)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        let left: CGFloat = prefix.isEmpty ? 8 : 9 + prefixLabel.intrinsicContentSize.width + 2
        return bounds.inset(by: UIEdgeInsets(top: 0, left: left, bottom: 0, right: 8))
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        textRect(forBounds: bounds)
    }
}

/// Rechner-Tastatur für Maße wie bei Shapr3D (schwebt neben dem Maß statt der großen Bildschirmtastatur):
/// Ziffern, Rechenzeichen, Klammern, Einheiten, Schloss, Variablen und Umschalten auf die Bildschirmtastatur.
final class DimensionKeypad: UIView {
    enum Key {
        case text(String)
        case delete, clear, cancel, done, negate, lock, keyboard
        case createVariable
    }

    var onKey: (Key) -> Void = { _ in }
    /// Namen der Projektvariablen für das Menü „Variable einfügen“
    var variableNames: [String] = [] {
        didSet {
            guard variableNames != oldValue else { return }
            updateVariableMenu()
        }
    }
    /// Schloss-Taste: nil = Maß ohne Schloss (ausgegraut)
    var lockState: Bool? {
        didSet {
            guard lockState != oldValue else { return }
            updateLockKey()
        }
    }

    private static let keySize = CGSize(width: 50, height: 40)
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 8
    private static let headerHeight: CGFloat = 32
    private static let columns = 5

    /// Erste Zeile: Klammern und Einheiten (schmaler, sieben Tasten)
    private static let unitRow: [(String, Key)] = [
        ("(", .text("(")), (")", .text(")")), ("mm", .text(" mm")), ("cm", .text(" cm")), ("m", .text(" m")),
        ("in", .text(" in")), ("°", .text("°")),
    ]

    /// Ziffernblock: Titel und Taste; „✓“ doppelt breit
    private static let rows: [[(String, Key)]] = [
        [("7", .text("7")), ("8", .text("8")), ("9", .text("9")), ("÷", .text("÷")), ("⌫", .delete)],
        [("4", .text("4")), ("5", .text("5")), ("6", .text("6")), ("×", .text("×")), ("🔒", .lock)],
        [("1", .text("1")), ("2", .text("2")), ("3", .text("3")), ("−", .text("−")), ("+", .text("+"))],
        [("±", .negate), ("0", .text("0")), (",", .text(",")), ("✓", .done)],
    ]

    private let variableButton = UIButton(type: .system)
    private var lockButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.97)
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header())
        let fullWidth = Self.keySize.width * CGFloat(Self.columns) + Self.spacing * CGFloat(Self.columns - 1)
        let unitWidth = (fullWidth - Self.spacing * CGFloat(Self.unitRow.count - 1)) / CGFloat(Self.unitRow.count)
        stack.addArrangedSubview(line(Self.unitRow, width: { _ in unitWidth }, height: 32, font: 15))
        for row in Self.rows {
            stack.addArrangedSubview(line(row, width: { key in
                if case .done = key { return Self.keySize.width * 2 + Self.spacing }
                return Self.keySize.width
            }, height: Self.keySize.height, font: 20))
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
        ])
        updateVariableMenu()
        updateLockKey()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    /// Kopfzeile: Variable einfügen, Bildschirmtastatur, Löschen, Abbrechen.
    private func header() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = Self.spacing
        row.alignment = .center
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: "x.squareroot")
        configuration.title = "Variable"
        configuration.imagePadding = 4
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        variableButton.configuration = configuration
        variableButton.showsMenuAsPrimaryAction = true
        row.addArrangedSubview(variableButton)
        row.addArrangedSubview(UIView())
        for (symbol, key, label) in [("keyboard", Key.keyboard, "Bildschirmtastatur"), ("c.circle", Key.clear, "Leeren"),
                                     ("xmark.circle", Key.cancel, "Abbrechen")] {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)),
                            for: .normal)
            button.accessibilityLabel = label
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.onKey(key) }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        let width = Self.keySize.width * CGFloat(Self.columns) + Self.spacing * CGFloat(Self.columns - 1)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        return row
    }

    private func line(_ keys: [(String, Key)], width: (Key) -> CGFloat, height: CGFloat, font: CGFloat) -> UIView {
        let line = UIStackView()
        line.axis = .horizontal
        line.spacing = Self.spacing
        for (title, key) in keys {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: font, weight: .semibold)
            var isDone = false, isAction = false
            switch key {
            case .done: isDone = true
            case .delete, .lock, .negate: isAction = true
            case .text(let text): isAction = !text.allSatisfy { $0.isNumber || $0 == "," }
            default: break
            }
            button.backgroundColor = isDone ? .systemBlue : isAction ? .tertiarySystemFill : .secondarySystemBackground
            button.setTitleColor(isDone ? .white : .label, for: .normal)
            button.layer.cornerRadius = 10
            button.widthAnchor.constraint(equalToConstant: width(key)).isActive = true
            button.heightAnchor.constraint(equalToConstant: height).isActive = true
            button.addAction(UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.onKey(key)
            }, for: .touchUpInside)
            if case .lock = key { lockButton = button }
            line.addArrangedSubview(button)
        }
        return line
    }

    private func updateVariableMenu() {
        var actions: [UIMenuElement] = variableNames.sorted().map { name in
            UIAction(title: name, image: UIImage(systemName: "function")) { [weak self] _ in self?.onKey(.text(name)) }
        }
        let create = UIAction(title: "Variable erstellen …", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.onKey(.createVariable)
        }
        if actions.isEmpty {
            actions = [create]
        } else {
            actions.append(UIMenu(options: .displayInline, children: [create]))
        }
        variableButton.menu = UIMenu(title: "Variable einfügen", children: actions)
    }

    private func updateLockKey() {
        guard let lockButton else { return }
        lockButton.setTitle(lockState == false ? "🔓" : "🔒", for: .normal)
        lockButton.isEnabled = lockState != nil
        lockButton.alpha = lockState == nil ? 0.35 : 1
        lockButton.accessibilityLabel = lockState == true ? "Maß lösen" : "Maß festlegen"
    }

    // Berührungen neben den Tasten nicht an den Viewport weiterreichen (sonst begänne dort ein Strich)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = Self.keySize.width * CGFloat(Self.columns) + Self.spacing * CGFloat(Self.columns - 1)
        let height = Self.headerHeight + 32 + Self.keySize.height * CGFloat(Self.rows.count)
            + Self.spacing * CGFloat(Self.rows.count + 1)
        return CGSize(width: width + Self.padding * 2, height: height + Self.padding * 2)
    }
}
