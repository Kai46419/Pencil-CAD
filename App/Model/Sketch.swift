import Foundation
import simd

enum SketchTool: String, CaseIterable, Identifiable {
    /// Pfeil: zeichnet nicht, wählt Elemente, verschiebt sie und zieht Eck- und Endpunkte
    case select = "Auswählen"
    case polyline = "Linie"
    case rectangle = "Rechteck"
    case circle = "Kreis"
    case ellipse = "Ellipse"
    case polygon = "Polygon"
    case arc = "Bogen"
    case spline = "Spline"
    case point = "Punkt"
    case text = "Text"
    case offset = "Kante versetzen"
    case project = "Projizieren"
    case trim = "Beschneiden"
    /// Ecke zweier Linien mit einem Bogen abrunden (Skizzenverrundung wie in Fusion 360)
    case fillet = "Abrunden"
    case scale = "Skalieren"
    /// Langloch (Fusion 360 „Slot“): Mittellinie ziehen, dann die Breite
    case slot = "Langloch"
    /// Ecke zweier Linien mit einer Fase abschneiden (Fusion 360 „Sketch Chamfer“)
    case chamfer = "Fase"
    /// Linienende bis zur nächsten Kurve verlängern (Fusion 360 „Extend“)
    case extend = "Verlängern"
    /// Kurve an den Schnittpunkten teilen, ohne etwas zu löschen (Fusion 360 „Break“)
    case breakCurve = "Unterbrechen"
    /// Gewählte Elemente an einer Linie spiegeln (Fusion 360 „Mirror“)
    case mirror = "Spiegeln"
    /// Gewählte Elemente in Zeilen und Spalten vervielfältigen (Fusion 360 „Rectangular Pattern“)
    case rectPattern = "Rechteckmuster"
    /// Gewählte Elemente um einen Punkt vervielfältigen (Fusion 360 „Circular Pattern“)
    case circPattern = "Kreismuster"
    /// Länge, Radius, Abstand und Winkel antippen (Fusion 360 „Messen“): zeigt z. B., ob zwei Linien parallel sind
    case measure = "Messen"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
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
        case .project: "square.and.arrow.down.on.square"
        case .trim: "scissors"
        case .fillet: "app"
        case .scale: "arrow.up.left.and.arrow.down.right"
        case .slot: "capsule"
        case .chamfer: "octagon"
        case .extend: "arrow.right.to.line"
        case .breakCurve: "divide"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .rectPattern: "square.grid.3x3"
        case .circPattern: "circle.grid.cross"
        case .measure: "ruler"
        }
    }

    /// Untertitel in der Werkzeugleiste (Variante des Werkzeugs).
    var subtitle: String? {
        switch self {
        case .select: "Verschieben, Größe"
        case .polyline: "Automatisch"
        case .arc: "3 Punkte"
        case .text: "Schrift als Profil"
        case .offset: "Kurven versetzen"
        case .project: "Körperkanten"
        case .trim: "Bis zum Schnittpunkt"
        case .fillet: "Ecke antippen"
        case .scale: "Auswahl oder alles"
        case .chamfer: "Ecke antippen"
        case .extend: "Linienende antippen"
        case .breakCurve: "An Schnittpunkten teilen"
        case .mirror: "Auswahl, zuletzt Achse"
        case .rectPattern, .circPattern: "Auswahl vervielfältigen"
        case .measure: "Länge, Abstand, Winkel"
        default: nil
        }
    }
}

/// Varianten des Rechteck-Werkzeugs (wie Shapr3D).
enum RectangleMode: String, CaseIterable, Identifiable {
    case center = "Mitte"
    case diagonal = "Diagonal"
    case threePoint = "3 Punkte"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .center: "rectangle.center.inset.filled"
        case .diagonal: "rectangle"
        case .threePoint: "rectangle.portrait.rotate"
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
        /// Abstand (zwei Punkte, Punkt–Linie) und Winkel zweier Linien in Grad
        case distance, angle
    }

    /// Was eine Eingabe in das Maßfeld ändert.
    enum Target {
        /// Nur Anzeige
        case display
        /// Maß eines Elements (Breite, Höhe, Durchmesser, Radius, Länge)
        case entity(Int)
        /// Vorhandenes treibendes Maß (Index in constraints)
        case constraint(Int)
        /// Neues treibendes Maß aus der Auswahl
        case create(SketchConstraint.Variant)
    }

    var kind: Kind
    var value: Double
    /// Ansatz am Element (lokal) und Richtung, in die das Etikett abgesetzt wird.
    var position: Point2
    var direction: Point2
    var isEditable: Bool
    /// Gemessene Punkte (lokal) für die Maßlinie mit Pfeilen; leer = nur Etikett.
    var span: [Point2] = []
    /// Eindeutig je Maß (ein Eingabefeld im Viewport)
    var id = ""
    var target: Target = .display

    var prefix: String {
        switch kind {
        case .diameter: "Ø "
        case .radius: "R "
        case .angle: "∠ "
        default: ""
        }
    }

    /// Dasselbe Maß mit Kennung und Ziel.
    func tagged(_ id: String, _ target: Target) -> SketchDimension {
        var copy = self
        copy.id = id
        copy.target = target
        if case .display = target { copy.isEditable = false }
        return copy
    }
}

/// Einschränkung bzw. Aktion der rechten Spalte, die auf die passende Auswahl wartet
/// (wie in Fusion 360: erst das Symbol, dann die Elemente antippen).
enum SketchPendingAction: Equatable {
    case constraint(ConstraintKind)
    case detach
    case construction

    var title: String {
        switch self {
        case .constraint(let kind): kind.rawValue
        case .detach: "Trennen"
        case .construction: "Konstruktion erstellen"
        }
    }

    /// Was jetzt anzutippen ist.
    var hint: String {
        switch self {
        case .constraint(let kind): kind.selectionHint
        case .detach: "Trennen: Element oder gemeinsamen Punkt antippen, dessen Verbindungen gelöst werden sollen."
        case .construction: "Konstruktion erstellen: Elemente antippen, die zu Hilfslinien werden sollen."
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
    @Published var tool: SketchTool = .select {
        didSet {
            if tool == .polyline || tool == .arc { lineVariant = tool }
            finishInput()
        }
    }
    /// Zuletzt benutzte Variante der Kachel „Linie/Bogen“ (Antippen startet sie, langes Drücken zeigt alle)
    @Published private(set) var lineVariant: SketchTool = .polyline
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
    @Published var rectangleMode: RectangleMode = .diagonal {
        didSet {
            rectangleBase = nil
            changed()
        }
    }
    /// Faktor für das Skalieren-Werkzeug.
    @Published var scaleFactor: Double = 2
    /// Radius für das Abrunden-Werkzeug (mm)
    @Published var filletRadius: Double = 2
    /// Abstand für das Fasen-Werkzeug (mm, auf beiden Linien gleich)
    @Published var chamferDistance: Double = 2
    @Published var circleMode: CircleMode = .center {
        didSet {
            stepBase = nil
            changed()
        }
    }
    @Published var arcMode: ArcMode = .threePoint {
        didSet {
            stepBase = nil
            arcChord = nil
            changed()
        }
    }
    @Published var polygonMode: PolygonMode = .inscribed
    @Published var slotMode: SlotMode = .centerToCenter {
        didSet {
            stepBase = nil
            changed()
        }
    }
    // Muster der Auswahl (Rechteck: Spalten entlang x, Zeilen entlang y; Kreis: um einen gewählten Punkt)
    @Published var patternColumns = 3 { didSet { changed() } }
    @Published var patternRows = 1 { didSet { changed() } }
    @Published var patternSpacingX: Double = 10 { didSet { changed() } }
    @Published var patternSpacingY: Double = 10 { didSet { changed() } }
    @Published var circularCount = 6 { didSet { changed() } }
    @Published var circularAngle: Double = 360 { didSet { changed() } }
    /// Neue Elemente als Konstruktionsgeometrie (zählen nicht als Profil).
    @Published var constructionMode = false
    // Skizzenpalette (wie in Fusion 360): was beim Skizzieren angezeigt wird
    @Published var showsGrid = true
    @Published var showsProfiles = true
    @Published var showsPoints = true
    @Published var showsDimensions = true
    @Published var showsConstraintBadges = true
    @Published var showsConstruction = true
    /// Hinweis für die Oberfläche (z. B. Einschränkung nicht möglich).
    @Published var notice: String?
    /// Gewählte Einschränkung, die auf passende Elemente wartet
    @Published private(set) var pendingAction: SketchPendingAction?
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
    @Published private(set) var constraints: [SketchConstraint] = []
    /// Indizes der Konstruktionselemente
    @Published private(set) var construction: Set<Int> = []
    /// Ausgewählte Punkte und Kurven (Finger antippen), in Auswahlreihenfolge
    @Published private(set) var selection: [SketchRef] = []
    /// Hilfspunkte (kleine Dreiecke): Mitte zweier gewählter Punkte. Fangbar und selbst wieder wählbar,
    /// so lassen sich Mitten von Mitten bilden. Sie gehören nicht zur gespeicherten Skizze.
    @Published private(set) var marks: [Point2] = []
    @Published private(set) var selectedMarks: [Int] = []
    /// Per Stiftdruck gemerkte Fangpunkte (höchstens einer wartet auf den zweiten)
    @Published private(set) var capturedPoints: [Point2] = []
    /// Linien mit demselben Winkel wie die gerade gezeichnete (leuchten grün)
    private(set) var parallelLines: [[Point2]] = []
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
    /// Ungefangene Stiftpunkte des laufenden Strichs (Gesten: Kreis/Bogen aus dem Linienwerkzeug, Kritzeln)
    private var strokeSamples: [Point2] = []
    /// Linienwerkzeug: erkannter Kreis bzw. Bogen des laufenden Strichs (Vorschau)
    private(set) var strokeShape: SketchEntity?
    /// Kreis aufziehen: erkannte Abhängigkeit (tangential, gleicher Radius, durch Punkt)
    private var circleInference: CircleInference?
    /// Finger liegt auf dem Bildschirm, während der Stift zeichnet (wie Shapr3D): das Linienwerkzeug
    /// zeichnet dann einen tangentialen Bogen am Ende des Linienzugs.
    var arcModifier = false {
        didSet {
            // Einmal während eines Strichs aufgelegt, bleibt der Strich ein Bogen (auch wenn der Finger
            // inzwischen verrutscht oder abgehoben wurde)
            if arcModifier, dragStart != nil { startArcMidStroke() }
            if arcModifier != oldValue { changed() }
        }
    }
    private var arcLatched = false
    /// Ein Finger liegt auf (auch einer, den der Viewport nicht als Bogen-Taste gezählt hat): Strich wird Bogen
    func latchArc() {
        guard dragStart != nil, tool == .polyline, !arcLatched else { return }
        startArcMidStroke()
        changed()
    }

    /// Wie Shapr3D: Linie ziehen und mitten im Strich den Finger auflegen. Das bisher gezogene gerade Stück
    /// wird als Linie übernommen, der Strich geht ab der Stiftspitze als tangentialer Bogen weiter.
    /// (Vorher wurde der ganze Strich zum Bogen ab dem Strichanfang – am Ende kam Unsinn bzw. eine Gerade heraus.)
    private func startArcMidStroke() {
        guard !arcLatched else { return }
        arcLatched = true
        guard tool == .polyline, let start = dragStart, let current = dragCurrent else { return }
        let from = chainEnd ?? start
        guard simd_distance(from, current) > strokeTolerance else { return }
        endLineStroke(start: start, end: current)
        guard chainEnd != nil else { return }
        dragStart = current
        strokeSamples = [current]
        strokeShape = nil
    }
    /// Bogen-Modus für den laufenden Strich
    var arcActive: Bool { arcModifier || arcLatched }
    /// Fangradius des laufenden Strichs
    private var strokeTolerance = 1.0
    /// Hilfslinien zu gemerkten Punktpaaren: Verbindung und Mittelsenkrechte („Mittellinie“), nur Anzeige
    @Published private(set) var guideLines: [(mark: Point2, lines: [[Point2]])] = []
    private var chainStart: Point2?
    private var chainEnd: Point2?
    private var arcChord: (start: Point2, end: Point2)?
    /// Zweistufige Werkzeuge (Kreis 3 Punkte, Bogen um Mittelpunkt, Langloch): erster Zug steht, der zweite folgt
    private var stepBase: (start: Point2, end: Point2)?
    /// Bogen um Mittelpunkt: überstrichener Winkel des zweiten Zugs (folgt dem Stift, auch über 180°)
    private var arcSweep = 0.0
    private var arcLastAngle = 0.0
    private var splinePoints: [Point2] = []
    private var offsetTarget: OffsetTarget?
    /// Zuletzt gezeichnetes Element, dessen Maße noch änderbar sind.
    private var editableIndex: Int?
    /// Rechteck mit 3 Punkten: erste Kante steht, Höhe folgt.
    private var rectangleBase: (start: Point2, end: Point2)?
    /// Pfeil-Werkzeug: Element unter dem Stift, das gezogen wird
    private var selectDrag: SelectDrag?
    /// Pfeil-Werkzeug: Aufsetzpunkt (Tippen ohne Ziehen wählt beim Abheben)
    private var selectStart: (point: Point2, tolerance: Double)?

    /// Stand vor jeder Änderung (für Rückgängig).
    private struct Snapshot {
        var entities: [SketchEntity]
        var constraints: [SketchConstraint]
        var construction: Set<Int>
        var chainStart: Point2?
        var chainEnd: Point2?
    }
    private var undoStack: [Snapshot] = []

    private static let snapKindsKey = "snapKinds"

    private static func storedSnapKinds() -> Set<SnapKind> {
        guard let raw = UserDefaults.standard.stringArray(forKey: snapKindsKey) else { return Set(SnapKind.allCases) }
        return Set(raw.compactMap(SnapKind.init(rawValue:)))
    }

    // MARK: Zustand

    var hasProfile: Bool { !regions.isEmpty }
    var isEmpty: Bool { entities.isEmpty && !isInProgress }
    var canUndo: Bool { !undoStack.isEmpty || isInProgress || offsetTarget != nil }
    var isInProgress: Bool {
        dragStart != nil || chainEnd != nil || arcChord != nil || !splinePoints.isEmpty || rectangleBase != nil
            || stepBase != nil
    }
    /// Zweiter Schritt eines zweistufigen Werkzeugs steht aus
    var isWaitingForSecondStep: Bool { stepBase != nil }
    var isWaitingForRectangleHeight: Bool { rectangleBase != nil }
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
    func load(plane: SketchPlane, entities: [SketchEntity], constraints: [SketchConstraint] = [],
              construction: Set<Int> = []) {
        isChoosingPlane = false
        if let base = plane.base { basePlane = base }
        self.plane = plane
        self.entities = entities
        self.constraints = constraints
        self.construction = construction
        selection = []
        marks = []
        guideLines = []
        selectedMarks = []
        capturedPoints = []
        undoStack = []
        entitiesChanged()
    }

    // MARK: Eingabe

    func began(at point: Point2, tolerance: Double) {
        // Der Stift setzt auf: Schwebe-Fadenkreuz aus
        hoverSnap = nil
        hoverNodes = []
        if tool == .select {
            beginSelectDrag(at: point, tolerance: tolerance)
            return
        }
        let anchor: Point2? = switch tool {
        case .polyline: chainEnd
        case .spline: splinePoints.last
        default: nil
        }
        let p = snap(point, tolerance: tolerance, anchor: anchor)
        dragStart = p
        dragCurrent = p
        strokeSamples = [point]
        strokeShape = nil
        strokeTolerance = tolerance
        arcLatched = arcModifier
        if tool == .arc, arcMode == .center, let base = stepBase {
            let a0 = atan2(base.end.y - base.start.y, base.end.x - base.start.x)
            arcLastAngle = atan2(p.y - base.start.y, p.x - base.start.x)
            arcSweep = remainder(arcLastAngle - a0, 2 * .pi)
        }
        hoverSnap = nil
        hoverNodes = []
        changed()
    }

    func moved(to point: Point2, tolerance: Double) {
        if tool == .select {
            moveSelectDrag(to: point, tolerance: tolerance)
            return
        }
        guard dragStart != nil else { return }
        dragCurrent = snap(point, tolerance: tolerance, anchor: strokeAnchor)
        if strokeSamples.count < 4000 { strokeSamples.append(point) }
        if tool == .polyline, strokeSamples.count % 4 == 0 { strokeShape = recognizedShape() }
        if tool == .arc, arcMode == .center, let base = stepBase, let current = dragCurrent,
           simd_distance(current, base.start) > 1e-9 {
            let angle = atan2(current.y - base.start.y, current.x - base.start.x)
            arcSweep += remainder(angle - arcLastAngle, 2 * .pi)
            arcLastAngle = angle
        }
        if tool == .circle, let center = dragStart {
            circleInference = nil
            if !Self.isPointSnap(activeSnap?.kind), let found = inferCircle(center: center, raw: point, tolerance: tolerance) {
                circleInference = found
                dragCurrent = found.point
                activeSnap = SnapResult(point: found.point, kind: .onCurve)
            }
        }
        // Der Stift liefert bis zu 240 Punkte pro Sekunde: nicht jedes Mal die Oberfläche neu aufbauen,
        // der Viewport zeichnet selbst neu.
        changed(publish: false)
    }

    func ended(at point: Point2, tolerance: Double) {
        if tool == .select {
            endSelectDrag(at: point, tolerance: tolerance)
            return
        }
        guard let start = dragStart else { return }
        let previewed = dragCurrent, previewedKind = activeSnap?.kind
        var end = snap(point, tolerance: tolerance, anchor: strokeAnchor)
        var endKind = activeSnap?.kind
        // Beim Abheben zittert der Stift: es gilt der zuletzt angezeigte (eingerastete) Punkt, sonst springt
        // eine gerade noch parallele Linie im letzten Moment aus dem Fang
        if let previewed, strokeSamples.count > 1, let last = strokeSamples.last,
           simd_distance(last, point) <= tolerance * 0.5 {
            end = previewed
            endKind = previewedKind
        }
        let samples = strokeSamples + [point]
        // Angezeigter Kreis/Bogen des runden Strichs: wird übernommen, auch wenn die Erkennung mit dem
        // letzten (zittrigen) Punkt knapp scheitert – vorher wurde trotz Halbkreis-Vorschau eine Gerade daraus
        let previewShape = strokeShape
        // Angezeigter tangentialer Bogen: genau dieser wird übernommen (nicht neu berechnet)
        let shownArc = tool == .polyline && arcActive ? previewed.flatMap { arcPreview(to: $0) } : nil
        circleInference = nil
        let arcStroke = arcActive
        arcLatched = false
        dragStart = nil
        dragCurrent = nil
        activeSnap = nil
        parallelLines = []
        strokeSamples = []
        strokeShape = nil

        // Kritzeln über Elemente löscht sie (in allen Zeichenwerkzeugen)
        if Self.scribbleTools.contains(tool), !arcStroke, arcChord == nil, stepBase == nil,
           StrokeGesture.isScribble(samples, tolerance: tolerance) {
            eraseScribbled(samples, tolerance: tolerance)
            changed()
            return
        }

        switch tool {
        case .rectangle:
            endRectangleStroke(start: start, end: end)
        case .circle where circleMode == .twoPoint:
            if let circle = SketchShapes.circle(diameterFrom: start, to: end) { add(circle, editable: true) }
        case .circle where circleMode == .threePoint:
            if let base = stepBase {
                stepBase = nil
                if let circle = SketchShapes.circle(through: base.start, end, base.end) { add(circle, editable: true) }
            } else if simd_distance(start, end) > 1e-6 {
                stepBase = (start, end)
            }
        case .circle:
            var radius = simd_distance(start, end)
            let inference = Self.isPointSnap(endKind) ? nil : inferCircle(center: start, raw: point, tolerance: tolerance)
            if let inference { radius = inference.radius }
            if radius > 0 {
                add(.circle(center: start, radius: radius), editable: true)
                inferConstraints(forNew: entities.count - 1, center: start, inference: inference)
            }
        case .ellipse:
            let radii = simd_abs(end - start)
            if radii.x > 0, radii.y > 0 {
                add(.ellipse(center: start, radii: radii), editable: true)
                inferConstraints(forNew: entities.count - 1, center: start, inference: nil)
            }
        case .polygon:
            if let polygon = SketchShapes.polygon(center: start, through: end, sides: polygonSides, mode: polygonMode) {
                add(polygon, editable: true)
                inferConstraints(forNew: entities.count - 1, center: start, inference: nil)
            }
        case .polyline:
            // Finger aufgelegt: tangentialer Bogen am Ende des Linienzugs
            if arcStroke {
                if let arc = shownArc ?? arcPreview(to: end, origin: start, samples: samples) {
                    commitTangentArc(arc)
                    break
                }
                notice = "Kein Bogen möglich: Der Strich ist gerade – Gerade gezeichnet."
            }
            // Rund gezogen: Kreis bzw. Bogen statt Linie
            if !endShapeStroke(samples, start: start, end: end, tolerance: tolerance, preview: previewShape) {
                endLineStroke(start: start, end: end)
                if !arcStroke, simd_distance(start, end) > tolerance,
                   StrokeGesture.length(samples) > simd_distance(start, end) * 1.3 {
                    // Rund gezogen, aber keine Bogen-Taste und keine Erkennung: sagen, warum es gerade wurde
                    notice = "Gerade gezeichnet – für einen Bogen beim Zeichnen einen Finger auflegen."
                }
            }
        case .arc where arcMode == .center:
            // Fusion 360: Mittelpunkt zum Start ziehen, dann das Ende (der Bogen folgt dem Stift)
            if let base = stepBase {
                stepBase = nil
                if let arc = SketchShapes.arc(center: base.start, start: base.end, sweep: arcSweep) {
                    add(arc, editable: true)
                }
            } else if simd_distance(start, end) > 1e-6 {
                stepBase = (start, end)
            }
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
        case .trim:
            // Ungefangener Punkt: der Fang würde auf Schnittpunkte springen
            trim(at: point, tolerance: tolerance)
        case .fillet:
            filletCorner(at: point, tolerance: tolerance)
        case .chamfer:
            filletCorner(at: point, tolerance: tolerance, chamfer: true)
        case .slot:
            if let base = stepBase {
                stepBase = nil
                if let shapes = slotEntities(base: base, through: end) { addGroup(shapes) }
            } else if simd_distance(start, end) > 1e-6 {
                stepBase = (start, end)
            }
        case .extend:
            extendLine(at: point, tolerance: tolerance)
        case .breakCurve:
            breakCurve(at: point, tolerance: tolerance)
        case .mirror, .rectPattern, .circPattern:
            // Antippen wählt Elemente (bzw. beim Spiegeln zuletzt die Achse), angewendet wird über die Karte
            select(at: point, tolerance: tolerance)
        case .measure:
            measure(at: point, tolerance: tolerance)
        case .project, .scale, .select:
            // Projizieren übernimmt der Viewport (braucht die Körperkanten), Skalieren die Parameterkarte
            break
        }
        changed()
    }

    /// Rechteck je nach Variante: Diagonal (Ecke zu Ecke), Mitte (Mitte zu Ecke), 3 Punkte (Kante, dann Höhe).
    private func endRectangleStroke(start: Point2, end: Point2) {
        switch rectangleMode {
        case .diagonal:
            let size = end - start
            if size.x != 0, size.y != 0 { add(.rectangle(corner: start, size: size), editable: true) }
        case .center:
            let half = end - start
            if half.x != 0, half.y != 0 { add(.rectangle(corner: start - half, size: half * 2), editable: true) }
        case .threePoint:
            if let base = rectangleBase {
                rectangleBase = nil
                let corners = Self.threePointCorners(base.start, base.end, end)
                if abs(signedArea(corners)) > 1e-9 { add(.polyline(corners, closed: true)) }
            } else if simd_distance(start, end) > 1e-6 {
                rectangleBase = (start, end)
            }
        }
    }

    /// Ecken eines gedrehten Rechtecks: Kante a–b, Höhe bis zur Lotlinie durch p.
    private static func threePointCorners(_ a: Point2, _ b: Point2, _ p: Point2) -> [Point2] {
        let n = rightNormal(b - a)
        let h = simd_dot(p - a, n)
        return [a, b, b + n * h, a + n * h]
    }

    func cancelStroke() {
        if let drag = selectDrag {
            if drag.hasMoved {
                entities = drag.original
                undoStack.removeLast()
                entitiesChanged()
            }
            selectDrag = nil
        }
        selectStart = nil
        dragStart = nil
        dragCurrent = nil
        strokeSamples = []
        strokeShape = nil
        circleInference = nil
        arcLatched = false
        activeSnap = nil
        parallelLines = []
        changed()
    }

    // MARK: Abhängigkeiten erkennen (wie Fusion 360)

    /// Erkannte Abhängigkeit beim Aufziehen eines Kreises: Radius rastet ein, beim Loslassen wird die
    /// passende Einschränkung gesetzt (variant bekommt die Kurve des neuen Kreises).
    private struct CircleInference {
        var point: Point2
        var radius: Double
        var label: String
        var variant: ((SketchCurveRef) -> SketchConstraint.Variant)?
    }

    private static func isPointSnap(_ kind: SnapKind?) -> Bool {
        guard let kind else { return false }
        return [.endpoint, .midpoint, .center, .intersection].contains(kind)
    }

    /// Radius, bei dem der Kreis eine Linie oder einen Kreis berührt, denselben Radius wie ein vorhandener
    /// Kreis hat oder durch einen Fangpunkt geht – der nächste innerhalb des Fangradius.
    private func inferCircle(center: Point2, raw: Point2, tolerance: Double) -> CircleInference? {
        let current = simd_distance(center, raw)
        guard snapEnabled, current > tolerance else { return nil }
        let direction = (raw - center) / current
        var best: (score: Double, inference: CircleInference)?
        func consider(_ radius: Double, point: Point2?, label: String, weight: Double,
                      variant: ((SketchCurveRef) -> SketchConstraint.Variant)?) {
            guard radius > 1e-6 else { return }
            let score = abs(radius - current) * weight
            guard score <= tolerance, score < (best?.score ?? .infinity) else { return }
            best = (score, CircleInference(point: point ?? center + direction * radius, radius: radius, label: label,
                                           variant: variant))
        }
        for (index, entity) in entities.enumerated() {
            if case .text = entity { continue }
            for k in 0..<entity.curveCount {
                let ref = SketchCurveRef(entity: index, index: k)
                switch entity.constraintCurve(k) {
                case .line(let a, let b):
                    let d = b - a
                    let lengthSquared = simd_length_squared(d)
                    guard lengthSquared > 1e-12 else { continue }
                    let t = simd_dot(center - a, d) / lengthSquared
                    guard t >= -0.02, t <= 1.02 else { continue }
                    let foot = a + d * t
                    consider(simd_distance(center, foot), point: foot, label: "Tangential an Linie", weight: 1) {
                        .tangent(ref, $0, outside: true)
                    }
                case .circle(let c, let r):
                    consider(r, point: nil, label: "Gleicher Radius", weight: 0.9) { .equalRadius(ref, $0) }
                    let distance = simd_distance(center, c)
                    guard distance > 1e-6 else { continue }
                    let toward = (c - center) / distance
                    if distance > r {
                        consider(distance - r, point: center + toward * (distance - r), label: "Tangential an Kreis",
                                 weight: 1) { .tangent(ref, $0, outside: true) }
                    } else {
                        consider(r - distance, point: center - toward * (r - distance), label: "Tangential innen",
                                 weight: 1) { .tangent(ref, $0, outside: false) }
                    }
                    consider(distance + r, point: center + toward * (distance + r), label: "Umschließt tangential",
                             weight: 1) { .tangent(ref, $0, outside: false) }
                case .other:
                    break
                }
            }
        }
        for p in snapIndex.endpoints + snapIndex.midpoints + snapIndex.centers where simd_distance(p, center) > 1e-6 {
            consider(simd_distance(center, p), point: p, label: "Durch Punkt", weight: 1.1, variant: nil)
        }
        return best?.inference
    }

    /// Nach dem Zeichnen von Kreis, Ellipse bzw. Polygon die erkannten Abhängigkeiten als Einschränkungen setzen:
    /// Mitte einer Linie, auf einer Linie, konzentrisch, sowie tangential bzw. gleicher Radius aus dem Aufziehen.
    /// Die Mitte eines Rechtecks ist ein Griffpunkt und wird schon beim Hinzufügen verbunden (connect).
    private func inferConstraints(forNew index: Int, center: Point2, inference: CircleInference?) {
        guard entities.indices.contains(index) else { return }
        let centerRef = SketchPointRef(entity: index, index: centerIndex(of: index))
        var added: [SketchConstraint.Variant] = []
        var labels: [String] = []
        for (other, entity) in entities.enumerated() where other != index {
            if case .rectangle(let corner, let size) = entity, simd_distance(corner + size / 2, center) < 1e-6 {
                if !labels.contains("Mitte des Rechtecks") { labels.append("Mitte des Rechtecks") }
                continue
            }
            for k in 0..<entity.curveCount {
                let ref = SketchCurveRef(entity: other, index: k)
                switch entity.constraintCurve(k) {
                case .line(let a, let b):
                    if simd_distance((a + b) / 2, center) < 1e-6 {
                        added.append(.midpoint(centerRef, ref))
                        labels.append("Mitte der Linie")
                    } else if simd_distance(a, center) > 1e-6, simd_distance(b, center) > 1e-6,
                              polylineDistance(from: center, to: [a, b], closed: false).distance < 1e-6 {
                        added.append(.pointOnCurve(centerRef, ref))
                        labels.append("Mitte auf Linie")
                    }
                case .circle(let c, _):
                    if simd_distance(c, center) < 1e-6, case .circle = entities[index], case .circle = entity {
                        added.append(.concentric(ref, SketchCurveRef(entity: index, index: 0)))
                        labels.append("Konzentrisch")
                    }
                case .other:
                    break
                }
            }
        }
        if let variant = inference?.variant, let label = inference?.label {
            added.append(variant(SketchCurveRef(entity: index, index: 0)))
            labels.append(label)
        }
        guard !labels.isEmpty else { return }
        let beforeEntities = entities, beforeConstraints = constraints
        constraints += added.map { SketchConstraint(variant: $0) }
        let fixed = Set(entities.indices).subtracting([index])
        if added.isEmpty {
            notice = "Abhängigkeit gesetzt: " + labels.joined(separator: ", ") + "."
        } else if let solved = ConstraintSolver.solve(entities, constraints: constraints, locked: fixed) {
            entities = solved
            notice = "Abhängigkeit gesetzt: " + labels.joined(separator: ", ") + " (mit „Trennen“ rechts lösbar)."
        } else {
            entities = beforeEntities
            constraints = beforeConstraints
        }
        entitiesChanged()
    }

    /// Vorschläge beim Zeichnen von Kreis, Ellipse, Polygon und Rechteck von der Mitte: alle Mitten von
    /// Rechtecken, Kreisen und Linien, an denen der Stift einrastet.
    var suggestionNodes: [(point: Point2, kind: SnapKind)] {
        let centered = tool == .circle || tool == .ellipse || tool == .polygon
            || (tool == .rectangle && rectangleMode == .center)
        guard snapEnabled, centered, dragStart == nil else { return [] }
        return snapIndex.centers.map { ($0, SnapKind.center) } + snapIndex.midpoints.map { ($0, SnapKind.midpoint) }
    }

    // MARK: Tangentialer Bogen (Finger aufgelegt)

    /// Richtung, in der ein Linienzug an point weiterläuft: Linie bzw. Bogen, die dort enden (neueste zuerst).
    /// Zeigt vom Element weg, damit der Bogen glatt anschließt.
    private func outwardTangent(at point: Point2, tolerance: Double) -> (direction: Point2, entity: Int)? {
        for index in entities.indices.reversed() {
            switch entities[index] {
            case .line(let a, let b) where simd_distance(a, b) > 1e-9:
                if simd_distance(b, point) <= tolerance { return (simd_normalize(b - a), index) }
                if simd_distance(a, point) <= tolerance { return (simd_normalize(a - b), index) }
            case .arc(let a, let m, let b):
                guard let circle = circleThrough(a, m, b) else { continue }
                let counterClockwise = cross2D(m - a, b - m) > 0
                // Laufrichtung des Bogens an einem Punkt (von a über m nach b)
                func travel(_ p: Point2) -> Point2 {
                    let radial = p - circle.center
                    return counterClockwise ? Point2(-radial.y, radial.x) : Point2(radial.y, -radial.x)
                }
                if simd_distance(b, point) <= tolerance, simd_length(travel(b)) > 1e-12 {
                    return (simd_normalize(travel(b)), index)
                }
                if simd_distance(a, point) <= tolerance, simd_length(travel(a)) > 1e-12 {
                    return (simd_normalize(-travel(a)), index)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Anfang des tangentialen Bogens: Ende des Linienzugs, oder – setzt der Stift an einem anderen
    /// Linien- bzw. Bogenende an – dieses Ende.
    private func arcAnchor(from origin: Point2?) -> (start: Point2, direction: Point2, entity: Int)? {
        let reach = max(strokeTolerance, 1e-6)
        // Stift genau auf einem Linien- bzw. Bogenende angesetzt (eingerastet): dort beginnt der Bogen,
        // auch wenn der Linienzug woanders endet
        if let origin, chainEnd.map({ simd_distance($0, origin) > 1e-6 }) ?? true,
           let tangent = outwardTangent(at: origin, tolerance: 1e-6) {
            return (origin, tangent.direction, tangent.entity)
        }
        if let end = chainEnd, origin.map({ simd_distance($0, end) <= reach * 2 }) ?? true,
           let tangent = outwardTangent(at: end, tolerance: 1e-6) {
            return (end, tangent.direction, tangent.entity)
        }
        if let origin, let tangent = outwardTangent(at: origin, tolerance: reach) {
            let start: Point2 = switch entities[tangent.entity] {
            case .line(let a, let b), .arc(let a, _, let b): simd_distance(a, origin) < simd_distance(b, origin) ? a : b
            default: origin
            }
            return (start, tangent.direction, tangent.entity)
        }
        // Stift irgendwo angesetzt: wie die Linie am Ende des Linienzugs weiter
        if let end = chainEnd, let tangent = outwardTangent(at: end, tolerance: 1e-6) {
            return (end, tangent.direction, tangent.entity)
        }
        return nil
    }

    private func cross2D(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }

    /// Bogen vom Ende des Linienzugs nach end, tangential an das letzte Stück.
    private func tangentArc(to end: Point2, from origin: Point2? = nil) -> (entity: SketchEntity, previous: Int)? {
        guard let anchor = arcAnchor(from: origin ?? dragStart),
              let arc = Self.tangentArcShape(start: anchor.start, direction: anchor.direction, end: end) else { return nil }
        return (arc, anchor.entity)
    }

    /// Bogen von start nach end, der in start in Richtung direction losläuft. nil, wenn end (fast) auf der
    /// Verlängerung liegt.
    private static func tangentArcShape(start: Point2, direction: Point2, end: Point2) -> SketchEntity? {
        let d = end - start
        let normal = Point2(-direction.y, direction.x)
        let side = simd_dot(d, normal)
        // Fast gerade weiter: kein Bogen
        guard simd_length(d) > 1e-6, abs(side) > simd_length(d) * 0.02 else { return nil }
        let radius = simd_length_squared(d) / (2 * side)
        let center = start + normal * radius
        let a0 = atan2(start.y - center.y, start.x - center.x)
        let a1 = atan2(end.y - center.y, end.x - center.x)
        var sweep = a1 - a0
        if radius > 0 {
            while sweep <= 0 { sweep += 2 * .pi }
        } else {
            while sweep >= 0 { sweep -= 2 * .pi }
        }
        let middle = a0 + sweep / 2
        let mid = center + Point2(cos(middle), sin(middle)) * abs(radius)
        guard circleThrough(start, mid, end) != nil else { return nil }
        return .arc(start: start, mid: mid, end: end)
    }

    /// Bogen des Bogen-Strichs (Finger aufgelegt): tangential, wenn möglich. Liegt das Ende auf der
    /// Verlängerung der Tangente (dort gibt es keinen tangentialen Bogen, z. B. beim Schließen zum
    /// Linienanfang), folgt der Bogen dem gezogenen Strich: Anfang, weitester Punkt, Ende.
    /// So wird ein gezeichneter Halbkreis immer ein Halbkreis. previous = Element, an das er tangential ansetzt.
    private func arcPreview(to end: Point2, origin: Point2? = nil, samples: [Point2]? = nil)
        -> (entity: SketchEntity, previous: Int?)? {
        if let arc = tangentArc(to: end, from: origin) { return (arc.entity, arc.previous) }
        guard let from = origin ?? dragStart else { return nil }
        // Tangential am Ziel: Endet der Strich an einem Linien- bzw. Bogenende (z. B. am Anfang der ersten
        // Linie), schließt der Bogen dort tangential an – auch wenn der Stift gerade zum Ziel gezogen wurde
        if let target = outwardTangent(at: end, tolerance: 1e-6),
           case .arc(let a, let m, let b)? = Self.tangentArcShape(start: end, direction: target.direction, end: from) {
            return (.arc(start: b, mid: m, end: a), target.entity)
        }
        let points = samples ?? strokeSamples
        let chord = end - from
        let length = simd_length(chord)
        guard length > 1e-6 else { return nil }
        let normal = Point2(-chord.y, chord.x) / length
        guard let far = points.max(by: { abs(simd_dot($0 - from, normal)) < abs(simd_dot($1 - from, normal)) }),
              abs(simd_dot(far - from, normal)) > max(length * 0.05, strokeTolerance * 0.5),
              circleThrough(from, far, end) != nil else { return nil }
        // Durch den weitesten Punkt, aber als Mitte des Bogens (gleich weit von beiden Enden)
        guard let circle = circleThrough(from, far, end) else { return nil }
        let side = simd_dot(far - from, normal) > 0 ? 1.0 : -1.0
        let middle = (from + end) / 2
        let toMiddle = middle - circle.center
        var mid = circle.center + (simd_length(toMiddle) > 1e-9 ? simd_normalize(toMiddle) : normal * side) * circle.radius
        // Die Bogenmitte muss auf der Seite des gezogenen Strichs liegen
        if simd_dot(mid - from, normal) * side < 0 { mid = circle.center * 2 - mid }
        guard circleThrough(from, mid, end) != nil else { return nil }
        return (.arc(start: from, mid: mid, end: end), nil)
    }

    /// Tangentialen Bogen übernehmen; der Linienzug geht an seinem Ende weiter.
    private func commitTangentArc(_ arc: (entity: SketchEntity, previous: Int?)) {
        guard case .arc(_, _, let end) = arc.entity else { return }
        // Bogen an einem anderen Ende angesetzt: dort beginnt ein neuer Linienzug
        if case .arc(let arcStart, _, _) = arc.entity, chainEnd.map({ simd_distance($0, arcStart) > 1e-6 }) ?? true {
            chainStart = arcStart
        }
        add(arc.entity, editable: true)
        let index = entities.count - 1
        if let previous = arc.previous {
            let variant = SketchConstraint.Variant.tangent(SketchCurveRef(entity: previous, index: 0),
                                                           SketchCurveRef(entity: index, index: 0), outside: true)
            constraints.append(SketchConstraint(variant: variant))
            if ConstraintSolver.solve(entities, constraints: constraints, locked: Set(entities.indices)) == nil {
                constraints.removeLast()
            }
        }
        if let first = chainStart, simd_distance(first, end) < 1e-6 {
            chainStart = nil
            chainEnd = nil
        } else {
            chainEnd = end
        }
        entitiesChanged()
    }

    // MARK: Stiftgesten

    private static let scribbleTools: Set<SketchTool> = [.polyline, .arc, .spline, .rectangle, .circle, .ellipse, .polygon]

    /// Linienwerkzeug: Kreis bzw. Bogen, den der laufende Strich ergibt (nil = gerade Linie).
    private func recognizedShape() -> SketchEntity? {
        guard let start = dragStart, let current = dragCurrent,
              let shape = StrokeGesture.recognize(strokeSamples, tolerance: strokeTolerance) else { return nil }
        switch shape {
        case .circle(let center, let radius):
            return .circle(center: center, radius: radius)
        case .arc(let mid):
            let from = chainEnd ?? start
            guard circleThrough(from, mid, current) != nil else { return nil }
            return .arc(start: from, mid: mid, end: current)
        }
    }

    /// Kreis oder Bogen aus einem runden Strich des Linienwerkzeugs übernehmen. false = gerade Linie.
    private func endShapeStroke(_ samples: [Point2], start: Point2, end: Point2, tolerance: Double,
                                preview: SketchEntity? = nil) -> Bool {
        var previewed: StrokeGesture.Shape?
        switch preview {
        case .circle(let center, let radius)?: previewed = .circle(center: center, radius: radius)
        case .arc(_, let mid, _)?: previewed = .arc(mid: mid)
        default: previewed = nil
        }
        guard let shape = StrokeGesture.recognize(samples, tolerance: tolerance) ?? previewed else { return false }
        switch shape {
        case .circle(let center, let rawRadius):
            // Mitte rastet auf vorhandene Punkte ein, der Radius aufs Raster
            let kinds: Set<SnapKind> = [.endpoint, .center, .intersection, .midpoint]
            let snapped = snapEnabled
                ? snapIndex.snap(center, tolerance: tolerance, kinds: kinds, extra: inputPoints, gridStep: 0).point : center
            var radius = rawRadius
            if snapEnabled, gridStep > 0 { radius = max(gridStep, (rawRadius / gridStep).rounded() * gridStep) }
            add(.circle(center: snapped, radius: radius), editable: true)
            // Ein Kreis beendet den Linienzug
            chainStart = nil
            chainEnd = nil
            notice = "Kreis erkannt – Durchmesser lässt sich eintippen, Rückgängig nimmt ihn zurück."
        case .arc(let mid):
            let from = chainEnd ?? start
            // Der Bogen muss am Anfang des Strichs ansetzen
            guard let first = samples.first, simd_distance(first, from) <= tolerance * 1.5 || previewed != nil,
                  simd_distance(from, end) > 1e-6, circleThrough(from, mid, end) != nil else { return false }
            if chainEnd == nil { chainStart = from }
            add(.arc(start: from, mid: mid, end: end), editable: true)
            if let first = chainStart, simd_distance(first, end) < 1e-6 {
                chainStart = nil
                chainEnd = nil
            } else {
                chainEnd = end
            }
            notice = "Bogen erkannt – der Linienzug geht am Ende weiter."
        }
        return true
    }

    /// Kritzeln: alle Elemente löschen, über die gekritzelt wurde.
    private func eraseScribbled(_ samples: [Point2], tolerance: Double) {
        let hit = StrokeGesture.scribbledEntities(samples, entities: entities, reach: tolerance * 0.5)
        guard !hit.isEmpty else {
            notice = "Kritzeln löscht Elemente – direkt über eine Linie oder einen Kreis kritzeln."
            return
        }
        remember()
        removeEntities(hit)
        notice = hit.count == 1 ? "1 Element weggekritzelt (Rückgängig holt es zurück)."
            : "\(hit.count) Elemente weggekritzelt (Rückgängig holt sie zurück)."
        entitiesChanged()
    }

    /// Stift drücken bzw. doppeltippen beim Schweben: liegt ein Fangpunkt (Ende, Mitte, Zentrum, Schnittpunkt,
    /// Hilfspunkt) unter dem Stift, wird er gemerkt. false = nichts in der Nähe.
    func captureHovered(at p: Point2, tolerance: Double) -> Bool {
        let kinds: Set<SnapKind> = [.endpoint, .midpoint, .center, .intersection]
        guard snapIndex.snap(p, tolerance: tolerance * 1.5, kinds: kinds, extra: marks, gridStep: 0).kind != nil else {
            return false
        }
        capturePoint(at: p, tolerance: tolerance)
        return true
    }

    /// Stift über einem Punkt drücken: Fangpunkt (Ende, Mitte, Zentrum, Schnittpunkt, Hilfspunkt) merken.
    /// Zwei gemerkte Punkte ergeben ihre Mitte als neuen Hilfspunkt (Dreieck), der selbst wieder fangbar ist.
    func capturePoint(at p: Point2, tolerance: Double) {
        let kinds: Set<SnapKind> = [.endpoint, .midpoint, .center, .intersection, .onCurve]
        let point = snapIndex.snap(p, tolerance: tolerance * 1.5, kinds: kinds, extra: marks, gridStep: 0).point
        if let index = capturedPoints.firstIndex(where: { simd_distance($0, point) < 1e-6 }) {
            capturedPoints.remove(at: index)
            notice = nil
            changed()
            return
        }
        capturedPoints.append(point)
        if capturedPoints.count >= 2 {
            let a = capturedPoints[0], b = capturedPoints[1]
            let middle = (a + b) / 2
            if simd_distance(a, b) > 1e-6, !marks.contains(where: { simd_distance($0, middle) < 1e-6 }) {
                marks.append(middle)
                // Mittellinie: Verbindung der beiden Punkte und Mittelsenkrechte
                let half = simd_distance(a, b) * 0.6
                let across = rightNormal(b - a)
                guideLines.append((middle, [[a, b], [middle - across * half, middle + across * half]]))
            }
            capturedPoints = []
            notice = "Mitte gesetzt (Dreieck, fangbar) – gestrichelt die Mittellinie."
        } else {
            notice = "Punkt 1 gemerkt – zweiten Punkt merken (Stift darüber drücken bzw. doppeltippen)."
        }
        changed()
    }

    // MARK: Abrunden (Ecke zweier Linien)

    /// Ecke antippen: die beiden Linien werden gekürzt und durch einen tangentialen Bogen mit filletRadius
    /// verbunden. Rechtecke und Linienzüge werden dafür in einzelne Linien zerlegt.
    func filletCorner(at p: Point2, tolerance: Double, chamfer: Bool = false) {
        guard let corner = nearestCorner(to: p, tolerance: tolerance * 1.5) else {
            notice = "Ecke antippen, an der zwei Linien zusammenstoßen."
            changed()
            return
        }
        let radius = chamfer ? chamferDistance : filletRadius
        guard radius > 0 else { return }
        let before = (entities: entities, constraints: constraints, construction: construction)
        remember()
        func fail(_ message: String) {
            undoStack.removeLast()
            entities = before.entities
            constraints = before.constraints
            construction = before.construction
            notice = message
            entitiesChanged()
        }
        for index in entities.indices.reversed() {
            switch entities[index] {
            case .rectangle, .polyline:
                if entities[index].handlePoints.contains(where: { simd_distance($0, corner) < 1e-6 }) { explode(index) }
            default:
                break
            }
        }
        let lines = entities.indices.filter { index in
            guard case .line(let a, let b) = entities[index] else { return false }
            return simd_distance(a, corner) < 1e-6 || simd_distance(b, corner) < 1e-6
        }
        guard lines.count == 2, case .line(let a1, let b1) = entities[lines[0]],
              case .line(let a2, let b2) = entities[lines[1]] else {
            fail("Hier stoßen nicht genau zwei Linien zusammen.")
            return
        }
        let firstAtStart = simd_distance(a1, corner) < 1e-6, secondAtStart = simd_distance(a2, corner) < 1e-6
        let far1 = firstAtStart ? b1 : a1, far2 = secondAtStart ? b2 : a2
        let u1 = simd_normalize(far1 - corner), u2 = simd_normalize(far2 - corner)
        let theta = acos(min(max(simd_dot(u1, u2), -1), 1))
        guard theta > 1e-3, theta < .pi - 1e-3 else {
            fail("Die Linien liegen in einer Flucht – keine Ecke zum Abrunden.")
            return
        }
        // Fase: gleicher Abstand auf beiden Linien; Rundung: Tangentenlänge aus dem Radius
        let t = chamfer ? radius : radius / tan(theta / 2)
        guard t < simd_distance(far1, corner) - 1e-6, t < simd_distance(far2, corner) - 1e-6 else {
            fail(chamfer ? "Fase zu groß für diese Ecke." : "Radius zu groß für diese Ecke.")
            return
        }
        let t1 = corner + u1 * t, t2 = corner + u2 * t
        let bisector = simd_normalize(u1 + u2)
        let center = corner + bisector * (radius / sin(theta / 2))
        let mid = center - bisector * radius
        entities[lines[0]] = firstAtStart ? .line(t1, b1) : .line(a1, t1)
        entities[lines[1]] = secondAtStart ? .line(t2, b2) : .line(a2, t2)
        // Die alte Ecke gibt es nicht mehr
        let pair = Set(lines)
        constraints.removeAll { constraint in
            if case .coincident = constraint.variant { return Set(constraint.entities) == pair }
            return false
        }
        entities.append(chamfer ? .line(t1, t2) : .arc(start: t1, mid: mid, end: t2))
        let arc = entities.count - 1
        if construction.contains(lines[0]) { construction.insert(arc) }
        connect(arc)
        selection = []
        editableIndex = arc
        notice = nil
        entitiesChanged()
    }

    /// Nächste Ecke (Linienende, Rechteck- oder Linienzugecke) beim Punkt.
    private func nearestCorner(to p: Point2, tolerance: Double) -> Point2? {
        var best: (distance: Double, point: Point2)?
        for entity in entities {
            let corners: [Point2]
            switch entity {
            case .line(let a, let b): corners = [a, b]
            case .rectangle: corners = Array(entity.handlePoints.prefix(4))
            case .polyline(let points, _): corners = points
            default: continue
            }
            for q in corners {
                let d = simd_distance(p, q)
                if d <= tolerance, d < (best?.distance ?? .infinity) { best = (d, q) }
            }
        }
        return best?.point
    }

    /// Rechteck bzw. Linienzug in einzelne, verbundene Linien zerlegen.
    private func explode(_ index: Int) {
        let entity = entities[index]
        let points: [Point2]
        let closed: Bool
        switch entity {
        case .rectangle:
            points = Array(entity.handlePoints.prefix(4))
            closed = true
        case .polyline(let corners, let isClosed):
            points = corners
            closed = isClosed
        default:
            return
        }
        let wasConstruction = construction.contains(index)
        removeEntities([index])
        let count = closed ? points.count : points.count - 1
        guard count > 0 else { return }
        for k in 0..<count {
            let a = points[k], b = points[(k + 1) % points.count]
            guard simd_distance(a, b) > 1e-9 else { continue }
            entities.append(.line(a, b))
            if wasConstruction { construction.insert(entities.count - 1) }
            connect(entities.count - 1)
        }
    }

    // MARK: Pfeil-Werkzeug (Auswählen, Verschieben, Größe ändern)

    private struct SelectDrag {
        enum Kind {
            /// Griffpunkt (Ecke, Ende, Zentrum) ziehen
            case handle(Int)
            /// Kante eines Rechtecks bzw. Linienzugs parallel verschieben
            case edge(Int)
            /// Kreis- bzw. Ellipsenrand: Größe ändern
            case radius
            /// Bogen: Wölbung ändern
            case bulge
            /// Ganzes Element verschieben
            case move
        }
        var entity: Int
        var kind: Kind
        var start: Point2
        /// Gegriffener Punkt am Element (Griffpunkt bzw. Aufsetzpunkt)
        var grab: Point2
        var original: [SketchEntity]
        /// Fang ohne das gezogene Element (sonst rastet es an seiner alten Lage ein)
        var snapIndex: SnapIndex
        var hasMoved = false
    }

    private func beginSelectDrag(at p: Point2, tolerance: Double) {
        selectStart = (point: p, tolerance: tolerance)
        selectDrag = nil
        guard let ref = pick(at: p, tolerance: tolerance), entities.indices.contains(ref.entity) else { return }
        let index = ref.entity
        let kind: SelectDrag.Kind
        var grab = p
        switch ref {
        case .point(let point):
            kind = .handle(point.index)
            let handles = entities[index].handlePoints
            if handles.indices.contains(point.index) { grab = handles[point.index] }
        case .curve(let curve):
            switch entities[index] {
            case .circle, .ellipse: kind = .radius
            case .arc: kind = .bulge
            case .rectangle, .polyline: kind = .edge(curve.index)
            default: kind = .move
            }
        }
        let others = entities.indices.filter { $0 != index }.map { entities[$0] }
        selectDrag = SelectDrag(entity: index, kind: kind, start: p, grab: grab, original: entities,
                                snapIndex: SnapIndex(entities: others))
    }

    private func moveSelectDrag(to p: Point2, tolerance: Double) {
        guard var drag = selectDrag else { return }
        if !drag.hasMoved {
            // Kleines Zittern beim Tippen ist noch kein Ziehen
            guard simd_distance(p, drag.start) > tolerance * 0.15 else { return }
            drag.hasMoved = true
            remember()
        }
        let raw = drag.grab + (p - drag.start)
        var target = raw
        if snapEnabled {
            let result = drag.snapIndex.snap(raw, tolerance: tolerance, kinds: snapKinds, extra: marks, gridStep: gridStep)
            activeSnap = result.kind == nil ? nil : result
            target = result.point
        }
        var result = drag.original
        result[drag.entity] = Self.dragged(drag.original[drag.entity], kind: drag.kind, grab: drag.grab, to: target)
        // Verbundene Elemente folgen über die Einschränkungen (gemeinsame Ecken, Mittelpunkte …)
        if !constraints.isEmpty {
            guard let solved = solveKeepingLines(result, moving: drag.entity)?.entities else {
                selectDrag = drag
                notice = "Die Einschränkungen lassen diese Änderung nicht zu (z. B. „Verankern“)."
                changed(publish: false)
                return
            }
            result = solved
        }
        notice = nil
        selectDrag = drag
        entities = result
        changed(publish: false)
    }

    private func endSelectDrag(at p: Point2, tolerance: Double) {
        defer {
            selectDrag = nil
            selectStart = nil
            activeSnap = nil
        }
        if let drag = selectDrag, drag.hasMoved {
            moveSelectDrag(to: p, tolerance: tolerance)
            // Maße des gezogenen Elements bleiben zum Eintippen offen
            editableIndex = drag.entity
            entitiesChanged()
            return
        }
        // Tippen ohne Ziehen: Element wählen bzw. abwählen (wie mit dem Finger)
        let start = selectStart ?? (point: p, tolerance: tolerance)
        select(at: start.point, tolerance: start.tolerance)
        editableIndex = selection.count == 1 ? selection[0].entity : nil
        changed()
    }

    /// Element nach dem Ziehen: aus dem Zustand beim Aufsetzen berechnet, damit sich nichts aufschaukelt.
    private static func dragged(_ entity: SketchEntity, kind: SelectDrag.Kind, grab: Point2, to p: Point2) -> SketchEntity {
        let delta = p - grab
        switch kind {
        case .move:
            return entity.translated(by: delta)
        case .handle(let k):
            return entity.movingHandle(k, to: p) ?? entity.translated(by: delta)
        case .radius:
            switch entity {
            case .circle(let center, _):
                return .circle(center: center, radius: max(simd_distance(center, p), 1e-4))
            case .ellipse(let center, let radii):
                // Gleichmäßig größer bzw. kleiner, Seitenverhältnis bleibt
                let before = simd_distance(center, grab)
                guard before > 1e-9 else { return entity }
                let factor = max(simd_distance(center, p) / before, 1e-4)
                return .ellipse(center: center, radii: radii * factor)
            default:
                return entity.translated(by: delta)
            }
        case .bulge:
            if case .arc(let a, _, let b) = entity, circleThrough(a, p, b) != nil {
                return .arc(start: a, mid: p, end: b)
            }
            return entity
        case .edge(let i):
            switch entity {
            case .rectangle(let corner, let size):
                let lo = simd_min(corner, corner + size), hi = simd_max(corner, corner + size)
                let corners = [corner, corner + Point2(size.x, 0), corner + size, corner + Point2(0, size.y)]
                let a = corners[i % 4], b = corners[(i + 1) % 4]
                var newLo = lo, newHi = hi
                if abs(a.y - b.y) < abs(a.x - b.x) {
                    // Waagrechte Kante: nur in y
                    if abs(a.y - lo.y) < abs(a.y - hi.y) { newLo.y += delta.y } else { newHi.y += delta.y }
                } else {
                    if abs(a.x - lo.x) < abs(a.x - hi.x) { newLo.x += delta.x } else { newHi.x += delta.x }
                }
                let low = simd_min(newLo, newHi), high = simd_max(newLo, newHi)
                guard high.x - low.x > 1e-6, high.y - low.y > 1e-6 else { return entity }
                return .rectangle(corner: low, size: high - low)
            case .polyline(var points, let closed):
                guard points.count >= 2 else { return entity }
                let j = i % points.count, k = (i + 1) % points.count
                points[j] += delta
                points[k] += delta
                return .polyline(points, closed: closed)
            default:
                return entity.translated(by: delta)
            }
        }
    }

    /// Bezugspunkt für Winkelschritte während eines Strichs.
    private var strokeAnchor: Point2? {
        switch tool {
        case .polyline: chainEnd ?? dragStart
        case .arc: arcChord == nil && stepBase == nil ? dragStart : nil
        case .slot: stepBase == nil ? dragStart : nil
        case .rectangle: rectangleMode == .threePoint && rectangleBase == nil ? dragStart : nil
        case .spline: splinePoints.last ?? dragStart
        case .circle where circleMode == .threePoint && stepBase != nil: nil
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
            ? withParallel(snapIndex.snap(point, tolerance: tolerance, kinds: snapKinds, extra: inputPoints, anchor: anchor,
                                          gridStep: gridStep), raw: point, anchor: anchor, tolerance: tolerance)
            : SnapResult(point: point, kind: nil)
        let radius = tolerance * 5
        hoverNodes = snapEnabled
            ? (snapIndex.nodes.map { $0.point } + inputPoints).filter { simd_distance($0, point) <= radius }
            : []
    }

    func endHover() {
        hoverSnap = nil
        hoverNodes = []
        if dragStart == nil { parallelLines = [] }
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
        remember()
        let first = entities.count
        entities += added
        if constructionMode { construction.formUnion(first..<entities.count) }
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
        stepBase = nil
        splinePoints = []
        offsetTarget = nil
        offsetPreview = []
        editableIndex = nil
        rectangleBase = nil
        activeSnap = nil
        hoverSnap = nil
        hoverNodes = []
        entities = []
        constraints = []
        construction = []
        selection = []
        marks = []
        guideLines = []
        selectedMarks = []
        capturedPoints = []
        parallelLines = []
        undoStack = []
        notice = nil
        entitiesChanged()
    }

    /// Laufende Eingabe beim Werkzeugwechsel abschließen.
    private func finishInput() {
        if tool != .select { pendingAction = nil }
        if splinePoints.count >= 2 {
            add(.spline(points: splinePoints, kind: splineKind, closed: false))
        }
        splinePoints = []
        chainStart = nil
        chainEnd = nil
        arcChord = nil
        stepBase = nil
        offsetTarget = nil
        offsetPreview = []
        pendingTextAnchor = nil
        editableIndex = nil
        rectangleBase = nil
        measureRefs = []
        changed()
    }

    /// Nimmt den letzten Schritt zurück: laufende Eingabe, sonst den letzten Stand der Skizze.
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
        if arcChord != nil || rectangleBase != nil || stepBase != nil {
            arcChord = nil
            rectangleBase = nil
            stepBase = nil
            changed()
            return
        }
        if offsetTarget != nil {
            cancelOffset()
            return
        }
        guard let snapshot = undoStack.popLast() else {
            if chainEnd != nil { endChain() }
            return
        }
        restore(snapshot)
    }

    /// Stand vor einer Änderung merken.
    private func remember() {
        undoStack.append(Snapshot(entities: entities, constraints: constraints, construction: construction,
                                  chainStart: chainStart, chainEnd: chainEnd))
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    // MARK: Maße am Element

    /// Maße der laufenden Eingabe (nur Anzeige) bzw. des zuletzt gezeichneten Elements (änderbar).
    /// Alle Maße mit eindeutiger Kennung: Maße beim Aufziehen haben sonst keine, und Breite und Höhe
    /// eines Rechtecks teilten sich ein einziges Feld im Viewport (nur ein Maß sichtbar).
    var dimensions: [SketchDimension] {
        rawDimensions.enumerated().map { pair -> SketchDimension in
            var copy = placedOutside(pair.element)
            if copy.id.isEmpty { copy.id = "live-\(pair.offset)" }
            return copy
        }
    }

    /// Längenmaße immer außerhalb des Objekts (Kai): Maßlinie auf die Seite ohne Fläche, bei offenen
    /// Linienzügen weg von der Mitte der zusammenhängenden Kurven.
    private func placedOutside(_ dimension: SketchDimension) -> SketchDimension {
        let linear: Set<SketchDimension.Kind> = [.length, .distance, .width, .height]
        guard linear.contains(dimension.kind), dimension.span.count == 2 else { return dimension }
        let a = dimension.span[0], b = dimension.span[1]
        let length = simd_distance(a, b)
        guard length > 1e-9 else { return dimension }
        let mid = (a + b) / 2
        let n = dimension.direction
        let probe = max(length * 0.02, 1e-4)
        func filled(_ p: Point2) -> Bool {
            regions.contains { region in
                polygonContains(region.polygon, p) && !region.holes.contains { polygonContains($0.polygon, p) }
            }
        }
        var copy = dimension
        let ahead = filled(mid + n * probe), behind = filled(mid - n * probe)
        if ahead != behind {
            if ahead { copy.direction = -n }
            return copy
        }
        if let center = connectedCenter(touching: [a, b]), simd_dot(center - mid, n) > length * 0.01 {
            copy.direction = -n
        }
        return copy
    }

    /// Mitte der Kurven, die über gemeinsame Endpunkte mit den Punkten zusammenhängen (nil = keine).
    private func connectedCenter(touching points: [Point2]) -> Point2? {
        guard entities.count <= 400 else { return nil }
        let reach = 1e-5 + strokeTolerance * 0.01
        var frontier = points
        var used = Set<Int>()
        var changedSet = true
        while changedSet {
            changedSet = false
            for index in entities.indices where !used.contains(index) && !construction.contains(index) {
                let ends = entities[index].drawing.flatMap { line in [line.first, line.last].compactMap { $0 } }
                guard ends.contains(where: { end in frontier.contains { simd_distance($0, end) <= reach } }) else { continue }
                used.insert(index)
                frontier += ends
                changedSet = true
            }
        }
        let samples = used.flatMap { entities[$0].drawing.joined() }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(Point2.zero, +) / Double(samples.count)
    }

    private var rawDimensions: [SketchDimension] {
        if let start = dragStart, let current = dragCurrent {
            if tool == .polyline, arcActive, let arc = arcPreview(to: current) {
                return Self.dimensions(of: arc.entity, editable: false)
            }
            if tool == .polyline, let shape = strokeShape {
                return Self.dimensions(of: shape, editable: false)
            }
            if tool == .polyline {
                let from = chainEnd ?? start
                // Wie in Fusion 360: beim Ziehen Länge und Winkel zur Waagrechten
                return Self.lineDimensions(from, current, editable: false) + Self.lineAngle(from, current)
            }
            if let base = stepBase, let shapes = stepPreview(base: base, current: current) {
                if tool == .slot, let first = shapes.first, case .line(let a, let b) = first {
                    // Länge zwischen den Mitten und Breite
                    let half = SketchShapes.slotHalfWidth(base.start, base.end, through: current)
                    let n = rightNormal(b - a)
                    return Self.lineDimensions(a, b, editable: false)
                        + Self.lineDimensions(a, a + n * 2 * half, editable: false)
                }
                return shapes.first.map { Self.dimensions(of: $0, editable: false) } ?? []
            }
            if tool == .arc, arcMode == .center, let base = stepBase,
               let arc = SketchShapes.arc(center: base.start, start: base.end, sweep: arcSweep) {
                return Self.dimensions(of: arc, editable: false)
            }
            if tool == .arc, arcChord == nil {
                return Self.lineDimensions(start, current, editable: false)
            }
            if tool == .slot || (tool == .circle && circleMode == .threePoint) {
                return Self.lineDimensions(start, current, editable: false)
            }
            if tool == .rectangle, rectangleMode == .threePoint {
                if let base = rectangleBase {
                    let corners = Self.threePointCorners(base.start, base.end, current)
                    return Self.lineDimensions(corners[1], corners[2], editable: false)
                }
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
            return Self.lineDimensions(from, hover, editable: false) + Self.lineAngle(from, hover)
        }
        var result: [SketchDimension] = []
        if let index = editableIndex, entities.indices.contains(index), !isInProgress || chainEnd != nil {
            result = Self.dimensions(of: entities[index], editable: true)
                .map { $0.tagged("e\(index)-\($0.kind)", .entity(index)) }
        } else if !isInProgress {
            result = selectionDimensions
        }
        if !isInProgress || chainEnd != nil {
            result += drivingDimensions
        }
        return result
    }

    /// Wie bei Shapr3D: Maße zur Auswahl. Ein Element zeigt seine Maße, zwei Punkte ihren Abstand,
    /// Punkt und Linie den senkrechten Abstand, zwei Linien ihren Winkel (bzw. Abstand, wenn parallel).
    private var selectionDimensions: [SketchDimension] {
        let points = selection.compactMap { ref -> SketchPointRef? in
            if case .point(let p) = ref { return p }
            return nil
        }
        let curves = selection.compactMap { ref -> SketchCurveRef? in
            if case .curve(let c) = ref { return c }
            return nil
        }
        func position(_ ref: SketchPointRef) -> Point2? { ConstraintSolver.point(ref, entities) }
        func distance(_ a: SketchPointRef, _ b: SketchPointRef) -> [SketchDimension] {
            guard let p = position(a), let q = position(b) else { return [] }
            return Self.lineDimensions(p, q, editable: true).map { dimension -> SketchDimension in
                var copy = dimension
                copy.kind = .distance
                return copy.tagged("s-distance", .create(.distance(a, b, value: dimension.value)))
            }
        }
        // Gleiches Maß schon vorhanden: nur das treibende zeigen
        func exists(_ entitiesInvolved: Set<Int>) -> Bool {
            constraints.contains { $0.kind == .dimension && Set($0.entities) == entitiesInvolved }
        }

        switch (points.count, curves.count) {
        case (0, 1):
            let ref = curves[0]
            guard entities.indices.contains(ref.entity) else { return [] }
            if case .polyline = entities[ref.entity], let ends = lineEndIndices(ref) {
                return distance(SketchPointRef(entity: ref.entity, index: ends.0),
                                SketchPointRef(entity: ref.entity, index: ends.1))
            }
            return Self.dimensions(of: entities[ref.entity], editable: true)
                .map { $0.tagged("s\(ref.entity)-\($0.kind)", .entity(ref.entity)) }
        case (2, 0):
            guard points[0] != points[1] else { return [] }
            return distance(points[0], points[1])
        case (1, 1):
            guard let p = position(points[0]), case .line(let q1, let q2) = ConstraintSolver.curve(curves[0], entities) else {
                return []
            }
            let d = simd_normalize(q2 - q1)
            let foot = q1 + d * simd_dot(p - q1, d)
            let value = simd_distance(p, foot)
            guard value > 1e-6 else { return [] }
            return Self.lineDimensions(foot, p, editable: true).map { dimension -> SketchDimension in
                var copy = dimension
                copy.kind = .distance
                return copy.tagged("s-pointline", .create(.pointLineDistance(points[0], curves[0], value: value)))
            }
        case (0, 2):
            guard case .line(let p1, let p2) = ConstraintSolver.curve(curves[0], entities),
                  case .line(let q1, let q2) = ConstraintSolver.curve(curves[1], entities) else {
                // Zwei Kreise/Bögen: Abstand der Mittelpunkte
                guard case .circle = ConstraintSolver.curve(curves[0], entities),
                      case .circle = ConstraintSolver.curve(curves[1], entities) else { return [] }
                let a = SketchPointRef(entity: curves[0].entity, index: centerIndex(of: curves[0].entity))
                let b = SketchPointRef(entity: curves[1].entity, index: centerIndex(of: curves[1].entity))
                guard a.entity != b.entity, !exists([a.entity, b.entity]) else { return [] }
                return distance(a, b)
            }
            let d1 = simd_normalize(p2 - p1), d2 = simd_normalize(q2 - q1)
            let crossing = abs(d1.x * d2.y - d1.y * d2.x)
            if crossing < 1e-6 {
                // Parallel: Abstand von einem Ende der zweiten Linie zur ersten
                guard let ends = lineEndIndices(curves[1]) else { return [] }
                let p = SketchPointRef(entity: curves[1].entity, index: ends.0)
                let foot = p1 + d1 * simd_dot(q1 - p1, d1)
                let value = simd_distance(q1, foot)
                guard value > 1e-6 else { return [] }
                return Self.lineDimensions(foot, q1, editable: true).map { dimension -> SketchDimension in
                    var copy = dimension
                    copy.kind = .distance
                    return copy.tagged("s-parallel", .create(.pointLineDistance(p, curves[0], value: value)))
                }
            }
            let degrees = atan2(crossing, simd_dot(d1, d2)) * 180 / .pi
            let label = ((p1 + p2) / 2 + (q1 + q2) / 2) / 2
            return [SketchDimension(kind: .angle, value: degrees, position: label, direction: Point2(0, 1),
                                    isEditable: true)
                .tagged("s-angle", .create(.angle(curves[0], curves[1], degrees: degrees)))]
        default:
            return []
        }
    }

    /// Treibende Maße (Abstände, Winkel) bleiben in der Skizze sichtbar und änderbar.
    private var drivingDimensions: [SketchDimension] {
        constraints.enumerated().flatMap { entry -> [SketchDimension] in
            let index = entry.offset
            switch entry.element.variant {
            case .distance(let a, let b, let value):
                guard let p = ConstraintSolver.point(a, entities), let q = ConstraintSolver.point(b, entities) else {
                    return []
                }
                return Self.lineDimensions(p, q, editable: true).map { dimension -> SketchDimension in
                    var copy = dimension
                    copy.kind = .distance
                    copy.value = value
                    return copy.tagged("c\(index)", .constraint(index))
                }
            case .pointLineDistance(let a, let c, let value):
                guard let p = ConstraintSolver.point(a, entities) else { return [] }
                var foot = p
                switch ConstraintSolver.curve(c, entities) {
                case .line(let q1, let q2):
                    let d = simd_normalize(q2 - q1)
                    foot = q1 + d * simd_dot(p - q1, d)
                case .circle(let center, let r):
                    foot = center + simd_normalize(p - center) * r
                case .other:
                    return []
                }
                return Self.lineDimensions(foot, p, editable: true).map { dimension -> SketchDimension in
                    var copy = dimension
                    copy.kind = .distance
                    copy.value = value
                    return copy.tagged("c\(index)", .constraint(index))
                }
            case .angle(let a, let b, let degrees):
                guard case .line(let p1, let p2) = ConstraintSolver.curve(a, entities),
                      case .line(let q1, let q2) = ConstraintSolver.curve(b, entities) else { return [] }
                let label = ((p1 + p2) / 2 + (q1 + q2) / 2) / 2
                return [SketchDimension(kind: .angle, value: degrees, position: label, direction: Point2(0, 1),
                                        isEditable: true)
                    .tagged("c\(index)", .constraint(index))]
            default:
                return []
            }
        }
    }

    /// Wert eines Maßfelds übernehmen: Element ändern, treibendes Maß ändern oder neu anlegen.
    func setDimension(id: String, to value: Double) {
        guard value > 0, let dimension = dimensions.first(where: { $0.id == id }) else { return }
        switch dimension.target {
        case .display:
            return
        case .entity(let index):
            setEntityDimension(dimension.kind, of: index, to: value)
        case .constraint(let index):
            guard constraints.indices.contains(index) else { return }
            var updated = constraints
            updated[index] = updated[index].withDimensionValue(value)
            applyDimension(updated, anchor: constraints[index].entities.first)
        case .create(let variant):
            let constraint = SketchConstraint(variant: variant).withDimensionValue(value)
            applyDimension(constraints + [constraint], anchor: selection.first?.entity)
        }
    }

    /// Treibendes Maß einhalten; das zuerst gewählte Element bleibt nach Möglichkeit stehen.
    private func applyDimension(_ updated: [SketchConstraint], anchor: Int?) {
        remember()
        let before = entities, beforeConstraints = constraints
        constraints = updated
        let locked: Set<Int> = anchor.map { [$0] } ?? []
        if let solved = ConstraintSolver.solve(entities, constraints: constraints, locked: locked)
            ?? ConstraintSolver.solve(entities, constraints: constraints) {
            entities = solved
            selection = []
            selectedMarks = []
            notice = nil
        } else {
            entities = before
            constraints = beforeConstraints
            undoStack.removeLast()
            notice = "Maß widerspricht den Einschränkungen."
        }
        editableIndex = nil
        entitiesChanged()
    }

    /// Maß eines Elements setzen. Startecke, Mitte bzw. Startpunkt bleiben fest.
    private func setEntityDimension(_ kind: SketchDimension.Kind, of index: Int, to value: Double) {
        guard entities.indices.contains(index) else { return }
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
        case (.line, .length), (.arc, .radius):
            setStretchableDimension(of: index, to: value)
            return
        default:
            break
        }
        guard let updated else { return }
        let before = entities
        remember()
        entities[index] = updated
        // Verbundene Elemente folgen über die Einschränkungen
        if !constraints.isEmpty {
            if let solved = solveKeepingLines(entities, moving: index)?.entities {
                entities = solved
            } else {
                entities = before
                undoStack.removeLast()
                notice = "Maß widerspricht den Einschränkungen."
            }
        }
        entitiesChanged()
    }

    /// Einschränkungen lösen; gerade Elemente (Linien, Rechtecke, Polygone, Linienzüge) bleiben dabei stehen,
    /// solange es geht – Bögen und Kreise passen sich an (Kai: einen Bogen ändern darf keine Linie verschieben).
    /// Erst wenn das nicht lösbar ist, dürfen auch Linien mitgehen (linesMoved).
    private func solveKeepingLines(_ trial: [SketchEntity], moving index: Int)
        -> (entities: [SketchEntity], linesMoved: Bool)? {
        guard !constraints.isEmpty else { return (trial, false) }
        let straight = Set(trial.indices.filter { other in
            guard other != index else { return false }
            switch trial[other] {
            case .line, .rectangle, .regularPolygon, .polyline: return true
            default: return false
            }
        })
        if !straight.isEmpty,
           let solved = ConstraintSolver.solve(trial, constraints: constraints, locked: straight.union([index])) {
            return (solved, false)
        }
        return ConstraintSolver.solve(trial, constraints: constraints, locked: [index]).map { ($0, !straight.isEmpty) }
    }

    /// Linienlänge bzw. Bogenradius: Mehrere Arten, das Element zu ändern (Anfang, Ende, Mitte bzw. Enden
    /// fest), und es gilt die, bei der sich der Rest der Skizze am wenigsten bewegt. Verankerte Punkte
    /// schließen die Arten aus, die sie verschieben würden. Vorher wanderte beim Radius die ganze Kontur,
    /// weil die Bogenenden immer stehen blieben und tangentiale Linien kippen mussten.
    private func setStretchableDimension(of index: Int, to value: Double) {
        var candidates: [SketchEntity] = []
        switch entities[index] {
        case .line(let a, let b):
            let direction = simd_normalize(b - a)
            let middle = (a + b) / 2
            candidates = [.line(a, a + direction * value), .line(b - direction * value, b),
                          .line(middle - direction * value / 2, middle + direction * value / 2)]
        case .arc(let a, let m, let b):
            if let mid = Self.arc(a, m, b, radius: value) { candidates.append(.arc(start: a, mid: mid, end: b)) }
            if let circle = circleThrough(a, m, b), circle.radius > 1e-9 {
                let k = value / circle.radius
                // Ähnlich vergrößern: um ein Ende (dort bleibt die Tangente) bzw. um die Mitte
                for pivot in [a, b, circle.center] {
                    candidates.append(.arc(start: pivot + (a - pivot) * k, mid: pivot + (m - pivot) * k,
                                           end: pivot + (b - pivot) * k))
                }
            }
        default:
            return
        }
        let before = entities
        var best: (cost: Double, entities: [SketchEntity])?
        for candidate in candidates {
            var trial = entities
            trial[index] = candidate
            guard let found = solveKeepingLines(trial, moving: index) else { continue }
            let solved = found.entities
            // Bewegung der übrigen Elemente; Linien zu verschieben kommt nur in Frage, wenn es nicht anders geht
            var cost = found.linesMoved ? 1e12 : 0.0
            for other in solved.indices where other != index {
                let old = before[other].parameters, new = solved[other].parameters
                guard old.count == new.count else { continue }
                cost += zip(old, new).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            }
            if cost < (best?.cost ?? .infinity) - 1e-12 { best = (cost, solved) }
        }
        guard let best else {
            notice = "Maß widerspricht den Einschränkungen (z. B. verankerten Punkten)."
            return
        }
        remember()
        entities = best.entities
        if best.cost >= 1e12 {
            notice = "Dafür mussten Linien mitgehen – Punkte verankern (Auswählen › Verankern) hält sie fest."
        }
        // Laufender Linienzug geht am neuen Ende weiter
        if let end = chainEnd, case .line(let oldA, let oldB) = before[index], case .line(let newA, let newB) = entities[index] {
            if simd_distance(end, oldB) < 1e-6 { chainEnd = newB } else if simd_distance(end, oldA) < 1e-6 { chainEnd = newA }
        }
        entitiesChanged()
    }

    /// Winkel der Linie a→b zur Waagrechten (0…360°), nur Anzeige, auf halbem Winkel neben dem Startpunkt.
    private static func lineAngle(_ a: Point2, _ b: Point2) -> [SketchDimension] {
        let length = simd_distance(a, b)
        guard length > 1e-6 else { return [] }
        var radians = atan2(b.y - a.y, b.x - a.x)
        if radians < 0 { radians += 2 * .pi }
        let half = radians / 2
        let label = a + Point2(cos(half), sin(half)) * length * 0.45
        return [SketchDimension(kind: .angle, value: radians * 180 / .pi, position: label, direction: Point2(0, 1),
                                isEditable: false).tagged("live-angle", .display)]
    }

    private static func lineDimensions(_ a: Point2, _ b: Point2, editable: Bool) -> [SketchDimension] {
        guard simd_distance(a, b) > 1e-6 else { return [] }
        var normal = rightNormal(b - a)
        if normal.y < 0 || (normal.y == 0 && normal.x < 0) { normal = -normal }
        return [SketchDimension(kind: .length, value: simd_distance(a, b), position: (a + b) / 2, direction: normal,
                                isEditable: editable, span: [a, b])]
    }

    private static func dimensions(of entity: SketchEntity, editable: Bool) -> [SketchDimension] {
        switch entity {
        case .rectangle(let corner, let size):
            let lo = simd_min(corner, corner + size), hi = simd_max(corner, corner + size)
            return [
                SketchDimension(kind: .width, value: abs(size.x), position: Point2((lo.x + hi.x) / 2, lo.y),
                                direction: Point2(0, -1), isEditable: editable, span: [lo, Point2(hi.x, lo.y)]),
                SketchDimension(kind: .height, value: abs(size.y), position: Point2(hi.x, (lo.y + hi.y) / 2),
                                direction: Point2(1, 0), isEditable: editable, span: [Point2(hi.x, lo.y), hi]),
            ]
        case .circle(let center, let radius):
            let d = Point2(1, 1) / sqrt(2.0)
            return [SketchDimension(kind: .diameter, value: 2 * radius, position: center + d * radius, direction: d,
                                    isEditable: editable, span: [center - d * radius, center + d * radius])]
        case .ellipse(let center, let radii):
            return [
                SketchDimension(kind: .width, value: 2 * radii.x, position: center - Point2(0, radii.y),
                                direction: Point2(0, -1), isEditable: editable,
                                span: [center - Point2(radii.x, radii.y), center + Point2(radii.x, -radii.y)]),
                SketchDimension(kind: .height, value: 2 * radii.y, position: center + Point2(radii.x, 0),
                                direction: Point2(1, 0), isEditable: editable,
                                span: [center + Point2(radii.x, -radii.y), center + radii]),
            ]
        case .regularPolygon(let center, let radius, _, let angle):
            let d = Point2(cos(angle), sin(angle))
            // Etikett außen hinter der Ecke
            return [SketchDimension(kind: .radius, value: radius, position: center + d * radius,
                                    direction: d, isEditable: editable, span: [center, center + d * radius])]
        case .line(let a, let b):
            return lineDimensions(a, b, editable: editable)
        case .arc(let a, let m, let b):
            guard let circle = circleThrough(a, m, b) else { return [] }
            let samples = SketchSegment.arc(a, m, b).samples
            let mid = samples[samples.count / 2]
            return [SketchDimension(kind: .radius, value: circle.radius, position: mid,
                                    direction: simd_normalize(mid - circle.center), isEditable: editable,
                                    span: [circle.center, mid])]
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

    // MARK: Beschneiden

    /// Element, dessen Kurve dem Punkt am nächsten liegt (höchstens tolerance entfernt).
    private func nearestEntity(to p: Point2, tolerance: Double, among candidates: [Int]? = nil) -> Int? {
        var best: (distance: Double, index: Int)?
        for index in candidates ?? Array(entities.indices) {
            let distance = entities[index].drawing
                .map { polylineDistance(from: p, to: $0, closed: false).distance }
                .min() ?? .infinity
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (distance, index) }
        }
        return best?.index
    }

    /// Angetipptes Stück bis zu den nächsten Schnittpunkten entfernen (Rechtecke und Polygone werden dazu
    /// in Linien zerlegt). Ohne Schnittpunkte wird das ganze Element gelöscht.
    func trim(at p: Point2, tolerance: Double) {
        guard let index = nearestEntity(to: p, tolerance: tolerance) else { return }
        if case .text = entities[index] {
            notice = "Text lässt sich nur als Ganzes löschen."
            return
        }
        remember()
        var target = index
        if let lines = entities[index].exploded {
            let first = replaceEntity(index, with: lines)
            target = nearestEntity(to: p, tolerance: .infinity, among: Array(first..<entities.count)) ?? first
        }
        let cutters = entities.indices.filter { $0 != target }.flatMap { entities[$0].trimPrimitives }
        guard let pieces = SketchTrim.trim(entities[target], at: p, cutters: cutters) else {
            if let snapshot = undoStack.popLast() { restore(snapshot) }
            notice = "Ellipsen und Splines mit Schnittpunkten lassen sich nicht beschneiden – nur ganz löschen."
            return
        }
        replaceEntity(target, with: pieces)
        notice = nil
        entitiesChanged()
    }

    /// Element durch neue ersetzen (hinten angehängt, Konstruktionsart bleibt). Liefert den ersten neuen Index.
    @discardableResult
    private func replaceEntity(_ index: Int, with replacement: [SketchEntity]) -> Int {
        let wasConstruction = construction.contains(index)
        removeEntities([index])
        let first = entities.count
        for entity in replacement {
            entities.append(entity)
            if wasConstruction { construction.insert(entities.count - 1) }
            connect(entities.count - 1)
        }
        return first
    }

    /// Elemente entfernen; Einschränkungen, Konstruktionsart und Auswahl werden angepasst.
    private func removeEntities(_ removed: Set<Int>) {
        var map: [Int: Int] = [:]
        var kept: [SketchEntity] = []
        for (index, entity) in entities.enumerated() where !removed.contains(index) {
            map[index] = kept.count
            kept.append(entity)
        }
        entities = kept
        constraints = constraints.compactMap { $0.remapped { map[$0] } }
        construction = Set(construction.compactMap { map[$0] })
        selection = []
        editableIndex = nil
    }

    private func restore(_ snapshot: Snapshot) {
        entities = snapshot.entities
        constraints = snapshot.constraints
        construction = snapshot.construction
        chainStart = snapshot.chainStart
        chainEnd = snapshot.chainEnd
        editableIndex = nil
        selection = []
        entitiesChanged()
    }

    // MARK: Projizieren und Skalieren

    /// Projizierte Körperkanten (lokale Linienzüge) als Skizzenelemente übernehmen.
    func addProjected(_ polylines: [[Point2]]) {
        let shapes = polylines.compactMap(SketchTrim.entity(fromProjected:))
        guard !shapes.isEmpty else {
            notice = "Keine Kante zum Projizieren gefunden."
            return
        }
        remember()
        for shape in shapes {
            entities.append(shape)
            if constructionMode { construction.insert(entities.count - 1) }
            connect(entities.count - 1)
        }
        notice = nil
        editableIndex = nil
        entitiesChanged()
    }

    /// Auswahl (sonst alle Elemente) um die Mitte ihres Hüllrechtecks skalieren.
    func applyScale() {
        guard scaleFactor > 0, scaleFactor != 1, !entities.isEmpty else { return }
        let chosen = selectedEntities.isEmpty ? Set(entities.indices) : selectedEntities
        let points = chosen.flatMap { entities[$0].handlePoints + entities[$0].drawing.flatMap { $0 } }
        guard let first = points.first else { return }
        let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
        let center = (lo + hi) / 2
        remember()
        for index in chosen { entities[index] = entities[index].scaled(about: center, by: scaleFactor) }
        constraints = constraints.map { constraint in
            guard case .lock(let ref, let at) = constraint.variant, chosen.contains(ref.entity) else { return constraint }
            return SketchConstraint(variant: .lock(ref, at: center + (at - center) * scaleFactor))
        }
        if let solved = ConstraintSolver.solve(entities, constraints: constraints, locked: chosen) { entities = solved }
        editableIndex = nil
        entitiesChanged()
    }

    // MARK: Auswahl

    var selectedEntities: Set<Int> { Set(selection.map(\.entity)) }

    /// Punkt (Ende, Ecke, Mitte) oder Kurve unter dem Finger; Punkte haben Vorrang.
    func pick(at p: Point2, tolerance: Double) -> SketchRef? {
        var bestPoint: (distance: Double, ref: SketchPointRef)?
        for (index, entity) in entities.enumerated() {
            if case .text = entity { continue }
            for (k, q) in entity.handlePoints.enumerated() {
                let d = simd_distance(p, q)
                if d <= tolerance * 0.6, d < (bestPoint?.distance ?? .infinity) {
                    bestPoint = (d, SketchPointRef(entity: index, index: k))
                }
            }
        }
        if let bestPoint { return .point(bestPoint.ref) }
        var bestCurve: (distance: Double, ref: SketchCurveRef)?
        for (index, entity) in entities.enumerated() {
            for k in 0..<entity.curveCount {
                let ref = SketchCurveRef(entity: index, index: k)
                guard let line = curvePolyline(ref) else { continue }
                let d = polylineDistance(from: p, to: line, closed: false).distance
                if d <= tolerance, d < (bestCurve?.distance ?? .infinity) { bestCurve = (d, ref) }
            }
        }
        return bestCurve.map { .curve($0.ref) }
    }

    /// Finger antippen: Element zur Auswahl hinzufügen bzw. entfernen; ins Leere tippen leert die Auswahl.
    func select(at p: Point2, tolerance: Double) {
        let ref = pick(at: p, tolerance: tolerance)
        var pointRef = false
        if case .point? = ref { pointRef = true }
        // Hilfspunkte vor Kurven, Elementpunkte vor Hilfspunkten
        let mark: Int? = pointRef ? nil : marks.indices
            .filter { simd_distance(marks[$0], p) <= tolerance * 0.6 }
            .min { simd_distance(marks[$0], p) < simd_distance(marks[$1], p) }
        if let mark {
            if let index = selectedMarks.firstIndex(of: mark) {
                selectedMarks.remove(at: index)
            } else {
                selectedMarks.append(mark)
            }
        } else if let ref {
            if let index = selection.firstIndex(of: ref) {
                selection.remove(at: index)
            } else {
                selection.append(ref)
            }
        } else {
            selection = []
            selectedMarks = []
        }
        addMidpointMark()
        notice = nil
        // Wartende Einschränkung: setzen, sobald die Auswahl passt; danach geht es mit den nächsten Elementen weiter
        if let action = pendingAction {
            if canPerform(action) {
                perform(action)
                selection = []
                selectedMarks = []
                if notice == nil {
                    notice = "„\(action.title)“ gesetzt. Nächste Elemente antippen – oder das Symbol nochmal tippen zum Beenden."
                }
            } else {
                notice = action.hint
            }
        }
        changed()
    }

    /// Einschränkung bzw. Trennen/Konstruktion aus der rechten Spalte. Passt die Auswahl schon, wird sie
    /// sofort angewendet; sonst wartet sie, bis die passenden Elemente angetippt sind (Pfeil-Werkzeug).
    /// Nochmal tippen beendet das Warten.
    func start(_ action: SketchPendingAction) {
        if pendingAction == action {
            cancelPending()
            return
        }
        if canPerform(action) {
            pendingAction = nil
            perform(action)
            return
        }
        if tool != .select { tool = .select }
        selection = []
        selectedMarks = []
        pendingAction = action
        notice = action.hint
        changed()
    }

    func cancelPending() {
        pendingAction = nil
        notice = nil
        changed()
    }

    private func canPerform(_ action: SketchPendingAction) -> Bool {
        switch action {
        case .constraint(let kind): canApply(kind)
        case .detach, .construction: !selection.isEmpty
        }
    }

    private func perform(_ action: SketchPendingAction) {
        switch action {
        case .constraint(let kind): applyConstraint(kind)
        case .detach: detachSelection()
        case .construction: toggleConstruction()
        }
    }

    /// Zwei Punkte gewählt (Elementpunkte oder Hilfspunkte): ihre Mitte als Hilfspunkt zeigen.
    private func addMidpointMark() {
        let chosen = selectionPoints + selectedMarks.filter { marks.indices.contains($0) }.map { marks[$0] }
        guard chosen.count == 2, simd_distance(chosen[0], chosen[1]) > 1e-6 else { return }
        let middle = (chosen[0] + chosen[1]) / 2
        guard !marks.contains(where: { simd_distance($0, middle) < 1e-6 }) else { return }
        marks.append(middle)
    }

    func clearSelection() {
        selection = []
        selectedMarks = []
        changed()
    }

    func deleteSelection() {
        guard !selection.isEmpty || !selectedMarks.isEmpty else {
            notice = "Elemente mit dem Finger antippen, dann „Löschen“."
            return
        }
        if !selectedMarks.isEmpty {
            let removed = Set(selectedMarks)
            marks = marks.indices.filter { !removed.contains($0) }.map { marks[$0] }
            selectedMarks = []
            guideLines = guideLines.filter { guide in marks.contains { simd_distance($0, guide.mark) < 1e-9 } }
        }
        guard !selection.isEmpty else {
            notice = nil
            changed()
            return
        }
        remember()
        removeEntities(selectedEntities)
        notice = nil
        entitiesChanged()
    }

    var selectedMarkPoints: [Point2] {
        selectedMarks.filter { marks.indices.contains($0) }.map { marks[$0] }
    }

    /// „Konstruktion erstellen“: Auswahl zu Konstruktionsgeometrie (oder zurück).
    func toggleConstruction() {
        let chosen = selectedEntities
        guard !chosen.isEmpty else {
            notice = "Elemente antippen, die zu Konstruktionsgeometrie werden sollen."
            return
        }
        remember()
        if chosen.isSubset(of: construction) {
            construction.subtract(chosen)
        } else {
            construction.formUnion(chosen)
        }
        selection = []
        entitiesChanged()
    }

    /// „Trennen“: Einschränkungen der Auswahl lösen.
    func detachSelection() {
        let chosen = selectedEntities
        guard !chosen.isEmpty else {
            notice = "Elemente antippen, deren Verbindungen gelöst werden sollen."
            return
        }
        let points = Set(selection.compactMap { ref -> SketchPointRef? in
            if case .point(let p) = ref { return p }
            return nil
        })
        remember()
        let before = constraints.count
        constraints.removeAll { constraint in
            if !points.isEmpty, case .coincident(let a, let b) = constraint.variant {
                return points.contains(a) || points.contains(b)
            }
            return points.isEmpty && !chosen.isDisjoint(with: constraint.entities)
        }
        if constraints.count == before {
            undoStack.removeLast()
            notice = "An der Auswahl hängen keine Einschränkungen."
        } else {
            notice = nil
            selection = []
        }
        changed()
    }

    // MARK: Einschränkungen

    /// Ob die Einschränkung zur aktuellen Auswahl passt.
    func canApply(_ kind: ConstraintKind) -> Bool {
        !variants(for: kind).isEmpty
    }

    /// Einschränkung auf die Auswahl anwenden. Das zuerst gewählte Element bleibt stehen.
    func applyConstraint(_ kind: ConstraintKind) {
        let new = variants(for: kind)
        guard !new.isEmpty else {
            notice = kind.selectionHint
            return
        }
        remember()
        let before = entities, beforeConstraints = constraints
        constraints += new.map { SketchConstraint(variant: $0) }
        let involved = Set(new.flatMap { SketchConstraint(variant: $0).entities })
        let anchor: Set<Int> = involved.count > 1 ? Set(selection.prefix(1).map(\.entity)) : []
        if let solved = ConstraintSolver.solve(entities, constraints: constraints, locked: anchor)
            ?? ConstraintSolver.solve(entities, constraints: constraints) {
            entities = solved
            selection = []
            notice = nil
        } else {
            entities = before
            constraints = beforeConstraints
            undoStack.removeLast()
            notice = "„\(kind.rawValue)“ widerspricht den vorhandenen Einschränkungen."
        }
        editableIndex = nil
        entitiesChanged()
    }

    // MARK: Verankern

    /// Griffpunkte der Auswahl (gewählte Punkte und alle Punkte gewählter Kurven)
    private var selectedPointRefs: [SketchPointRef] {
        var refs: [SketchPointRef] = []
        for ref in selection {
            switch ref {
            case .point(let point):
                refs.append(point)
            case .curve(let curve):
                guard entities.indices.contains(curve.entity) else { continue }
                refs += entities[curve.entity].handlePoints.indices.map { SketchPointRef(entity: curve.entity, index: $0) }
            }
        }
        return refs
    }

    private var anchoredPoints: Set<SketchPointRef> {
        Set(constraints.compactMap { constraint -> SketchPointRef? in
            guard case .lock(let ref, _) = constraint.variant else { return nil }
            return ref
        })
    }

    /// Alle gewählten Punkte sind schon verankert (dann löst der Knopf sie wieder)
    var isSelectionAnchored: Bool {
        let refs = selectedPointRefs
        return !refs.isEmpty && Set(refs).isSubset(of: anchoredPoints)
    }

    /// Auswahl verankern bzw. – ist schon alles verankert – wieder lösen.
    func toggleAnchor() {
        let refs = selectedPointRefs
        guard !refs.isEmpty else {
            notice = ConstraintKind.lock.selectionHint
            return
        }
        remember()
        if isSelectionAnchored {
            let chosen = Set(refs)
            constraints.removeAll { constraint in
                guard case .lock(let ref, _) = constraint.variant else { return false }
                return chosen.contains(ref)
            }
            notice = refs.count == 1 ? "Punkt gelöst." : "\(refs.count) Punkte gelöst."
        } else {
            let anchored = anchoredPoints
            for ref in refs where !anchored.contains(ref) {
                guard let p = ConstraintSolver.point(ref, entities) else { continue }
                constraints.append(SketchConstraint(variant: .lock(ref, at: p)))
            }
            notice = refs.count == 1 ? "Punkt verankert – er bleibt beim Ändern von Maßen stehen."
                : "\(refs.count) Punkte verankert – sie bleiben beim Ändern von Maßen stehen."
        }
        selection = []
        selectedMarks = []
        entitiesChanged()
    }

    private func variants(for kind: ConstraintKind) -> [SketchConstraint.Variant] {
        let points = selection.compactMap { ref -> SketchPointRef? in
            if case .point(let p) = ref { return p }
            return nil
        }
        let curves = selection.compactMap { ref -> SketchCurveRef? in
            if case .curve(let c) = ref { return c }
            return nil
        }
        func curve(_ ref: SketchCurveRef) -> ConstraintCurve { ConstraintSolver.curve(ref, entities) }
        func isLine(_ ref: SketchCurveRef) -> Bool {
            if case .line = curve(ref) { return true }
            return false
        }
        func isCircle(_ ref: SketchCurveRef) -> Bool {
            if case .circle = curve(ref) { return true }
            return false
        }
        let lines = curves.filter(isLine), circles = curves.filter(isCircle)
        switch kind {
        case .parallel:
            guard points.isEmpty, lines.count >= 2, lines.count == curves.count else { return [] }
            return lines.dropFirst().map { .parallel(lines[0], $0) }
        case .collinear:
            // Parallel zur ersten Linie und mit einem Ende auf ihrer Geraden
            guard points.isEmpty, lines.count >= 2, lines.count == curves.count else { return [] }
            return lines.dropFirst().flatMap { other -> [SketchConstraint.Variant] in
                guard let ends = lineEndIndices(other) else { return [] }
                return [.parallel(lines[0], other), .pointOnCurve(SketchPointRef(entity: other.entity, index: ends.0), lines[0])]
            }
        case .perpendicular:
            guard points.isEmpty, lines.count == 2, curves.count == 2 else { return [] }
            return [.perpendicular(lines[0], lines[1])]
        case .tangent:
            guard points.isEmpty, curves.count == 2, !circles.isEmpty else { return [] }
            var outside = true
            if case .circle(let c1, let r1) = curve(curves[0]), case .circle(let c2, let r2) = curve(curves[1]) {
                outside = simd_distance(c1, c2) > max(r1, r2)
            }
            return [.tangent(curves[0], curves[1], outside: outside)]
        case .coincident:
            if curves.isEmpty, points.count >= 2 {
                return points.dropFirst().map { .coincident(points[0], $0) }
            }
            if points.count == 1, curves.count == 1, isLine(curves[0]) || isCircle(curves[0]) {
                return [.pointOnCurve(points[0], curves[0])]
            }
            return []
        case .midpoint:
            guard points.count == 1, lines.count == 1, curves.count == 1 else { return [] }
            return [.midpoint(points[0], lines[0])]
        case .concentric:
            guard points.isEmpty, circles.count >= 2, circles.count == curves.count else { return [] }
            return circles.dropFirst().map { .concentric(circles[0], $0) }
        case .horizontalVertical:
            if points.isEmpty, !lines.isEmpty, lines.count == curves.count {
                return lines.map { ref -> SketchConstraint.Variant in
                    guard case .line(let a, let b) = curve(ref) else { return .horizontal(ref) }
                    return abs(b.x - a.x) >= abs(b.y - a.y) ? .horizontal(ref) : .vertical(ref)
                }
            }
            if curves.isEmpty, points.count == 2,
               let p = ConstraintSolver.point(points[0], entities), let q = ConstraintSolver.point(points[1], entities) {
                return abs(q.x - p.x) >= abs(q.y - p.y)
                    ? [.horizontalPoints(points[0], points[1])] : [.verticalPoints(points[0], points[1])]
            }
            return []
        case .equal:
            guard points.isEmpty, curves.count >= 2 else { return [] }
            if lines.count == curves.count { return lines.dropFirst().map { .equalLength(lines[0], $0) } }
            if circles.count == curves.count { return circles.dropFirst().map { .equalRadius(circles[0], $0) } }
            return []
        case .symmetric:
            // Zwei Punkte und eine Linie als Achse, oder zwei Kreise/Linien und zuletzt die Achse
            if points.count == 2, lines.count == 1, curves.count == 1 {
                return [.symmetric(points[0], points[1], axis: lines[0])]
            }
            guard points.isEmpty, curves.count == 3, isLine(curves[2]) else { return [] }
            let axis = curves[2], a = curves[0], b = curves[1]
            if isCircle(a), isCircle(b) {
                let ca = SketchPointRef(entity: a.entity, index: centerIndex(of: a.entity)),
                    cb = SketchPointRef(entity: b.entity, index: centerIndex(of: b.entity))
                return [.symmetric(ca, cb, axis: axis)]
            }
            if isLine(a), isLine(b), case .line(let a0, let a1) = curve(a), case .line(let b0, let b1) = curve(b),
               case .line(let s0, let s1) = curve(axis) {
                // Enden so zuordnen, dass sie nach dem Spiegeln am nächsten liegen
                let mirror = { (p: Point2) -> Point2 in
                    let d = simd_normalize(s1 - s0)
                    let foot = s0 + d * simd_dot(p - s0, d)
                    return foot * 2 - p
                }
                let straight = simd_distance(mirror(a0), b0) + simd_distance(mirror(a1), b1)
                let crossed = simd_distance(mirror(a0), b1) + simd_distance(mirror(a1), b0)
                guard let ia = lineEndIndices(a), let ib = lineEndIndices(b) else { return [] }
                let pa0 = SketchPointRef(entity: a.entity, index: ia.0), pa1 = SketchPointRef(entity: a.entity, index: ia.1)
                let pb0 = SketchPointRef(entity: b.entity, index: ib.0), pb1 = SketchPointRef(entity: b.entity, index: ib.1)
                return straight <= crossed
                    ? [.symmetric(pa0, pb0, axis: axis), .symmetric(pa1, pb1, axis: axis)]
                    : [.symmetric(pa0, pb1, axis: axis), .symmetric(pa1, pb0, axis: axis)]
            }
            return []
        case .dimension:
            return []
        case .lock:
            var result: [SketchConstraint.Variant] = points.compactMap { ref -> SketchConstraint.Variant? in
                guard let p = ConstraintSolver.point(ref, entities) else { return nil }
                return .lock(ref, at: p)
            }
            for ref in curves where entities.indices.contains(ref.entity) {
                for (k, p) in entities[ref.entity].handlePoints.enumerated() {
                    result.append(.lock(SketchPointRef(entity: ref.entity, index: k), at: p))
                }
            }
            return result
        }
    }

    /// Index des Mittelpunkts unter den Griffpunkten (Kreis 0, Bogen 2).
    private func centerIndex(of entity: Int) -> Int {
        if case .arc = entities[entity] { return 2 }
        return 0
    }

    /// Griffpunkt-Indizes der beiden Enden einer Linie bzw. Kante.
    private func lineEndIndices(_ ref: SketchCurveRef) -> (Int, Int)? {
        switch entities[ref.entity] {
        case .line: return (0, 1)
        case .rectangle: return (ref.index % 4, (ref.index + 1) % 4)
        case .regularPolygon(_, _, let n, _): return (1 + ref.index % n, 1 + (ref.index + 1) % n)
        case .polyline(let points, _): return (ref.index % points.count, (ref.index + 1) % points.count)
        default: return nil
        }
    }

    // MARK: Darstellung

    /// Linienzüge der fertigen Elemente (lokal), ohne Konstruktionsgeometrie.
    /// Enden und Ecken der Elemente (Anzeige „Punkte“ der Skizzenpalette), ohne Text.
    var entityPoints: [Point2] {
        entities.indices.flatMap { index -> [Point2] in
            switch entities[index] {
            case .text: return []
            case .rectangle: return Array(entities[index].handlePoints.prefix(4))
            default: return entities[index].handlePoints
            }
        }
    }

    /// Maße laut Skizzenpalette; beim Zeichnen bleiben Länge und Winkel immer sichtbar.
    var visibleDimensions: [SketchDimension] {
        showsDimensions || isInProgress ? dimensions : []
    }

    var entityPolylines: [[Point2]] {
        entities.indices.filter { !construction.contains($0) }.flatMap { entities[$0].drawing }
    }

    /// Konstruktionsgeometrie (gestrichelt dargestellt).
    var constructionPolylines: [[Point2]] {
        construction.sorted().filter { entities.indices.contains($0) }.flatMap { entities[$0].drawing }
    }

    /// Ausgewählte Kurven und Punkte zum Hervorheben.
    var selectionPolylines: [[Point2]] {
        selection.compactMap { ref -> [Point2]? in
            guard case .curve(let c) = ref else { return nil }
            return curvePolyline(c)
        }
    }

    var selectionPoints: [Point2] {
        selection.compactMap { ref -> Point2? in
            guard case .point(let p) = ref else { return nil }
            return ConstraintSolver.point(p, entities)
        }
    }

    /// Kurzzeichen der Einschränkungen mit Position (lokal).
    var constraintBadges: [(position: Point2, text: String)] {
        var used: [Point2] = []
        return constraints.compactMap { constraint -> (Point2, String)? in
            guard var position = badgePosition(constraint) else { return nil }
            // Übereinanderliegende Zeichen leicht versetzen
            while used.contains(where: { simd_distance($0, position) < 1e-6 }) { position.x += 1e-3 }
            used.append(position)
            return (position, constraint.kind.badge)
        }
    }

    private func badgePosition(_ constraint: SketchConstraint) -> Point2? {
        switch constraint.variant {
        case .parallel(let c, _), .perpendicular(let c, _), .tangent(let c, _, _), .concentric(let c, _),
             .horizontal(let c), .vertical(let c), .equalLength(let c, _), .equalRadius(let c, _):
            guard let line = curvePolyline(c), !line.isEmpty else { return nil }
            return line[line.count / 2]
        case .coincident(let p, _), .pointOnCurve(let p, _), .midpoint(let p, _), .horizontalPoints(let p, _),
             .verticalPoints(let p, _), .symmetric(let p, _, _), .lock(let p, _):
            return ConstraintSolver.point(p, entities)
        case .distance, .pointLineDistance, .angle:
            // Maße zeigt das Maßfeld
            return nil
        }
    }

    /// Kurve als Linienzug (für Auswahl, Hervorhebung, Abstand).
    func curvePolyline(_ ref: SketchCurveRef) -> [Point2]? {
        guard entities.indices.contains(ref.entity) else { return nil }
        let entity = entities[ref.entity]
        switch entity.constraintCurve(ref.index) {
        case .line(let a, let b):
            return [a, b]
        default:
            return entity.drawing.first
        }
    }

    /// Linienzüge der laufenden Eingabe und der Versatz-Vorschau (lokal).
    var previewPolylines: [[Point2]] {
        var polylines = offsetPreview.flatMap(\.drawing)
        // Beim Schweben zeigt der Linienzug, Bogen bzw. Spline schon das nächste Stück
        let current = dragCurrent ?? hoverSnap?.point
        switch tool {
        case .rectangle where rectangleMode == .threePoint:
            if let base = rectangleBase {
                if let current {
                    let corners = Self.threePointCorners(base.start, base.end, current)
                    polylines.append(corners + [corners[0]])
                } else {
                    polylines.append([base.start, base.end])
                }
            } else if let start = dragStart, let current = dragCurrent {
                polylines.append([start, current])
            }
        case .circle where circleMode == .threePoint, .slot:
            if let base = stepBase {
                if let current, let shapes = stepPreview(base: base, current: current) {
                    polylines += shapes.flatMap(\.drawing)
                } else {
                    polylines.append([base.start, base.end])
                }
            } else if let start = dragStart, let current = dragCurrent {
                polylines.append([start, current])
            }
        case .arc where arcMode == .center:
            if let base = stepBase {
                polylines.append([base.start, base.end])
                if dragStart != nil, let arc = SketchShapes.arc(center: base.start, start: base.end, sweep: arcSweep) {
                    polylines += arc.drawing
                } else if let current {
                    polylines.append([base.start, current])
                }
            } else if let start = dragStart, let current = dragCurrent {
                polylines.append([start, current])
                polylines += SketchEntity.circle(center: start, radius: simd_distance(start, current)).drawing
            }
        case .mirror, .rectPattern, .circPattern:
            polylines += transformPreview.flatMap(\.drawing)
        case .rectangle, .circle, .ellipse, .polygon:
            if let start = dragStart, let current = dragCurrent, let preview = shapePreview(from: start, to: current) {
                polylines += preview.drawing
                if tool == .circle || tool == .polygon { polylines.append([start, current]) }
            }
        case .polyline:
            if arcActive, let current, let arc = arcPreview(to: current) {
                polylines += arc.entity.drawing
            } else if let shape = strokeShape, dragStart != nil {
                polylines += shape.drawing
            } else if let from = chainEnd ?? dragStart, let current {
                polylines.append([from, current])
            }
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
        case .point, .text, .offset, .project, .trim, .scale, .select, .fillet, .chamfer, .extend, .breakCurve, .measure:
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
            if rectangleMode == .center {
                let half = current - start
                return .rectangle(corner: start - half, size: half * 2)
            }
            return .rectangle(corner: start, size: current - start)
        case .circle where circleMode == .twoPoint:
            return SketchShapes.circle(diameterFrom: start, to: current)
        case .circle:
            return .circle(center: start, radius: simd_distance(start, current))
        case .ellipse:
            return .ellipse(center: start, radii: simd_abs(current - start))
        case .polygon:
            return SketchShapes.polygon(center: start, through: current, sides: polygonSides, mode: polygonMode)
        default:
            return nil
        }
    }

    // MARK: Fang

    /// Punkte der laufenden Eingabe, an denen ebenfalls gefangen wird.
    private var inputPoints: [Point2] {
        var points = splinePoints + marks
        if let chainStart { points.append(chainStart) }
        if let arcChord { points += [arcChord.start, arcChord.end] }
        return points
    }

    private func snap(_ p: Point2, tolerance: Double, anchor: Point2?) -> Point2 {
        guard snapEnabled else {
            activeSnap = nil
            return p
        }
        var result = withParallel(snapIndex.snap(p, tolerance: tolerance, kinds: snapKinds, extra: inputPoints,
                                                 anchor: anchor, gridStep: gridStep),
                                  raw: p, anchor: anchor, tolerance: tolerance)
        // Bogen (Finger aufgelegt): Winkelschritte wie 90° zum Linienende bleiben samt Hilfslinie, nur ein Strahl
        // genau entlang der Tangente fällt weg – auf ihm gäbe es keinen Bogen, nur eine gerade Linie
        if tool == .polyline, arcActive, result.kind == .angle, tangentArc(to: result.point) == nil {
            parallelLines = []
            result = snapIndex.snap(p, tolerance: tolerance, kinds: snapKinds.subtracting([.angle]), extra: inputPoints,
                                    anchor: nil, gridStep: gridStep)
        }
        // Bogen (Finger aufgelegt oder rund gezogen): 90° zur Linie am Bogenanfang einrasten (Halbkreis), mit
        // gestrichelter Hilfslinie – unabhängig davon, ob die Linie selbst auf einem 15°-Schritt liegt
        var drawsArc = arcActive
        if case .arc? = strokeShape { drawsArc = true }
        if tool == .polyline, drawsArc, snapKinds.contains(.angle), !Self.isPointSnap(result.kind),
           let arcStart = arcAnchor(from: dragStart) {
            let normal = Point2(-arcStart.direction.y, arcStart.direction.x)
            let along = simd_dot(p - arcStart.start, normal)
            let foot = arcStart.start + normal * along
            if abs(along) > tolerance, simd_distance(foot, p) <= tolerance {
                parallelLines = []
                result = SnapResult(point: foot, kind: .angle, guides: [(arcStart.start, foot)])
            }
        }
        activeSnap = result.kind == nil ? nil : result
        return result.point
    }

    /// Gleicher Winkel wie eine vorhandene Linie: Richtung einrasten und die Linie grün hervorheben.
    private func withParallel(_ snapped: SnapResult, raw p: Point2, anchor: Point2?, tolerance: Double) -> SnapResult {
        parallelLines = []
        guard let anchor, tool == .polyline || tool == .rectangle && rectangleMode == .threePoint,
              snapKinds.contains(.angle) else { return snapped }
        // Punktfang hat Vorrang
        if let kind = snapped.kind, ([.endpoint, .midpoint, .center, .intersection, .onCurve] as [SnapKind]).contains(kind) {
            return snapped
        }
        let lines = entities.indices.flatMap { index -> [(Point2, Point2)] in
            (0..<entities[index].curveCount).compactMap { k -> (Point2, Point2)? in
                guard case .line(let a, let b) = entities[index].constraintCurve(k), simd_distance(a, b) > 1e-6 else {
                    return nil
                }
                return (a, b)
            }
        }
        guard !lines.isEmpty, simd_distance(p, anchor) > tolerance else { return snapped }
        var result = snapped
        var best: (distance: Double, point: Point2)?
        for (a, b) in lines {
            let d = simd_normalize(b - a)
            let along = simd_dot(p - anchor, d)
            let projected = anchor + d * along
            let distance = simd_distance(projected, p)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (distance, projected) }
        }
        guard let best else { return snapped.kind == .angle ? alignedOnRay(snapped, anchor: anchor, tolerance: tolerance) : snapped }
        // Parallel zu einer vorhandenen Linie schlägt den 15°-Schritt, wenn es näher am Stift liegt
        if snapped.kind != .angle || best.distance < simd_distance(snapped.point, p) - 1e-9 {
            result.point = best.point
            result.kind = .angle
            result.guides = [(anchor, best.point)]
        }
        result = alignedOnRay(result, anchor: anchor, tolerance: tolerance)
        // Alle Linien mit diesem Winkel leuchten grün
        let current = result.point - anchor
        guard simd_length(current) > 1e-9 else { return result }
        let direction = simd_normalize(current)
        parallelLines = lines.filter { line in
            let d = simd_normalize(line.1 - line.0)
            return abs(d.x * direction.y - d.y * direction.x) < 1e-4
        }.map { [$0.0, $0.1] }
        return result
    }

    // MARK: Messen

    /// Angetippt (höchstens zwei; ein drittes Antippen beginnt neu, erneutes Antippen nimmt es heraus)
    @Published private(set) var measureRefs: [SketchRef] = []

    func measure(at p: Point2, tolerance: Double) {
        guard let ref = pick(at: p, tolerance: tolerance) else {
            measureRefs = []
            changed()
            return
        }
        if let index = measureRefs.firstIndex(of: ref) {
            measureRefs.remove(at: index)
        } else {
            if measureRefs.count >= 2 { measureRefs = [] }
            measureRefs.append(ref)
        }
        changed()
    }

    func clearMeasure() {
        measureRefs = []
        changed()
    }

    var measurement: SketchMeasurement {
        SketchMeasurement(measureRefs.compactMap(measureItem))
    }

    /// Gemessene Kurven zum Hervorheben (lokal)
    var measuredPolylines: [[Point2]] {
        measureRefs.compactMap { ref -> [Point2]? in
            guard case .curve(let curve) = ref else { return nil }
            return curvePolyline(curve)
        }
    }

    /// Gemessene Punkte zum Hervorheben (lokal)
    var measuredPoints: [Point2] {
        measureRefs.compactMap { ref -> Point2? in
            guard case .point(let point) = ref else { return nil }
            return ConstraintSolver.point(point, entities)
        }
    }

    private func measureItem(_ ref: SketchRef) -> SketchMeasurement.Item? {
        switch ref {
        case .point(let point):
            return ConstraintSolver.point(point, entities).map { SketchMeasurement.Item.point($0) }
        case .curve(let curve):
            guard entities.indices.contains(curve.entity), let polyline = curvePolyline(curve) else { return nil }
            switch entities[curve.entity].constraintCurve(curve.index) {
            case .line(let a, let b):
                return .line(a, b)
            case .circle(let center, let radius):
                var isArc = false
                if case .arc = entities[curve.entity] { isArc = true }
                return .circle(center: center, radius: radius, polyline: polyline, isArc: isArc)
            case .other:
                return .curve(polyline)
            }
        }
    }

    /// Fluchtlinie auf dem eingerasteten Strahl: Die Länge rastet dort ein, wo ein vorhandener Punkt
    /// (z. B. der Anfang der ersten Linie) rechtwinklig, senkrecht oder waagerecht daneben liegt.
    private func alignedOnRay(_ result: SnapResult, anchor: Point2, tolerance: Double) -> SnapResult {
        guard snapKinds.contains(.alignment) else { return result }
        let ray = result.point - anchor
        let length = simd_length(ray)
        guard length > tolerance else { return result }
        let d = ray / length
        var nearest: (distance: Double, point: Point2, source: Point2)?
        for k in snapIndex.endpoints + snapIndex.centers + inputPoints where simd_distance(k, anchor) > 1e-6 {
            var lengths = [simd_dot(k - anchor, d)]
            if abs(d.x) > 1e-6 { lengths.append((k.x - anchor.x) / d.x) }
            if abs(d.y) > 1e-6 { lengths.append((k.y - anchor.y) / d.y) }
            for t in lengths where t > tolerance {
                let distance = abs(t - length)
                if distance <= tolerance, distance < (nearest?.distance ?? .infinity) {
                    nearest = (distance, anchor + d * t, k)
                }
            }
        }
        guard let nearest else { return result }
        var aligned = result
        aligned.point = nearest.point
        aligned.guides = [(anchor, nearest.point), (nearest.source, nearest.point)]
        return aligned
    }

    private func add(_ entity: SketchEntity, editable: Bool = false) {
        remember()
        entities.append(entity)
        let index = entities.count - 1
        if constructionMode { construction.insert(index) }
        connect(index)
        editableIndex = editable ? index : nil
        entitiesChanged()
    }

    /// Wie bei Shapr3D bleiben gefangene Enden verbunden: Zusammenfallend mit gleichen Punkten anderer Elemente.
    private func connect(_ index: Int) {
        let points = entities[index].handlePoints
        for (k, p) in points.enumerated() {
            for other in entities.indices where other != index {
                if case .text = entities[other] { continue }
                if let j = entities[other].handlePoints.firstIndex(where: { simd_distance($0, p) < 1e-6 }) {
                    constraints.append(SketchConstraint(variant: .coincident(SketchPointRef(entity: other, index: j),
                                                                             SketchPointRef(entity: index, index: k))))
                    break
                }
            }
        }
    }

    private func entitiesChanged() {
        let profile = entities.indices.filter { !construction.contains($0) }.map { entities[$0] }
        let found = findRegions(in: profile)
        regions = found.regions
        loops = found.loops
        snapIndex = SnapIndex(entities: entities)
        measureRefs = measureRefs.filter { entities.indices.contains($0.entity) }
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
                if let circleInference { return circleInference.label }
                return activeSnap?.kind.map { "Fang: \($0.rawValue)" }
            }
        }
        if tool == .offset, offsetTarget != nil {
            return "Versatz \(offsetDistance.formatted(.number.precision(.fractionLength(0...3)))) mm"
        } else if !splinePoints.isEmpty {
            return "Spline, \(splinePoints.count) Punkte"
        } else if !regions.isEmpty {
            return regions.count == 1 ? "1 geschlossener Bereich" : "\(regions.count) geschlossene Bereiche"
        } else {
            return nil
        }
    }
}

// MARK: Werkzeuge nach Fusion 360 (Langloch, Verlängern, Unterbrechen, Spiegeln, Muster)

extension SketchController {
    /// Vorschau des zweiten Schritts (Kreis durch 3 Punkte, Langloch).
    private func stepPreview(base: (start: Point2, end: Point2), current: Point2) -> [SketchEntity]? {
        switch tool {
        case .circle where circleMode == .threePoint:
            return SketchShapes.circle(through: base.start, current, base.end).map { [$0] }
        case .slot:
            return slotEntities(base: base, through: current)
        default:
            return nil
        }
    }

    private func slotEntities(base: (start: Point2, end: Point2), through p: Point2) -> [SketchEntity]? {
        let half = SketchShapes.slotHalfWidth(base.start, base.end, through: p)
        guard let centers = SketchShapes.slotCenters(base.start, base.end, half: half, mode: slotMode) else { return nil }
        return SketchShapes.slot(centers.0, centers.1, half: half)
    }

    /// Mehrere Elemente als ein Schritt (ein Rückgängig).
    private func addGroup(_ shapes: [SketchEntity], keepConstruction source: [Int]? = nil) {
        guard !shapes.isEmpty else { return }
        remember()
        for (k, shape) in shapes.enumerated() {
            entities.append(shape)
            let index = entities.count - 1
            let fromConstruction = source.map { construction.contains($0[k]) } ?? constructionMode
            if fromConstruction { construction.insert(index) }
            connect(index)
        }
        editableIndex = nil
        entitiesChanged()
    }

    /// Linienende antippen: bis zur nächsten Kurve in Verlängerung.
    func extendLine(at p: Point2, tolerance: Double) {
        guard let index = nearestEntity(to: p, tolerance: tolerance) else {
            notice = "Linie nahe dem Ende antippen, das verlängert werden soll."
            return
        }
        guard case .line = entities[index] else {
            notice = "Verlängern geht mit einzelnen Linien (Rechtecke vorher mit „Unterbrechen“ teilen)."
            return
        }
        let cutters = entities.indices.filter { $0 != index }.flatMap { entities[$0].trimPrimitives }
        guard let longer = SketchTrim.extend(entities[index], at: p, cutters: cutters) else {
            notice = "In dieser Richtung liegt keine Kurve, bis zu der verlängert werden kann."
            return
        }
        remember()
        replaceEntity(index, with: [longer])
        notice = nil
        entitiesChanged()
    }

    /// Kurve an den Schnittpunkten um die angetippte Stelle teilen (nichts wird gelöscht).
    func breakCurve(at p: Point2, tolerance: Double) {
        guard let index = nearestEntity(to: p, tolerance: tolerance) else { return }
        remember()
        var target = index
        if let lines = entities[index].exploded {
            let first = replaceEntity(index, with: lines)
            target = nearestEntity(to: p, tolerance: .infinity, among: Array(first..<entities.count)) ?? first
        }
        let cutters = entities.indices.filter { $0 != target }.flatMap { entities[$0].trimPrimitives }
        guard let pieces = SketchTrim.split(entities[target], at: p, cutters: cutters), pieces.count >= 2 else {
            if let snapshot = undoStack.popLast() { restore(snapshot) }
            notice = "Ellipsen, Splines und Text lassen sich nicht unterbrechen."
            return
        }
        replaceEntity(target, with: pieces)
        notice = "In \(pieces.count) Stücke geteilt – einzeln wählbar, verlängerbar und bemaßbar."
        entitiesChanged()
    }

    // MARK: Spiegeln und Muster

    /// Spiegelachse: die zuletzt gewählte Linie.
    private var mirrorAxis: (ref: SketchCurveRef, a: Point2, b: Point2)? {
        guard case .curve(let ref)? = selection.last, entities.indices.contains(ref.entity),
              case .line(let a, let b) = entities[ref.entity].constraintCurve(ref.index),
              simd_distance(a, b) > 1e-9 else { return nil }
        return (ref, a, b)
    }

    /// Elemente, die gespiegelt bzw. vervielfältigt werden (ohne Achse bzw. Mittelpunkt).
    private var transformSources: [Int] {
        var refs = selection
        switch tool {
        case .mirror:
            if mirrorAxis != nil { refs.removeLast() }
        case .circPattern:
            if case .point? = refs.last { refs.removeLast() }
        default:
            break
        }
        var seen = Set<Int>()
        return refs.map(\.entity).filter { entities.indices.contains($0) && seen.insert($0).inserted }
    }

    /// Mitte des Kreismusters: zuletzt gewählter Punkt, sonst der Ursprung der Skizze.
    private var patternCenter: Point2 {
        if case .point(let ref)? = selection.last, let p = ConstraintSolver.point(ref, entities) { return p }
        return .zero
    }

    /// Neue Elemente des Spiegelns bzw. Musters mit ihrem Ursprungselement.
    private var transformCopies: [(source: Int, entity: SketchEntity)] {
        let sources = transformSources
        guard !sources.isEmpty else { return [] }
        switch tool {
        case .mirror:
            guard let axis = mirrorAxis else { return [] }
            return sources.compactMap { index in
                entities[index].mirrored(through: axis.a, direction: axis.b - axis.a).map { (source: index, entity: $0) }
            }
        case .rectPattern:
            var result: [(source: Int, entity: SketchEntity)] = []
            for row in 0..<max(patternRows, 1) {
                for column in 0..<max(patternColumns, 1) where row != 0 || column != 0 {
                    let offset = Point2(Double(column) * patternSpacingX, Double(row) * patternSpacingY)
                    result += sources.map { (source: $0, entity: entities[$0].translated(by: offset)) }
                }
            }
            return result
        case .circPattern:
            let count = max(circularCount, 2)
            let full = abs(abs(circularAngle) - 360) < 1e-9
            let step = (circularAngle * .pi / 180) / Double(full ? count : count - 1)
            let center = patternCenter
            var result: [(source: Int, entity: SketchEntity)] = []
            for k in 1..<count {
                result += sources.compactMap { index in
                    entities[index].rotated(about: center, by: step * Double(k)).map { (source: index, entity: $0) }
                }
            }
            return result
        default:
            return []
        }
    }

    /// Vorschau der Kopien (gestrichelt wie die übrige Eingabe).
    var transformPreview: [SketchEntity] { transformCopies.map(\.entity) }

    /// Was beim Spiegeln bzw. Muster gerade gewählt ist (für die Karte).
    var transformStatus: String {
        let count = transformSources.count
        switch tool {
        case .mirror:
            if count == 0 { return "Elemente antippen, zuletzt die Spiegellinie" }
            return mirrorAxis == nil ? "\(count) gewählt – jetzt die Spiegellinie antippen"
                : "\(count) Element\(count == 1 ? "" : "e") an der Linie gespiegelt (Vorschau)"
        case .circPattern:
            if count == 0 { return "Elemente antippen, zuletzt den Mittelpunkt (sonst Ursprung)" }
            if case .point? = selection.last { return "\(count) gewählt, um den gewählten Punkt" }
            return "\(count) gewählt, um den Ursprung – Punkt antippen für eine andere Mitte"
        default:
            return count == 0 ? "Elemente antippen" : "\(count) gewählt"
        }
    }

    var canApplyTransform: Bool { !transformCopies.isEmpty }

    /// Spiegeln bzw. Muster übernehmen.
    func applyTransform() {
        let copies = transformCopies
        guard !copies.isEmpty else {
            notice = transformStatus
            return
        }
        addGroup(copies.map(\.entity), keepConstruction: copies.map(\.source))
        selection = []
        selectedMarks = []
        notice = "\(copies.count) Element\(copies.count == 1 ? "" : "e") erstellt."
        changed()
    }
}
