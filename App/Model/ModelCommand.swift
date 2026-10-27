import SwiftUI

/// Welche Picks ein Auswahlfeld annimmt (SolidCraft `Accept`)
struct PickKinds: OptionSet {
    let rawValue: Int
    static let regions = PickKinds(rawValue: 1)       // Skizzenbereiche (Profile)
    static let planarFaces = PickKinds(rawValue: 2)
    static let faces = PickKinds(rawValue: 4)
    static let edges = PickKinds(rawValue: 8)
    static let bodies = PickKinds(rawValue: 16)
    static let planes = PickKinds(rawValue: 32)       // Standard- und Konstruktionsebenen
    static let axes = PickKinds(rawValue: 64)         // Achsen, Skizzenlinien, gerade/runde Kanten, Zylinderflächen
    static let points = PickKinds(rawValue: 128)      // Ecken, Skizzenpunkte, Konstruktionspunkte, Kreismitten
    static let curves = PickKinds(rawValue: 256)      // Skizzenkurven (Pfad, Dünn)
    static let sketches = PickKinds(rawValue: 512)
}

/// Ein ausgewähltes Objekt in einem Auswahlfeld
enum Pick: Hashable {
    case region(RegionRef)
    case face(FaceRef)
    case edge(EdgeRef)
    case body(Int)
    case plane(ReferencePlane)
    case axis(ReferenceAxis)
    case point(SIMD3<Double>)
    case curve(sketch: Int, entity: UUID)
    case sketch(Int)
}

/// Auswahlfeld im Feature-Panel („↖ Auswählen“ / „N ausgewählt“)
struct PickInput: Identifiable {
    /// Stabiler Schlüssel, z. B. "profiles", "toObject"
    let id: String
    var title: String
    var accepts: PickKinds
    var multiple: Bool
    var items: [Pick] = []
    var hint: String
    var isOptional = false
}

enum ModelCommandID: String, CaseIterable {
    // Erstellen (Paket M1)
    case extrude, revolve, sweep, loft, hole, thread, box, cylinder, sphere, torus, cone, helix, thinExtrude
    // Ändern (Paket M2)
    case fillet, chamfer, pressPull, shell, draft, offsetFace, replaceFace, deleteFace, combine, splitBody, scale
    // Anordnen (M2)
    case move, copy, translate, align, mirror, patternRect, patternCircular
    // Konstruieren / Prüfen (M2)
    case constructPlane, constructAxis, constructPoint, measure, section
    // PencilCAD-eigene (M2)
    case wrap, imprint, offsetEdges, mold, printCheck, meshSculpt
}

/// Offener Modellbefehl nach SolidCraft-Vorbild: gehört dem Workspace (`workspace.command`), nil = kein Panel.
final class ModelCommand: ObservableObject, Identifiable {
    let id: ModelCommandID
    @Published var inputs: [PickInput]
    @Published var activeInput: Int = 0
    /// Werte als Ausdruckstexte (NumberField-Syntax mit Variablen); Schlüssel je Werkzeug
    @Published var values: [String: String] = [:]
    /// Auswahlen (Segmente, Listen) als Rohwerte
    @Published var choices: [String: String] = [:]
    @Published var flags: [String: Bool] = [:]
    /// Aufgeklappte Abschnitte
    @Published var expanded: Set<String> = []
    @Published var error: String?
    @Published var previewEnabled = true
    /// Wertfeld, das den Fokus bekommen soll (Antippen des Werts am Pfeil im Viewport)
    @Published var focusKey: String?
    /// Dauer der letzten Vorschau in Sekunden (Hinweis „Rechnet …“ bei langen Vorschauen)
    @Published var previewSeconds: Double = 0
    /// Bearbeiten: Feature-ID im Verlauf; nil = neu
    var editing: UUID?
    /// Automatik der Operation (Neu/Verbinden/Schneiden) aus, sobald der Nutzer selbst wählt
    var autoOperation = true

    init(_ id: ModelCommandID, inputs: [PickInput]) {
        self.id = id
        self.inputs = inputs
        advance()
    }

    /// Erstes leeres Pflichtfeld aktiv machen
    func advance() {
        if let index = inputs.firstIndex(where: { !$0.isOptional && $0.items.isEmpty }) {
            activeInput = index
        }
    }

    /// Alle Pflichtfelder gefüllt
    var isReady: Bool {
        inputs.allSatisfy { $0.isOptional || !$0.items.isEmpty }
    }

    /// Pick ins aktive Feld übernehmen; false, wenn das Feld diese Art nicht annimmt
    @discardableResult
    func pick(_ pick: Pick, kind: PickKinds) -> Bool {
        guard inputs.indices.contains(activeInput), inputs[activeInput].accepts.contains(kind) else { return false }
        if inputs[activeInput].multiple {
            if let existing = inputs[activeInput].items.firstIndex(of: pick) {
                inputs[activeInput].items.remove(at: existing)
            } else {
                inputs[activeInput].items.append(pick)
            }
        } else {
            inputs[activeInput].items = [pick]
            advance()
        }
        return true
    }

    func items(_ inputID: String) -> [Pick] {
        inputs.first { $0.id == inputID }?.items ?? []
    }

    func number(_ key: String, default fallback: Double) -> Double {
        guard let text = values[key] else { return fallback }
        return Double(text.replacingOccurrences(of: ",", with: ".")) ?? fallback
    }
}

/// Antippen im Viewport während eines offenen Befehls (Flächen bereits auf die echten Körper umgerechnet).
struct CommandTap {
    var face: FaceRef?
    var edge: EdgeRef?
    var region: RegionRef?
    var point: SIMD3<Double>?

    var isEmpty: Bool { face == nil && edge == nil && region == nil }
}

/// Jedes Modellwerkzeug implementiert das (je Paket in eigener Datei). Läuft auf dem Hauptthread wie Workspace.
@MainActor
protocol ModelCommandDriver {
    static var id: ModelCommandID { get }
    static var title: String { get }
    /// sc.*-Symbol
    static var icon: String { get }
    /// Felder, Standardwerte, Vorauswahl übernehmen
    static func make(_ ws: Workspace) -> ModelCommand
    /// Vorschau rechnen; nil = ok, sonst Fehlertext
    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String?
    static func commit(_ cmd: ModelCommand, _ ws: Workspace)
    static func cancel(_ cmd: ModelCommand, _ ws: Workspace)
    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle]
    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace)
    /// Schlüssel des Werts, der am Pfeil im Viewport steht
    static func primaryValueKey(_ cmd: ModelCommand) -> String?
    /// Panelzeilen
    @MainActor static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView
    /// Bearbeiten aus dem Verlauf
    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand?
    /// Eigenes Antippen (true = erledigt); sonst geht der Pick ins aktive bzw. erste passende Feld
    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool
    /// OK möglich (Standard: Pflichtfelder gefüllt, kein Fehler, Vorschau vorhanden)
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool
    /// Text am Pfeil im Viewport (nil = Länge des Pfeilwerts)
    static func valueText(handle: HandleKind, value: Double, _ cmd: ModelCommand) -> String?
    /// Kurze Erklärung für „ⓘ“ im Panel-Kopf
    static var explanation: String? { get }
    /// „Übernehmen“ (OK, Panel bleibt offen) anbieten
    static var repeatable: Bool { get }
}

extension ModelCommandDriver {
    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {}
    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] { [] }
    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace) {}
    static func primaryValueKey(_ cmd: ModelCommand) -> String? { nil }
    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? { nil }
    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool { false }
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }
    static func valueText(handle: HandleKind, value: Double, _ cmd: ModelCommand) -> String? { nil }
    static var explanation: String? { nil }
    static var repeatable: Bool { false }
}

extension ModelCommand {
    /// Zahl unter key speichern (als Text, wie ihn number(_:default:) liest)
    func setNumber(_ key: String, _ value: Double) {
        values[key] = String(value)
    }

    func choice(_ key: String, default fallback: String) -> String {
        choices[key] ?? fallback
    }

    func flag(_ key: String) -> Bool {
        flags[key] ?? false
    }

    /// Index des Felds mit dieser ID
    func inputIndex(_ inputID: String) -> Int? {
        inputs.firstIndex { $0.id == inputID }
    }

    /// Feld ersetzen bzw. leeren (z. B. Auswahl aus einem Menü statt Antippen)
    func setItems(_ inputID: String, _ items: [Pick]) {
        guard let index = inputIndex(inputID) else { return }
        inputs[index].items = items
    }

    /// Feld nur einmal anlegen (dynamische Felder wie „Bis Objekt“); entfernen mit removeInput
    func ensureInput(_ input: PickInput, after previousID: String? = nil) {
        guard inputIndex(input.id) == nil else { return }
        if let previousID, let index = inputIndex(previousID) {
            inputs.insert(input, at: index + 1)
        } else {
            inputs.append(input)
        }
    }

    func removeInput(_ inputID: String) {
        guard let index = inputIndex(inputID) else { return }
        inputs.remove(at: index)
        if activeInput >= inputs.count { activeInput = max(0, inputs.count - 1) }
    }
}

/// Register der Treiber; Pakete tragen sich in `registerAll()` ein
@MainActor
enum ModelCommands {
    static var drivers: [ModelCommandID: ModelCommandDriver.Type] = [:]

    static func driver(_ id: ModelCommandID) -> ModelCommandDriver.Type? {
        if drivers.isEmpty { registerAll() }
        return drivers[id]
    }

    /// Alle eingetragenen Treiber (z. B. für Bearbeiten aus dem Verlauf)
    static var all: [ModelCommandDriver.Type] {
        if drivers.isEmpty { registerAll() }
        return ModelCommandID.allCases.compactMap { drivers[$0] }
    }

    static func register(_ driver: ModelCommandDriver.Type) {
        drivers[driver.id] = driver
    }

    /// Paket M1 trägt `registerCreate()` ein, Paket M2 `registerModify()` (je eigene Datei als extension)
    static func registerAll() {
        registerCreate()
        registerModify()
    }
}
