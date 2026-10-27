import SwiftUI
import simd

// Blech › ERSTELLEN nach SolidCraft (dialogs_sheet.rs `Sm::Flange`, `Sm::Path`, `Sm::Hem`, `Sm::Fold`,
// `Sm::Perforate`; Beschriftungen aus assets/locales/de.json bzw. SheetKit/COMMANDS.md):
// - Flansch: Grundflansch (Skizzenbereich), Kantenflansch (Kanten eines Blechkörpers) oder Konturflansch (offene
//   Linien einer Skizze) – die Auswahl entscheidet den Typ, wie in SolidCraft.
// - Pfadflansch, Umkantung, Falten, Perforieren.
// Vorschau über die Modell-API (preview: true), OK übernimmt sie (LegacyFinish.commit → commitPreview).

// MARK: - Gemeinsames

@MainActor
enum SheetPick {
    nonisolated static func isEdge(_ pick: Pick) -> Bool {
        if case .edge = pick { return true }
        return false
    }

    nonisolated static func isRegion(_ pick: Pick) -> Bool {
        if case .region = pick { return true }
        return false
    }

    /// Fehlertext nach einer gescheiterten Vorschau
    static func failure(_ model: ModelStore, _ fallback: String) -> String {
        model.message ?? model.sheetDocument.lastError ?? fallback
    }

    /// Richtung, in die ein Kantenflansch wächst: Normale der größeren Nachbarfläche (aus dem Blech heraus,
    /// SolidCraft `edge_frame`). Topologie je Körper zwischengespeichert.
    static func flangeDirection(_ pick: SheetEdgePick, _ cmd: ModelCommand, _ model: ModelStore) -> SIMD3<Double>? {
        guard model.bodies.indices.contains(pick.body) else { return nil }
        let topology = SheetConvertTopology.topology(of: pick.body, cmd, model)
        var best: (edge: SheetModelEdge, distance: Double)?
        for edge in topology.edges {
            let distance = SheetEdgePicks.segmentDistance(pick.point, edge.start, edge.end)
            if distance < (best?.distance ?? .infinity) { best = (edge, distance) }
        }
        guard let edge = best?.edge, best?.distance ?? .infinity < 0.5 else { return nil }
        let faces = topology.faces.filter { edge.faces.contains($0.face) }
        guard let face = faces.max(by: { $0.area < $1.area }), simd_length(face.normal) > 1e-9 else { return nil }
        return simd_normalize(face.normal)
    }
}

// MARK: - Flansch

enum SheetFlangeKind {
    case base, edge, contour

    var title: String {
        switch self {
        case .base: "Grund"
        case .edge: "Kante"
        case .contour: "Kontur"
        }
    }
}

/// Weitere Biegung eines Kantenflanschs (SolidCraft `then`): Winkel, Höhe, „Entgegengesetzte Richtung“.
struct SheetThenBend: Codable, Hashable {
    var angle: Double = 45
    var height: Double = 20
    var otherWay = false
}

enum SheetFlangeDriver: SheetEditableDriver {
    static let sheetCommands: Set<String> = ["sheet.flange"]
    static let id = ModelCommandID.sheetFlange
    static let title = "Flansch"
    static let icon = "sc.flange"
    static var explanation: String? {
        "Grundflansch: Bereich einer Skizze antippen. Kantenflansch: Kanten eines Blechkörpers antippen. "
            + "Konturflansch: unten offene Linien einer Skizze wählen. Der Typ folgt der Auswahl."
    }

    static let inputID = "profile"
    static let edgesKey = "edges"
    static let thenKey = "then"

    static let positions = [SheetOption("inside", "Innen"), SheetOption("outside", "Außen"), SheetOption("middle", "Mitte"),
                            SheetOption("material_outside", "Material außen"), SheetOption("tangent", "Tangential an Kante")]
    static let heightFrom = [SheetOption("outer", "Außenkante"), SheetOption("inner", "Innenkante"),
                             SheetOption("tangent", "Tangential")]
    static let reliefShapes = [SheetOption("", "Regel"), SheetOption("notch", "Ausklinkung"), SheetOption("round", "Rund"),
                               SheetOption("rectangular", "Rechteckig"), SheetOption("tear", "Reißen")]

    @MainActor static func kind(_ cmd: ModelCommand) -> SheetFlangeKind {
        if cmd.items(inputID).contains(where: SheetPick.isEdge) { return .edge }
        if !SheetLines.selected(cmd).isEmpty { return .contour }
        return .base
    }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        let model = ws.model
        var items: [Pick] = pre.regions.map { Pick.region($0) }
        let input = PickInput(id: inputID, title: "Profil / Kanten", accepts: [.regions, .edges], multiple: true,
                              items: [], hint: "Bereich einer Skizze (Grundflansch) oder Kanten eines Blechkörpers "
                                  + "(Kantenflansch) antippen; offene Linien (Konturflansch) unten wählen.")
        let cmd = ModelCommand(id, inputs: [input])
        cmd.putNumber("height", 10)
        cmd.putNumber("angle", 90)
        cmd.putNumber("distance", 20)
        cmd.choices["position"] = "inside"
        cmd.choices["heightFrom"] = "outer"
        cmd.choices["relief"] = ""
        cmd.choices["rule"] = ""
        // Vorauswahl: gewählte Kanten eines Blechkörpers werden Kantenflansch
        let sheetEdges = pre.edges.filter { model.isSheetBody($0.body) }
        if !sheetEdges.isEmpty {
            items = []
            var picks: [SheetEdgePick] = []
            for edge in sheetEdges {
                guard let mid = SheetEdgePicks.midpoint(edge, model: model) else { continue }
                picks.append(SheetEdgePick(point: mid, body: edge.body, edge: edge.edge, lines: model.edgePolylines(edge)))
            }
            cmd.setItems(inputID, items)
            SheetEdgePicks.store(picks, cmd, edgesKey, inputID: inputID)
        } else {
            cmd.setItems(inputID, items)
        }
        model.resetSelection()
        return cmd
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard cmd.editing == nil else { return false }
        let model = ws.model
        if let edge = tap.edge {
            guard model.isSheetBody(edge.body) else {
                model.message = "Kantenflansch: Kante eines Blechkörpers antippen (erst Grundflansch oder „In Blech umwandeln“)."
                return true
            }
            // Kanten machen einen Kantenflansch: Bereiche und Linien gelten nicht mehr
            CommandPicks.setItems(cmd.items(inputID).filter(SheetPick.isEdge), cmd, inputID)
            SheetLines.setSelected([], cmd)
            SheetEdgePicks.toggle(edge, cmd, ws, key: edgesKey, inputID: inputID)
            ws.refreshCommandPreview()
            ws.objectWillChange.send()
            return true
        }
        if tap.region != nil {
            // Bereich macht einen Grundflansch: Kanten und Linien gelten nicht mehr; Antippen übernimmt route
            if cmd.items(inputID).contains(where: SheetPick.isEdge) || !SheetLines.selected(cmd).isEmpty {
                SheetEdgePicks.store([], cmd, edgesKey, inputID: inputID)
                SheetLines.setSelected([], cmd)
            }
        }
        return false
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        let flip = cmd.isOn("flip", default: false)
        switch kind(cmd) {
        case .edge:
            let picks = SheetEdgePicks.reconcile(cmd, edgesKey, inputID: inputID)
            guard let body = picks.first?.body else {
                model.dropPreview()
                return nil
            }
            guard model.isSheetBody(body) else {
                model.dropPreview()
                return "Kantenflansch: Kanten eines Blechkörpers antippen."
            }
            let height = cmd.number("height", default: 10)
            guard height > 0 else {
                model.dropPreview()
                return "Die Höhe muss größer als 0 sein."
            }
            let bends = thenBends(cmd)
            if let index = bends.firstIndex(where: { $0.height <= 0 }) {
                model.dropPreview()
                return "Biegung \(index + 2) braucht eine Höhe."
            }
            guard cmd.previewEnabled else {
                model.dropPreview()
                return nil
            }
            let same = picks.filter { $0.body == body }
            if model.appendSheetCommand(edgeCommand(cmd, same), to: body, preview: true) {
                if same.count < picks.count { model.message = "Kanten eines Blechkörpers zugleich – die übrigen bleiben." }
                return nil
            }
            return SheetPick.failure(model, "Flansch an diesen Kanten nicht möglich.")
        case .contour:
            guard let sketch = SheetLines.sketch(cmd, model) else {
                model.dropPreview()
                return nil
            }
            let lines = SheetLines.lines(model, sketch: sketch)
            guard let ordered = SheetLines.orderedChain(lines, selected: SheetLines.selected(cmd),
                                                        plane: model.sketches[sketch].plane, start: nil) else {
                model.dropPreview()
                return "Konturflansch: die Linien müssen eine zusammenhängende offene Kette bilden."
            }
            let distance = cmd.number("distance", default: 20)
            guard distance > 0 else {
                model.dropPreview()
                return "Der Abstand muss größer als 0 sein."
            }
            guard cmd.previewEnabled else {
                model.dropPreview()
                return nil
            }
            if model.createSheetContourFlange(sketch: sketch, entities: ordered, distance: distance,
                                              rule: cmd.sheetRuleName, flip: flip,
                                              reverse: cmd.isOn("reverse", default: false), preview: true) {
                return nil
            }
            return SheetPick.failure(model, "Konturflansch aus diesen Linien nicht möglich.")
        case .base:
            var regions = CommandPicks.regions(cmd, inputID)
            // Ein Grundflansch = ein Bereich = ein Blechkörper (Modell-API, REVIEW 8/28): der zuletzt angetippte gilt
            if regions.count > 1, let last = regions.last {
                regions = [last]
                CommandPicks.setItems([.region(last)], cmd, inputID)
                model.message = "Grundflansch aus genau einem Bereich – je Bereich ein eigener Blechkörper."
            }
            guard let region = regions.first else {
                model.dropPreview()
                return nil
            }
            guard cmd.previewEnabled else {
                model.dropPreview()
                return nil
            }
            let sketch = region.sketch
            let indices = [region.region]
            if model.createSheetBaseFlange(sketch: sketch, regions: indices, rule: cmd.sheetRuleName, flip: flip,
                                           preview: true) {
                return nil
            }
            return SheetPick.failure(model, "Grundflansch aus diesem Bereich nicht möglich.")
        }
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.error == nil && ws.model.hasPreview
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.commit(ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.cancel(ws)
    }

    /// sheet.flange (Kante) wie SolidCraft `commands`: Punkte bzw. {point, angle?, height?}, then, Entlastung.
    @MainActor static func edgeCommand(_ cmd: ModelCommand, _ picks: [SheetEdgePick]) -> SheetCommand {
        let flip = cmd.isOn("flip", default: false)
        let edges: [SheetJSON] = picks.map { pick -> SheetJSON in
            guard pick.angle != nil || pick.height != nil else { return SheetJSON(pick.point) }
            var entry: SheetJSON = ["point": SheetJSON(pick.point)]
            if let angle = pick.angle { entry["angle"] = SheetCommand.degrees(angle) }
            if let height = pick.height { entry["height"] = .number(height) }
            return entry
        }
        var p: SheetJSON = [
            "type": "edge",
            "edges": .array(edges),
            "height": .number(cmd.number("height", default: 10)),
            "angle": SheetCommand.degrees(cmd.number("angle", default: 90)),
            "position": .string(cmd.option("position", default: "inside")),
            "flip": .bool(flip),
        ]
        if let radius = cmd.optionalNumber("radius") { p["radius"] = .number(radius) }
        let from = cmd.option("heightFrom", default: "outer")
        if from != "outer" { p["height_from"] = .string(from) }
        let shape = cmd.option("relief", default: "")
        if !shape.isEmpty { p["corner_relief_shape"] = .string(shape) }
        if let size = cmd.optionalNumber("reliefSize") { p["corner_relief"] = .number(size) }
        let bends = thenBends(cmd)
        if !bends.isEmpty {
            p["then"] = .array(bends.map { bend -> SheetJSON in
                var entry: SheetJSON = ["angle": SheetCommand.degrees(bend.angle), "height": .number(bend.height)]
                // „Entgegengesetzte Richtung“: Flip des Flanschs umgekehrt; „Gleiche Richtung“ ohne flip
                if bend.otherWay { entry["flip"] = .bool(!flip) }
                return entry
            })
        }
        return SheetCommand("sheet.flange", p)
    }

    @MainActor static func thenBends(_ cmd: ModelCommand) -> [SheetThenBend] {
        guard let text = cmd.values[thenKey], let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([SheetThenBend].self, from: data) else { return [] }
        return list
    }

    @MainActor static func setThenBends(_ list: [SheetThenBend], _ cmd: ModelCommand) {
        if list.isEmpty {
            cmd.values[thenKey] = nil
        } else if let data = try? JSONEncoder().encode(list) {
            cmd.values[thenKey] = String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: Pfeil (Höhe bzw. Abstand)

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        let model = ws.model
        switch kind(cmd) {
        case .edge:
            guard let pick = SheetEdgePicks.list(cmd, edgesKey).first,
                  var direction = SheetPick.flangeDirection(pick, cmd, model) else { return [] }
            if cmd.isOn("flip", default: false) { direction = -direction }
            return [DragHandle(kind: .command("height"), axisOrigin: SIMD3<Float>(pick.point),
                               direction: SIMD3<Float>(direction), value: cmd.number("height", default: 10),
                               color: Workspace.handleBlue)]
        case .contour:
            guard let sketch = SheetLines.sketch(cmd, model),
                  let first = SheetLines.selected(cmd).first,
                  let line = SheetLines.lines(model, sketch: sketch).first(where: { $0.entity == first }),
                  let mid = SheetEdgePicks.polylineMidpoint([line.world]) else { return [] }
            var normal = simd_normalize(model.sketches[sketch].plane.normal)
            if cmd.isOn("reverse", default: false) { normal = -normal }
            return [DragHandle(kind: .command("distance"), axisOrigin: SIMD3<Float>(mid), direction: SIMD3<Float>(normal),
                               value: cmd.number("distance", default: 20), color: Workspace.handleBlue)]
        case .base:
            return []
        }
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .command(let key) = kind, key == "height" || key == "distance" else { return }
        cmd.putNumber(key, max(0.1, value))
        cmd.error = refresh(cmd, ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? {
        MainActor.assumeIsolated { () -> String? in
            switch kind(cmd) {
            case .edge: return "height"
            case .contour: return "distance"
            case .base: return nil
            }
        }
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetFlangeRows(cmd: cmd, workspace: ws, model: ws.model, document: ws.model.sheetDocument))
    }
}

/// Zeilen des Flanschs wie SolidCraft: Typ · (Kante) Höhe, Winkel, Biegeposition, Höhe ab, Weitere Biegungen,
/// ERWEITERT (Biegeradius, Eckenentlastung, Pro Kante) · (Kontur) Abstand, Regel · (Grund) Regel · Optionen.
private struct SheetFlangeRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var document: SheetDocument

    private static let wayOptions = [CommandChoice(id: "same", title: "Gleiche Richtung"),
                                     CommandChoice(id: "other", title: "Entgegengesetzte Richtung")]

    var body: some View {
        let kind = SheetFlangeDriver.kind(cmd)
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetInfoRow(title: "Typ", text: kind.title)
            switch kind {
            case .edge:
                edgeRows
            case .contour:
                CommandValueRow(title: "Abstand", key: "distance", command: cmd, value: cmd.number("distance", default: 20)) {
                    cmd.putNumber("distance", max(0.01, $0))
                    CommandCache.refreshNow(cmd, workspace)
                }
                SheetRuleMenuRow(cmd: cmd, document: document, workspace: workspace)
            case .base:
                SheetRuleMenuRow(cmd: cmd, document: document, workspace: workspace)
            }
            PaletteSection("Konturflansch", detail: "Offene Linien einer Skizze", expanded: kind == .contour) {
                SheetLinePicker(title: "Skizze", cmd: cmd, workspace: workspace, model: model) {
                    // Linien machen einen Konturflansch: Bereiche und Kanten gelten nicht mehr
                    if !SheetLines.selected(cmd).isEmpty {
                        SheetEdgePicks.store([], cmd, SheetFlangeDriver.edgesKey, inputID: SheetFlangeDriver.inputID)
                        CommandPicks.setItems([], cmd, SheetFlangeDriver.inputID)
                    }
                }
            }
            PaletteSection("Optionen") {
                CommandFlagRow(title: "Umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "flip", workspace: workspace)
                if kind == .contour {
                    CommandFlagRow(title: "Andere Seite", icon: "arrow.up.and.down", cmd: cmd, key: "reverse",
                                   workspace: workspace)
                }
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }

    @ViewBuilder private var edgeRows: some View {
        CommandValueRow(title: "Höhe", key: "height", command: cmd, value: cmd.number("height", default: 10)) {
            cmd.putNumber("height", max(0.01, $0))
            CommandCache.refreshNow(cmd, workspace)
        }
        CommandValueRow(title: "Winkel", key: "angle", command: cmd, unit: "°", value: cmd.number("angle", default: 90)) {
            cmd.putNumber("angle", $0)
            CommandCache.refreshNow(cmd, workspace)
        }
        SheetMenuRow(title: "Biegeposition", options: SheetFlangeDriver.positions,
                     selected: cmd.option("position", default: "inside")) { id in
            cmd.choices["position"] = id
            CommandCache.refreshNow(cmd, workspace)
        }
        SheetMenuRow(title: "Höhe ab", options: SheetFlangeDriver.heightFrom,
                     selected: cmd.option("heightFrom", default: "outer")) { id in
            cmd.choices["heightFrom"] = id
            CommandCache.refreshNow(cmd, workspace)
        }
        furtherBends
        CommandSection("Erweitert", command: SheetFlangeDriver.id, section: "advanced", expanded: false) {
            SheetCommandOptionalRow(title: "Biegeradius", cmd: cmd, key: "radius", workspace: workspace)
            SheetMenuRow(title: "Form der Eckenentlastung", options: SheetFlangeDriver.reliefShapes,
                         selected: cmd.option("relief", default: "")) { id in
                cmd.choices["relief"] = id
                CommandCache.refreshNow(cmd, workspace)
            }
            SheetCommandOptionalRow(title: "Eckenentlastung", cmd: cmd, key: "reliefSize", workspace: workspace)
            perEdge
        }
    }

    /// Weitere Biegungen: „Biegung hinzufügen“, je Biegung Kopf mit Papierkorb, Winkel, Höhe, Richtung.
    @ViewBuilder private var furtherBends: some View {
        let bends = SheetFlangeDriver.thenBends(cmd)
        PaletteLabeled(title: "Weitere Biegungen") {
            PrimaryWideButton(title: "Biegung hinzufügen", systemImage: "plus", isPrimary: false) {
                guard bends.count < 16 else { return }
                SheetFlangeDriver.setThenBends(bends + [SheetThenBend()], cmd)
                CommandCache.refreshNow(cmd, workspace)
            }
            .hoverTip("Biegung hinzufügen", "Eine weitere Biegung an der gegenüberliegenden Kante des letzten Flansches")
        }
        ForEach(bends.indices, id: \.self) { index in
            let bend = bends[index]
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                HStack(spacing: 4) {
                    Text("Biegung \(index + 2)")
                        .font(.footnote.weight(.semibold))
                    Text("\(SheetFormat.degrees(bend.angle)) · \(SheetFormat.length(bend.height))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Button {
                        var list = bends
                        list.remove(at: index)
                        SheetFlangeDriver.setThenBends(list, cmd)
                        CommandCache.refreshNow(cmd, workspace)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: PaletteStyle.touch, height: PaletteStyle.touch)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Diese Biegung entfernen")
                }
                PaletteNumberRow(title: "Winkel", value: bend.angle, unit: "°") { value in
                    update(index) { $0.angle = value }
                }
                PaletteNumberRow(title: "Höhe", value: bend.height) { value in
                    update(index) { $0.height = max(0.01, value) }
                }
                CommandSegmentRow(title: "Richtung", options: Self.wayOptions,
                                  selected: bend.otherWay ? "other" : "same") { id in
                    update(index) { $0.otherWay = id == "other" }
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius))
        }
    }

    private func update(_ index: Int, _ change: (inout SheetThenBend) -> Void) {
        var list = SheetFlangeDriver.thenBends(cmd)
        guard list.indices.contains(index) else { return }
        change(&list[index])
        SheetFlangeDriver.setThenBends(list, cmd)
        CommandCache.refreshNow(cmd, workspace)
    }

    /// Pro Kante (ab zwei Kanten): eigener Winkel und eigene Höhe, leer = Werte oben.
    @ViewBuilder private var perEdge: some View {
        let picks = SheetEdgePicks.list(cmd, SheetFlangeDriver.edgesKey)
        if picks.count > 1 || picks.contains(where: { $0.angle != nil || $0.height != nil }) {
            SheetInfoRow(title: "Pro Kante", text: "Winkel, Höhe – leer: Werte oben", color: .secondary)
            ForEach(picks.indices, id: \.self) { index in
                let pick = picks[index]
                VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                    HStack {
                        Text("Kante \(index + 1)")
                            .font(.footnote.weight(.semibold))
                        Spacer(minLength: 0)
                        Button {
                            SheetEdgePicks.remove(at: index, cmd, key: SheetFlangeDriver.edgesKey,
                                                  inputID: SheetFlangeDriver.inputID)
                            CommandCache.refreshNow(cmd, workspace)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: PaletteStyle.touch, height: PaletteStyle.touch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Kante \(index + 1) entfernen")
                    }
                    SheetOptionalValueRow(title: "Winkel", value: pick.angle,
                                          placeholder: SheetFormat.degrees(cmd.number("angle", default: 90)),
                                          unit: "°") { value in
                        SheetEdgePicks.setOwn(at: index, angle: .some(value), height: nil, cmd,
                                              key: SheetFlangeDriver.edgesKey, inputID: SheetFlangeDriver.inputID)
                        CommandCache.refreshNow(cmd, workspace)
                    }
                    SheetOptionalValueRow(title: "Höhe", value: pick.height,
                                          placeholder: SheetFormat.length(cmd.number("height", default: 10))) { value in
                        SheetEdgePicks.setOwn(at: index, angle: nil, height: .some(value), cmd,
                                              key: SheetFlangeDriver.edgesKey, inputID: SheetFlangeDriver.inputID)
                        CommandCache.refreshNow(cmd, workspace)
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius))
            }
        }
    }
}

// MARK: - Pfadflansch

enum SheetPathFlangeDriver: SheetEditableDriver {
    static let sheetCommands: Set<String> = ["sheet.path_flange"]
    static let id = ModelCommandID.sheetPathFlange
    static let title = "Pfadflansch"
    static let icon = "sc.path_flange"
    static var explanation: String? {
        "Eine offene Linienkette quer zur Kante skizzieren, beginnend an der Kante. Dann die Kante antippen und die "
            + "Linien wählen: jede Linie wird ein Flansch so lang wie die Linie, jede Ecke eine Biegung."
    }

    static let edgeKey = "edge"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let input = PickInput(id: "edge", title: "Kante", accepts: [.edges], multiple: false,
                              hint: "Ober- oder Unterkante des Blechs antippen, an der der Pfad beginnt.")
        let cmd = ModelCommand(id, inputs: [input])
        ws.model.resetSelection()
        return cmd
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard cmd.editing == nil, let edge = tap.edge else { return false }
        guard ws.model.isSheetBody(edge.body) else {
            ws.model.message = "Pfadflansch: Kante eines Blechkörpers antippen."
            return true
        }
        SheetEdgePicks.toggle(edge, cmd, ws, key: edgeKey, inputID: "edge", single: true)
        ws.refreshCommandPreview()
        ws.objectWillChange.send()
        return true
    }

    /// Gewählte Linien als Kette ab der Kante (SolidCraft `path_chain`)
    @MainActor static func chain(_ cmd: ModelCommand, _ model: ModelStore) -> (sketch: Int, entities: [Int])? {
        guard let sketch = SheetLines.sketch(cmd, model) else { return nil }
        let start = SheetEdgePicks.list(cmd, edgeKey).first?.point
        guard let ordered = SheetLines.orderedChain(SheetLines.lines(model, sketch: sketch), selected: SheetLines.selected(cmd),
                                                    plane: model.sketches[sketch].plane, start: start) else { return nil }
        return (sketch, ordered)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        let picks = SheetEdgePicks.reconcile(cmd, edgeKey, inputID: "edge")
        guard let pick = picks.first, !SheetLines.selected(cmd).isEmpty else {
            model.dropPreview()
            return nil
        }
        guard let path = chain(cmd, model) else {
            model.dropPreview()
            return "Der Pfad muss eine zusammenhängende offene Linienkette sein."
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        if model.appendSheetPathFlange(to: pick.body, edge: pick.point, sketch: path.sketch, entities: path.entities,
                                       radius: cmd.optionalNumber("radius"), preview: true) {
            return nil
        }
        return SheetPick.failure(model, "Pfadflansch an dieser Kante nicht möglich.")
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetPathFlangeRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct SheetPathFlangeRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    private var lengths: String {
        guard let sketch = SheetLines.sketch(cmd, model) else { return "Pfad wählen" }
        let lines = SheetLines.lines(model, sketch: sketch)
        let order = SheetPathFlangeDriver.chain(cmd, model)?.entities ?? SheetLines.selected(cmd)
        let values = order.compactMap { id in lines.first { $0.entity == id }?.length }
        guard !values.isEmpty else { return "Pfad wählen" }
        return values.map { LengthUnit.current.number($0) }.joined(separator: " · ") + " " + LengthUnit.current.symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetLinePicker(title: "Pfad", cmd: cmd, workspace: workspace, model: model, chains: true)
            SheetInfoRow(title: "Flansche", text: lengths)
            PaletteHint(text: "Durch die Linien der Skizze festgelegt.")
            SheetCommandOptionalRow(title: "Biegeradius", cmd: cmd, key: "radius", workspace: workspace)
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

// MARK: - Umkantung

enum SheetHemDriver: SheetEditableDriver {
    static let sheetCommands: Set<String> = ["sheet.hem"]
    static let id = ModelCommandID.sheetHem
    static let title = "Umkantung"
    static let icon = "sc.hem"
    static var explanation: String? {
        "Blechkanten antippen: die Kante wird flach auf das Blech zurückgebogen (Saum). Länge bis zur Außenfläche."
    }

    static let edgesKey = "edges"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        let input = PickInput(id: "edges", title: "Kanten", accepts: [.edges], multiple: true,
                              hint: "Kanten eines Blechkörpers antippen.")
        let cmd = ModelCommand(id, inputs: [input])
        cmd.putNumber("length", 5)
        var picks: [SheetEdgePick] = []
        for edge in model.selectedEdges where model.isSheetBody(edge.body) {
            guard let mid = SheetEdgePicks.midpoint(edge, model: model) else { continue }
            picks.append(SheetEdgePick(point: mid, body: edge.body, edge: edge.edge, lines: model.edgePolylines(edge)))
        }
        SheetEdgePicks.store(picks, cmd, edgesKey, inputID: "edges")
        model.resetSelection()
        return cmd
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard cmd.editing == nil, let edge = tap.edge else { return false }
        guard ws.model.isSheetBody(edge.body) else {
            ws.model.message = "Umkantung: Kante eines Blechkörpers antippen."
            return true
        }
        SheetEdgePicks.toggle(edge, cmd, ws, key: edgesKey, inputID: "edges")
        ws.refreshCommandPreview()
        ws.objectWillChange.send()
        return true
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        let picks = SheetEdgePicks.reconcile(cmd, edgesKey, inputID: "edges")
        guard let body = picks.first?.body else {
            model.dropPreview()
            return nil
        }
        let length = cmd.number("length", default: 5)
        guard length > 0 else {
            model.dropPreview()
            return "Die Länge muss größer als 0 sein."
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        let points = picks.filter { $0.body == body }.map(\.point)
        let command = SheetCommand.hem(edges: points, length: length, gap: cmd.optionalNumber("gap"),
                                       flip: cmd.isOn("flip", default: false))
        if model.appendSheetCommand(command, to: body, preview: true) { return nil }
        return SheetPick.failure(model, "Umkantung an diesen Kanten nicht möglich.")
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "length" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetHemRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct SheetHemRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetInfoRow(title: "Typ", text: "Flach")
            CommandValueRow(title: "Länge", key: "length", command: cmd, value: cmd.number("length", default: 5)) {
                cmd.putNumber("length", max(0.01, $0))
                CommandCache.refreshNow(cmd, workspace)
            }
            SheetCommandOptionalRow(title: "Spalt", cmd: cmd, key: "gap", workspace: workspace)
            PaletteSection("Optionen") {
                CommandFlagRow(title: "Umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "flip", workspace: workspace)
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

// MARK: - Falten

enum SheetFoldDriver: SheetEditableDriver {
    static let sheetCommands: Set<String> = ["sheet.fold"]
    static let id = ModelCommandID.sheetFold
    static let title = "Falten"
    static let icon = "sc.fold"
    static var explanation: String? {
        "Eine Linie auf das Blech skizzieren und unten wählen: das Blech wird entlang der Linie gebogen. "
            + "Optional die Seite antippen, die stehen bleibt."
    }

    static let positions = [SheetOption("centerline", "Mittellinie"), SheetOption("start", "Biegungsanfang"),
                            SheetOption("end", "Biegungsende"), SheetOption("mould", "Außenformlinie")]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let fixed = PickInput(id: "fixed", title: "Feste Seite", accepts: [.planarFaces], multiple: false,
                              hint: "Fläche der Seite antippen, die stehen bleibt (sonst die größere).", isOptional: true)
        let cmd = ModelCommand(id, inputs: [fixed])
        cmd.putNumber("angle", 90)
        cmd.choices["position"] = "centerline"
        // Skizze einer gewählten Region als Vorgabe
        if let region = ws.model.selectedRegions.first { cmd.choices["lineSketch"] = String(region.sketch) }
        ws.model.resetSelection()
        return cmd
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard cmd.editing == nil else { return false }
        let model = ws.model
        // Bereich einer Skizze: diese Skizze für die Biegelinie
        if let region = tap.region {
            cmd.choices["lineSketch"] = String(region.sketch)
            SheetLines.setSelected([], cmd)
            ws.refreshCommandPreview()
            return true
        }
        guard let face = tap.face, model.plane(of: face) != nil else { return false }
        // Nur der Tippunkt liegt sicher auf der Fläche (Schwerpunkt kann bei L-/U-Flächen daneben liegen, REVIEW 24)
        guard let point = tap.point else {
            model.message = "Feste Seite: Fläche noch einmal antippen."
            return true
        }
        cmd.setItems("fixed", [.face(face)])
        cmd.values["fixedPoint"] = "\(point.x),\(point.y),\(point.z)"
        ws.refreshCommandPreview()
        return true
    }

    @MainActor static func fixedPoint(_ cmd: ModelCommand) -> SIMD3<Double>? {
        guard !cmd.items("fixed").isEmpty else { return nil }
        let parts = (cmd.values["fixedPoint"] ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : nil
    }

    /// Blechkörper: der der festen Seite, sonst der Fläche, auf der skizziert wurde, sonst gewählt bzw. letzter.
    @MainActor static func body(_ cmd: ModelCommand, _ model: ModelStore, sketch: Int) -> Int? {
        if let face = CommandPicks.faces(cmd, "fixed").first, model.isSheetBody(face.body) { return face.body }
        if let source = model.sketches[sketch].plane.sourceBody, model.isSheetBody(source) { return source }
        return SheetUI.targetSheetBody(model)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        guard let sketch = SheetLines.sketch(cmd, model), let entity = SheetLines.selected(cmd).first,
              let line = SheetLines.lines(model, sketch: sketch).first(where: { $0.entity == entity }),
              let a = line.world.first, let b = line.world.last else {
            model.dropPreview()
            return nil
        }
        guard !line.isPolyline else {
            model.dropPreview()
            return "Biegelinie: eine einzelne Linie wählen."
        }
        guard let body = Self.body(cmd, model, sketch: sketch) else {
            model.dropPreview()
            return "Kein Blechkörper im Projekt."
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        let command = SheetCommand.fold(from: a, to: b, angle: cmd.number("angle", default: 90),
                                        radius: cmd.optionalNumber("radius"),
                                        position: cmd.option("position", default: "centerline"),
                                        fixed: fixedPoint(cmd), flip: cmd.isOn("flip", default: false))
        if model.appendSheetCommand(command, to: body, preview: true) { return nil }
        return SheetPick.failure(model, "Falten entlang dieser Linie nicht möglich.")
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.error == nil && ws.model.hasPreview
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "angle" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetFoldRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct SheetFoldRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetLinePicker(title: "Biegelinie", cmd: cmd, workspace: workspace, model: model, single: true)
            SheetMenuRow(title: "Position der Biegelinie", options: SheetFoldDriver.positions,
                         selected: cmd.option("position", default: "centerline")) { id in
                cmd.choices["position"] = id
                CommandCache.refreshNow(cmd, workspace)
            }
            CommandValueRow(title: "Winkel", key: "angle", command: cmd, unit: "°", value: cmd.number("angle", default: 90)) {
                cmd.putNumber("angle", $0)
                CommandCache.refreshNow(cmd, workspace)
            }
            SheetCommandOptionalRow(title: "Biegeradius", cmd: cmd, key: "radius", workspace: workspace)
            PaletteSection("Optionen") {
                CommandFlagRow(title: "Umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "flip", workspace: workspace)
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

// MARK: - Perforieren

enum SheetPerforateDriver: SheetEditableDriver {
    static let sheetCommands: Set<String> = ["sheet.perforate"]
    static let id = ModelCommandID.sheetPerforate
    static let title = "Perforieren"
    static let icon = "sc.perforate"
    static var explanation: String? {
        "Lochfeld über das ganze flache Blech, mit Rand zu Kanten, Ausschnitten und Biegungen. Die Löcher erscheinen "
            + "im Flachmuster und im DXF (Layer PERFORATION), nicht im 3D-Körper."
    }

    static let patterns = [CommandChoice(id: "staggered", title: "Versetzt (60°)"),
                           CommandChoice(id: "square", title: "Quadratisch")]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        let input = PickInput(id: "body", title: "Körper (letzter, wenn keiner)", accepts: [.bodies, .faces],
                              multiple: false, items: pre.bodyPicks.prefix(1).map { $0 },
                              hint: "Blechkörper antippen.", isOptional: true)
        let cmd = ModelCommand(id, inputs: [input])
        cmd.putNumber("diameter", 3)
        cmd.putNumber("pitch", 6)
        cmd.choices["pattern"] = "staggered"
        ws.model.resetSelection()
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        let picked = CommandPicks.bodies(cmd, "body", model: model).first
        if let picked, !model.isSheetBody(picked) {
            model.dropPreview()
            return "Das ist kein Blechkörper."
        }
        guard let body = SheetUI.targetSheetBody(model, picked: picked) else {
            model.dropPreview()
            return "Kein Blechkörper im Projekt."
        }
        let diameter = cmd.number("diameter", default: 3)
        let pitch = cmd.number("pitch", default: 6)
        guard diameter > 0, pitch > diameter else {
            model.dropPreview()
            return diameter > 0 ? "Die Teilung muss größer als der Durchmesser sein." : "Der Durchmesser muss größer als 0 sein."
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        let command = SheetCommand.perforate(diameter: diameter, pitch: pitch, margin: cmd.optionalNumber("margin"),
                                             pattern: cmd.option("pattern", default: "staggered"))
        if model.appendSheetCommand(command, to: body, preview: true) { return nil }
        return SheetPick.failure(model, "Perforieren nicht möglich.")
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.error == nil && ws.model.hasPreview
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetPerforateRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct SheetPerforateRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            CommandNumberRow(title: "Durchmesser", cmd: cmd, key: "diameter", fallback: 3, workspace: workspace) {
                max(0.01, $0)
            }
            CommandNumberRow(title: "Teilung", cmd: cmd, key: "pitch", fallback: 6, workspace: workspace) { max(0.01, $0) }
            SheetCommandOptionalRow(title: "Rand", cmd: cmd, key: "margin", placeholder: "wie Durchmesser",
                                    workspace: workspace)
            CommandOptionRow(title: "Muster", cmd: cmd, key: "pattern", options: SheetPerforateDriver.patterns,
                             fallback: "staggered", workspace: workspace)
            PaletteHint(text: "Die Löcher erscheinen im Flachmuster und im DXF.")
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}
