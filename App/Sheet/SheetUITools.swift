import SwiftUI

// Blech-Werkzeuge im Ribbon (Punkt 6, Kai zum Flansch: „verstehe ich nicht“):
// - Werkzeugliste (SheetTools.catalog): Ribbon-Gruppe „Blech“ und Befehlssuche lesen dieselbe Liste. Ein neues
//   Werkzeug = Treiber in ModelCommands.registerSheet() eintragen und hier eine Zeile ergänzen.
// - Der frühere „Flansch“ (Typ folgt der Auswahl) ist in drei Werkzeuge mit festem Typ geteilt:
//   „Blechteil aus Skizze“ (Grundflansch), „Lasche“ (Kantenflansch) und „Profil biegen“ (Konturflansch).
//   Gerechnet wird weiter in SheetFlangeDriver (SheetUIFlange.swift).
// - Frage „In Blech umwandeln?“, wenn ein Werkzeug Blech erwartet und ein Vollkörper angetippt wird.
// - Mini-Vorschaubild je Werkzeug oben im Panel (schematische Skizze des Ergebnisses).

// MARK: - Werkzeugliste

/// Ein Blech-Werkzeug im Ribbon und in der Befehlssuche.
struct SheetToolEntry {
    let id: ModelCommandID
    let title: String
    /// Untertitel im Gruppenmenü
    let subtitle: String
    /// sc.*-Symbol bzw. SF Symbol
    let icon: String
    /// Zwischenüberschrift im Gruppenmenü (ERSTELLEN, ABWICKLUNG, REGELN)
    let heading: String
    /// Als Kachel direkt in der Leiste
    var featured = false
    /// Befehlssuche: Untertitel und Suchwörter
    let search: String
    let keywords: String
    /// Erklärkapsel unten beim Start (nil = keine)
    var capsule: String? = nil
}

@MainActor
enum SheetTools {
    /// Reihenfolge = Reihenfolge im Gruppenmenü (SolidCraft workspace.rs: CREATE · FLAT · OUTPUT · RULES). AUSGABE
    /// (DXF, Biegetabelle) steht in SheetUI.ribbonCommands, weil es Aktionen ohne Panel sind.
    static let catalog: [SheetToolEntry] = [
        SheetToolEntry(id: .sheetBaseFlange, title: "Blechteil aus Skizze", subtitle: "Geschlossene Skizze wird Blech",
                       icon: "sc.sheet", heading: "ERSTELLEN", featured: true,
                       search: "Blech: geschlossenes Skizzenprofil wird Blech mit Dicke (Grundflansch)",
                       keywords: "grundflansch base flange platte zuschnitt profil skizze blechteil",
                       capsule: "Geschlossenen Bereich einer Skizze antippen: er wird ein flaches Blechteil mit der "
                           + "Dicke der Blechregel."),
        SheetToolEntry(id: .sheetEdgeFlange, title: "Lasche", subtitle: "Kante antippen, Länge und Winkel",
                       icon: "sc.flange", heading: "ERSTELLEN", featured: true,
                       search: "Blech: an einer Blechkante ankanten (Kantenflansch)",
                       keywords: "kantenflansch edge flange lasche kantung abkanten schenkel flanke",
                       capsule: "Kante eines Blechteils antippen: dort wird eine Lasche angekantet. Länge am Pfeil "
                           + "ziehen oder eingeben, Winkel im Panel."),
        SheetToolEntry(id: .sheetContourFlange, title: "Profil biegen", subtitle: "Offene Skizzenlinie wird Profil",
                       icon: "point.3.connected.trianglepath.dotted", heading: "ERSTELLEN", featured: true,
                       search: "Blech: offene Linienkette wird gebogenes Profil (Konturflansch)",
                       keywords: "konturflansch contour flange profil z-profil u-profil winkelprofil kantteil",
                       capsule: "Offene Linien einer Skizze wählen: jede Linie wird eine Blechwand, jede Ecke eine "
                           + "Biegung. Breite am Pfeil ziehen oder eingeben."),
        SheetToolEntry(id: .sheetKanten, title: "Kanten", subtitle: "Flanke am Blech hochkanten",
                       icon: "arrow.turn.right.up", heading: "ERSTELLEN", featured: true,
                       search: "Blech: vorhandenes Blech an einer Linie parallel zur Kante hochkanten (Flankenlänge)",
                       keywords: "kanten kantung abkanten hochkanten flanke biegen falten biegelinie fold",
                       capsule: "Außenkante eines Blechteils antippen und die Flankenlänge eingeben: an der gestrichelten "
                           + "Linie wird das Blech hochgekantet. Mehrere Kanten zugleich gehen auch."),
        SheetToolEntry(id: .sheetBox, title: "Kasten aus Maßen", subtitle: "Boden und Laschen aus fertigen Maßen",
                       icon: "shippingbox", heading: "ERSTELLEN", featured: true,
                       search: "Blech: Kasten/Wanne aus Länge, Breite, Laschenhöhe, Dicke und Radius",
                       keywords: "kasten wanne schale box tray assistent maße laschen boden abwicklung zuschnitt",
                       capsule: "Fertige Maße eingeben – Länge, Breite, Laschenhöhe, Blechdicke und Biegeradius: daraus "
                           + "wird ein gekanteter Kasten mit Eckfreischnitten."),
        SheetToolEntry(id: .sheetPathFlange, title: "Pfadflansch", subtitle: "Profil entlang einer Blechkante",
                       icon: "sc.path_flange", heading: "ERSTELLEN",
                       search: "Blech: Flansche entlang einer Linienkette an einer Kante", keywords: "path flange pfad"),
        SheetToolEntry(id: .sheetHem, title: "Umkantung", subtitle: "Blechkante zurückbiegen", icon: "sc.hem",
                       heading: "ERSTELLEN", search: "Blech: Kante zurückbiegen (Saum)", keywords: "hem saum umschlag"),
        SheetToolEntry(id: .sheetFold, title: "Falten", subtitle: "Entlang einer Skizzenlinie biegen", icon: "sc.fold",
                       heading: "ERSTELLEN", search: "Blech: entlang einer Skizzenlinie biegen",
                       keywords: "fold abkanten biegen"),
        SheetToolEntry(id: .sheetPerforate, title: "Perforieren", subtitle: "Lochfeld über das Blech",
                       icon: "sc.perforate", heading: "ERSTELLEN", search: "Blech: Lochfeld",
                       keywords: "perforate lochung lochblech"),
        SheetToolEntry(id: .sheetConvert, title: "In Blech umwandeln", subtitle: "Platte, Volumen- oder Schalenkörper",
                       icon: "sc.convert_sheet", heading: "ERSTELLEN", featured: true,
                       search: "Körper zu Blech, offene Kanten wählbar",
                       keywords: "convert umwandeln offene kanten abwickeln"),
        SheetToolEntry(id: .sheetUnfold, title: "Entfalten", subtitle: "Alle Biegungen flach", icon: "sc.unfold",
                       heading: "ABWICKLUNG", featured: true, search: "Blech: alle Biegungen flach",
                       keywords: "unfold abwickeln flach"),
        SheetToolEntry(id: .sheetRefold, title: "Wieder falten", subtitle: "Entfalteten Körper zurückbiegen",
                       icon: "sc.refold", heading: "ABWICKLUNG", search: "Blech: zurückbiegen",
                       keywords: "refold zurückfalten"),
        SheetToolEntry(id: .sheetFlatPattern, title: "Flachmuster erstellen", subtitle: "Abwicklung, Biegelinien, Biegetabelle",
                       icon: "sc.flat", heading: "ABWICKLUNG", featured: true,
                       search: "Abwicklung mit Biegelinien und Biegetabelle",
                       keywords: "flat pattern abwicklung zuschnitt laser"),
        SheetToolEntry(id: .sheetRules, title: "Blechregeln", subtitle: "Dicke, Biegeradius, K-Faktor, Freistiche",
                       icon: "sc.sheet_rules", heading: "REGELN", search: "Dicke, Biegeradius, K-Faktor, Freistiche",
                       keywords: "rules regel dicke k-faktor biegeradius"),
        SheetToolEntry(id: .sheetRuleList, title: "Blechregeln auflisten", subtitle: "Alle Regeln mit Werten",
                       icon: "sc.sheet_rules", heading: "REGELN", search: "Alle Regeln mit Werten",
                       keywords: "rules liste"),
    ]

    /// Werkzeug starten und, wo gepflegt, die Erklärkapsel zeigen.
    static func start(_ entry: SheetToolEntry, _ ws: Workspace) {
        SheetUI.start(entry.id, ws)
        guard ws.command?.id == entry.id, let text = entry.capsule else { return }
        ws.explain(ToolExplanation(title: entry.title, text: text))
    }
}

// MARK: - Werkzeuge mit festem Flanschtyp

/// Werkzeug, das SheetFlangeDriver mit festem Typ benutzt (Panel, Vorschau, Pfeil, Bearbeiten aus der Zeitleiste).
@MainActor
protocol SheetFlangeVariant: SheetEditableDriver {
    static var flangeKind: SheetFlangeKind { get }
}

extension SheetFlangeVariant {
    static var sheetCommands: Set<String> { ["sheet.flange"] }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        SheetFlangeDriver.buildCommand(ws, id: id)
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        SheetFlangeDriver.tapped(tap, cmd, ws)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        SheetFlangeDriver.refresh(cmd, ws)
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        SheetFlangeDriver.canCommit(cmd, ws)
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetFlangeDriver.finish(cmd, ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetFlangeDriver.abort(cmd, ws)
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        SheetFlangeDriver.arrows(cmd, ws)
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        SheetFlangeDriver.drag(kind, value, cmd, ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? {
        SheetFlangeDriver.mainValueKey(cmd)
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        SheetFlangeDriver.panel(cmd, ws)
    }

    /// Zeitleiste: nur Flansche des eigenen Typs öffnen (die anderen öffnet das passende Werkzeug)
    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        guard feature.kind == .sheetMetal, let found = ws.model.sheetStep(for: feature),
              found.step.command.command == "sheet.flange",
              SheetFlangeDriver.kind(of: found.step.command) == flangeKind else { return nil }
        return SheetEdit.load(feature, into: ws, id: id, commands: sheetCommands)
    }
}

/// Blechteil aus Skizze (Grundflansch): geschlossener Skizzenbereich → flaches Blech mit der Dicke der Regel.
enum SheetBaseFlangeDriver: SheetFlangeVariant {
    static let id = ModelCommandID.sheetBaseFlange
    static let title = "Blechteil aus Skizze"
    static let icon = "sc.sheet"
    static let flangeKind = SheetFlangeKind.base
    static var explanation: String? {
        "Geschlossenen Bereich einer Skizze antippen: er wird ein flaches Blechteil mit der Dicke der Blechregel. "
            + "„Umkehren“ legt das Material auf die andere Seite der Skizze."
    }
}

/// Lasche (Kantenflansch): Kante eines Blechteils antippen, Länge am Pfeil, Winkel im Panel.
enum SheetEdgeFlangeDriver: SheetFlangeVariant {
    static let id = ModelCommandID.sheetEdgeFlange
    static let title = "Lasche"
    static let icon = "sc.flange"
    static let flangeKind = SheetFlangeKind.edge
    static var explanation: String? {
        "Kante eines Blechteils antippen (mehrere möglich): dort wird eine Lasche angekantet. Länge am Pfeil ziehen "
            + "oder eingeben, Winkel im Panel (90° = rechtwinklig). Ein Vollkörper lässt sich vorher in Blech umwandeln."
    }
}

/// Profil biegen (Konturflansch): offene Linienkette einer Skizze → gebogenes Profil mit Breite.
enum SheetContourFlangeDriver: SheetFlangeVariant {
    static let id = ModelCommandID.sheetContourFlange
    static let title = "Profil biegen"
    static let icon = "point.3.connected.trianglepath.dotted"
    static let flangeKind = SheetFlangeKind.contour
    static var explanation: String? {
        "Offene Linien einer Skizze wählen (z. B. ein Z- oder U-Profil als Linienzug): jede Linie wird eine Blechwand, "
            + "jede Ecke eine Biegung. Die Breite geht senkrecht zur Skizze."
    }
}

// MARK: - Frage „In Blech umwandeln?“

/// Ein Werkzeug erwartet Blech, angetippt wurde ein Vollkörper: statt einer Fehlermeldung fragt das Panel, ob der
/// Körper umgewandelt werden soll (Ja → „In Blech umwandeln“ mit diesem Körper, Nein → Frage schließen).
@MainActor
enum SheetConvertQuestion {
    static func ask(_ body: Int, _ cmd: ModelCommand, _ model: ModelStore) {
        guard model.bodies.indices.contains(body), !model.isSheetBody(body) else { return }
        SheetCommandState.of(cmd).convertBody = body
    }

    static func clear(_ cmd: ModelCommand) {
        guard let state = SheetCommandState.existing(cmd), state.convertBody != nil else { return }
        state.convertBody = nil
    }

    /// „Ja“: In Blech umwandeln mit diesem Körper starten; größte ebene Fläche als feste Fläche (mit Vorschlag).
    static func convert(_ body: Int, _ ws: Workspace) {
        let model = ws.model
        guard model.bodies.indices.contains(body) else { return }
        let name = model.bodies[body].name
        SheetUI.start(.sheetConvert, ws)
        guard let cmd = ws.command, cmd.id == .sheetConvert else { return }
        let faces = SheetConvertTopology.topology(of: body, cmd, model).faces
        if let face = faces.max(by: { $0.area < $1.area }) {
            SheetConvertDriver.choose(base: FaceRef(body: body, face: face.face), cmd, model, suggest: true)
            ws.refreshCommandPreview()
        }
        ws.explain(ToolExplanation(title: "In Blech umwandeln",
                                   text: "„\(name)“ wird Blech: feste Fläche und offene Kanten prüfen, dann OK. "
                                       + "Danach das Blech-Werkzeug erneut wählen."))
    }
}

/// Frage im Panel (oben, gut sichtbar), solange der angetippte Körper kein Blech ist.
struct SheetConvertQuestionRow: View {
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var state: SheetCommandState

    var body: some View {
        if let target = state.convertBody, model.bodies.indices.contains(target), !model.isSheetBody(target) {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("„\(model.bodies[target].name)“ ist kein Blech.")
                            .font(.footnote.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("In Blech umwandeln?")
                            .font(.footnote)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: PaletteStyle.spacing) {
                    PrimaryWideButton(title: "Ja", systemImage: "checkmark", isPrimary: true) {
                        state.convertBody = nil
                        SheetConvertQuestion.convert(target, workspace)
                    }
                    .accessibilityLabel("Ja, in Blech umwandeln")
                    PrimaryWideButton(title: "Nein", systemImage: "xmark", isPrimary: false) {
                        state.convertBody = nil
                    }
                    .accessibilityLabel("Nein, nicht umwandeln")
                }
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
        }
    }
}

// MARK: - Mini-Vorschaubild

/// Schematische Skizze des Ergebnisses je Werkzeug.
enum SheetToolSketch {
    case base, edge, contour, pathFlange, hem, fold, perforate, unfold, kanten, box

    init(_ kind: SheetFlangeKind) {
        switch kind {
        case .base: self = .base
        case .edge: self = .edge
        case .contour: self = .contour
        }
    }

    var accessibilityText: String {
        switch self {
        case .base: "Skizze wird flaches Blechteil"
        case .edge: "Blechteil mit angekanteter Lasche"
        case .contour: "Offene Linie wird gebogenes Profil"
        case .pathFlange: "Profil entlang einer Blechkante"
        case .hem: "Blechkante zurückgebogen"
        case .fold: "Blech entlang einer Linie gebogen"
        case .perforate: "Blech mit Lochfeld"
        case .unfold: "Gebogenes Blech wird flach"
        case .kanten: "Flaches Blech, an der gestrichelten Linie hochgekantet"
        case .box: "Kasten aus Boden und vier Laschen"
        }
    }
}

/// Mini-Vorschaubild (ca. 120 × 70 pt), neutrale Farben aus der Umgebung (hell/dunkel), Neues in der Akzentfarbe.
struct SheetToolPreview: View {
    let sketch: SheetToolSketch

    var body: some View {
        Canvas { context, size in
            SheetSketchPainter(context: context, size: size).draw(sketch)
        }
        .frame(width: 120, height: 70)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(sketch.accessibilityText)
    }
}

/// Zeichnet in Entwurfseinheiten (120 × 70) mit schräger Parallelprojektion: x nach rechts, y in die Tiefe
/// (schräg nach rechts oben), z nach oben.
private struct SheetSketchPainter {
    let context: GraphicsContext
    let size: CGSize

    enum Tone { case old, new }

    private var scale: CGFloat { min(size.width / 120, size.height / 70) }
    private var inset: CGPoint {
        CGPoint(x: (size.width - 120 * scale) / 2, y: (size.height - 70 * scale) / 2)
    }

    private var lineColor: Color { Color.primary.opacity(0.62) }
    private var fillColor: Color { Color.primary.opacity(0.10) }
    private var accent: Color { Color.accentColor }

    /// Punkt im Raum (Ursprung o in Entwurfseinheiten) → Bildpunkt
    private func point(_ o: CGPoint, _ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        CGPoint(x: inset.x + (o.x + CGFloat(x + 0.5 * y)) * scale,
                y: inset.y + (o.y - CGFloat(z + 0.42 * y)) * scale)
    }

    private func flat(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: inset.x + x * scale, y: inset.y + y * scale)
    }

    private func polygon(_ o: CGPoint, _ points: [(Double, Double, Double)]) -> Path {
        var path = Path()
        path.addLines(points.map { point(o, $0.0, $0.1, $0.2) })
        path.closeSubpath()
        return path
    }

    private func face(_ o: CGPoint, _ points: [(Double, Double, Double)], _ tone: Tone) {
        let path = polygon(o, points)
        context.fill(path, with: .color(tone == .new ? accent.opacity(0.28) : fillColor))
        context.stroke(path, with: .color(tone == .new ? accent : lineColor),
                       style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }

    /// Quader: sichtbare Flächen vorne, rechts, oben
    private func box(_ o: CGPoint, _ x: Double, _ y: Double, _ z: Double, _ dx: Double, _ dy: Double, _ dz: Double,
                     _ tone: Tone) {
        face(o, [(x, y, z), (x + dx, y, z), (x + dx, y, z + dz), (x, y, z + dz)], tone)
        face(o, [(x + dx, y, z), (x + dx, y + dy, z), (x + dx, y + dy, z + dz), (x + dx, y, z + dz)], tone)
        face(o, [(x, y, z + dz), (x + dx, y, z + dz), (x + dx, y + dy, z + dz), (x, y + dy, z + dz)], tone)
    }

    private func dashed(_ points: [CGPoint], closed: Bool = false) {
        var path = Path()
        path.addLines(points)
        if closed { path.closeSubpath() }
        context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 2]))
    }

    /// Pfeil zwischen zwei Bildpunkten
    private func arrow(_ from: CGPoint, _ to: CGPoint, color: Color? = nil) {
        let shading = GraphicsContext.Shading.color(color ?? lineColor)
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let head = 4 * scale
        var tip = Path()
        tip.move(to: to)
        tip.addLine(to: CGPoint(x: to.x - head * ux + head * 0.55 * uy, y: to.y - head * uy - head * 0.55 * ux))
        tip.addLine(to: CGPoint(x: to.x - head * ux - head * 0.55 * uy, y: to.y - head * uy + head * 0.55 * ux))
        tip.closeSubpath()
        context.fill(tip, with: shading)
    }

    func draw(_ sketch: SheetToolSketch) {
        switch sketch {
        case .base:
            // Skizzenrechteck (gestrichelt) → flaches Blechteil
            let left = CGPoint(x: 6, y: 50)
            dashed([point(left, 0, 0, 0), point(left, 34, 0, 0), point(left, 34, 30, 0), point(left, 0, 30, 0)],
                   closed: true)
            arrow(flat(56, 38), flat(66, 38))
            box(CGPoint(x: 68, y: 52), 0, 0, 0, 32, 30, 4, .new)
        case .edge:
            // Blechteil, an der hinteren Kante hochgekantete Lasche, Pfeil für die Länge
            let o = CGPoint(x: 14, y: 60)
            box(o, 0, 0, 0, 60, 32, 4, .old)
            box(o, 0, 28, 4, 60, 4, 30, .new)
            arrow(point(o, 70, 30, 6), point(o, 70, 30, 34), color: accent)
        case .contour:
            // Offener Linienzug (gestrichelt) → Profil mit Biegungen
            dashed([flat(6, 52), flat(20, 52), flat(20, 32), flat(34, 32)])
            arrow(flat(38, 42), flat(48, 42))
            let o = CGPoint(x: 52, y: 60)
            face(o, [(0, 0, 0), (16, 0, 0), (16, 30, 0), (0, 30, 0)], .new)
            face(o, [(16, 0, 0), (16, 0, 22), (16, 30, 22), (16, 30, 0)], .new)
            face(o, [(16, 0, 22), (32, 0, 22), (32, 30, 22), (16, 30, 22)], .new)
        case .pathFlange:
            // Profil (hoch, dann nach hinten) entlang der hinteren Blechkante
            let o = CGPoint(x: 14, y: 60)
            box(o, 0, 0, 0, 60, 30, 4, .old)
            face(o, [(0, 30, 22), (60, 30, 22), (60, 42, 22), (0, 42, 22)], .new)
            face(o, [(0, 30, 4), (60, 30, 4), (60, 30, 22), (0, 30, 22)], .new)
        case .hem:
            // Vordere Kante flach auf das Blech zurückgebogen
            let o = CGPoint(x: 14, y: 58)
            box(o, 0, 0, 0, 64, 32, 4, .old)
            box(o, 0, 0, 7, 64, 12, 3, .new)
            face(o, [(0, 0, 4), (64, 0, 4), (64, 0, 7), (0, 0, 7)], .new)
        case .fold:
            // Biegelinie (gestrichelt), rechte Hälfte hochgebogen
            let o = CGPoint(x: 16, y: 58)
            box(o, 0, 0, 0, 34, 30, 3, .old)
            let c = cos(Double.pi / 4) * 28
            face(o, [(34, 0, 3), (34 + c, 0, 3 + c), (34 + c, 30, 3 + c), (34, 30, 3)], .new)
            dashed([point(o, 34, 0, 3), point(o, 34, 30, 3)])
        case .perforate:
            // Lochfeld (versetzt) auf dem Blech
            let o = CGPoint(x: 12, y: 58)
            box(o, 0, 0, 0, 70, 32, 4, .old)
            for row in 0..<3 {
                for column in 0..<7 {
                    let x = 6 + Double(column) * 9.5 + (row % 2 == 1 ? 4.75 : 0)
                    guard x < 68 else { continue }
                    let center = point(o, x, 6 + Double(row) * 10, 4)
                    let rect = CGRect(x: center.x - 2 * scale, y: center.y - 1.2 * scale, width: 4 * scale,
                                      height: 2.4 * scale)
                    context.stroke(Path(ellipseIn: rect), with: .color(accent), lineWidth: 1)
                }
            }
        case .unfold:
            // Winkel → flaches Teil mit Biegelinie
            let left = CGPoint(x: 6, y: 56)
            box(left, 0, 0, 0, 24, 22, 3, .old)
            box(left, 0, 19, 3, 24, 3, 20, .old)
            arrow(flat(46, 40), flat(56, 40))
            let right = CGPoint(x: 60, y: 56)
            box(right, 0, 0, 0, 44, 22, 3, .new)
            dashed([point(right, 24, 0, 3), point(right, 24, 22, 3)])
        case .kanten:
            // Flaches Blech mit gestrichelter Linie parallel zur vorderen Kante → vorderer Streifen hochgekantet
            let left = CGPoint(x: 4, y: 54)
            box(left, 0, 0, 0, 34, 26, 3, .old)
            dashed([point(left, 0, 8, 3), point(left, 34, 8, 3)])
            arrow(flat(48, 40), flat(58, 40))
            let right = CGPoint(x: 62, y: 60)
            box(right, 0, 8, 0, 34, 18, 3, .old)
            box(right, 0, 8, 3, 34, 3, 16, .new)
        case .box:
            // Kasten: Boden, vier Laschen (hinten und links zuerst, damit vorne und rechts darüber liegen)
            let o = CGPoint(x: 18, y: 60)
            box(o, 0, 29, 3, 64, 3, 20, .new)
            box(o, 0, 0, 3, 3, 32, 20, .new)
            box(o, 0, 0, 0, 64, 32, 3, .old)
            box(o, 61, 0, 3, 3, 32, 20, .new)
            box(o, 0, 0, 3, 64, 3, 20, .new)
        }
    }
}
