import Foundation
import simd

enum SketchTool: String, CaseIterable, Identifiable {
    case polyline = "Linie"
    case rectangle = "Rechteck"
    case circle = "Kreis"
    case ellipse = "Ellipse"
    case polygon = "Polygon"
    case arc = "Bogen"
    case spline = "Spline"
    case point = "Punkt"
    case text = "Text"
    case offset = "Versatz"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .polyline: "line.diagonal"
        case .rectangle: "rectangle"
        case .circle: "circle.circle"
        case .ellipse: "oval"
        case .polygon: "pentagon"
        case .arc: "point.topleft.down.curvedto.point.bottomright.up"
        case .spline: "scribble.variable"
        case .point: "smallcircle.filled.circle"
        case .text: "textformat"
        case .offset: "square.on.square.dashed"
        }
    }

    /// Untertitel in der Werkzeugleiste (Variante des Werkzeugs).
    var subtitle: String? {
        switch self {
        case .polyline: "Linienzug"
        case .rectangle: "Diagonal"
        case .arc: "Enden, dann Wölbung"
        case .spline: "Fit- oder Kontrollpunkte"
        case .text: "Schrift als Profil"
        case .offset: "Kurven versetzen"
        default: nil
        }
    }
}

/// Standardebenen durch den Ursprung. Die Normale zeigt zur Seite, von der aus man auf die Ebene blickt.
enum BasePlane: String, CaseIterable, Identifiable {
    case top = "Oben"
    case bottom = "Unten"
    case front = "Vorne"
    case back = "Hinten"
    case right = "Rechts"
    case left = "Links"

    var id: Self { self }

    var normal: SIMD3<Double> {
        switch self {
        case .top: [0, 0, 1]
        case .bottom: [0, 0, -1]
        case .front: [0, -1, 0]
        case .back: [0, 1, 0]
        case .right: [1, 0, 0]
        case .left: [-1, 0, 0]
        }
    }
}

/// Ebene im Raum mit lokalem 2D-Koordinatensystem (u, v) für die Skizze.
struct SketchPlane {
    var origin: SIMD3<Double>
    var u: SIMD3<Double>
    var v: SIMD3<Double>
    var normal: SIMD3<Double>
    /// true, wenn die Ebene auf einer Körperfläche liegt (Normale zeigt aus dem Material).
    var isOnFace: Bool
    /// Körper, auf dessen Fläche skizziert wird (Ziel für „Vereinigen“).
    var sourceBody: Int?
    /// Mitte der angezeigten Ebenenscheibe (bei Flächen ein Punkt der Fläche).
    var anchor: SIMD3<Double>
    /// Standardebene, falls die Skizze auf einer liegt.
    var base: BasePlane?

    static let ground = SketchPlane.base(.top)

    /// Standardebene, entlang der Normale um offset verschoben.
    static func base(_ side: BasePlane, offset: Double = 0) -> SketchPlane {
        var plane = SketchPlane(point: side.normal * offset, normal: side.normal, isOnFace: false)
        plane.base = side
        return plane
    }

    /// Ebene durch point mit Normale normal. Der Ursprung liegt dem Weltursprung am nächsten,
    /// damit das Raster bei achsparallelen Flächen auf ganzen Millimetern bleibt.
    /// u zeigt waagerecht, v bei senkrechten Ebenen nach oben.
    init(point: SIMD3<Double>, normal n: SIMD3<Double>, isOnFace: Bool, sourceBody: Int? = nil) {
        let normal = simd_normalize(n)
        let u: SIMD3<Double> = abs(normal.z) > 0.99
            ? [1, 0, 0]
            : simd_normalize(simd_cross(SIMD3<Double>(0, 0, 1), normal))
        self.init(origin: normal * simd_dot(point, normal), u: u, v: simd_cross(normal, u),
                  normal: normal, isOnFace: isOnFace)
        self.sourceBody = sourceBody
        anchor = point
    }

    init(origin: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>, normal: SIMD3<Double>, isOnFace: Bool) {
        self.origin = origin
        self.u = u
        self.v = v
        self.normal = normal
        self.isOnFace = isOnFace
        anchor = origin
    }

    var name: String { isOnFace ? "Fläche" : base?.rawValue ?? "Ebene" }

    func world(_ p: SIMD2<Double>) -> SIMD3<Double> {
        origin + p.x * u + p.y * v
    }

    func world(direction d: SIMD2<Double>) -> SIMD3<Double> {
        d.x * u + d.y * v
    }

    func local(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let d = p - origin
        return SIMD2(simd_dot(d, u), simd_dot(d, v))
    }

    /// Richtung eines positiven Extrusionswerts: „Abziehen“ auf einer Fläche geht ins Material.
    func extrusionSign(mode: ExtrudeMode) -> Double {
        mode == .cut && isOnFace ? -1 : 1
    }
}

/// Kurve oder Kontur, die das Versatz-Werkzeug versetzt.
private struct OffsetTarget {
    enum Kind {
        case loop(SketchLoop)
        case segment(SketchSegment)
    }

    var kind: Kind
    /// Ansatzpunkt und Richtung des Ziehpfeils (positiver Versatz)
    var anchor: Point2
    var direction: Point2
}

/// Zustand der aktuellen Skizze: Elemente, Werkzeugeingabe, geschlossene Bereiche.
/// Bekommt Punkte im lokalen System der Skizzenebene vom Viewport.
@MainActor
final class SketchController: ObservableObject {
    @Published var isActive = false {
        didSet {
            if !isActive {
                isChoosingPlane = false
                pendingTextAnchor = nil
                reset()
                plane = .ground
            }
        }
    }
    /// Beim Start einer Skizze ohne gewählte Fläche: Standardebene antippen.
    @Published var isChoosingPlane = false
    @Published private(set) var basePlane: BasePlane = .top
    @Published var tool: SketchTool = .rectangle {
        didSet { finishInput() }
    }
    /// Für Geräte ohne Apple Pencil: ein Finger zeichnet statt zu drehen.
    /// Im Simulator standardmäßig an, weil die Maus dort als Finger zählt.
    #if targetEnvironment(simulator)
    @Published var fingerDraws = true
    #else
    @Published var fingerDraws = false
    #endif
    @Published var plane: SketchPlane = .ground {
        didSet { reset() }
    }
    @Published var gridStep: Double = 1
    /// Fang an Raster und Endpunkten (Schalter in der rechten Leiste)
    @Published var snapEnabled = true
    /// Eckenzahl für das Polygon-Werkzeug; ändert auch das zuletzt gezeichnete Polygon.
    @Published var polygonSides = 5 {
        didSet {
            if case .regularPolygon(let center, let radius, _, let angle) = entities.last, polygonSides >= 3 {
                entities[entities.count - 1] = .regularPolygon(center: center, radius: radius, sides: polygonSides,
                                                               angle: angle)
                entitiesChanged()
            }
        }
    }
    @Published var splineKind: SplineKind = .fit {
        didSet { changed() }
    }
    @Published var offsetKind: OffsetKind = .loop {
        didSet {
            offsetTarget = nil
            updateOffsetPreview()
        }
    }
    @Published var offsetDistance: Double = 2 {
        didSet { updateOffsetPreview() }
    }
    // Text
    @Published var textHeight: Double = 10
    @Published var textFont = SketchText.fonts[0].name
    @Published var textAlignment: TextAlignmentOption = .left
    /// Gesetzt, wenn das Text-Werkzeug eine Position bekommen hat; die Oberfläche fragt dann den Inhalt ab.
    @Published var pendingTextAnchor: Point2?

    /// Extrusion der geschlossenen Bereiche; der Ziehpfeil im Viewport ändert extrudeDistance.
    @Published var extrudeDistance: Double = 10
    @Published var extrudeMode: ExtrudeMode = .newBody

    @Published private(set) var entities: [SketchEntity] = []
    /// Geschlossene Bereiche (Außenkontur mit Löchern), größter zuerst.
    @Published private(set) var regions: [SketchRegion] = []
    @Published private(set) var offsetPreview: [SketchEntity] = []
    @Published private(set) var liveLabel: String?
    @Published private(set) var revision = 0
    /// Ändert sich nur, wenn sich die Elemente ändern (für die Extrusionsvorschau).
    @Published private(set) var geometryRevision = 0

    private var loops: [SketchLoop] = []
    private var dragStart: Point2?
    private var dragCurrent: Point2?
    private var chainStart: Point2?
    private var chainEnd: Point2?
    private var arcChord: (start: Point2, end: Point2)?
    private var splinePoints: [Point2] = []
    private var offsetTarget: OffsetTarget?

    // MARK: Zustand

    var hasProfile: Bool { !regions.isEmpty }
    var isEmpty: Bool { entities.isEmpty && !isInProgress }
    var canUndo: Bool { !entities.isEmpty || isInProgress || offsetTarget != nil }
    var isInProgress: Bool { dragStart != nil || chainEnd != nil || arcChord != nil || !splinePoints.isEmpty }
    var hasOpenChain: Bool { chainEnd != nil }
    var hasOpenSpline: Bool { !splinePoints.isEmpty }
    var isWaitingForArcBulge: Bool { arcChord != nil }
    var hasOffsetTarget: Bool { offsetTarget != nil }

    /// Ansatz und Richtung des Versatz-Pfeils (lokal).
    var offsetHandle: (anchor: Point2, direction: Point2)? {
        offsetTarget.map { ($0.anchor, $0.direction) }
    }

    /// Schwerpunkt des größten Bereichs (Ansatz des Extrudieren-Pfeils).
    var profileCentroid: Point2? {
        guard let polygon = regions.first?.polygon, !polygon.isEmpty else { return nil }
        return polygon.reduce(.zero, +) / Double(polygon.count)
    }

    // MARK: Ebene

    func choose(_ side: BasePlane) {
        basePlane = side
        isChoosingPlane = false
        plane = .base(side)
    }

    /// Zurück auf die zuletzt gewählte Standardebene (z. B. nach einer Fläche).
    func useBasePlane() {
        plane = .base(basePlane)
    }

    /// Abstand der Standardebene vom Ursprung entlang ihrer Normale.
    var planeOffset: Double {
        get { plane.isOnFace ? 0 : simd_dot(plane.origin, plane.normal) }
        set { plane = .base(plane.base ?? basePlane, offset: newValue) }
    }

    // MARK: Eingabe

    func began(at point: Point2, tolerance: Double) {
        let p = snap(point, tolerance: tolerance)
        dragStart = p
        dragCurrent = p
        changed()
    }

    func moved(to point: Point2, tolerance: Double) {
        guard dragStart != nil else { return }
        dragCurrent = snap(point, tolerance: tolerance)
        changed()
    }

    func ended(at point: Point2, tolerance: Double) {
        guard let start = dragStart else { return }
        let end = snap(point, tolerance: tolerance)
        dragStart = nil
        dragCurrent = nil

        switch tool {
        case .rectangle:
            let size = end - start
            if size.x != 0, size.y != 0 {
                add(.rectangle(corner: start, size: size))
            }
        case .circle:
            let radius = simd_distance(start, end)
            if radius > 0 {
                add(.circle(center: start, radius: radius))
            }
        case .ellipse:
            let radii = simd_abs(end - start)
            if radii.x > 0, radii.y > 0 {
                add(.ellipse(center: start, radii: radii))
            }
        case .polygon:
            let radius = simd_distance(start, end)
            if radius > 0 {
                add(.regularPolygon(center: start, radius: radius, sides: polygonSides,
                                    angle: atan2(end.y - start.y, end.x - start.x)))
            }
        case .polyline:
            endLineStroke(start: start, end: end)
        case .arc:
            // Shapr3D: Enden aufziehen, dann die Wölbung ziehen
            if let chord = arcChord {
                if circleThrough(chord.start, end, chord.end) != nil {
                    arcChord = nil
                    add(.arc(start: chord.start, mid: end, end: chord.end))
                }
            } else if simd_distance(start, end) > 1e-6 {
                arcChord = (start, end)
            }
        case .spline:
            endSplineStroke(start: start, end: end)
        case .point:
            add(.point(end))
        case .text:
            pendingTextAnchor = end
        case .offset:
            pickOffset(at: end, tolerance: tolerance)
        }
        changed()
    }

    func cancelStroke() {
        dragStart = nil
        dragCurrent = nil
        changed()
    }

    /// Linie: Jeder Strich setzt den nächsten Punkt, zurück zum Startpunkt schließt den Linienzug.
    private func endLineStroke(start: Point2, end: Point2) {
        guard let from = chainEnd else {
            chainStart = start
            if simd_distance(start, end) > 1e-6 {
                add(.line(start, end))
            }
            chainEnd = end
            return
        }
        guard simd_distance(from, end) > 1e-6 else { return }
        add(.line(from, end))
        if let first = chainStart, simd_distance(first, end) < 1e-6 {
            chainStart = nil
            chainEnd = nil
        } else {
            chainEnd = end
        }
    }

    /// Linienzug beenden, ohne ihn zu schließen.
    func endChain() {
        chainStart = nil
        chainEnd = nil
        changed()
    }

    /// Spline: Jeder Strich setzt einen Punkt. Ende auf dem ersten Punkt schließt,
    /// Ende auf dem letzten Punkt (nochmal tippen) beendet den Spline.
    private func endSplineStroke(start: Point2, end: Point2) {
        if splinePoints.isEmpty {
            splinePoints = [start]
            if simd_distance(start, end) > 1e-6 { splinePoints.append(end) }
            return
        }
        if splinePoints.count >= 3, let first = splinePoints.first, simd_distance(first, end) < 1e-6 {
            add(.spline(points: splinePoints, kind: splineKind, closed: true))
            splinePoints = []
        } else if let last = splinePoints.last, simd_distance(last, end) < 1e-6 {
            finishSpline()
        } else {
            splinePoints.append(end)
        }
    }

    func finishSpline() {
        if splinePoints.count >= 2 {
            add(.spline(points: splinePoints, kind: splineKind, closed: false))
        }
        splinePoints = []
        changed()
    }

    func addText(_ string: String) {
        guard let anchor = pendingTextAnchor else { return }
        pendingTextAnchor = nil
        let text = SketchText(string: string, anchor: anchor, height: textHeight, fontName: textFont,
                              alignment: textAlignment)
        guard !text.loops.isEmpty else { return }
        add(.text(text))
    }

    // MARK: Versatz

    private func pickOffset(at p: Point2, tolerance: Double) {
        var best: (distance: Double, target: OffsetTarget)?
        func consider(_ kind: OffsetTarget.Kind, points: [Point2], closed: Bool, outwardSign: Double) {
            let hit = polylineDistance(from: p, to: points, closed: closed)
            guard hit.distance <= tolerance, hit.distance < (best?.distance ?? .infinity) else { return }
            best = (hit.distance, OffsetTarget(kind: kind, anchor: hit.point,
                                               direction: rightNormal(hit.tangent) * outwardSign))
        }
        for loop in loops {
            var isChain = false
            if case .chain = loop { isChain = true }
            // Kreise, Ellipsen und geschlossene Splines werden immer als Ganzes versetzt
            guard offsetKind == .loop || !isChain else { continue }
            let polygon = loop.polygon
            consider(.loop(loop), points: polygon, closed: true, outwardSign: signedArea(polygon) > 0 ? 1 : -1)
        }
        if offsetKind == .single || best == nil {
            let chainSegments = loops.flatMap { loop -> [SketchSegment] in
                if case .chain(let segments) = loop { return segments }
                return []
            }
            for segment in entities.flatMap(\.openSegments) + chainSegments {
                consider(.segment(segment), points: segment.samples, closed: false, outwardSign: 1)
            }
        }
        offsetTarget = best?.target
        updateOffsetPreview()
    }

    private func updateOffsetPreview() {
        guard let target = offsetTarget else {
            offsetPreview = []
            changed()
            return
        }
        switch target.kind {
        case .loop(let loop):
            offsetPreview = SketchOffset.loop(loop, distance: offsetDistance)
        case .segment(let segment):
            offsetPreview = SketchOffset.segment(segment, distance: offsetDistance, sign: 1)
                .map { [SketchOffset.entity($0)] } ?? []
        }
        changed()
    }

    func applyOffset() {
        guard offsetTarget != nil, offsetDistance != 0 else { return }
        let added = offsetPreview
        offsetTarget = nil
        offsetPreview = []
        entities += added
        entitiesChanged()
    }

    func cancelOffset() {
        offsetTarget = nil
        updateOffsetPreview()
    }

    // MARK: Zurücksetzen und Rückgängig

    func reset() {
        dragStart = nil
        dragCurrent = nil
        chainStart = nil
        chainEnd = nil
        arcChord = nil
        splinePoints = []
        offsetTarget = nil
        offsetPreview = []
        entities = []
        entitiesChanged()
    }

    /// Laufende Eingabe beim Werkzeugwechsel abschließen.
    private func finishInput() {
        if splinePoints.count >= 2 {
            add(.spline(points: splinePoints, kind: splineKind, closed: false))
        }
        splinePoints = []
        chainStart = nil
        chainEnd = nil
        arcChord = nil
        offsetTarget = nil
        offsetPreview = []
        pendingTextAnchor = nil
        changed()
    }

    /// Nimmt den letzten Schritt zurück: Punkt, Bogenenden oder zuletzt gezeichnetes Element.
    func undo() {
        if dragStart != nil {
            cancelStroke()
            return
        }
        if !splinePoints.isEmpty {
            splinePoints.removeLast()
            if splinePoints.count == 1 { splinePoints = [] }
            changed()
            return
        }
        if arcChord != nil {
            arcChord = nil
            changed()
            return
        }
        if offsetTarget != nil {
            cancelOffset()
            return
        }
        guard let last = entities.popLast() else { return }
        if case .line(let a, let b) = last, let end = chainEnd, simd_distance(end, b) < 1e-6 {
            if let first = chainStart, simd_distance(first, a) < 1e-6 {
                chainStart = nil
                chainEnd = nil
            } else {
                chainEnd = a
            }
        } else {
            chainStart = nil
            chainEnd = nil
        }
        entitiesChanged()
    }

    // MARK: Exakte Maße nach dem Zeichnen (zuletzt gezeichnetes Element)

    /// Breite/Tiefe des zuletzt gezeichneten Rechtecks. Die Startecke bleibt fest.
    var rectangleSize: Point2? {
        get {
            guard case .rectangle(_, let size) = entities.last else { return nil }
            return simd_abs(size)
        }
        set {
            guard let newValue, newValue.x > 0, newValue.y > 0,
                  case .rectangle(let corner, let size) = entities.last else { return }
            let sign = Point2(size.x < 0 ? -1.0 : 1.0, size.y < 0 ? -1.0 : 1.0)
            entities[entities.count - 1] = .rectangle(corner: corner, size: newValue * sign)
            entitiesChanged()
        }
    }

    var circleDiameter: Double? {
        get {
            guard case .circle(_, let radius) = entities.last else { return nil }
            return 2 * radius
        }
        set {
            guard let newValue, newValue > 0, case .circle(let center, _) = entities.last else { return }
            entities[entities.count - 1] = .circle(center: center, radius: newValue / 2)
            entitiesChanged()
        }
    }

    // MARK: Extrudieren

    /// Körper aus allen geschlossenen Bereichen. Beim Abziehen beginnt das Werkzeug minimal außerhalb,
    /// damit keine hauchdünnen Restflächen bleiben.
    func extrusion(distance: Double, mode: ExtrudeMode) -> PCKShape? {
        guard !regions.isEmpty, distance != 0 else { return nil }
        let plane = self.plane
        let sign = plane.extrusionSign(mode: mode)
        let from = mode == .cut ? -sign * 0.01 : 0
        let base = plane.normal * from
        let direction = plane.normal * (sign * distance - from)
        let world = { (p: Point2) -> [NSNumber] in
            let w = plane.world(p) + base
            return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
        }
        var shapes: [PCKShape] = []
        for region in regions {
            let shape: PCKShape?
            if PCKShape.kernelAvailable {
                let wires = ([region.outer] + region.holes).map { $0.code(normal: plane.normal, xAxis: plane.u, world: world) }
                shape = PCKShape.prism(profileWires: wires, direction: direction)
            } else {
                shape = PCKShape.prism(pointsXYZ: region.polygon.flatMap(world), direction: direction)
            }
            guard let shape else { return nil }
            shapes.append(shape)
        }
        return PCKShape.compound(shapes)
    }

    // MARK: Darstellung

    /// Liniensegmente (Punktpaare, lokal) für den Renderer: Elemente und laufende Eingabe.
    var segments: [Point2] {
        var polylines = entities.flatMap(\.drawing) + offsetPreview.flatMap(\.drawing)
        let current = dragCurrent
        switch tool {
        case .rectangle, .circle, .ellipse, .polygon:
            if let start = dragStart, let current, let preview = shapePreview(from: start, to: current) {
                polylines += preview.drawing
                if tool == .circle || tool == .polygon { polylines.append([start, current]) }
            }
        case .polyline:
            if let from = chainEnd ?? dragStart, let current { polylines.append([from, current]) }
        case .arc:
            if let chord = arcChord {
                if let current, circleThrough(chord.start, current, chord.end) != nil {
                    polylines.append(SketchSegment.arc(chord.start, current, chord.end).samples)
                } else {
                    polylines.append([chord.start, chord.end])
                }
            } else if let start = dragStart, let current {
                polylines.append([start, current])
            }
        case .spline:
            var points = splinePoints
            if current != nil, points.isEmpty, let start = dragStart { points = [start] }
            if let current { points.append(current) }
            if points.count >= 2 {
                let preview = SketchEntity.spline(points: points, kind: splineKind, closed: false)
                polylines += preview.drawing
                if splineKind == .control { polylines.append(points) }
            }
        case .point, .text, .offset:
            break
        }
        return polylines.flatMap { line in
            zip(line, line.dropFirst()).flatMap { [$0, $1] }
        }
    }

    private func shapePreview(from start: Point2, to current: Point2) -> SketchEntity? {
        switch tool {
        case .rectangle:
            return .rectangle(corner: start, size: current - start)
        case .circle:
            return .circle(center: start, radius: simd_distance(start, current))
        case .ellipse:
            return .ellipse(center: start, radii: simd_abs(current - start))
        case .polygon:
            return .regularPolygon(center: start, radius: simd_distance(start, current), sides: polygonSides,
                                   angle: atan2(current.y - start.y, current.x - start.x))
        default:
            return nil
        }
    }

    // MARK: Fang und Maße

    /// Fang an Endpunkten, Ecken, Mittelpunkten und Punkten (innerhalb tolerance), sonst am Raster.
    private func snap(_ p: Point2, tolerance: Double) -> Point2 {
        guard snapEnabled else { return p }
        var candidates = entities.flatMap(\.snapPoints) + splinePoints
        if let chainStart { candidates.append(chainStart) }
        if let arcChord { candidates += [arcChord.start, arcChord.end] }
        if let nearest = candidates.min(by: { simd_distance($0, p) < simd_distance($1, p) }),
           simd_distance(nearest, p) <= tolerance {
            return nearest
        }
        return (p / gridStep).rounded(.toNearestOrAwayFromZero) * gridStep
    }

    private func add(_ entity: SketchEntity) {
        entities.append(entity)
        entitiesChanged()
    }

    private func entitiesChanged() {
        let found = findRegions(in: entities)
        regions = found.regions
        loops = found.loops
        geometryRevision += 1
        changed()
    }

    private func changed() {
        updateLabel()
        revision += 1
    }

    private func updateLabel() {
        if let start = dragStart, let current = dragCurrent {
            switch tool {
            case .rectangle:
                liveLabel = "\(format(abs(current.x - start.x))) × \(format(abs(current.y - start.y))) mm"
            case .circle:
                liveLabel = "Ø \(format(2 * simd_distance(start, current))) mm"
            case .ellipse:
                liveLabel = "\(format(2 * abs(current.x - start.x))) × \(format(2 * abs(current.y - start.y))) mm"
            case .polygon:
                liveLabel = "\(polygonSides) Seiten · R \(format(simd_distance(start, current))) mm"
            case .polyline:
                liveLabel = "\(format(simd_distance(chainEnd ?? start, current))) mm"
            case .arc:
                if let chord = arcChord, let circle = circleThrough(chord.start, current, chord.end) {
                    liveLabel = "R \(format(circle.radius)) mm"
                } else {
                    liveLabel = "\(format(simd_distance(start, current))) mm"
                }
            case .spline:
                liveLabel = "\(splinePoints.count + 1) Punkte"
            case .point, .text, .offset:
                liveLabel = nil
            }
            return
        }
        if tool == .offset, offsetTarget != nil {
            liveLabel = "Versatz \(format(offsetDistance)) mm"
        } else if !splinePoints.isEmpty {
            liveLabel = "Spline, \(splinePoints.count) Punkte"
        } else if case .rectangle(_, let size) = entities.last {
            liveLabel = "\(format(abs(size.x))) × \(format(abs(size.y))) mm"
        } else if case .circle(_, let radius) = entities.last {
            liveLabel = "Ø \(format(2 * radius)) mm"
        } else if !regions.isEmpty {
            liveLabel = regions.count == 1 ? "1 geschlossener Bereich" : "\(regions.count) geschlossene Bereiche"
        } else {
            liveLabel = nil
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
