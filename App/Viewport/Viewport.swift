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
    private var sketchTouch: UITouch?
    private var handleDrag: HandleDragState?
    private let valueLabel = PaddedLabel()
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
    /// Aufgelegte Finger beim Skizzieren mit dem Stift (Finger auflegen = tangentialer Bogen)
    private var heldFingers = Set<UITouch>()
    /// Der aufgelegte Finger hat als Bogen-Taste gedient: sein Loslassen ist kein Antippen
    private var suppressFingerTap = false
    /// Ende des letzten Stiftstrichs: Drücken/Doppeltippen direkt danach war meist ein festerer Griff, kein Merken
    private var strokeEndedAt: TimeInterval = 0

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

    private struct HandleDragState {
        let touch: UITouch
        let handle: DragHandle
        let startParameter: Float
        let step: Double
    }

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

        // Punkte merken nur per Stift drücken bzw. doppeltippen (pencilAction): ein 1-s-Halten hat beim
        // langsamen Zeichnen und bei aufgelegtem Finger ungewollt „Punkt 1 gemerkt“ ausgelöst.
        for recognizer in [orbit, pan, pinch, tap, hover] as [UIGestureRecognizer] {
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
        valueLabel.layer.borderWidth = 2
        valueLabel.layer.borderColor = UIColor.systemBlue.cgColor
        valueLabel.layer.masksToBounds = true
        valueLabel.isHidden = true
        addSubview(valueLabel)
        boxView.isHidden = true
        addSubview(boxView)
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
            HandleGraphic(base: arrowBase(handle), direction: handle.pointing, color: handle.color)
        }
        updateValueLabel(handles)
        updateDimensionFields()
    }

    // MARK: Linien und Bereiche

    private static let sketchInk = SIMD3<Float>(0.05, 0.06, 0.09)
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

        for (index, stored) in model.sketches.enumerated() where !stored.isHidden {
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
        if !sketch.isActive, workspace.tool == .measure, !workspace.measurePoints.isEmpty {
            let points = workspace.measurePoints.map { SIMD3<Float>($0) }
            groups.append(LineGroup(polylines: points.count == 2 ? [points] : [], color: Self.previewBlue, width: 2,
                                    dots: points, dotRadius: 5))
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
            groups.append(LineGroup(polylines: sketch.entityPolylines.map { $0.map(world) }, color: Self.sketchInk,
                                    width: 2.6))
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
            if let hover = sketch.hoverSnap?.point {
                let arm = 9 * perPoint, gap = 2.5 * perPoint
                let cross: [[Point2]] = [
                    [hover + Point2(gap, 0), hover + Point2(arm, 0)], [hover - Point2(gap, 0), hover - Point2(arm, 0)],
                    [hover + Point2(0, gap), hover + Point2(0, arm)], [hover - Point2(0, gap), hover - Point2(0, arm)],
                ]
                groups.append(LineGroup(polylines: cross.map { $0.map(world) }, color: Self.sketchInk, width: 1.3,
                                        dots: [world(hover)], dotRadius: 1.4))
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
            return ([], a + simd_normalize(bisector) * radius, true)
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
            field.prefix = dimension.prefix
            if !field.isFirstResponder {
                field.text = dimension.value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
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
        case .digit(let text):
            // Ein Komma genügt
            if text == ",", (field.text ?? "").contains(where: { $0 == "," || $0 == "." }) { return }
            field.insertText(text)
        case .delete:
            field.deleteBackward()
        case .clear:
            field.text = ""
        case .cancel:
            field.appliesOnEnd = false
            field.resignFirstResponder()
        case .done:
            field.resignFirstResponder()
        }
        field.sizeToFit()
    }

    private func makeDimensionField(_ id: String) -> DimensionField {
        let field = DimensionField(dimensionID: id)
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        dimensionFields[id] = field
        return field
    }

    private func apply(_ field: DimensionField) {
        let text = (field.text ?? "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(text), value > 0 else { return }
        sketch?.setDimension(id: field.dimensionID, to: value)
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
        let length = Renderer.handleLength * renderer.camera.worldUnitsPerPoint(at: base, viewHeight: Float(bounds.height))
        guard let tip = renderer.camera.project(base + active.pointing * length * 1.25, viewSize: bounds.size) else {
            valueLabel.isHidden = true
            return
        }
        valueLabel.text = "\(active.value.formatted(.number.precision(.fractionLength(0...3)))) mm"
        valueLabel.sizeToFit()
        valueLabel.center = tip
        valueLabel.isHidden = false
    }

    // MARK: Ziehpfeile

    private func handleHit(at point: CGPoint) -> DragHandle? {
        guard let renderer, let workspace else { return nil }
        var best: (distance: CGFloat, handle: DragHandle)?
        for handle in workspace.handles {
            let base = arrowBase(handle)
            let length = Renderer.handleLength * renderer.camera.worldUnitsPerPoint(at: base, viewHeight: Float(bounds.height))
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

    /// Fuß des gezeichneten Pfeils: wie bei Shapr3D etwas über dem Objekt schwebend (Verschiebe-Pfeile am Mittelpunkt).
    private func arrowBase(_ handle: DragHandle) -> SIMD3<Float> {
        guard !handle.isMove, let renderer else { return handle.base }
        let gap = 22 * renderer.camera.worldUnitsPerPoint(at: handle.base, viewHeight: Float(bounds.height))
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
        if boxTouch == nil, alone, let touch = touches.first(where: acceptsForBox) {
            boxTouch = touch
            boxStart = touch.location(in: self)
            return
        }
        guard sketchTouch == nil, let touch = touches.first(where: acceptsForSketch),
              let point = sketchPoint(for: touch) else {
            super.touchesBegan(touches, with: event)
            return
        }
        sketchTouch = touch
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
            let rect = boxRect(to: touch.location(in: self))
            if max(rect.width, rect.height) >= Self.boxMinimum {
                boxView.show(rect, crossing: touch.location(in: self).x < boxStart.x)
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
        if let drag = handleDrag, touches.contains(drag.touch) {
            handleDrag = nil
            if drag.handle.kind == .offset { sketch?.endOffsetSnap() }
            refresh()
            return
        }
        if let touch = boxTouch, touches.contains(touch) {
            boxTouch = nil
            boxView.isHidden = true
            let end = touch.location(in: self)
            let rect = boxRect(to: end)
            // Kurzer Zug bleibt ein Tippen (das übernimmt die Tipp-Geste)
            if max(rect.width, rect.height) >= Self.boxMinimum {
                let crossing = end.x < boxStart.x
                workspace?.boxSelected(bodies(in: rect, crossing: crossing), crossing: crossing)
            }
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
        if let drag = handleDrag, touches.contains(drag.touch) {
            handleDrag = nil
            if drag.handle.kind == .offset { sketch?.endOffsetSnap() }
            refresh()
            return
        }
        if let touch = boxTouch, touches.contains(touch) {
            boxTouch = nil
            boxView.isHidden = true
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
        guard let found = model.mesh.nearestEdge(to: location, tolerance: 16,
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
            guard sketch.isActive, !sketch.isChoosingPlane, sketchTouch == nil,
                  let point = sketchPoint(at: gesture.location(in: self)) else { return }
            sketch.hover(at: point, tolerance: snapTolerance)
        default:
            lastHoverLocation = nil
            sketch.endHover()
        }
        refresh()
    }

    /// Stift drücken bzw. doppeltippen: Schwebt der Stift im Skizzenmodus über einem Fangpunkt, wird er gemerkt
    /// (zwei gemerkte Punkte ergeben Mitte und Mittellinie). Sonst öffnet sich das Werkzeugrad.
    /// Während und kurz nach einem Strich (bzw. mit aufgelegtem Finger) wird nichts ausgelöst: Ein festerer
    /// Griff beim Zeichnen meldet der Pencil Pro als Drücken, das hat ungewollt „Punkt 1 gemerkt“ ergeben.
    /// Gemerkt wird nur, wenn der Stift gerade wirklich über dem Punkt schwebt.
    /// Im Skizzenmodus öffnet Drücken nie das Werkzeugrad (Kai: Drücken = Punkt markieren, auch bei
    /// Konstruktionslinien). Fehlt die Schwebeposition im Ereignis, gilt die letzte bekannte des Stifts.
    fileprivate func pencilAction(at location: CGPoint?) {
        if let sketch, sketch.isActive, !sketch.isChoosingPlane {
            guard sketchTouch == nil, heldFingers.isEmpty, CACurrentMediaTime() - strokeEndedAt > 0.8 else { return }
            guard let location = location ?? lastHoverLocation, let point = sketchPoint(at: location) else {
                sketch.notice = "Stift über den Punkt halten (nicht aufsetzen) und drücken."
                return
            }
            if !sketch.captureHovered(at: point, tolerance: snapTolerance * 1.25) {
                sketch.notice = "Kein Punkt unter dem Stift – Ende, Mitte, Zentrum oder Schnittpunkt anpeilen und drücken."
            }
            refresh()
            return
        }
        showQuickTools(at: location)
    }

    /// Während ein Ziehpfeil gezogen wird, drehen und wählen die Finger nicht. Während der Stift zeichnet,
    /// verschiebt, dreht, zoomt und tippt kein Finger: ein aufgelegter Finger ist dann nur die Bogen-Taste
    /// (mit einem Finger begann sonst bei kleinster Bewegung das Verschieben).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if handleDrag != nil, gestureRecognizer === orbitGesture || gestureRecognizer === tapGesture {
            return false
        }
        if sketchTouch != nil,
           gestureRecognizer === orbitGesture || gestureRecognizer === panGesture
            || gestureRecognizer === pinchGesture || gestureRecognizer === tapGesture {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
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
        (textField as? DimensionField)?.appliesOnEnd = true
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
    /// false, wenn das Feld geschlossen wird, weil sein Element nicht mehr das aktuelle ist.
    var appliesOnEnd = true
    var allowsEditing = false {
        didSet { updateStyle() }
    }
    var prefix = "" {
        didSet { prefixLabel.text = prefix.isEmpty ? nil : prefix }
    }
    private let prefixLabel = UILabel()

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

    private func updateStyle() {
        layer.borderColor = (allowsEditing ? UIColor.systemBlue : UIColor.systemGray3).cgColor
        isUserInteractionEnabled = allowsEditing
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = (self.text ?? "") as NSString
        let width = text.size(withAttributes: [.font: font ?? UIFont.systemFont(ofSize: 15)]).width
        let prefixWidth = prefix.isEmpty ? 0 : prefixLabel.intrinsicContentSize.width + 2
        return CGSize(width: max(width + prefixWidth + 22, 46), height: 30)
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

/// Kleines Ziffernfeld für Maße (schwebt neben dem Maß statt der großen Bildschirmtastatur).
final class DimensionKeypad: UIView {
    enum Key {
        case digit(String)
        case delete, clear, cancel, done
    }

    var onKey: (Key) -> Void = { _ in }

    private static let keySize = CGSize(width: 48, height: 42)
    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 8

    /// Zeilen: Titel und Taste; „✓“ in der letzten Zeile doppelt breit
    private static let rows: [[(String, Key)]] = [
        [("7", .digit("7")), ("8", .digit("8")), ("9", .digit("9")), ("⌫", .delete)],
        [("4", .digit("4")), ("5", .digit("5")), ("6", .digit("6")), ("C", .clear)],
        [("1", .digit("1")), ("2", .digit("2")), ("3", .digit("3")), ("✕", .cancel)],
        [(",", .digit(",")), ("0", .digit("0")), ("✓", .done)],
    ]

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
        for row in Self.rows {
            let line = UIStackView()
            line.axis = .horizontal
            line.spacing = Self.spacing
            for (title, key) in row {
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
                var isDone = false
                if case .done = key { isDone = true }
                var isAction = isDone
                switch key {
                case .delete, .clear, .cancel: isAction = true
                default: break
                }
                button.backgroundColor = isDone ? .systemBlue
                    : isAction ? .tertiarySystemFill : .secondarySystemBackground
                button.setTitleColor(isDone ? .white : .label, for: .normal)
                button.layer.cornerRadius = 10
                let width = isDone ? Self.keySize.width * 2 + Self.spacing : Self.keySize.width
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
                button.heightAnchor.constraint(equalToConstant: Self.keySize.height).isActive = true
                button.addAction(UIAction { [weak self] _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self?.onKey(key)
                }, for: .touchUpInside)
                line.addArrangedSubview(button)
            }
            stack.addArrangedSubview(line)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht verwendet")
    }

    // Berührungen neben den Tasten nicht an den Viewport weiterreichen (sonst begänne dort ein Strich)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: Self.keySize.width * 4 + Self.spacing * 3 + Self.padding * 2,
               height: Self.keySize.height * 4 + Self.spacing * 3 + Self.padding * 2)
    }
}
