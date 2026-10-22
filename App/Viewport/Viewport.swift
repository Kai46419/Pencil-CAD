import MetalKit
import SwiftUI

/// 3D-Ansicht. Finger navigieren (1 Finger drehen, 2 Finger verschieben, Pinch zoomen).
/// Der Apple Pencil skizziert, wenn der Skizzenmodus aktiv ist.
struct Viewport: UIViewRepresentable {
    let mesh: Mesh
    let revision: Int
    @ObservedObject var sketch: SketchController

    final class Coordinator {
        var renderer: Renderer?
        var revision = -1
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
        view.sketch = sketch
        return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            context.coordinator.renderer?.update(mesh: mesh)
        }
        view.sketchStateChanged()
    }
}

final class ViewportView: MTKView, UIGestureRecognizerDelegate {
    weak var renderer: Renderer?
    weak var sketch: SketchController?

    private var orbitGesture: UIPanGestureRecognizer?
    private var sketchTouch: UITouch?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setUpGestures()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setUpGestures()
    }

    private func setUpGestures() {
        let fingersOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

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

        [orbit, pan, pinch].forEach(addGestureRecognizer)
        orbitGesture = orbit
    }

    // MARK: Skizze

    /// Gleicht Renderer und Gesten mit dem Skizzenzustand ab.
    func sketchStateChanged() {
        guard let sketch else { return }
        orbitGesture?.isEnabled = !(sketch.isActive && sketch.fingerDraws)
        renderer?.gridZ = Float(sketch.planeZ)
        renderer?.updateSketch(segments: sketch.isActive ? sketch.segments : [], z: sketch.planeZ)
        setNeedsDisplay()
    }

    private func acceptsForSketch(_ touch: UITouch) -> Bool {
        guard let sketch, sketch.isActive else { return false }
        return touch.type == .pencil || (sketch.fingerDraws && touch.type == .direct)
    }

    private func sketchPoint(for touch: UITouch) -> SIMD2<Double>? {
        guard let renderer, let sketch else { return nil }
        let hit = renderer.camera.intersect(screenPoint: touch.location(in: self), viewSize: bounds.size,
                                            planeZ: Float(sketch.planeZ))
        return hit.map { SIMD2(Double($0.x), Double($0.y)) }
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
