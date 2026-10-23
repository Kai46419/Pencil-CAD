import MetalKit
import SwiftUI

/// Einmalige Kamerabefehle aus der Oberfläche. Eine neue id löst den Befehl aus.
struct ViewCommand: Equatable {
    enum Kind {
        case alignToSketchPlane
        case fitAll
    }

    var id = 0
    var kind: Kind = .fitAll
}

/// 3D-Ansicht. Finger navigieren (1 Finger drehen, 2 Finger verschieben, Pinch zoomen, tippen wählt Fläche).
/// Der Apple Pencil skizziert, wenn der Skizzenmodus aktiv ist.
struct Viewport: UIViewRepresentable {
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController
    let command: ViewCommand

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
        view.model = model
        view.sketch = sketch
        return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.meshRevision != model.revision {
            coordinator.meshRevision = model.revision
            coordinator.renderer?.update(mesh: model.mesh)
            coordinator.selectionRevision = -1
        }
        if coordinator.selectionRevision != model.selectionRevision {
            coordinator.selectionRevision = model.selectionRevision
            coordinator.renderer?.updateSelection(indices: model.selectionIndices)
        }
        if coordinator.commandID != command.id {
            coordinator.commandID = command.id
            view.run(command.kind)
        }
        view.sketchStateChanged()
    }
}

final class ViewportView: MTKView, UIGestureRecognizerDelegate {
    weak var renderer: Renderer?
    weak var model: ModelStore?
    weak var sketch: SketchController?

    private var orbitGesture: UIPanGestureRecognizer?
    private var tapGesture: UITapGestureRecognizer?
    private var sketchTouch: UITouch?

    private let fingersOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    private let fingersAndPencil = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                    NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setUpGestures()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setUpGestures()
    }

    private func setUpGestures() {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit))
        orbit.maximumNumberOfTouches = 1
        orbit.allowedTouchTypes = fingersOnly

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 2
        pan.allowedTouchTypes = fingersOnly
        pan.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.allowedTouchTypes = fingersOnly
        pinch.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = fingersAndPencil

        [orbit, pan, pinch, tap].forEach(addGestureRecognizer)
        orbitGesture = orbit
        tapGesture = tap
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
        }
        setNeedsDisplay()
    }

    // MARK: Skizze

    /// Gleicht Renderer und Gesten mit dem Skizzenzustand ab.
    func sketchStateChanged() {
        guard let sketch else { return }
        let fingerSketching = sketch.isActive && sketch.fingerDraws
        orbitGesture?.isEnabled = !fingerSketching
        tapGesture?.isEnabled = !fingerSketching
        tapGesture?.allowedTouchTypes = sketch.isActive ? fingersOnly : fingersAndPencil

        let plane = sketch.plane
        renderer?.gridTransform = sketch.isActive
            ? float4x4(origin: SIMD3<Float>(plane.origin), u: SIMD3<Float>(plane.u),
                       v: SIMD3<Float>(plane.v), n: SIMD3<Float>(plane.normal))
            : matrix_identity_float4x4
        let points = sketch.isActive ? sketch.segments.map { SIMD3<Float>(plane.world($0)) } : []
        renderer?.updateSketch(points: points)
        setNeedsDisplay()
    }

    private func acceptsForSketch(_ touch: UITouch) -> Bool {
        guard let sketch, sketch.isActive else { return false }
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard sketchTouch == nil, let touch = touches.first(where: acceptsForSketch),
              let point = sketchPoint(for: touch) else {
            super.touchesBegan(touches, with: event)
            return
        }
        sketchTouch = touch
        sketch?.began(at: point, tolerance: snapTolerance)
        sketchStateChanged()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        if let point = sketchPoint(for: touch) {
            sketch?.moved(to: point, tolerance: snapTolerance)
            sketchStateChanged()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        sketchStateChanged()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = sketchTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        sketchTouch = nil
        sketch?.cancelStroke()
        sketchStateChanged()
    }

    // MARK: Gesten

    /// Tippen wählt eine Fläche. Im Skizzenmodus wird eine ebene Fläche zur Skizzenebene,
    /// Tippen ins Leere setzt die Skizze auf die Bodenebene zurück.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let renderer, let model, let sketch,
              let ray = renderer.camera.ray(through: gesture.location(in: self), viewSize: bounds.size) else { return }
        let hit = model.pick(origin: ray.origin, direction: ray.direction)

        if sketch.isActive {
            guard let hit else {
                sketch.plane = .ground
                sketchStateChanged()
                return
            }
            if let plane = model.plane(of: hit.face) {
                sketch.plane = plane
                model.message = nil
            } else {
                model.message = "Auf gekrümmten Flächen kann nicht skizziert werden."
            }
            sketchStateChanged()
        } else {
            model.select(hit?.face)
        }
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
        gesture.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        renderer?.camera.pan(dx: Float(t.x), dy: Float(t.y), viewHeight: Float(bounds.height))
        gesture.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        renderer?.camera.zoom(by: Float(gesture.scale))
        gesture.scale = 1
        setNeedsDisplay()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
