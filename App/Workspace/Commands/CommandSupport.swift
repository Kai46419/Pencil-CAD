import SwiftUI
import simd

// Gemeinsame Bausteine der Treiber ÄNDERN/ANORDNEN/KONSTRUIEREN/PRÜFEN (Paket M2, SolidCraft-Vorbild).
//
// Die Treiber rechnen mit den bisherigen Werkzeugen weiter (ModelTool, ModelStore.preview…/set…Value): `build`
// startet das bisherige Werkzeug (Viewport-Hilfen wie Drehringe, Rollenfarben, Ebenenvorschau bleiben) und füllt die
// Auswahlfelder mit der Vorauswahl; `refresh` überträgt die Auswahlfelder auf die Auswahl des ModelStore und rechnet
// die Vorschau. Werkzeuge, deren Antippen eigene Regeln hat (Messen, Konstruieren …), stehen in
// `ModelCommands.legacyTapIDs`: dort läuft Antippen weiter über Workspace.tapped.
//
// ModelCommandDriver ist @MainActor; MainActor.assumeIsolated in der Erweiterung unten stammt aus der Zeit davor und
// ist damit nur noch eine Absicherung.

/// Modellbefehl, dessen Arbeit auf dem Main Actor läuft.
@MainActor
protocol MainCommandDriver: ModelCommandDriver {
    /// Befehl anlegen: bisheriges Werkzeug starten, Vorauswahl übernehmen, Standardwerte
    @MainActor static func build(_ ws: Workspace) -> ModelCommand
    /// Auswahlfelder übernehmen und Vorschau rechnen; nil = in Ordnung, sonst Fehlertext
    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String?
    /// OK: übernehmen (ein Verlaufsschritt)
    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace)
    /// Abbrechen: Vorschau verwerfen
    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace)
    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle]
    /// Pfeil gezogen: Wert übernehmen (Vorschau rechnen)
    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace)
    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView
    /// Schlüssel des Hauptwerts (Wertfeld am Pfeil)
    static func mainValueKey(_ cmd: ModelCommand) -> String?
    /// Features im Verlauf, die dieser Befehl bearbeitet (Doppeltippen in der Zeitleiste)
    static var featureKinds: [FeatureKind] { get }
}

extension MainCommandDriver {
    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        LegacyFinish.commit(ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        LegacyFinish.cancel(ws)
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] { [] }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {}

    static func mainValueKey(_ cmd: ModelCommand) -> String? { nil }

    static var featureKinds: [FeatureKind] { [] }

    // MARK: ModelCommandDriver

    static func make(_ ws: Workspace) -> ModelCommand {
        let box = MainActor.assumeIsolated { () -> UncheckedBox<ModelCommand> in
            UncheckedBox(build(ws))
        }
        return box.value
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        MainActor.assumeIsolated { () -> String? in
            // Bearbeiten aus dem Verlauf: Werte ändern, Nachbau erst bei OK
            guard cmd.editing == nil else { return nil }
            return CommandCache.run(cmd) { refresh(cmd, ws) }
        }
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        MainActor.assumeIsolated {
            if cmd.editing != nil {
                FeatureEdit.commit(cmd, ws.model)
            } else {
                finish(cmd, ws)
            }
            CommandCache.forget(cmd)
        }
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        MainActor.assumeIsolated {
            if cmd.editing == nil { abort(cmd, ws) }
            CommandCache.forget(cmd)
        }
    }

    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        MainActor.assumeIsolated { () -> [DragHandle] in
            cmd.editing == nil ? arrows(cmd, ws) : []
        }
    }

    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        MainActor.assumeIsolated {
            guard cmd.editing == nil else { return }
            drag(handle, value, cmd, ws)
            CommandCache.mark(cmd, error: nil)
        }
    }

    static func primaryValueKey(_ cmd: ModelCommand) -> String? {
        cmd.editing == nil ? mainValueKey(cmd) : nil
    }

    @MainActor static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        if cmd.editing != nil {
            return AnyView(FeatureEditRows(cmd: cmd, model: ws.model))
        }
        return panel(cmd, ws)
    }

    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        guard featureKinds.contains(feature.kind) else { return nil }
        return FeatureEdit.command(id, feature)
    }

    /// Bearbeiten aus dem Verlauf rechnet erst bei OK (keine Vorschau): dann nur ohne Fehler
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }
}

/// Werkzeug, das ganz über das bisherige Antippen arbeitet; das Panel zeigt seine Werte (PencilCAD-eigene Werkzeuge,
/// Messen, Konstruieren). Steht in `ModelCommands.legacyTapIDs`.
@MainActor
protocol LegacyTapDriver: MainCommandDriver {
    static var legacyTool: ModelTool { get }
    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView
}

extension LegacyTapDriver {
    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        ws.activate(legacyTool)
        return ModelCommand(id, inputs: [])
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? { nil }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        content(cmd, ws)
    }

    /// OK wie „Fertig“ im bisherigen Werkzeug (Messen, Druckprüfung … haben keine Vorschau); fehlt noch etwas,
    /// meldet es preview als Fehler
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil
    }
}

// MARK: - Vorschau nur bei Änderung

/// Merkt sich je offenem Befehl den Stand der letzten Vorschau, damit ein erneutes `preview` ohne Änderung (z. B. nach
/// einem Pfeilzug) nicht noch einmal im Kernel rechnet. Dazu gemerkte Pfeilansätze (vor der Vorschau berechnet).
@MainActor
enum CommandCache {
    private static var states: [ObjectIdentifier: (signature: String, error: String?)] = [:]
    /// Pfeilansatz und Richtung je Befehl (Fläche versetzen, Skalieren …)
    static var anchors: [ObjectIdentifier: (origin: SIMD3<Double>, direction: SIMD3<Double>, size: Double)] = [:]

    static func signature(_ cmd: ModelCommand) -> String {
        var text = "\(cmd.inputs.map(\.items))|\(cmd.previewEnabled)"
        for key in cmd.values.keys.sorted() { text += "|v\(key)=\(cmd.values[key] ?? "")" }
        for key in cmd.choices.keys.sorted() { text += "|c\(key)=\(cmd.choices[key] ?? "")" }
        for key in cmd.flags.keys.sorted() { text += "|f\(key)=\(cmd.flags[key] == true)" }
        return text
    }

    /// Befehle, deren Vorschau gerade rechnet (ein Werkzeug-Baustein, der dabei updatePreview aufruft, landet über
    /// refreshCommandPreview wieder hier – dann nicht noch einmal rechnen)
    private static var running: Set<ObjectIdentifier> = []

    static func run(_ cmd: ModelCommand, _ body: () -> String?) -> String? {
        let key = ObjectIdentifier(cmd)
        if let state = states[key], state.signature == signature(cmd) { return state.error }
        guard !running.contains(key) else { return nil }
        running.insert(key)
        let error = body()
        running.remove(key)
        // Nach dem Rechnen merken: refresh darf Felder ändern (z. B. übernommene Rundung)
        states[key] = (signature(cmd), error)
        return error
    }

    static func mark(_ cmd: ModelCommand, error: String?) {
        states[ObjectIdentifier(cmd)] = (signature(cmd), error)
    }

    static func forget(_ cmd: ModelCommand) {
        states[ObjectIdentifier(cmd)] = nil
        anchors[ObjectIdentifier(cmd)] = nil
    }

    /// Vorschau sofort neu (nach einer Eingabe im Panel); Fehler steht dann im Panel.
    static func refreshNow(_ cmd: ModelCommand, _ ws: Workspace) {
        guard let driver = ModelCommands.driver(cmd.id) else { return }
        cmd.error = driver.preview(cmd, ws)
    }
}

// MARK: - Übernehmen und Abbrechen wie „Fertig“/„Abbrechen“

@MainActor
enum LegacyFinish {
    /// Wie Workspace.done() im Standardfall (ohne Rückweg dorthin, der beim offenen Befehl hierher zurückführt).
    static func commit(_ ws: Workspace) {
        ws.model.commitPreview()
        ws.tool = .select
        ws.model.resetSelection()
    }

    static func cancel(_ ws: Workspace) {
        ws.model.cancelPreview()
        ws.model.resetSelection()
        ws.tool = .select
    }
}

// MARK: - Vorauswahl

/// Auswahl beim Start eines Befehls (vor dem Wechsel ins Werkzeug, der sie zurücksetzt).
@MainActor
struct Preselection {
    let faces: [FaceRef]
    let edges: [EdgeRef]
    let bodies: [Int]
    let regions: [RegionRef]

    init(_ model: ModelStore) {
        faces = model.selectedFaces
        edges = model.selectedEdges
        bodies = model.selectedBodies
        regions = model.selectedRegions
    }

    /// Gewählte Körper, sonst der Körper der gewählten Fläche bzw. Kante
    var anyBodies: [Int] {
        if !bodies.isEmpty { return bodies }
        if let face = faces.first { return [face.body] }
        if let edge = edges.first { return [edge.body] }
        return []
    }

    var bodyPicks: [Pick] { anyBodies.map { Pick.body($0) } }
    var facePicks: [Pick] { faces.map { Pick.face($0) } }
}

// MARK: - Auswahlfelder lesen

@MainActor
enum CommandPicks {
    static func faces(_ cmd: ModelCommand, _ id: String) -> [FaceRef] {
        var result: [FaceRef] = []
        for pick in cmd.items(id) {
            if case .face(let face) = pick, !result.contains(face) { result.append(face) }
        }
        return result
    }

    /// Kanten; eine Fläche steht für alle ihre Kanten (SolidCraft „Kanten oder Flächen“).
    static func edges(_ cmd: ModelCommand, _ id: String, model: ModelStore) -> [EdgeRef] {
        var result: [EdgeRef] = []
        for pick in cmd.items(id) {
            switch pick {
            case .edge(let edge):
                if !result.contains(edge) { result.append(edge) }
            case .face(let face):
                guard model.bodies.indices.contains(face.body) else { continue }
                for number in model.bodies[face.body].shape.edgeNumbers(ofFace: face.face) {
                    let edge = EdgeRef(body: face.body, edge: number.intValue)
                    if !result.contains(edge) { result.append(edge) }
                }
            default:
                break
            }
        }
        return result
    }

    /// Körper; eine Fläche oder Kante steht für ihren Körper.
    static func bodies(_ cmd: ModelCommand, _ id: String, model: ModelStore) -> [Int] {
        var result: [Int] = []
        for pick in cmd.items(id) {
            let body: Int?
            switch pick {
            case .body(let index): body = index
            case .face(let face): body = face.body
            case .edge(let edge): body = edge.body
            default: body = nil
            }
            if let body, model.bodies.indices.contains(body), !result.contains(body) { result.append(body) }
        }
        return result
    }

    static func points(_ cmd: ModelCommand, _ id: String) -> [SIMD3<Double>] {
        var result: [SIMD3<Double>] = []
        for pick in cmd.items(id) {
            if case .point(let point) = pick { result.append(point) }
        }
        return result
    }

    static func regions(_ cmd: ModelCommand, _ id: String) -> [RegionRef] {
        var result: [RegionRef] = []
        for pick in cmd.items(id) {
            if case .region(let region) = pick, !result.contains(region) { result.append(region) }
        }
        return result
    }

    /// Bezugsebene: Standard-/Konstruktionsebene oder ebene Fläche
    static func referencePlane(_ cmd: ModelCommand, _ id: String) -> ReferencePlane? {
        for pick in cmd.items(id) {
            switch pick {
            case .plane(let plane): return plane
            case .face(let face): return .face(face)
            default: continue
            }
        }
        return nil
    }

    /// Gerade aus einem Pick: Achse, gerade Kante, Zylinderfläche (Achse) bzw. ebene Fläche (Normale)
    static func line(_ pick: Pick, model: ModelStore) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        switch pick {
        case .axis(let axis):
            return model.resolve(axis)
        case .edge(let edge):
            let points = model.edgePolylines(edge).flatMap { $0 }
            guard let a = points.first, let b = points.last, simd_distance(a, b) > 1e-6 else { return nil }
            return (a, simd_normalize(b - a))
        case .face(let face):
            if let cylinder = model.cylinder(of: face) {
                return (cylinder.origin, simd_normalize(cylinder.axis))
            }
            guard let plane = model.plane(of: face) else { return nil }
            let center = model.mesh.centroid(of: face).map { SIMD3<Double>($0) } ?? plane.anchor
            return (center, simd_normalize(plane.normal))
        default:
            return nil
        }
    }

    static func axis(_ cmd: ModelCommand, _ id: String, model: ModelStore)
        -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        for pick in cmd.items(id) {
            if let found = line(pick, model: model) { return found }
        }
        return nil
    }

    /// Feld leeren bzw. füllen (z. B. übernommene Rundungsfläche aus dem Kantenfeld nehmen)
    static func setItems(_ items: [Pick], _ cmd: ModelCommand, _ id: String) {
        guard let index = cmd.inputs.firstIndex(where: { $0.id == id }) else { return }
        cmd.inputs[index].items = items
    }
}

// MARK: - Auswahl des ModelStore angleichen

/// Überträgt Auswahlfelder auf die Auswahl des ModelStore (nur bei Änderung, offene Vorschau wird verworfen).
@MainActor
enum CommandSync {
    @discardableResult
    static func faces(_ faces: [FaceRef], _ model: ModelStore) -> Bool {
        guard model.selectedFaces != faces else { return false }
        model.dropPreview()
        guard let first = faces.first else {
            model.resetSelection()
            return true
        }
        model.selectForTool(first)
        for face in faces.dropFirst() { model.toggleFace(face, commitsPreview: false) }
        return true
    }

    /// Wie faces, aber mit Pfeil der Fläche (Extrudieren der Fläche, Press Pull)
    @discardableResult
    static func pullFaces(_ faces: [FaceRef], _ model: ModelStore) -> Bool {
        guard model.selectedFaces != faces else { return false }
        model.dropPreview()
        guard let first = faces.first else {
            model.resetSelection()
            return true
        }
        model.select(face: first)
        for face in faces.dropFirst() { model.toggleFace(face, commitsPreview: false) }
        return true
    }

    @discardableResult
    static func bodies(_ bodies: [Int], _ model: ModelStore) -> Bool {
        guard model.selectedBodies != bodies else { return false }
        model.dropPreview()
        if bodies.isEmpty {
            model.resetSelection()
        } else {
            model.selectBodies(bodies)
        }
        return true
    }

    @discardableResult
    static func edges(_ edges: [EdgeRef], _ model: ModelStore) -> Bool {
        guard model.selectedEdges != edges else { return false }
        model.dropPreview()
        model.resetSelection()
        for edge in edges { model.toggleEdge(edge) }
        return true
    }

    @discardableResult
    static func regions(_ regions: [RegionRef], _ model: ModelStore) -> Bool {
        guard model.selectedRegions != regions else { return false }
        model.dropPreview()
        model.selectRegions(regions)
        return true
    }
}

// MARK: - Werte

extension ModelCommand {
    /// Zahl als Text speichern (Punkt als Dezimalzeichen, wie `number(_:default:)` liest)
    func putNumber(_ key: String, _ value: Double) {
        values[key] = CommandFormat.plain(value)
    }

    func isOn(_ key: String, default fallback: Bool) -> Bool {
        flags[key] ?? fallback
    }

    func option(_ key: String, default fallback: String) -> String {
        choices[key] ?? fallback
    }
}

enum CommandFormat {
    /// Zahl ohne Tausendertrennung, höchstens vier Nachkommastellen
    static func plain(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10_000).rounded() / 10_000
        if rounded == rounded.rounded(), abs(rounded) < 1e12 { return String(Int(rounded)) }
        return String(rounded)
    }
}

// MARK: - Bearbeiten aus dem Verlauf

/// Doppeltippen auf ein Feature: dasselbe Panel mit den gespeicherten Werten (Zahl oder Formel mit Variablen);
/// OK rechnet den Verlauf ab dort neu (ein Schritt), Abbrechen ändert nichts.
enum FeatureEdit {
    static func command(_ id: ModelCommandID, _ feature: Feature) -> ModelCommand {
        let cmd = ModelCommand(id, inputs: [])
        cmd.editing = feature.id
        for parameter in feature.parameters {
            cmd.values[parameter.key] = text(for: parameter)
        }
        return cmd
    }

    /// Formel bzw. Zahl in der Projekteinheit (wie FeatureEditor)
    static func text(for parameter: FeatureParameter) -> String {
        if let formula = parameter.formula { return formula }
        switch parameter.unit {
        case .length: return LengthUnit.current.number(parameter.value)
        case .angle: return CommandFormat.plain(parameter.value)
        case .count: return String(Int(parameter.value.rounded()))
        }
    }

    /// Geänderte Werte ausrechnen und den Verlauf nachbauen. Fehler stehen im Panel.
    @MainActor
    static func commit(_ cmd: ModelCommand, _ model: ModelStore) {
        guard let id = cmd.editing, let feature = model.features.first(where: { $0.id == id }) else { return }
        var parameters = feature.parameters
        var changed = false
        for index in parameters.indices {
            let key = parameters[index].key
            let text = (cmd.values[key] ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != Self.text(for: parameters[index]) else { continue }
            do {
                let value = try parameters[index].unit.evaluate(text, variables: model.variableValues)
                guard value.isFinite else { continue }
                parameters[index].value = value
                parameters[index].formula = Formula.isPlainNumber(text) ? nil : text
                changed = true
            } catch {
                model.message = "\(parameters[index].title): \(error.localizedDescription)"
                return
            }
        }
        if changed { model.updateFeature(id, parameters: parameters) }
    }
}

/// Panelzeilen beim Bearbeiten: je gespeichertem Wert ein Feld (Zahl oder Formel).
struct FeatureEditRows: View {
    @ObservedObject var cmd: ModelCommand
    @ObservedObject var model: ModelStore

    private var feature: Feature? {
        guard let id = cmd.editing else { return nil }
        return model.features.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            if let feature {
                if feature.parameters.isEmpty {
                    PaletteHint(text: "Dieser Schritt hat keine änderbaren Werte.")
                }
                ForEach(feature.parameters) { parameter in
                    FeatureTextRow(title: parameter.title, unit: FeatureEditor.unitLabel(parameter.unit),
                                   text: Binding(get: { cmd.values[parameter.key] ?? "" },
                                                 set: { cmd.values[parameter.key] = $0 }))
                }
                PaletteHint(text: "Zahl oder Formel mit Variablen, z. B. „breite / 2“. OK rechnet den Verlauf ab hier neu.")
                if feature.failed, let problem = feature.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(SketchTheme.error)
                }
            } else {
                PaletteHint(text: "Der Schritt ist nicht mehr im Verlauf.")
            }
        }
    }
}

/// Textfeld für Zahl oder Formel (ohne sofortiges Ausrechnen).
private struct FeatureTextRow: View {
    let title: String
    let unit: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: PaletteStyle.spacing) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: PaletteStyle.labelWidth, alignment: .leading)
            PaletteFieldBox(isLocked: false, hasError: false) {
                TextField(title, text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Panelzeilen

/// Wahl in einer Segmentreihe (SolidCraft `segmented`)
struct CommandChoice: Identifiable, Hashable {
    let id: String
    let title: String
    var isEnabled = true
}

/// Segmentreihe 44 pt hoch, Titel darüber (passt auch mit vier Wahlen in die Panelbreite).
struct CommandSegmentRow: View {
    let title: String
    let options: [CommandChoice]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(options) { option in
                    segment(option)
                }
            }
            .background(PaletteStyle.field, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(PaletteStyle.controlBorder, lineWidth: 1) }
        }
    }

    private func segment(_ option: CommandChoice) -> some View {
        let isSelected = option.id == selected
        return Button {
            pick(option.id)
        } label: {
            Text(option.title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(isSelected ? PaletteStyle.activeFill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .opacity(option.isEnabled ? 1 : 0.4)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Zahlenzeile für einen Wert des Befehls; rechnet nach der Eingabe die Vorschau neu.
struct CommandNumberRow: View {
    let title: String
    @ObservedObject var cmd: ModelCommand
    let key: String
    let fallback: Double
    var unit = "mm"
    let workspace: Workspace
    /// Begrenzen bzw. umrechnen, bevor der Wert gespeichert wird
    var adjust: (Double) -> Double = { $0 }

    var body: some View {
        PaletteNumberRow(title: title, value: cmd.number(key, default: fallback), unit: unit) { value in
            cmd.putNumber(key, adjust(value))
            CommandCache.refreshNow(cmd, workspace)
        }
    }
}

/// Segmentreihe für eine Wahl des Befehls (`choices[key]`).
struct CommandOptionRow: View {
    let title: String
    @ObservedObject var cmd: ModelCommand
    let key: String
    let options: [CommandChoice]
    let fallback: String
    let workspace: Workspace
    /// Zusätzlich nach der Wahl (z. B. Felder umbauen)
    var then: (String) -> Void = { _ in }

    var body: some View {
        CommandSegmentRow(title: title, options: options, selected: cmd.option(key, default: fallback)) { id in
            cmd.choices[key] = id
            then(id)
            CommandCache.refreshNow(cmd, workspace)
        }
    }
}

/// Schalterzeile für `flags[key]`.
struct CommandFlagRow: View {
    let title: String
    var icon: String?
    @ObservedObject var cmd: ModelCommand
    let key: String
    var fallback = false
    let workspace: Workspace

    var body: some View {
        CheckRow(title: title, icon: icon, isOn: Binding(get: { cmd.isOn(key, default: fallback) }, set: { value in
            cmd.flags[key] = value
            CommandCache.refreshNow(cmd, workspace)
        }))
    }
}

/// Schalter „Vorschau“ (SolidCraft OPTIONEN).
struct CommandPreviewRow: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        CheckRow(title: "Vorschau", icon: "eye", isOn: Binding(get: { cmd.previewEnabled }, set: { value in
            cmd.previewEnabled = value
            CommandCache.refreshNow(cmd, workspace)
        }))
    }
}

/// Anzahl mit Minus/Plus für `values[key]` (ganzzahlig).
struct CommandCountRow: View {
    let title: String
    @ObservedObject var cmd: ModelCommand
    let key: String
    let fallback: Int
    let range: ClosedRange<Int>
    let workspace: Workspace

    var body: some View {
        CountRow(title: title, value: Binding(get: {
            Int(cmd.number(key, default: Double(fallback)).rounded())
        }, set: { value in
            cmd.putNumber(key, Double(value))
            CommandCache.refreshNow(cmd, workspace)
        }), range: range)
    }
}

/// Zeile „Titel · Text“ für Zustände (z. B. „2 von 3 Punkten“).
struct CommandStatusRow: View {
    let title: String
    let text: String
    var isDone = false

    var body: some View {
        HStack(spacing: PaletteStyle.spacing) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: PaletteStyle.labelWidth, alignment: .leading)
            Label(text, systemImage: isDone ? "checkmark.circle.fill" : "hand.tap")
                .font(.callout)
                .foregroundStyle(isDone ? SketchTheme.success : Color.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(minHeight: PaletteStyle.touch)
    }
}

/// Achswahl X/Y/Z als Segmentreihe.
enum CommandAxes {
    static let choices = [CommandChoice(id: "0", title: "X"), CommandChoice(id: "1", title: "Y"),
                          CommandChoice(id: "2", title: "Z")]

    static func index(_ cmd: ModelCommand, _ key: String, default fallback: Int) -> Int {
        let index = Int(cmd.option(key, default: String(fallback))) ?? fallback
        return min(max(index, 0), 2)
    }
}
