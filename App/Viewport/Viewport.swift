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
        if renderer?.camera.isOrthographic != workspace.isOrthographic {
            renderer?.camera.isOrthographic = workspace.isOrthographic
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
    private var previewKey = ""
    private let valueLabel = PaddedLabel()
    private var planeLabels: [PaddedLabel] = []

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

        for recognizer in [orbit, pan, pinch, tap] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
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
            renderer.camera.look(along: normal, at: target)
        case .fitAll:
            if let bounds = model?.mesh.bounds {
                renderer.camera.frame(min: bounds.min, max: bounds.max)
            }
        case .look(let normal):
            renderer.camera.look(along: normal, at: renderer.camera.target)
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

    /// Gleicht Renderer, Gesten, Ziehpfeile und Vorschau mit dem Zustand ab.
    func refresh() {
        guard let renderer, let sketch, let workspace else { return }
        let choosing = sketch.isActive && sketch.isChoosingPlane
        let fingerSketching = sketch.isActive && sketch.fingerDraws && !choosing
        orbitGesture?.isEnabled = !fingerSketching
        tapGesture?.isEnabled = !fingerSketching
        tapGesture?.allowedTouchTypes = sketch.isActive && !choosing ? fingersOnly : fingersAndPencil

        let plane = sketch.plane
        renderer.gridTransform = sketch.isActive && !choosing
            ? float4x4(origin: SIMD3<Float>(plane.origin), u: SIMD3<Float>(plane.u),
                       v: SIMD3<Float>(plane.v), n: SIMD3<Float>(plane.normal))
            : matrix_identity_float4x4
        let points = sketch.isActive && !choosing ? sketch.segments.map { SIMD3<Float>(plane.world($0)) } : []
        renderer.updateSketch(points: points)
        refreshExtrusionPreview()
        refreshPlanes()

        let handles = workspace.handles
        renderer.handles = handles.map { HandleGraphic(base: $0.base, direction: $0.pointing, color: $0.color) }
        updateValueLabel(handles)
        setNeedsDisplay()
    }

    private func refreshExtrusionPreview() {
        guard let renderer, let sketch else { return }
        guard sketch.isActive, sketch.hasProfile, sketch.extrudeDistance != 0 else {
            if !previewKey.isEmpty {
                previewKey = ""
                renderer.updatePreview(nil, filled: false)
            }
            return
        }
        let key = "\(sketch.geometryRevision)|\(sketch.extrudeDistance)|\(sketch.extrudeMode.rawValue)"
        guard key != previewKey else { return }
        previewKey = key
        let mesh = sketch.extrusion(distance: sketch.extrudeDistance, mode: sketch.extrudeMode)
            .map { Mesh($0.triangulate(deflection: 0.05), body: -1) }
        renderer.updatePreview(mesh, filled: sketch.extrudeMode != .cut)
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

    /// Ebenenwahl: drei antippbare Scheiben. Beim Skizzieren: Scheibe der aktiven Ebene.
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
        } else if sketch.isActive {
            let plane = sketch.plane
            let center = SIMD3<Float>(plane.origin + plane.u * simd_dot(plane.anchor - plane.origin, plane.u)
                                      + plane.v * simd_dot(plane.anchor - plane.origin, plane.v))
            let size = plane.isOnFace ? max(15, half * 0.5) : half
            graphics.append(PlaneGraphic(center: center, u: SIMD3<Float>(plane.u), v: SIMD3<Float>(plane.v),
                                         halfSize: size, color: SIMD3(0.25, 0.5, 0.95)))
            labels.append((plane.name,
                           center + (SIMD3<Float>(plane.u) * -0.85 + SIMD3<Float>(plane.v) * 0.85) * size))
        }
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
        guard let renderer, let sketch else { return nil }
        let plane = sketch.plane
        let hit = renderer.camera.intersect(screenPoint: touch.location(in: self), viewSize: bounds.size,
                                            planeOrigin: SIMD3<Float>(plane.origin),
                                            planeNormal: SIMD3<Float>(plane.normal))
        return hit.map { plane.local(SIMD3<Double>($0)) }
    }

    /// Fangradius: etwa 20 Bildschirmpunkte in Weltmaß.
    private var snapTolerance: Double {
        Double((renderer?.camera.worldUnitsPerPoint(viewHeight: Float(bounds.height)) ?? 0.1) * 20)
    }

    /// Wie bei Shapr3D: Der erste Strich legt die Skizzenebene fest. Beginnt er auf einer ebenen Fläche,
    /// wird auf dieser Fläche gezeichnet, beginnt er im Leeren, auf der Bodenebene.
    /// Gibt false zurück, wenn der Strich auf einer gekrümmten Fläche beginnt.
    private func choosePlane(for touch: UITouch) -> Bool {
        guard let renderer, let model, let sketch, sketch.isEmpty,
              let ray = renderer.camera.ray(through: touch.location(in: self), viewSize: bounds.size) else { return true }
        guard let hit = model.pick(origin: ray.origin, direction: ray.direction) else {
            if sketch.plane.isOnFace {
                sketch.useBasePlane()
            }
            return true
        }
        guard let plane = model.plane(of: hit.face) else {
            model.message = "Auf gekrümmten Flächen kann nicht skizziert werden. Auf einer ebenen Fläche oder im Leeren beginnen."
            return false
        }
        model.message = nil
        let samePlane = sketch.plane.isOnFace
            && simd_distance(sketch.plane.normal, plane.normal) < 1e-6
            && simd_distance(sketch.plane.origin, plane.origin) < 1e-6
        if !samePlane {
            sketch.plane = plane
        }
        return true
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
              choosePlane(for: touch),
              let point = sketchPoint(for: touch) else {
            super.touchesBegan(touches, with: event)
            return
        }
        sketchTouch = touch
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
        workspace.tapped(face: hit?.face, edge: edge)
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

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
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
