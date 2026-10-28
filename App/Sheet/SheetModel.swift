import Foundation
import simd

// Datenmodell des Blechmoduls (SheetKit/API.md „Datenmodell“ und „Swift-Modell-API“): Ein Blechkörper speichert
// sein Rezept – die SolidCraft-Befehle, die ihn in einer frischen Sitzung erzeugen (Blechregel, Skizze, Flansche …).
// Neu berechnet wird durch Wiedergabe, der Körper kommt per STEP nach OpenCASCADE. Jeder Blechschritt ist ein
// Feature „Blech“ im parametrischen Verlauf (FeatureHistory.swift) und damit rückgängig machbar und änderbar.
//
// Aufteilung: SheetModel.swift (Typen, Dokument, öffentliche Funktionen am ModelStore), SheetModelReplay.swift
// (Wiedergabe, Verlauf), SheetModelSketch.swift (PencilCAD-Skizze → SolidCraft-Skizze),
// SheetModelConvert.swift („In Blech umwandeln“, offene Kanten, Abwicklungsbaum).

// MARK: - Rezept

/// Ein Schritt im Blechrezept: ein SolidCraft-Befehl mit Anzeigenamen. Die ID bleibt beim Bearbeiten gleich.
struct SheetStep: Codable, Hashable, Identifiable {
    var id = UUID()
    /// Anzeigename, z. B. „Kantenflansch“
    var title: String
    var command: SheetCommand
    /// Nach dem Ausführen heißt der erzeugte bzw. geänderte Körper der Sitzung so (z. B. „$src“); nil = keiner
    var alias: String? = nil

    init(_ title: String, _ command: SheetCommand) {
        self.title = title
        self.command = command
    }
}

/// Blechdaten eines Körpers (SceneBody.sheetMetal), gespeichert in bodies.json.
struct SheetBodyInfo: Codable, Hashable {
    /// Rezept in Reihenfolge
    var steps: [SheetStep] = []
    /// Name des Körpers in der SolidCraft-Sitzung (der exportiert wird)
    var kernelBody: String
    /// Name der Blechregel des Körpers
    var rule: String
    /// „In Blech umwandeln“: Ausgangskörper als STEP im Projektordner (sheet/<Datei>); nil = aus Skizze
    var sourceFile: String? = nil
    /// Hüllquader des zuletzt wiedergegebenen Körpers – erkennt Verschiebungen außerhalb des Blechmoduls
    var resultBox: [Double]? = nil

    var recipe: [SheetCommand] { steps.map(\.command) }

    /// Abgewickelt: der letzte Entfalten/Zurückfalten-Schritt ist ein Entfalten.
    var isUnfolded: Bool {
        guard let last = steps.last(where: { $0.command.command == "sheet.unfold" || $0.command.command == "sheet.refold" })
        else { return false }
        return last.command.command == "sheet.unfold"
    }
}

// MARK: - Blechregel

/// Blechregel (SolidCraft sheet.manage_rules): Stärke, Biegeradius, K-Faktor und Freischnitte. Längen in mm.
struct SheetRule: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var thickness: Double = 2.5
    var kFactor: Double = 0.44
    /// Innerer Biegeradius; nil = wie SolidCraft der Ausdruck „Thickness“ (folgt der Dicke)
    var bendRadius: Double? = nil
    /// Biegefreischnitt (nil = Vorgabe der Engine)
    var reliefWidth: Double? = nil
    var reliefDepth: Double? = nil
    /// Eckfreischnitt: Größe und Form („notch“, „round“, „rectangular“, „tear“)
    var cornerRelief: Double? = nil
    var cornerReliefShape: String? = nil
    /// Spalt bei der Umkantung
    var hemGap: Double? = nil
    /// Spalt zwischen Flanschen, die an einer Ecke zusammenstoßen
    var gap: Double? = nil
    /// Winkelangabe im DXF: „bend“ (Biegewinkel) oder „included“ (Innenwinkel)
    var angleDisplay: String? = nil

    var id: String { name }

    /// Tatsächlicher Biegeradius (nil = Dicke)
    var effectiveBendRadius: Double { bendRadius ?? thickness }

    static let cornerShapes: [(key: String, title: String)] = [
        ("notch", "Ausklinkung"), ("round", "Rund"), ("rectangular", "Rechteckig"), ("tear", "Reißen"),
    ]

    /// Vorgaberegel neuer Projekte (wie SolidCraft „Steel (mm)“: 2,5 mm, K 0,44, Radius = Dicke als Ausdruck)
    static let standard = SheetRule(name: "Stahl (mm)")

    /// Als SolidCraft-Befehl (sheet.manage_rules); active = zur aktiven Regel der Sitzung machen.
    func command(active: Bool = true) -> SheetCommand {
        var params: SheetJSON = [
            "name": .string(name),
            "thickness": .number(thickness),
            "k_factor": .number(kFactor),
            "bend_radius": bendRadius.map { SheetJSON.number($0) } ?? .string("Thickness"),
            "active": .bool(active),
        ]
        if let reliefWidth { params["relief_width"] = .number(reliefWidth) }
        if let reliefDepth { params["relief_depth"] = .number(reliefDepth) }
        if let cornerRelief { params["corner_relief"] = .number(cornerRelief) }
        if let cornerReliefShape { params["corner_relief_shape"] = .string(cornerReliefShape) }
        if let hemGap { params["hem_gap"] = .number(hemGap) }
        if let gap { params["gap"] = .number(gap) }
        if let angleDisplay { params["angle_display"] = .string(angleDisplay) }
        return SheetCommand("sheet.manage_rules", params)
    }

    /// Regel aus einem sheet.manage_rules-Befehl (nil bei anderen Befehlen bzw. Ausdrücken statt Zahlen).
    init?(command: SheetCommand) {
        guard command.command == "sheet.manage_rules", let name = command.params["name"]?.asString else { return nil }
        self.name = name
        let p = command.params
        thickness = p["thickness"]?.asDouble ?? thickness
        kFactor = p["k_factor"]?.asDouble ?? kFactor
        bendRadius = p["bend_radius"]?.asDouble
        reliefWidth = p["relief_width"]?.asDouble
        reliefDepth = p["relief_depth"]?.asDouble
        cornerRelief = p["corner_relief"]?.asDouble
        cornerReliefShape = p["corner_relief_shape"]?.asString
        hemGap = p["hem_gap"]?.asDouble
        gap = p["gap"]?.asDouble
        angleDisplay = p["angle_display"]?.asString
    }

    init(name: String, thickness: Double = 2.5, kFactor: Double = 0.44, bendRadius: Double? = nil) {
        self.name = name
        self.thickness = thickness
        self.kFactor = kFactor
        self.bendRadius = bendRadius
    }
}

// MARK: - Flachmuster

/// Biegelinie im Flachmuster mit ihrer Zeile der Biegetabelle.
struct FlatBend: Identifiable, Hashable {
    /// Laufende Zeile (eindeutig; eine durch Ausschnitte geteilte Biegung hat mehrere Zeilen mit derselben Nummer)
    var position: Int
    /// Nummer (B1, B2 …)
    var index: Int
    var angle: Double
    var includedAngle: Double
    var radius: Double
    /// true = nach oben, false = nach unten
    var up: Bool
    var allowance: Double
    var length: Double
    var start: SIMD2<Double>
    var end: SIMD2<Double>

    var id: Int { position }
}

/// Bereich einer Bearbeitung (Tasche) im Flachmuster.
struct FlatPocket: Hashable {
    var outline: [SIMD2<Double>]
    var cutouts: [[SIMD2<Double>]]
    /// „bottom“, „top“, „internal“
    var side: String
    var depth: Double
}

/// Flachmuster (sheet.flat_pattern) in Flachkoordinaten (mm).
struct FlatPattern {
    var body: String
    var rule: String
    var thickness: Double
    var kFactor: Double
    /// Breite und Höhe der Abwicklung
    var size: SIMD2<Double>
    /// Außenkonturen (je Teil eine), Punktlisten
    var outline: [[SIMD2<Double>]]
    /// Ausschnitte (Löcher) als Punktlisten
    var cutouts: [[SIMD2<Double>]]
    var bends: [FlatBend]
    var pockets: [FlatPocket]
    /// Bereiche der Biegezonen [xmin, xmax, ymin, ymax]
    var bendZones: [[Double]]
    /// Anzahl der Löcher aus Perforieren (sheet.perforate)
    var perforationCount: Int
    /// Löcher aus Perforieren (Mitte, Radius); leer, solange SheetKit psk.perforation_holes nicht kennt
    var perforationHoles: [(center: SIMD2<Double>, radius: Double)] = []
    /// Rohdaten der Engine (alles Weitere, z. B. cutout_shapes)
    var raw: SheetJSON

    var upBends: [FlatBend] { bends.filter(\.up) }
    var downBends: [FlatBend] { bends.filter { !$0.up } }

    /// Hüllrechteck aller Konturen (min, max).
    var bounds: (min: SIMD2<Double>, max: SIMD2<Double>) {
        let points = outline.flatMap { $0 }
        guard let first = points.first else { return (.zero, size) }
        var lo = first, hi = first
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    init(json: SheetJSON) {
        raw = json
        body = json["body"]?.asString ?? ""
        rule = json["rule"]?.asString ?? ""
        thickness = json["thickness"]?.asDouble ?? 0
        kFactor = json["k_factor"]?.asDouble ?? 0
        let flat = json["flat_size_mm"]?.asArray ?? []
        size = SIMD2(flat.first?.asDouble ?? 0, flat.count > 1 ? flat[1].asDouble ?? 0 : 0)
        outline = (json["outline"]?.asArray ?? []).map(\.asPoints2)
        cutouts = (json["cutouts"]?.asArray ?? []).map(\.asPoints2)
        bends = (json["bends"]?.asArray ?? []).enumerated().compactMap { position, b in
            guard let start = b["start"]?.asPoint2, let end = b["end"]?.asPoint2 else { return nil }
            return FlatBend(position: position, index: b["bend"]?.asInt ?? 0, angle: b["angle_deg"]?.asDouble ?? 0,
                            includedAngle: b["included_angle_deg"]?.asDouble ?? 0, radius: b["radius"]?.asDouble ?? 0,
                            up: b["direction"]?.asString != "down", allowance: b["allowance"]?.asDouble ?? 0,
                            length: b["length"]?.asDouble ?? 0, start: start, end: end)
        }
        pockets = (json["pockets"]?.asArray ?? []).map { p in
            FlatPocket(outline: p["outline"]?.asPoints2 ?? [], cutouts: (p["cutouts"]?.asArray ?? []).map(\.asPoints2),
                       side: p["side"]?.asString ?? "", depth: p["depth_mm"]?.asDouble ?? 0)
        }
        bendZones = (json["bend_zones"]?.asArray ?? []).map { ($0.asArray ?? []).compactMap(\.asDouble) }
        perforationCount = (json["perforations"]?.asArray ?? []).reduce(0) { $0 + ($1["count"]?.asInt ?? 0) }
    }
}

/// Optionen für den DXF-Export des Flachmusters (sheet.export_dxf).
struct SheetDXFOptions: Hashable {
    /// false = Bögen und Linien statt exakter Kurven (für Maschinen, die nur diese lesen)
    var exactCurves = true
    /// Biegenotiz neben jeder Biegelinie
    var bendNotes = false
    /// Biegelinien mit ausgeben (BEND_UP, BEND_DOWN)
    var bendLines = true
    /// Alles auf Layer 0
    var singleLayer = false
    /// Text gravieren statt ausschneiden
    var etchText = false

    var params: SheetJSON {
        var p: SheetJSON = [
            "curves": .string(exactCurves ? "exact" : "arcs"),
            "bend_notes": .bool(bendNotes),
            "bend_lines": .bool(bendLines),
            "layers": .string(singleLayer ? "single" : "roles"),
        ]
        if etchText { p["text"] = "etch" }
        return p
    }
}

// MARK: - Kanten für „In Blech umwandeln“

/// Kante eines PencilCAD-Körpers mit Nachbarflächen (OCCT-Nummern wie edgeIndexData/faceIndexData).
struct SheetModelEdge: Identifiable, Hashable {
    /// Kantennummer (ab 1)
    var edge: Int
    var start: SIMD3<Double>
    var end: SIMD3<Double>
    var mid: SIMD3<Double>
    /// Nachbarflächen (ab 1); zwei bei inneren Kanten
    var faces: [Int]
    /// Knickwinkel zwischen den Flächennormalen in Grad (0 = tangential)
    var angle: Double
    /// Kann Biegekante oder offene Kante sein: gerade Kante zwischen zwei ebenen Wänden mit Knick, oder Vertreter
    /// einer modellierten Biegung (Zylinder bzw. Fasenstreifen zwischen zwei Wänden; faces = die beiden Wände)
    var isCandidate: Bool
    /// Modellierte Biegung: Nummer der Zylinder- bzw. Fasenfläche (nil = scharfe Kante)
    var bendFace: Int? = nil
    /// Punkt für `bends` in sheet.convert: auf der Biegefläche bzw. nil = Kantenmitte
    var bendPoint: SIMD3<Double>? = nil

    var id: Int { edge }
}

/// Ebene Wand eines Körpers für den Abwicklungsbaum (ohne Stirnflächen dünner Körper und ohne Biegeflächen).
struct SheetModelFace: Identifiable, Hashable {
    var face: Int
    var area: Double
    var normal: SIMD3<Double>
    /// Punkt sicher im Inneren der Fläche (Mitte ihres größten Netzdreiecks)
    var point: SIMD3<Double>

    var id: Int { face }
}

/// Vorschlag für „In Blech umwandeln“: Grundfläche, offene Kanten (Schnitt) und Biegekanten.
struct SheetConversionPlan: Hashable {
    /// Feste Grundfläche (OCCT-Nummer) und ein Punkt darauf
    var baseFace: Int
    var basePoint: SIMD3<Double>
    /// Offene Kanten (aufgeschnitten)
    var openEdges: Set<Int>
    /// Biegekanten (Spannbaum der Flächen)
    var bendEdges: Set<Int>
    /// Ergebnis der Probe-Wiedergabe: nil = in Ordnung, sonst Problem (Fehler oder Überlappung)
    var problem: String?
    /// Ebene Platte gleichmäßiger Stärke erkannt: ohne Biegungen umwandeln (convertToSheet plateOnly: true)
    var plateOnly = false
    /// Probe brach am Zeitlimit ab (SheetWorker)
    var timedOut = false
}

// MARK: - Dokument

/// Blechdaten eines Projekts, die nicht an einem Körper hängen: Regeln und aktive Regel (sheet-rules.json),
/// Sitzungs-Zwischenspeicher und letzte Meldung. ModelStore.sheetDocument.
@MainActor
final class SheetDocument: ObservableObject {
    /// Regeln des Projekts (mindestens eine)
    @Published private(set) var rules: [SheetRule] = [.standard]
    @Published private(set) var activeRuleName: String = SheetRule.standard.name
    /// Fehler des letzten Blechbefehls (für das Panel); nil = keiner
    @Published var lastError: String?
    /// Warnung der Engine zum letzten Blechbefehl (Entlastung ausgelassen, Ecke offen …); nil = keine
    @Published var lastWarning: String?

    let folder: URL?
    /// Wiedergegebene Sitzung des zuletzt abgefragten Rezepts (Flachmuster, Exporte ohne erneute Wiedergabe)
    var sessionCache: (key: Int, kernel: SheetKernel, name: String)?
    /// Die angezeigte Vorschau stammt von einem Blechbefehl (wird beim nächsten Blechbefehl verworfen statt übernommen)
    var previewing = false

    init(folder: URL?) {
        self.folder = folder
        load()
    }

    var activeRule: SheetRule { rules.first { $0.name == activeRuleName } ?? rules.first ?? .standard }

    func rule(named name: String) -> SheetRule? { rules.first { $0.name == name } }

    /// Ordner für Ausgangskörper (STEP) umgewandelter Körper.
    var storageDirectory: URL {
        let base = folder ?? FileManager.default.temporaryDirectory.appending(path: "pencil-sheet", directoryHint: .isDirectory)
        let url = base.appending(path: "sheet", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Regel anlegen bzw. ersetzen (gleicher Name).
    func store(_ rule: SheetRule, active: Bool) {
        if let index = rules.firstIndex(where: { $0.name == rule.name }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        if active { activeRuleName = rule.name }
        save()
    }

    func setActive(_ name: String) {
        guard rules.contains(where: { $0.name == name }) else { return }
        activeRuleName = name
        save()
    }

    /// Regel löschen (die letzte bleibt).
    func remove(_ name: String) {
        guard rules.count > 1 else { return }
        rules.removeAll { $0.name == name }
        if !rules.contains(where: { $0.name == activeRuleName }) { activeRuleName = rules[0].name }
        save()
    }

    private struct RuleFile: Codable {
        var rules: [SheetRule]
        var active: String
    }

    private var rulesURL: URL? { folder?.appending(path: "sheet-rules.json") }

    private func load() {
        guard let url = rulesURL, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RuleFile.self, from: data), !file.rules.isEmpty else { return }
        rules = file.rules
        activeRuleName = file.rules.contains { $0.name == file.active } ? file.active : file.rules[0].name
    }

    private func save() {
        guard let url = rulesURL, let data = try? JSONEncoder().encode(RuleFile(rules: rules, active: activeRuleName)) else { return }
        try? data.write(to: url)
    }
}

// MARK: - Befehle bauen

extension SheetCommand {
    /// Winkel als Ausdruck in Grad („90 deg“)
    static func degrees(_ value: Double) -> SheetJSON { .string("\(value) deg") }

    /// Kantenflansch: Punkte auf Ober- bzw. Unterkanten des Blechs.
    /// heightFrom: „outer“, „inner“, „tangent“; position: „inside“, „outside“, „middle“, „material_outside“, „tangent“.
    static func edgeFlange(edges: [SIMD3<Double>], height: Double, angle: Double = 90, radius: Double? = nil,
                           heightFrom: String? = nil, position: String? = nil, flip: Bool = false,
                           cornerReliefShape: String? = nil, cornerRelief: Double? = nil,
                           then: [(angle: Double, height: Double, flip: Bool?)] = []) -> SheetCommand {
        var p: SheetJSON = [
            "type": "edge",
            "edges": .array(edges.map { SheetJSON($0) }),
            "height": .number(height),
            "angle": degrees(angle),
        ]
        if let radius { p["radius"] = .number(radius) }
        if let heightFrom { p["height_from"] = .string(heightFrom) }
        if let position { p["position"] = .string(position) }
        if flip { p["flip"] = true }
        if let cornerReliefShape { p["corner_relief_shape"] = .string(cornerReliefShape) }
        if let cornerRelief { p["corner_relief"] = .number(cornerRelief) }
        if !then.isEmpty {
            p["then"] = .array(then.map { step in
                var s: SheetJSON = ["angle": degrees(step.angle), "height": .number(step.height)]
                if let flip = step.flip { s["flip"] = .bool(flip) }
                return s
            })
        }
        return SheetCommand("sheet.flange", p)
    }

    /// Umkantung (Saum) an Blechkanten.
    static func hem(edges: [SIMD3<Double>], length: Double, gap: Double? = nil, flip: Bool = false) -> SheetCommand {
        var p: SheetJSON = ["edges": .array(edges.map { SheetJSON($0) }), "length": .number(length)]
        if let gap { p["gap"] = .number(gap) }
        if flip { p["flip"] = true }
        return SheetCommand("sheet.hem", p)
    }

    /// Falten entlang einer Linie (zwei Punkte auf der Grundfläche). position: „centerline“, „start“, „end“, „mould“.
    static func fold(from a: SIMD3<Double>, to b: SIMD3<Double>, angle: Double = 90, radius: Double? = nil,
                     position: String? = nil, fixed: SIMD3<Double>? = nil, flip: Bool = false) -> SheetCommand {
        var p: SheetJSON = ["points": [SheetJSON(a), SheetJSON(b)], "angle": degrees(angle)]
        if let radius { p["radius"] = .number(radius) }
        if let position { p["position"] = .string(position) }
        if let fixed { p["fixed"] = SheetJSON(fixed) }
        if flip { p["flip"] = true }
        return SheetCommand("sheet.fold", p)
    }

    /// Perforieren über das ganze Blech. pattern: „staggered“ oder „square“.
    static func perforate(diameter: Double, pitch: Double, margin: Double? = nil, pattern: String? = nil) -> SheetCommand {
        var p: SheetJSON = ["diameter": .number(diameter), "pitch": .number(pitch)]
        if let margin { p["margin"] = .number(margin) }
        if let pattern { p["pattern"] = .string(pattern) }
        return SheetCommand("sheet.perforate", p)
    }

    static let unfold = SheetCommand("sheet.unfold")
    static let refold = SheetCommand("sheet.refold")

    /// Befehl auf einen Körper der Sitzung richten (Parameter „body“).
    func targeting(_ body: String) -> SheetCommand {
        var copy = self
        if case .object = copy.params {} else { copy.params = [:] }
        copy.params["body"] = .string(body)
        return copy
    }

    /// Deutscher Anzeigename eines Befehls.
    var title: String {
        switch command {
        case "sheet.flange":
            switch params["type"]?.asString ?? (params["edges"] != nil ? "edge" : params["curves"] != nil ? "contour" : "base") {
            case "edge": return "Kantenflansch"
            case "contour": return "Konturflansch"
            default: return "Grundflansch"
            }
        case "sheet.path_flange": return "Pfadflansch"
        case "sheet.hem": return "Umkantung"
        case "sheet.fold": return "Falten"
        case "sheet.unfold": return "Entfalten"
        case "sheet.refold": return "Wieder falten"
        case "sheet.convert": return "In Blech umwandeln"
        case "sheet.perforate": return "Perforieren"
        case "sheet.manage_rules": return "Blechregel „\(params["name"]?.asString ?? "")“"
        case "solid.mirror": return "Spiegeln"
        case "solid.move": return params["copy"]?.asBool == true ? "Kopieren" : "Verschieben"
        case "psk.import_step": return "Ausgangskörper"
        default:
            if command.hasPrefix("sketch.") { return "Skizze" }
            return command
        }
    }
}

// MARK: - Öffentliche Funktionen (Oberfläche → Modell)

extension ModelStore {
    /// Blechmodul eingebaut (xcframework) und OCCT mit STEP vorhanden.
    var sheetAvailable: Bool { SheetKernel.isAvailable && PCKShape.stepAvailable }

    /// Hinweis, wenn das Blechmodul fehlt (für Panels und Meldungen).
    var sheetUnavailableReason: String? {
        if !SheetKernel.isAvailable { return SheetKernelError.notBuilt.message }
        if !PCKShape.stepAvailable { return "Blech braucht OpenCASCADE mit STEP (siehe README)." }
        return nil
    }

    /// Blechdaten eines Körpers (nil = kein Blechkörper).
    func sheetInfo(_ body: Int) -> SheetBodyInfo? {
        bodies.indices.contains(body) ? bodies[body].sheetMetal : nil
    }

    func isSheetBody(_ body: Int) -> Bool { sheetInfo(body) != nil }

    /// Blechkörper der Szene (Indizes).
    var sheetBodies: [Int] { bodies.indices.filter { bodies[$0].sheetMetal != nil } }

    // Neue Blechkörper

    /// Grundflansch aus Skizzenbereichen (eine Skizze): neuer Blechkörper mit der aktiven bzw. genannten Regel.
    /// flip = Material auf die andere Seite der Skizzenebene. preview = nur Vorschau (OK übernimmt mit commitPreview).
    @discardableResult
    func createSheetBaseFlange(sketch: Int, regions: [Int], rule: String? = nil, flip: Bool = false,
                               preview: Bool = false) -> Bool {
        sheetRun(preview: preview) { try self.sheetBaseFlangePlan(sketch: sketch, regions: regions, rule: rule, flip: flip) }
    }

    /// Konturflansch aus einer offenen Linienkette einer Skizze (Elementnummern der Skizze), Breite distance.
    @discardableResult
    func createSheetContourFlange(sketch: Int, entities: [Int], distance: Double, rule: String? = nil,
                                  flip: Bool = false, reverse: Bool = false, preview: Bool = false) -> Bool {
        sheetRun(preview: preview) {
            try self.sheetContourFlangePlan(sketch: sketch, entities: entities, distance: distance, rule: rule,
                                            flip: flip, reverse: reverse)
        }
    }

    // Schritte an einem Blechkörper

    /// Befehl an einen Blechkörper anhängen (Kantenflansch, Umkantung, Falten, Perforieren …) und neu wiedergeben.
    /// Punkte im Befehl sind Weltkoordinaten des angezeigten Körpers. preview = nur Vorschau.
    @discardableResult
    func appendSheetCommand(_ command: SheetCommand, to body: Int, title: String? = nil, preview: Bool = false) -> Bool {
        sheetRun(preview: preview) {
            try self.sheetAppendPlan([SheetStep(title ?? command.title, command)], to: body)
        }
    }

    /// Pfadflansch: offene Linienkette einer Skizze (quer zur Kante gezeichnet) entlang einer Blechkante.
    @discardableResult
    func appendSheetPathFlange(to body: Int, edge: SIMD3<Double>, sketch: Int, entities: [Int], radius: Double? = nil,
                               preview: Bool = false) -> Bool {
        sheetRun(preview: preview) {
            try self.sheetPathFlangePlan(to: body, edge: edge, sketch: sketch, entities: entities, radius: radius)
        }
    }

    /// Entfalten bzw. zurückfalten (als Schritt im Rezept, rückgängig machbar).
    @discardableResult
    func setSheetUnfolded(_ unfolded: Bool, body: Int) -> Bool {
        guard let info = sheetInfo(body), info.isUnfolded != unfolded else { return false }
        return appendSheetCommand(unfolded ? .unfold : .refold, to: body)
    }

    /// Schritt im Rezept ändern (Parameter) und ab dort neu wiedergeben – über den Verlauf, ein Undo-Schritt.
    @discardableResult
    func updateSheetStep(body: Int, step id: UUID, command: SheetCommand) -> Bool {
        sheetEditStep(body: body, step: id) { $0.command = command }
    }

    /// Schritt aus dem Rezept löschen (nicht den ersten, der den Körper erzeugt).
    @discardableResult
    func deleteSheetStep(body: Int, step id: UUID) -> Bool {
        sheetEditStep(body: body, step: id, delete: true) { _ in }
    }

    // Kopieren und Spiegeln (eigenes Flachmuster je Kopie, wie in SolidCraft)

    /// Blechkörper als Kopie verschieben (Rezept + solid.move copy).
    @discardableResult
    func copySheetBody(_ body: Int, offset: SIMD3<Double>) -> Bool {
        sheetRun(preview: false) { try self.sheetCopyPlan(body, mirror: nil, offset: offset) }
    }

    /// Blechkörper spiegeln: Gegenstück mit eigenem Flachmuster (Rezept + solid.mirror). keepOriginal = Kopie.
    @discardableResult
    func mirrorSheetBody(_ body: Int, planeOrigin: SIMD3<Double>, normal: SIMD3<Double>, keepOriginal: Bool = true) -> Bool {
        sheetRun(preview: false) {
            try self.sheetCopyPlan(body, mirror: (planeOrigin, normal, keepOriginal), offset: .zero)
        }
    }

    // Blechregeln

    /// Regel anlegen bzw. ändern. Geänderte Regeln wirken auf alle Blechkörper mit dieser Regel (Neuberechnung).
    func setSheetRule(_ rule: SheetRule, active: Bool = true) {
        let old = sheetDocument.rule(named: rule.name)
        sheetDocument.store(rule, active: active)
        if let old, old != rule { sheetRebuildBodies(usingRule: rule) }
    }

    func setActiveSheetRule(_ name: String) { sheetDocument.setActive(name) }

    /// Regel löschen; Körper behalten ihre Kopie der Regel im Rezept.
    func deleteSheetRule(_ name: String) { sheetDocument.remove(name) }

    // Flachmuster und Exporte

    /// Flachmuster eines Blechkörpers (sheet.flat_pattern).
    func flatPattern(of body: Int) throws -> FlatPattern {
        let session = try sheetSession(body)
        let command = SheetCommand("sheet.flat_pattern").targeting(session.name)
        let holesCommand = SheetCommand("psk.perforation_holes").targeting(session.name)
        let kernel = session.kernel
        let (json, holes) = try SheetWorker.run { () throws -> (SheetJSON, SheetJSON?) in
            let json = try kernel.execute(command)
            // Lochmitten nur bei Perforation abfragen; ältere SheetKit-Stände kennen den Befehl nicht
            guard !(json["perforations"]?.asArray ?? []).isEmpty else { return (json, nil) }
            let holes = try? kernel.execute(holesCommand)
            return (json, holes)
        }
        var pattern = FlatPattern(json: json)
        pattern.perforationHoles = (holes?["holes"]?.asArray ?? []).compactMap { hole in
            guard let center = hole["center"]?.asPoint2, let radius = hole["radius"]?.asDouble else { return nil }
            return (center, radius)
        }
        return pattern
    }

    /// Flachmuster als DXF in eine temporäre Datei (für den Teilen-Dialog).
    func exportFlatPatternDXF(of body: Int, options: SheetDXFOptions = SheetDXFOptions()) throws -> URL {
        let session = try sheetSession(body)
        let url = SheetKernel.temporaryURL("dxf", name: Self.sheetFileName(bodies[body].name))
        try? FileManager.default.removeItem(at: url)
        var params = options.params
        params["body"] = .string(session.name)
        params["path"] = .string(url.path(percentEncoded: false))
        let kernel = session.kernel
        let command = SheetCommand("sheet.export_dxf", params)
        try SheetWorker.run { try kernel.execute(command) }
        return url
    }

    /// Biegetabelle als CSV in eine temporäre Datei (für den Teilen-Dialog).
    func exportBendTableCSV(of body: Int) throws -> URL {
        let session = try sheetSession(body)
        let url = SheetKernel.temporaryURL("csv", name: Self.sheetFileName(bodies[body].name) + " Biegetabelle")
        try? FileManager.default.removeItem(at: url)
        let kernel = session.kernel
        let command = SheetCommand("sheet.export_bend_table", [
            "body": .string(session.name), "format": "csv", "path": .string(url.path(percentEncoded: false)),
        ])
        try SheetWorker.run { try kernel.execute(command) }
        return url
    }

    // In Blech umwandeln

    /// Kanten und ebene Flächen eines beliebigen Körpers (für die Wahl offener Kanten).
    func sheetConversionTopology(of body: Int) -> (faces: [SheetModelFace], edges: [SheetModelEdge]) {
        guard bodies.indices.contains(body) else { return ([], []) }
        return Self.sheetTopology(bodies[body].shape)
    }

    /// Biegekanten aus den gewählten offenen Kanten: jede andere Kandidatenkante zwischen zwei ebenen Wänden.
    func sheetBendEdges(of body: Int, open: Set<Int>) -> Set<Int> {
        Self.sheetBendEdges(sheetConversionTopology(of: body).edges, open: open)
    }

    /// Automatischer Vorschlag: größte ebene Fläche als Grundfläche, Spannbaum über die Flächennachbarschaft
    /// (Biegekanten), alle anderen Kanten offen; mit Probe-Wiedergabe (Fehler bzw. Überlappung im Flachmuster).
    /// baseFace = eigene Grundfläche (OCCT-Nummer) statt der größten.
    func suggestSheetConversion(of body: Int, baseFace: Int? = nil, rule: String? = nil) -> SheetConversionPlan? {
        sheetSuggestConversion(body, baseFace: baseFace, rule: rule)
    }

    /// Probe-Wiedergabe eines Plans (offene Kanten vom Benutzer): Problem oder nil.
    /// gap: Spalt der offenen Kanten (nil = aus der Regel; SolidCraft kennt nur einen Spalt für alle Kanten).
    func checkSheetConversion(of body: Int, baseFace: Int, openEdges: Set<Int>, rule: String? = nil,
                              gap: Double? = nil) -> SheetConversionPlan? {
        sheetCheckConversion(body, baseFace: baseFace, openEdges: openEdges, rule: rule, gap: gap)
    }

    /// Körper in Blech umwandeln: baseFace (OCCT-Nummer) bleibt fest, gewählte offene Kanten werden
    /// aufgeschnitten, alle anderen Kanten zwischen ebenen Wänden werden Biegekanten. Eine ebene Platte
    /// gleichmäßiger Stärke braucht keine offenen Kanten (openEdges leer, nur Platte: plateOnly = true).
    @discardableResult
    /// gap: Spalt der offenen Kanten (nil = aus der Regel); steht als abgeleitete Regel nur im Rezept des Körpers.
    func convertToSheet(_ body: Int, baseFace: Int, openEdges: Set<Int>, rule: String? = nil,
                        plateOnly: Bool = false, gap: Double? = nil, preview: Bool = false) -> Bool {
        sheetRun(preview: preview) {
            try self.sheetConvertPlan(body, baseFace: baseFace, openEdges: openEdges, rule: rule, plateOnly: plateOnly,
                                      gap: gap)
        }
    }

    /// Bearbeiten aus der Zeitleiste: Körper und Hauptschritt eines Blech-Features (mit den aktuellen Werten, wie
    /// sie im Rezept des Körpers stehen). Ändern dann mit updateSheetStep(body:step:command:).
    func sheetStep(for feature: Feature) -> (body: Int, step: SheetStep)? {
        guard feature.kind == .sheetMetal, let data = feature.data.sheet else { return nil }
        let main = data.steps.last { step in
            let name = step.command.command
            return !name.hasPrefix("sketch.") && name != "sheet.manage_rules" && name != "psk.import_step"
        } ?? data.steps.last
        guard let main else { return nil }
        for index in bodies.indices {
            if let step = bodies[index].sheetMetal?.steps.first(where: { $0.id == main.id }) { return (index, step) }
        }
        return nil
    }

    /// Dateiname ohne Zeichen, die das Dateisystem stören.
    static func sheetFileName(_ name: String) -> String {
        let cleaned = name.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }
        let text = String(cleaned).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Blech" : text
    }
}
