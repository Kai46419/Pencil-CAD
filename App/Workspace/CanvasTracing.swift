import SwiftUI
import Vision
import simd

// Foto nachzeichnen (Vorbild Shapr3D/Fusion 360 „Canvas kalibrieren“): Maßstab über zwei angetippte Punkte und
// ein echtes Maß einstellen, Umrisse mit Vision erkennen und als Skizze auf der Bildebene übernehmen.

/// Laufendes Kalibrieren eines Bilds: angetippte Punkte (lokal in der Bildebene, mm).
struct CanvasCalibration: Equatable {
    var canvas: UUID
    var points: [Point2] = []
}

extension Workspace {
    // MARK: Maßstab kalibrieren

    func startCalibration(_ canvas: UUID) {
        canvasCalibration = CanvasCalibration(canvas: canvas)
        model.message = "Zwei Punkte auf dem Bild antippen, deren echten Abstand du kennst – mit dem Stift ziehen "
            + "zeigt eine Lupe, der Punkt sitzt beim Absetzen."
    }

    func cancelCalibration() {
        canvasCalibration = nil
    }

    /// Bild, das gerade kalibriert wird.
    var calibrationCanvas: CanvasImage? {
        guard let calibration = canvasCalibration else { return nil }
        return model.canvases.first { $0.id == calibration.canvas }
    }

    /// Schnitt des Sehstrahls mit der Bildebene (lokal, mm); nil, wenn die Ebene von der Seite zu sehen ist.
    func calibrationPoint(origin: SIMD3<Double>, direction: SIMD3<Double>) -> Point2? {
        guard let canvas = calibrationCanvas else { return nil }
        let frame = SketchPlane.base(canvas.plane)
        let denominator = simd_dot(direction, frame.normal)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = simd_dot(frame.origin - origin, frame.normal) / denominator
        return frame.local(origin + direction * t)
    }

    /// Angetippter Punkt auf der Bildebene (Sehstrahl aus dem Viewport).
    func calibrationTapped(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        guard var calibration = canvasCalibration, calibrationCanvas != nil else {
            canvasCalibration = nil
            return
        }
        guard let local = calibrationPoint(origin: origin, direction: direction) else {
            model.message = "Die Bildebene ist von der Seite zu sehen – Ansicht drehen."
            return
        }
        if calibration.points.count >= 2 { calibration.points = [] }
        calibration.points.append(local)
        canvasCalibration = calibration
        model.message = calibration.points.count == 1 ? "Zweiten Punkt antippen."
            : "Echtes Maß eingeben – das Bild wird passend skaliert."
    }

    /// Angetippte Punkte in Weltkoordinaten (zum Zeichnen im Viewport).
    var calibrationWorldPoints: [SIMD3<Double>]? {
        guard let calibration = canvasCalibration, !calibration.points.isEmpty,
              let canvas = model.canvases.first(where: { $0.id == calibration.canvas }) else { return nil }
        let frame = SketchPlane.base(canvas.plane)
        return calibration.points.map { frame.world($0) }
    }

    /// Gemessener Abstand der beiden Punkte (mm, im jetzigen Maßstab).
    var calibrationDistance: Double? {
        guard let points = canvasCalibration?.points, points.count == 2 else { return nil }
        let d = simd_distance(points[0], points[1])
        return d > 1e-9 ? d : nil
    }

    /// Bild so skalieren, dass der Abstand der beiden Punkte length (mm) beträgt. Der erste Punkt bleibt stehen.
    func applyCalibration(length: Double) {
        guard let calibration = canvasCalibration, let measured = calibrationDistance, length > 0,
              var canvas = model.canvases.first(where: { $0.id == calibration.canvas }) else { return }
        let factor = length / measured
        let anchor = calibration.points[0]
        canvas.width *= factor
        canvas.offset = anchor + (canvas.offset - anchor) * factor
        // Danach sperren, damit das Foto beim Daraufkonstruieren nicht verrutscht
        canvas.isLocked = true
        model.commitCanvas(canvas, name: "\(canvas.name) kalibrieren")
        canvasCalibration = nil
        model.message = "\(canvas.name): Maßstab eingestellt und gesperrt, Breite jetzt "
            + "\(LengthUnit.current.format(canvas.width)). Jetzt in Originalgröße daraufkonstruieren."
    }

    // MARK: Kontur erkennen

    /// Umrisse im Bild erkennen (Vision) und als neue Skizze auf der Bildebene einfügen.
    /// darkOnLight: dunkle Formen auf hellem Grund (z. B. Zeichnung auf Papier), sonst helle auf dunklem.
    func detectContours(_ id: UUID, darkOnLight: Bool = true) {
        guard let canvas = model.canvases.first(where: { $0.id == id }), let url = model.canvasURL(canvas) else { return }
        model.message = "Kontur wird erkannt …"
        Task.detached(priority: .userInitiated) { [weak self] in
            let loops = CanvasContours.detect(url: url, darkOnLight: darkOnLight)
            await self?.storeContours(loops, canvas: canvas)
        }
    }

    private func storeContours(_ loops: [[Point2]], canvas: CanvasImage) {
        guard !loops.isEmpty else {
            model.message = "Keine deutliche Kontur gefunden – Bild mit mehr Kontrast versuchen oder lange drücken für „Helle Formen“."
            return
        }
        // Normierte Bildkoordinaten (0…1, Ursprung links unten) → Bildebene (mm)
        let w = canvas.width, h = canvas.width * canvas.aspect
        let place = { (p: Point2) in canvas.offset + Point2((p.x - 0.5) * w, (p.y - 0.5) * h) }
        let entities = loops.compactMap { loop -> SketchEntity? in
            CanvasContours.entity(loop.map(place), tolerance: max(w, h) * 0.004)
        }
        guard !entities.isEmpty else { return }
        if sketch.isActive { finishSketch() }
        model.storeSketch(plane: .base(canvas.plane), entities: entities, replacing: nil)
        model.message = "Kontur aus „\(canvas.name)“: \(entities.count) Kurve\(entities.count == 1 ? "" : "n") als neue Skizze – zum Nachbessern bearbeiten."
    }
}

/// Umrisse mit Vision (VNDetectContoursRequest) finden und vereinfachen.
enum CanvasContours {
    /// Geschlossene Umrisse in normierten Bildkoordinaten (Ursprung links unten, dicht), größte zuerst.
    static func detect(url: URL, darkOnLight: Bool) -> [[Point2]] {
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false))?.cgImage else { return [] }
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.5
        request.detectsDarkOnLight = darkOnLight
        request.maximumImageDimension = 1024
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observation = (request.results as? [VNContoursObservation])?.first else { return [] }
        var loops: [(area: Double, points: [Point2])] = []
        for index in 0..<min(observation.contourCount, 2000) {
            guard let contour = try? observation.contour(at: index), contour.pointCount >= 8 else { continue }
            // Pixelstufen glätten, sehr lange Umrisse ausdünnen; vereinfacht wird beim Übernehmen (entity)
            var points = SplineFit.cleaned(contour.normalizedPoints.map { Point2(Double($0.x), Double($0.y)) })
            if points.count >= 2, simd_distance(points[0], points[points.count - 1]) < 1e-6 { points.removeLast() }
            guard points.count >= 3 else { continue }
            let lo = points.reduce(points[0]) { simd_min($0, $1) }, hi = points.reduce(points[0]) { simd_max($0, $1) }
            let size = hi - lo
            // Bildrand und Krümel weglassen
            if size.x > 0.98 && size.y > 0.98 { continue }
            if max(size.x, size.y) < 0.03 { continue }
            loops.append((abs(signedArea(points)), points))
        }
        return loops.sorted { $0.area > $1.area }.prefix(40).map { $0.points }
    }

    /// Umriss als Skizzenelement: eckige Formen (wenige Punkte) als Linienzug, runde als geglättete Spline.
    static func entity(_ points: [Point2], tolerance: Double) -> SketchEntity? {
        guard points.count >= 3 else { return nil }
        let corners = SplineFit.simplifiedIndices(points + [points[0]], epsilon: tolerance * 1.5)
            .filter { $0 < points.count }.map { points[$0] }
        if corners.count <= 8 {
            return corners.count >= 3 ? .polyline(corners, closed: true) : nil
        }
        let fit = SplineFit.fit(points, closed: true, epsilon: tolerance)
        return fit.count >= 3 ? .spline(points: fit, kind: .fit, closed: true) : .polyline(corners, closed: true)
    }
}

/// Zusatzkarte im Bild-Werkzeug: Maßstab kalibrieren und Kontur erkennen.
struct CanvasTraceCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    let canvasID: UUID

    var body: some View {
        Card {
            HStack(spacing: 14) {
                if let calibration = workspace.canvasCalibration, calibration.canvas == canvasID {
                    calibrationControls(calibration)
                } else {
                    Button("Maßstab kalibrieren", systemImage: "ruler") { workspace.startCalibration(canvasID) }
                        .hoverTip("Maßstab kalibrieren", "Zwei Punkte auf dem Bild antippen und das echte Maß eingeben.")
                    Menu {
                        Button("Dunkle Formen auf hellem Grund", systemImage: "circle.fill") {
                            workspace.detectContours(canvasID, darkOnLight: true)
                        }
                        Button("Helle Formen auf dunklem Grund", systemImage: "circle") {
                            workspace.detectContours(canvasID, darkOnLight: false)
                        }
                    } label: {
                        Label("Kontur erkennen", systemImage: "wand.and.stars")
                    } primaryAction: {
                        workspace.detectContours(canvasID, darkOnLight: true)
                    }
                    .fixedSize()
                    .hoverTip("Kontur erkennen", "Umrisse im Bild werden zu einer Skizze auf der Bildebene. Lange drücken: helle Formen.")
                }
            }
        }
        .onDisappear {
            if workspace.canvasCalibration?.canvas == canvasID { workspace.cancelCalibration() }
        }
    }

    @ViewBuilder
    private func calibrationControls(_ calibration: CanvasCalibration) -> some View {
        Label(calibration.points.count < 2 ? "Punkt \(calibration.points.count + 1) auf dem Bild antippen" : "Echtes Maß",
              systemImage: "ruler")
            .font(.callout.weight(.semibold))
        if let measured = workspace.calibrationDistance {
            NumberField(title: "Abstand", value: measured, width: 80) { value in
                if value > 0 { workspace.applyCalibration(length: value) }
            }
        }
        Button("Abbrechen", systemImage: "xmark") { workspace.cancelCalibration() }
            .labelStyle(.iconOnly)
    }
}
