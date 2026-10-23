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
    private var tapGesture: UITapGestureRecognizer?
    private var sketchTouch: UITouch?
    private var handleDrag: HandleDragState?
    private let valueLabel = PaddedLabel()
    private var planeLabels: [PaddedLabel] = []
    private var dimensionFields: [SketchDimension.Kind: DimensionField] = [:]
    /// Bereichsfüllungen der aktuellen Skizze, neu berechnet nur bei geänderter Geometrie.
    private var sketchFillRevision = -1
    private var sketchFills: [[SIMD3<Float>]] = []
    private var needsSync = true

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

        for recognizer in [orbit, pan, pinch, tap, hover] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        // Drücken (Apple Pencil Pro) bzw. Doppeltippen öffnet das Werkzeugrad
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        orbitGesture = orbit
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
        orbitGesture?.isEnabled = !fingerSketching
        tapGesture?.isEnabled = !fingerSketching
        tapGesture?.allowedTouchTypes = sketching ? fingersOnly : fingersAndPencil

        let plane = sketch.plane
        renderer.gridTransform = sketching
            ? float4x4(origin: SIMD3<Float>(plane.origin), u: SIMD3<Float>(plane.u),
                       v: SIMD3<Float>(plane.v), n: SIMD3<Float>(plane.normal))
            : matrix_identity_float4x4
        updateLines()
        refreshPlanes()

        let handles = workspace.handles
        renderer.handles = handles.map { HandleGraphic(base: $0.base, direction: $0.pointing, color: $0.color) }
        updateValueLabel(handles)
        updateDimensionFields()
    }

    // MARK: Linien und Bereiche

    private static let sketchInk = SIMD3<Float>(0.05, 0.06, 0.09)
    private static let previewBlue = SIMD3<Float>(0.05, 0.4, 0.98)
    private static let snapOrange = SIMD3<Float>(0.98, 0.45, 0.05)

    /// Skizzenlinien (dick, immer sichtbar), gespeicherte Skizzen, Fangsymbole, Knoten und Bereichsfüllungen.
    private func updateLines() {
        guard let renderer, let sketch, let model, let workspace else { return }
        let sketching = sketch.isActive && !sketch.isChoosingPlane
        var groups: [LineGroup] = []
        var fills: [FillGroup] = []

        for (index, stored) in model.sketches.enumerated() where !stored.isHidden {
            if sketch.isActive, index == workspace.editingSketchIndex { continue }
            groups.append(LineGroup(polylines: stored.lines,
                                    color: sketching ? SIMD3(0.36, 0.38, 0.44) : SIMD3(0.12, 0.14, 0.2),
                                    width: 1.8, onTop: false))
            guard !sketch.isActive else { continue }
            for (region, triangles) in stored.fills.enumerated() {
                let selected = model.selectedRegions.contains(RegionRef(sketch: index, region: region))
                fills.append(FillGroup(triangles: triangles,
                                       color: selected ? SIMD4(0.1, 0.42, 0.98, 0.5) : SIMD4(0.2, 0.45, 0.95, 0.14)))
            }
        }

        if sketching {
            let plane = sketch.plane
            let world = { (p: Point2) in SIMD3<Float>(plane.world(p)) }
            if sketchFillRevision != sketch.geometryRevision {
                sketchFillRevision = sketch.geometryRevision
                sketchFills = sketch.regions.map { regionTriangles($0, plane: plane) }
            }
            fills += sketchFills.map { FillGroup(triangles: $0, color: SIMD4(0.2, 0.45, 0.95, 0.16)) }
            groups.append(LineGroup(polylines: sketch.entityPolylines.map { $0.map(world) }, color: Self.sketchInk,
                                    width: 2.6))
            let preview = sketch.previewPolylines
            if !preview.isEmpty {
                groups.append(LineGroup(polylines: preview.map { $0.map(world) }, color: Self.previewBlue, width: 2.6))
            }
            let perPoint = Double(renderer.camera.worldUnitsPerPoint(viewHeight: Float(bounds.height)))
            if !sketch.hoverNodes.isEmpty {
                groups.append(LineGroup(polylines: [], color: Self.previewBlue, width: 0,
                                        dots: sketch.hoverNodes.map(world), dotRadius: 3.5))
            }
            if let snap = sketch.currentSnap, let kind = snap.kind {
                let guides = snap.guides.flatMap { dashed($0.0, $0.1, dash: 5 * perPoint) }
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

    /// Gestrichelte Hilfslinie als einzelne Striche.
    private func dashed(_ a: Point2, _ b: Point2, dash: Double) -> [[Point2]] {
        let length = simd_distance(a, b)
        guard length > 1e-9, dash > 0 else { return [] }
        let d = (b - a) / length
        var result: [[Point2]] = []
        var t = 0.0
        while t < length, result.count < 300 {
            result.append([a + d * t, a + d * min(t + dash, length)])
            t += dash * 2
        }
        return result
    }

    // MARK: Maße am Element

    /// Maße des Elements beim Aufziehen (nur Anzeige) und danach als Eingabefelder direkt am Element.
    private func updateDimensionFields() {
        guard let renderer, let sketch else { return }
        let dimensions = sketch.isActive && !sketch.isChoosingPlane ? sketch.dimensions : []
        let plane = sketch.plane
        let perPoint = Double(renderer.camera.worldUnitsPerPoint(viewHeight: Float(bounds.height)))
        var shown = Set<SketchDimension.Kind>()
        for dimension in dimensions {
            let field = dimensionFields[dimension.kind] ?? makeDimensionField(dimension.kind)
            let anchorWorld = SIMD3<Float>(plane.world(dimension.position))
            let tipWorld = SIMD3<Float>(plane.world(dimension.position + dimension.direction * perPoint * 10))
            guard let anchor = renderer.camera.project(anchorWorld, viewSize: bounds.size),
                  let tip = renderer.camera.project(tipWorld, viewSize: bounds.size) else { continue }
            shown.insert(dimension.kind)
            field.isEditable = dimension.isEditable
            field.prefix = dimension.prefix
            if !field.isFirstResponder {
                field.text = dimension.value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
            }
            field.sizeToFit()
            var dx = tip.x - anchor.x, dy = tip.y - anchor.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1e-6)
            dx /= length
            dy /= length
            // Etikett neben das Element setzen, Abstand passend zur Größe des Felds
            let distance = 10 + abs(dx) * field.bounds.width / 2 + abs(dy) * field.bounds.height / 2
            field.center = CGPoint(x: anchor.x + dx * distance, y: anchor.y + dy * distance)
            field.isHidden = false
        }
        for (kind, field) in dimensionFields where !shown.contains(kind) {
            if field.isFirstResponder {
                field.appliesOnEnd = false
                field.resignFirstResponder()
            }
            field.isHidden = true
        }
    }

    private func makeDimensionField(_ kind: SketchDimension.Kind) -> DimensionField {
        let field = DimensionField(kind: kind)
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        dimensionFields[kind] = field
        return field
    }

    private func apply(_ field: DimensionField) {
        let text = (field.text ?? "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(text), value > 0 else { return }
        sketch?.setDimension(field.kind, to: value)
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

    /// Ebenenwahl: drei antippbare Scheiben.
    private func refreshPlanes() {
        guard let renderer, let sketch else { return }
        let half = planeHalfSize
        var graphics: [PlaneGraphic] = []
        var labels: [(text: String, position: SIMD3<Float>)] = []
        if sketch.isActive, sketch.isChoosingPlane {
            for (index, plane) in Self.basePlanes.enumerated() {
                graphics.append(PlaneGraphic(center: .zero, u: plane.u, v: plane.v, halfSize: half,
                                             color: SIMD3(0.35, 0.55, 0.95)))
                labels.append((facingSide(ofBasePlane: index).rawValue, (plane.u + plane.v) * half * 0.8))
            }
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

    /// Getroffene Standardebene (vorderste Scheibe unter dem Finger) und Abstand entlang des Sehstrahls.
    private func basePlaneHit(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>)) -> (side: BasePlane, t: Float)? {
        let half = planeHalfSize
        var best: (side: BasePlane, t: Float)?
        for (index, plane) in Self.basePlanes.enumerated() {
            let denominator = simd_dot(ray.direction, plane.normal)
            guard abs(denominator) > 1e-6 else { continue }
            let t = -simd_dot(ray.origin, plane.normal) / denominator
            guard t > 0, t < (best?.t ?? .infinity) else { continue }
            let p = ray.origin + t * ray.direction
            guard abs(simd_dot(p, plane.u)) <= half, abs(simd_dot(p, plane.v)) <= half else { continue }
            best = (facingSide(ofBasePlane: index), t)
        }
        return best
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
        let length = Renderer.handleLength * renderer.camera.worldUnitsPerPoint(at: active.base,
                                                                                viewHeight: Float(bounds.height))
        guard let tip = renderer.camera.project(active.base + active.pointing * length * 1.25, viewSize: bounds.size) else {
            valueLabel.isHidden = true
            return
        }
        valueLabel.text = "\(active.value.formatted(.number.precision(.fractionLength(0...2)))) mm"
        valueLabel.sizeToFit()
        valueLabel.center = tip
        valueLabel.isHidden = false
    }

    // MARK: Ziehpfeile

    private func handleHit(at point: CGPoint) -> DragHandle? {
        guard let renderer, let workspace else { return nil }
        var best: (distance: CGFloat, handle: DragHandle)?
        for handle in workspace.handles {
            let length = Renderer.handleLength * renderer.camera.worldUnitsPerPoint(at: handle.base,
                                                                                    viewHeight: Float(bounds.height))
            guard let a = renderer.camera.project(handle.base, viewSize: bounds.size),
                  let b = renderer.camera.project(handle.base + handle.pointing * length, viewSize: bounds.size) else {
                continue
            }
            let distance = point.distance(toSegment: a, b)
            if distance <= 30, distance < (best?.distance ?? .infinity) {
                best = (distance, handle)
            }
        }
        return best?.handle
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
        return [0.1, 0.5, 1, 5, 10].first { $0 >= perPoint * 3 } ?? 10
    }

    // MARK: Skizze

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
        if handleDrag == nil,
           let touch = touches.first(where: { $0.type == .pencil || $0.type == .direct }),
           let handle = handleHit(at: touch.location(in: self)),
           let parameter = axisParameter(at: touch.location(in: self), handle: handle) {
            handleDrag = HandleDragState(touch: touch, handle: handle, startParameter: parameter,
                                         step: dragStep(at: handle.base))
            return
        }
        guard sketchTouch == nil, let touch = touches.first(where: acceptsForSketch),
              let point = sketchPoint(for: touch) else {
            super.touchesBegan(touches, with: event)
            return
        }
        sketchTouch = touch
        // Ein offenes Maßfeld gehört zum vorigen Element: verwerfen statt auf das neue anwenden
        for field in dimensionFields.values where field.isFirstResponder {
            field.appliesOnEnd = false
            field.resignFirstResponder()
        }
        sketch?.began(at: point, tolerance: snapTolerance)
        refresh()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let drag = handleDrag, touches.contains(drag.touch) {
            if let parameter = axisParameter(at: drag.touch.location(in: self), handle: drag.handle) {
                let raw = drag.handle.value + Double(parameter - drag.startParameter)
                let snapped = (raw / drag.step).rounded() * drag.step
                workspace?.apply(drag.handle.kind, value: snapped)
                refresh()
            }
            return
        }
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        if let point = sketchPoint(for: touch) {
            sketch?.moved(to: point, tolerance: snapTolerance)
            refresh()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let drag = handleDrag, touches.contains(drag.touch) {
            handleDrag = nil
            refresh()
            return
        }
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        sketchTouch = nil
        if let point = sketchPoint(for: touch) {
            sketch?.ended(at: point, tolerance: snapTolerance)
        } else {
            sketch?.cancelStroke()
        }
        refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let drag = handleDrag, touches.contains(drag.touch) {
            handleDrag = nil
            refresh()
            return
        }
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        sketchTouch = nil
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
        let edge = pickEdge(at: location, ray: ray, faceHit: hit)
        // Skizzenbereich vor der Fläche, auf der er liegt
        var region: RegionRef?
        if edge == nil, let regionHit = model.pickRegion(origin: ray.origin, direction: ray.direction) {
            let faceT = hit.map { simd_dot($0.point - ray.origin, ray.direction) } ?? .infinity
            if regionHit.t <= faceT + max(faceT * 0.002, 0.05) {
                region = regionHit.ref
            }
        }
        workspace.tapped(face: hit?.face, edge: edge, region: region)
    }

    /// Ebenenwahl: vorderste Standardebene oder ebene Körperfläche unter dem Finger.
    private func chooseSketchPlane(ray: (origin: SIMD3<Float>, direction: SIMD3<Float>),
                                   faceHit: (face: FaceRef, point: SIMD3<Float>)?) {
        guard let model, let workspace else { return }
        let planeHit = basePlaneHit(ray: ray)
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
                          faceHit: (face: FaceRef, point: SIMD3<Float>)?) -> EdgeRef? {
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
        return found.edge
    }

    /// Während ein Ziehpfeil gezogen wird, drehen und wählen die Finger nicht.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if handleDrag != nil, gestureRecognizer === orbitGesture || gestureRecognizer === tapGesture {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Schwebender Stift: Fangpunkt und Knoten zeigen, beim Linienzug schon das nächste Stück.
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let sketch else { return }
        switch gesture.state {
        case .began, .changed:
            guard sketch.isActive, !sketch.isChoosingPlane, sketchTouch == nil,
                  let point = sketchPoint(at: gesture.location(in: self)) else { return }
            sketch.hover(at: point, tolerance: snapTolerance)
        default:
            sketch.endHover()
        }
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
        !(touch.view is UITextField)
    }
}

extension ViewportView: UITextFieldDelegate {
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        (textField as? DimensionField)?.isEditable ?? false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        (textField as? DimensionField)?.appliesOnEnd = true
        textField.selectAll(nil)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let field = textField as? DimensionField, field.appliesOnEnd else { return }
        apply(field)
    }
}

extension ViewportView: UIPencilInteractionDelegate {
    /// Apple Pencil Pro: Drücken öffnet das Werkzeugrad (sofern in den Einstellungen nicht abgeschaltet).
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        showQuickTools(at: squeeze.hoverPose?.location)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        showQuickTools(at: tap.hoverPose?.location)
    }

    /// Ältere Systeme: Doppeltippen auf den Apple Pencil (2. Gen.).
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        showQuickTools(at: nil)
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
    let kind: SketchDimension.Kind
    /// false, wenn das Feld geschlossen wird, weil sein Element nicht mehr das aktuelle ist.
    var appliesOnEnd = true
    var isEditable = false {
        didSet { updateStyle() }
    }
    var prefix = "" {
        didSet { prefixLabel.text = prefix.isEmpty ? nil : prefix }
    }
    private let prefixLabel = UILabel()

    init(kind: SketchDimension.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        textAlignment = .center
        keyboardType = .decimalPad
        returnKeyType = .done
        autocorrectionType = .no
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
        layer.borderColor = (isEditable ? UIColor.systemBlue : UIColor.systemGray3).cgColor
        isUserInteractionEnabled = isEditable
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
