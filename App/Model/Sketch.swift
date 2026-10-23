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
enum BasePlane: String, CaseIterable, Identifiable, Codable {
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
struct SketchPlane: Codable {
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

/// Maß am Element, das beim Aufziehen angezeigt und danach direkt geändert werden kann.
struct SketchDimension: Identifiable {
    enum Kind: Hashable {
        case width, height, diameter, radius, length
    }

    var kind: Kind
    var value: Double
    /// Ansatz am Element (lokal) und Richtung, in die das Etikett abgesetzt wird.
    var position: Point2
    var direction: Point2
    var isEditable: Bool

    var id: Kind { kind }

    var prefix: String {
        switch kind {
        case .diameter: "Ø "
        case .radius: "R "
        default: ""
        }
    }
}

/// Zustand der aktuellen Skizze: Elemente, Werkzeugeingabe, Fang, geschlossene Bereiche.
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
    /// Für Geräte ohne Apple Pencil: ein Finger zeichnet statt zu verschieben.
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
    /// Fang insgesamt (Magnet in der rechten Leiste)
    @Published var snapEnabled = true
    /// Einzelne Fangarten; werden für die nächste Sitzung gemerkt.
    @Published var snapKinds: Set<SnapKind> = SketchController.storedSnapKinds() {
        didSet { UserDefaults.standard.set(snapKinds.map(\.rawValue), forKey: Self.snapKindsKey) }
    }
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

    @Published private(set) var entities: [SketchEntity] = []
    /// Geschlossene Bereiche (Außenkontur mit Löchern), größter zuerst.
    @Published private(set) var regions: [SketchRegion] = []
    @Published private(set) var offsetPreview: [SketchEntity] = []
    @Published private(set) var liveLabel: String?
    /// Zählt jede Änderung; veröffentlicht wird nur außerhalb laufender Striche.
    @Published private(set) var revision = 0
    /// Ändert sich nur, wenn sich die Elemente ändern (für Bereichsfüllungen).
    @Published private(set) var geometryRevision = 0

    /// Fang während eines Strichs bzw. beim Schweben des Stifts. Nicht veröffentlicht:
    /// Schweben aktualisiert nur den Viewport, nicht die Oberfläche.
    private(set) var activeSnap: SnapResult?
    private(set) var hoverSnap: SnapResult?
    /// Knoten in Stiftnähe (Enden, Mitten, Zentren, Schnittpunkte).
    private(set) var hoverNodes: [Point2] = []

    private var loops: [SketchLoop] = []
    private var snapIndex = SnapIndex()
    private var dragStart: Point2?
    private var dragCurrent: Point2?
    private var chainStart: Point2?
    private var chainEnd: Point2?
    private var arcChord: (start: Point2, end: Point2)?
    private var splinePoints: [Point2] = []
    private var offsetTarget: OffsetTarget?
    /// Zuletzt gezeichnetes Element, dessen Maße noch änderbar sind.
    private var editableIndex: Int?

    private static let snapKindsKey = "snapKinds"

    private static func storedSnapKinds() -> Set<SnapKind> {
        guard let raw = UserDefaults.standard.stringArray(forKey: snapKindsKey) else { return Set(SnapKind.allCases) }
        return Set(raw.compactMap(SnapKind.init(rawValue:)))
    }

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

    /// Gespeicherte Skizze zum Bearbeiten laden.
    func load(plane: SketchPlane, entities: [SketchEntity]) {
        isChoosingPlane = false
        if let base = plane.base { basePlane = base }
        self.plane = plane
        self.entities = entities
        entitiesChanged()
    }

    // MARK: Eingabe

    func began(at point: Point2, tolerance: Double) {
        let anchor: Point2? = switch tool {
        case .polyline: chainEnd
        case .spline: splinePoints.last
        default: nil
        }
        let p = snap(point, tolerance: tolerance, anchor: anchor)
        dragStart = p
        dragCurrent = p
        hoverSnap = nil
        hoverNodes = []
        changed()
    }

    func moved(to point: Point2, tolerance: Double) {
        guard dragStart != nil else { return }
        dragCurrent = snap(point, tolerance: tolerance, anchor: strokeAnchor)
        // Der Stift liefert bis zu 240 Punkte pro Sekunde: nicht jedes Mal die Oberfläche neu aufbauen,
        // der Viewport zeichnet selbst neu.
        changed(publish: false)
    }

    func ended(at point: Point2, tolerance: Double) {
        guard let start = dragStart else { return }
        let end = snap(point, tolerance: tolerance, anchor: strokeAnchor)
        dragStart = nil
        dragCurrent = nil
        activeSnap = nil

        switch tool {
        case .rectangle:
            let size = end - start
            if size.x != 0, size.y != 0 {
                add(.rectangle(corner: start, size: size), editable: true)
            }
        case .circle:
            let radius = simd_distance(start, end)
            if radius > 0 {
                add(.circle(center: start, radius: radius), editable: true)
            }
        case .ellipse:
            let radii = simd_abs(end - start)
            if radii.x > 0, radii.y > 0 {
                add(.ellipse(center: start, radii: radii), editable: true)
            }
        case .polygon:
            let radius = simd_distance(start, end)
            if radius > 0 {
                add(.regularPolygon(center: start, radius: radius, sides: polygonSides,
                                    angle: atan2(end.y - start.y, end.x - start.x)), editable: true)
            }
        case .polyline:
            endLineStroke(start: start, end: end)
        case .arc:
            // Shapr3D: Enden aufziehen, dann die Wölbung ziehen
            if let chord = arcChord {
                if circleThrough(chord.start, end, chord.end) != nil {
                    arcChord = nil
                    add(.arc(start: chord.start, mid: end, end: chord.end), editable: true)
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
        activeSnap = nil
        changed()
    }

    /// Bezugspunkt für Winkelschritte während eines Strichs.
    private var strokeAnchor: Point2? {
        switch tool {
        case .polyline: chainEnd ?? dragStart
        case .arc: arcChord == nil ? dragStart : nil
        case .spline: splinePoints.last ?? dragStart
        case .circle, .polygon: dragStart
        default: nil
        }
    }

    /// Linie: Jeder Strich setzt den nächsten Punkt, zurück zum Startpunkt schließt den Linienzug.
    private func endLineStroke(start: Point2, end: Point2) {
        guard let from = chainEnd else {
            chainStart = start
            if simd_distance(start, end) > 1e-6 {
                add(.line(start, end), editable: true)
            }
            chainEnd = end
            return
        }
        guard simd_distance(from, end) > 1e-6 else { return }
        add(.line(from, end), editable: true)
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

    // MARK: Schweben des Stifts

    /// Stift schwebt über der Ebene: Fangpunkt und Knoten in der Nähe zeigen.
    func hover(at point: Point2, tolerance: Double) {
        guard dragStart == nil else { return }
        let anchor: Point2? = switch tool {
        case .polyline: chainEnd
        case .spline: splinePoints.last
        default: nil
        }
        hoverSnap = snapEnabled
            ? snapIndex.snap(point, tolerance: tolerance, kinds: snapKinds, extra: inputPoints, anchor: anchor,
                             gridStep: gridStep)
            : SnapResult(point: point, kind: nil)
        let radius = tolerance * 5
        hoverNodes = snapEnabled
            ? (snapIndex.nodes.map { $0.point } + inputPoints).filter { simd_distance($0, point) <= radius }
            : []
    }

    func endHover() {
        hoverSnap = nil
        hoverNodes = []
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
        editableIndex = nil
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
        editableIndex = nil
        activeSnap = nil
        hoverSnap = nil
        hoverNodes = []
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
        editableIndex = nil
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
        editableIndex = nil
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

    // MARK: Maße am Element

    /// Maße der laufenden Eingabe (nur Anzeige) bzw. des zuletzt gezeichneten Elements (änderbar).
    var dimensions: [SketchDimension] {
        if let start = dragStart, let current = dragCurrent {
            if tool == .polyline {
                let from = chainEnd ?? start
                return Self.lineDimensions(from, current, editable: false)
            }
            if tool == .arc, arcChord == nil {
                return Self.lineDimensions(start, current, editable: false)
            }
            if tool == .arc, let chord = arcChord {
                return Self.dimensions(of: .arc(start: chord.start, mid: current, end: chord.end), editable: false)
            }
            if let preview = shapePreview(from: start, to: current) {
                return Self.dimensions(of: preview, editable: false)
            }
            return []
        }
        if tool == .polyline, let from = chainEnd, let hover = hoverSnap?.point, simd_distance(from, hover) > 1e-6 {
            return Self.lineDimensions(from, hover, editable: false)
        }
        guard let index = editableIndex, entities.indices.contains(index), !isInProgress || chainEnd != nil else {
            return []
        }
        return Self.dimensions(of: entities[index], editable: true)
    }

    /// Maß des zuletzt gezeichneten Elements setzen. Startecke, Mitte bzw. Startpunkt bleiben fest.
    func setDimension(_ kind: SketchDimension.Kind, to value: Double) {
        guard value > 0, let index = editableIndex, entities.indices.contains(index) else { return }
        let entity = entities[index]
        var updated: SketchEntity?
        switch (entity, kind) {
        case (.rectangle(let corner, let size), .width):
            updated = .rectangle(corner: corner, size: Point2(size.x < 0 ? -value : value, size.y))
        case (.rectangle(let corner, let size), .height):
            updated = .rectangle(corner: corner, size: Point2(size.x, size.y < 0 ? -value : value))
        case (.circle(let center, _), .diameter):
            updated = .circle(center: center, radius: value / 2)
        case (.ellipse(let center, let radii), .width):
            updated = .ellipse(center: center, radii: Point2(value / 2, radii.y))
        case (.ellipse(let center, let radii), .height):
            updated = .ellipse(center: center, radii: Point2(radii.x, value / 2))
        case (.regularPolygon(let center, _, let sides, let angle), .radius):
            updated = .regularPolygon(center: center, radius: value, sides: sides, angle: angle)
        case (.line(let a, let b), .length):
            let direction = simd_normalize(b - a)
            let newEnd = a + direction * value
            updated = .line(a, newEnd)
            // Laufender Linienzug geht am neuen Ende weiter
            if let end = chainEnd, simd_distance(end, b) < 1e-6 { chainEnd = newEnd }
        case (.arc(let a, let m, let b), .radius):
            updated = Self.arc(a, m, b, radius: value).map { SketchEntity.arc(start: a, mid: $0, end: b) }
        default:
            break
        }
        guard let updated else { return }
        entities[index] = updated
        entitiesChanged()
    }

    private static func lineDimensions(_ a: Point2, _ b: Point2, editable: Bool) -> [SketchDimension] {
        guard simd_distance(a, b) > 1e-6 else { return [] }
        var normal = rightNormal(b - a)
        if normal.y < 0 || (normal.y == 0 && normal.x < 0) { normal = -normal }
        return [SketchDimension(kind: .length, value: simd_distance(a, b), position: (a + b) / 2, direction: normal,
                                isEditable: editable)]
    }

    private static func dimensions(of entity: SketchEntity, editable: Bool) -> [SketchDimension] {
        switch entity {
        case .rectangle(let corner, let size):
            let lo = simd_min(corner, corner + size), hi = simd_max(corner, corner + size)
            return [
                SketchDimension(kind: .width, value: abs(size.x), position: Point2((lo.x + hi.x) / 2, lo.y),
                                direction: Point2(0, -1), isEditable: editable),
                SketchDimension(kind: .height, value: abs(size.y), position: Point2(hi.x, (lo.y + hi.y) / 2),
                                direction: Point2(1, 0), isEditable: editable),
            ]
        case .circle(let center, let radius):
            let d = Point2(1, 1) / sqrt(2.0)
            return [SketchDimension(kind: .diameter, value: 2 * radius, position: center + d * radius, direction: d,
                                    isEditable: editable)]
        case .ellipse(let center, let radii):
            return [
                SketchDimension(kind: .width, value: 2 * radii.x, position: center - Point2(0, radii.y),
                                direction: Point2(0, -1), isEditable: editable),
                SketchDimension(kind: .height, value: 2 * radii.y, position: center + Point2(radii.x, 0),
                                direction: Point2(1, 0), isEditable: editable),
            ]
        case .regularPolygon(let center, let radius, _, let angle):
            let d = Point2(cos(angle), sin(angle))
            return [SketchDimension(kind: .radius, value: radius, position: center + d * radius / 2,
                                    direction: rightNormal(d) * -1, isEditable: editable)]
        case .line(let a, let b):
            return lineDimensions(a, b, editable: editable)
        case .arc(let a, let m, let b):
            guard let circle = circleThrough(a, m, b) else { return [] }
            let samples = SketchSegment.arc(a, m, b).samples
            let mid = samples[samples.count / 2]
            return [SketchDimension(kind: .radius, value: circle.radius, position: mid,
                                    direction: simd_normalize(mid - circle.center), isEditable: editable)]
        default:
            return []
        }
    }

    /// Neuer Punkt auf dem Bogen für einen anderen Radius bei festen Enden (auf derselben Seite der Sehne).
    private static func arc(_ a: Point2, _ m: Point2, _ b: Point2, radius: Double) -> Point2? {
        let chord = simd_distance(a, b)
        guard radius >= chord / 2, let circle = circleThrough(a, m, b) else { return nil }
        let middle = (a + b) / 2
        var side = rightNormal(b - a)
        if simd_dot(m - middle, side) < 0 { side = -side }
        // Großer Bogen, wenn der Mittelpunkt auf der Seite des Bogens liegt
        let isMajor = simd_dot(circle.center - middle, side) > 0
        let h = (radius * radius - chord * chord / 4).squareRoot()
        return middle + side * (isMajor ? radius + h : radius - h)
    }

    // MARK: Darstellung

    /// Linienzüge der fertigen Elemente (lokal).
    var entityPolylines: [[Point2]] {
        entities.flatMap(\.drawing)
    }

    /// Linienzüge der laufenden Eingabe und der Versatz-Vorschau (lokal).
    var previewPolylines: [[Point2]] {
        var polylines = offsetPreview.flatMap(\.drawing)
        // Beim Schweben zeigt der Linienzug, Bogen bzw. Spline schon das nächste Stück
        let current = dragCurrent ?? hoverSnap?.point
        switch tool {
        case .rectangle, .circle, .ellipse, .polygon:
            if let start = dragStart, let current = dragCurrent, let preview = shapePreview(from: start, to: current) {
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
            } else if let start = dragStart, let current = dragCurrent {
                polylines.append([start, current])
            }
        case .spline:
            var points = splinePoints
            if dragCurrent != nil, points.isEmpty, let start = dragStart { points = [start] }
            if let current, !points.isEmpty { points.append(current) }
            if points.count >= 2 {
                let preview = SketchEntity.spline(points: points, kind: splineKind, closed: false)
                polylines += preview.drawing
                if splineKind == .control { polylines.append(points) }
            }
        case .point, .text, .offset:
            break
        }
        return polylines
    }

    /// Aktueller Fang (Strich hat Vorrang vor Schweben).
    var currentSnap: SnapResult? {
        activeSnap ?? hoverSnap
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

    // MARK: Fang

    /// Punkte der laufenden Eingabe, an denen ebenfalls gefangen wird.
    private var inputPoints: [Point2] {
        var points = splinePoints
        if let chainStart { points.append(chainStart) }
        if let arcChord { points += [arcChord.start, arcChord.end] }
        return points
    }

    private func snap(_ p: Point2, tolerance: Double, anchor: Point2?) -> Point2 {
        guard snapEnabled else {
            activeSnap = nil
            return p
        }
        let result = snapIndex.snap(p, tolerance: tolerance, kinds: snapKinds, extra: inputPoints, anchor: anchor,
                                    gridStep: gridStep)
        activeSnap = result.kind == nil ? nil : result
        return result.point
    }

    private func add(_ entity: SketchEntity, editable: Bool = false) {
        entities.append(entity)
        editableIndex = editable ? entities.count - 1 : nil
        entitiesChanged()
    }

    private func entitiesChanged() {
        let found = findRegions(in: entities)
        regions = found.regions
        loops = found.loops
        snapIndex = SnapIndex(entities: entities)
        geometryRevision += 1
        changed()
    }

    private func changed(publish: Bool = true) {
        updateLabel()
        if publish { revision += 1 }
    }

    private func updateLabel() {
        let label = currentLabel
        // @Published meldet jede Zuweisung, auch ohne Änderung
        if label != liveLabel { liveLabel = label }
    }

    private var currentLabel: String? {
        if dragStart != nil {
            switch tool {
            case .polygon:
                return "\(polygonSides) Seiten"
            case .spline:
                return "\(splinePoints.count + 1) Punkte"
            default:
                return activeSnap?.kind.map { "Fang: \($0.rawValue)" }
            }
        }
        if tool == .offset, offsetTarget != nil {
            return "Versatz \(offsetDistance.formatted(.number.precision(.fractionLength(0...2)))) mm"
        } else if !splinePoints.isEmpty {
            return "Spline, \(splinePoints.count) Punkte"
        } else if !regions.isEmpty {
            return regions.count == 1 ? "1 geschlossener Bereich" : "\(regions.count) geschlossene Bereiche"
        } else {
            return nil
        }
    }
}
