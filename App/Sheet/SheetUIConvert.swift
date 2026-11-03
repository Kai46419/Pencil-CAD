import SwiftUI
import simd

// „In Blech umwandeln“ nach SolidCraft (dialogs_sheet.rs `Sm::Convert`, sheet.convert) mit Kais Erweiterung:
// Der Benutzer wählt, welche Kanten OFFEN (aufgeschnitten) bleiben – bzw. umgekehrt, welche Kanten Biegungen werden.
// - Grundfläche antippen (ebene Fläche, bleibt fest) → automatischer Vorschlag (Spannbaum, ModelStore.suggestSheetConversion)
// - Kanten antippen schaltet sie zwischen offen und Biegung um (wie Kanten beim Abrunden/Fasen)
// - Ansichtsfenster: Biegekanten grün, offene Kanten rot gestrichelt, Grundfläche getönt (SheetUIOverlay.swift)
// - Probe-Wiedergabe (checkSheetConversion) meldet Fehler und Überlappungen im Flachmuster als Warnung
// - 3D-Vorschau zuschaltbar (Standard aus: das Umwandeln spielt das Rezept in OpenCASCADE ab und braucht Zeit)
//
// Gespeichert im Befehl (gehört damit zur Signatur der Vorschau): values["open"] = offene Kantennummern
// („3,5,7“, OCCT-Nummern des Ausgangskörpers), choices["mode"] = „open“ | „bends“, values["gap"] = Spalt.

// MARK: - Topologie (zwischengespeichert)

@MainActor
enum SheetConvertTopology {
    /// Ebene Flächen und gerade Kanten eines Körpers (ModelStore.sheetConversionTopology), je Befehl gemerkt, solange
    /// sich die Form des Körpers nicht ändert.
    static func topology(of body: Int, _ cmd: ModelCommand, _ model: ModelStore)
        -> (faces: [SheetModelFace], edges: [SheetModelEdge]) {
        guard model.bodies.indices.contains(body) else { return ([], []) }
        let state = SheetCommandState.of(cmd)
        let key = "\(body)#\(ObjectIdentifier(model.bodies[body].shape).hashValue)"
        if state.topologyKey == key { return state.topology }
        let topology = model.sheetConversionTopology(of: body)
        state.topologyKey = key
        state.topology = topology
        return topology
    }
}

// MARK: - Treiber

enum SheetConvertDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetConvert
    static let title = "In Blech umwandeln"
    static let icon = "sc.convert_sheet"
    static var explanation: String? {
        "Grundfläche antippen: sie bleibt fest, ein Vorschlag legt offene Kanten und Biegekanten fest. Kanten antippen "
            + "schaltet zwischen offen (rot, gestrichelt) und Biegung (grün) um. Eine ebene Platte braucht keine Kanten."
    }

    static let faceInput = "face"
    static let edgesInput = "edges"

    static let modes = [CommandChoice(id: "open", title: "Offene Kanten wählen"),
                        CommandChoice(id: "bends", title: "Biegekanten wählen")]

    /// Kanten antippen wählt offene Kanten (Standard) bzw. Biegekanten
    @MainActor static func choosesOpen(_ cmd: ModelCommand) -> Bool {
        cmd.option("mode", default: "open") != "bends"
    }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        let pre = Preselection(model)
        let face = PickInput(id: faceInput, title: "Feste Fläche", accepts: [.planarFaces], multiple: false,
                             hint: "Ebene Fläche des Körpers antippen, die beim Abwickeln fest bleibt.")
        let edges = PickInput(id: edgesInput, title: "Offene Kanten", accepts: [.edges], multiple: true,
                              hint: "Kanten antippen: offen (aufgeschnitten) bzw. Biegung umschalten.", isOptional: true)
        let cmd = ModelCommand(id, inputs: [face, edges])
        cmd.choices["mode"] = "open"
        cmd.choices["rule"] = ""
        // Umwandeln rechnet lange: 3D-Vorschau zuschaltbar, OK schaltet sie ohnehin ein (Workspace.confirmCommand)
        cmd.previewEnabled = false
        model.resetSelection()
        if let first = pre.faces.first, model.plane(of: first) != nil {
            choose(base: first, cmd, model, suggest: true)
        }
        return cmd
    }

    // MARK: Zustand lesen und schreiben

    @MainActor static func baseFace(_ cmd: ModelCommand) -> FaceRef? {
        CommandPicks.faces(cmd, faceInput).first
    }

    @MainActor static func openEdges(_ cmd: ModelCommand) -> Set<Int> {
        Set((cmd.values["open"] ?? "").split(separator: ",").compactMap { Int($0) })
    }

    /// Offene Kanten speichern und das Auswahlfeld angleichen (zeigt je nach Modus offene bzw. Biegekanten)
    @MainActor static func setOpen(_ open: Set<Int>, _ cmd: ModelCommand, _ model: ModelStore) {
        cmd.values["open"] = open.isEmpty ? nil : open.sorted().map(String.init).joined(separator: ",")
        syncEdgeItems(cmd, model)
    }

    /// Kandidatenkanten der Haut der Grundfläche (REVIEW 38): über Kandidatenkanten von der Grundfläche aus erreichbar.
    /// Kanten der anderen Haut eines dünnen Körpers gehören nicht zum Blech und werden weder gezeigt noch Biegungen.
    @MainActor static func skinCandidates(_ cmd: ModelCommand, _ model: ModelStore) -> [SheetModelEdge] {
        guard let face = baseFace(cmd) else { return [] }
        let candidates = SheetConvertTopology.topology(of: face.body, cmd, model).edges
            .filter { $0.isCandidate && $0.faces.count == 2 }
        var reached: Set<Int> = [face.face]
        var frontier = [face.face]
        while let current = frontier.popLast() {
            for edge in candidates where edge.faces.contains(current) {
                for next in edge.faces where !reached.contains(next) {
                    reached.insert(next)
                    frontier.append(next)
                }
            }
        }
        return candidates.filter { reached.contains($0.faces[0]) && reached.contains($0.faces[1]) }
    }

    /// Offene Kanten für das Modell: Wahl des Benutzers plus alle Kandidaten außerhalb der Haut (nie Biegungen)
    @MainActor static func modelOpen(_ cmd: ModelCommand, _ model: ModelStore) -> Set<Int> {
        guard let face = baseFace(cmd) else { return [] }
        let skin = Set(skinCandidates(cmd, model).map(\.edge))
        let others = SheetConvertTopology.topology(of: face.body, cmd, model).edges
            .filter { $0.isCandidate && !skin.contains($0.edge) }.map(\.edge)
        return openEdges(cmd).union(others)
    }

    @MainActor static func bendEdges(_ cmd: ModelCommand, _ model: ModelStore) -> Set<Int> {
        Set(skinCandidates(cmd, model).map(\.edge)).subtracting(openEdges(cmd))
    }

    /// Kandidaten der Haut, die offen sind
    @MainActor static func openCandidates(_ cmd: ModelCommand, _ model: ModelStore) -> [SheetModelEdge] {
        let open = openEdges(cmd)
        return skinCandidates(cmd, model).filter { open.contains($0.edge) }
    }

    @MainActor static func syncEdgeItems(_ cmd: ModelCommand, _ model: ModelStore) {
        guard let index = cmd.inputIndex(edgesInput) else { return }
        let open = choosesOpen(cmd)
        cmd.inputs[index].title = open ? "Offene Kanten" : "Biegekanten"
        guard let face = baseFace(cmd) else {
            cmd.inputs[index].items = []
            return
        }
        let numbers = open ? openCandidates(cmd, model).map(\.edge) : bendEdges(cmd, model).sorted()
        cmd.inputs[index].items = numbers.map { Pick.edge(EdgeRef(body: face.body, edge: $0)) }
        cmd.values["shown"] = String(numbers.count)
    }

    /// Feld „×“ geleert: im Modus „Offene Kanten“ werden alle Biegungen, im Modus „Biegekanten“ alle offen.
    @MainActor static func reconcile(_ cmd: ModelCommand, _ model: ModelStore) {
        guard baseFace(cmd) != nil else {
            if cmd.values["open"] != nil { cmd.values["open"] = nil }
            cmd.values["shown"] = nil
            return
        }
        let shown = Int(cmd.values["shown"] ?? "0") ?? 0
        guard shown > 0, cmd.items(edgesInput).isEmpty else { return }
        if choosesOpen(cmd) {
            setOpen([], cmd, model)
        } else {
            setOpen(Set(skinCandidates(cmd, model).map(\.edge)), cmd, model)
        }
    }

    /// Grundfläche setzen; anderer Körper bzw. suggest = automatischer Vorschlag
    @MainActor static func choose(base face: FaceRef, _ cmd: ModelCommand, _ model: ModelStore, suggest: Bool) {
        let previous = baseFace(cmd)
        cmd.setItems(faceInput, [.face(face)])
        if suggest || previous?.body != face.body {
            self.suggest(cmd, model)
        } else {
            syncEdgeItems(cmd, model)
        }
    }

    /// „Vorschlag“: Spannbaum ab der gewählten Grundfläche (Biegekanten), alle übrigen Kanten offen
    @MainActor static func suggest(_ cmd: ModelCommand, _ model: ModelStore) {
        guard let face = baseFace(cmd) else { return }
        let state = SheetCommandState.of(cmd)
        // Ebene Platte: keine Biegungen, nichts vorzuschlagen
        if isPlate(cmd, model) {
            setOpen([], cmd, model)
            state.warning = nil
            state.checkKey = checkKey(cmd)
            return
        }
        guard let plan = model.suggestSheetConversion(of: face.body, baseFace: face.face, rule: cmd.sheetRuleName) else {
            setOpen([], cmd, model)
            state.warning = "Kein Vorschlag möglich – der Körper hat keine ebene Fläche als Grundfläche."
            return
        }
        if plan.baseFace != face.face {
            cmd.setItems(faceInput, [.face(FaceRef(body: face.body, face: plan.baseFace))])
        }
        setOpen(plan.plateOnly ? [] : plan.openEdges, cmd, model)
        state.warning = plan.timedOut ? "Probe zu aufwendig – Vorschlag nicht geprüft." : plan.problem
        state.checkKey = checkKey(cmd)
    }

    // MARK: Regel und Spalt

    @MainActor static func baseRule(_ cmd: ModelCommand, _ model: ModelStore) -> SheetRule {
        cmd.sheetRuleName.flatMap { model.sheetDocument.rule(named: $0) } ?? model.sheetDocument.activeRule
    }

    /// Eigener Spalt der offenen Kanten (nil = aus der Regel). Das Modell legt ihn als abgeleitete Regel nur ins
    /// Rezept des Körpers (convertToSheet/checkSheetConversion gap:); SolidCraft kennt einen Spalt für alle Kanten.
    @MainActor static func gap(_ cmd: ModelCommand) -> Double? {
        cmd.optionalNumber("gap")
    }

    // MARK: Prüfen

    @MainActor static func checkKey(_ cmd: ModelCommand) -> String {
        let face = baseFace(cmd).map { "\($0.body):\($0.face)" } ?? "-"
        let plate = cmd.flags["plate"].map { $0 ? "p" : "n" } ?? "a"
        return "\(face)|\(cmd.values["open"] ?? "")|\(cmd.choices["rule"] ?? "")|\(plate)|\(cmd.values["gap"] ?? "")"
    }

    /// Probe-Wiedergabe der aktuellen Wahl (nur bei Änderung): Fehler bzw. Überlappung als Warnung
    @MainActor static func check(_ cmd: ModelCommand, _ model: ModelStore) {
        let state = SheetCommandState.of(cmd)
        let key = checkKey(cmd)
        guard state.checkKey != key else { return }
        state.checkKey = key
        guard let face = baseFace(cmd) else {
            state.warning = nil
            return
        }
        if isPlate(cmd, model) {
            state.warning = nil
            return
        }
        let plan = model.checkSheetConversion(of: face.body, baseFace: face.face, openEdges: modelOpen(cmd, model),
                                              rule: cmd.sheetRuleName, gap: gap(cmd))
        state.warning = plan?.problem ?? (plan == nil ? "Diese Grundfläche ist keine ebene Fläche des Körpers." : nil)
    }

    /// Ebene Platte (plateOnly, keine Biegungen): Schalter „Ebene Platte“ bzw. erkannt (detectsPlate)
    @MainActor static func isPlate(_ cmd: ModelCommand, _ model: ModelStore) -> Bool {
        guard let face = baseFace(cmd) else { return false }
        if let forced = cmd.flags["plate"] { return forced }
        return detectsPlate(SheetConvertTopology.topology(of: face.body, cmd, model))
    }

    /// Platte erkennen wie das Modell (SheetConversionPlan.plateOnly, REVIEW 21): keine Kandidatenkante. Stirnflächen
    /// dünner Körper zählen dort nicht als Wände, ihre Kanten sind also keine Kandidaten.
    static func detectsPlate(_ topology: (faces: [SheetModelFace], edges: [SheetModelEdge])) -> Bool {
        ModelStore.sheetIsPlate(topology)
    }

    // MARK: Antippen

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard cmd.editing == nil else { return false }
        let model = ws.model
        if let edge = tap.edge {
            toggle(edge, tap: tap, cmd, ws)
        } else if let face = tap.face {
            // Biegefläche (Zylinder, Fasenstreifen) antippen schaltet ihre Biegung um (REVIEW 39)
            if model.plane(of: face) == nil, baseFace(cmd)?.body == face.body,
               let bend = skinCandidates(cmd, model).first(where: { $0.bendFace == face.face }) {
                if isPlate(cmd, model) {
                    model.message = "Ebene Platte: keine Biegekanten. Zum Wählen „Ebene Platte“ ausschalten."
                } else {
                    flip(bend.edge, cmd, model)
                }
                CommandCache.refreshNow(cmd, ws)
                ws.objectWillChange.send()
                return true
            }
            guard model.plane(of: face) != nil else {
                model.message = "Als Grundfläche eine ebene Fläche antippen."
                return true
            }
            guard !model.isSheetBody(face.body) else {
                model.message = "„\(model.bodies[face.body].name)“ ist schon ein Blechkörper."
                return true
            }
            choose(base: face, cmd, model, suggest: false)
        } else {
            return false
        }
        CommandCache.refreshNow(cmd, ws)
        ws.objectWillChange.send()
        return true
    }

    /// Angetippte Kante zwischen offen und Biegung umschalten. Während der 3D-Vorschau zeigt das Ansichtsfenster den
    /// Blechkörper (andere Kantennummern): dann die nächste Kante des Ausgangskörpers zur Mitte der angetippten Kante.
    @MainActor static func toggle(_ edge: EdgeRef, tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) {
        let model = ws.model
        if baseFace(cmd)?.body != edge.body {
            guard !model.isSheetBody(edge.body) || model.hasPreview else {
                model.message = "„\(model.bodies[edge.body].name)“ ist schon ein Blechkörper."
                return
            }
            // Erstes Antippen eines Körpers wählt ihn: größte ebene Fläche als Grundfläche, dann der Vorschlag.
            // Erst das nächste Antippen schaltet Kanten um.
            let topology = SheetConvertTopology.topology(of: edge.body, cmd, model)
            guard let largest = topology.faces.max(by: { $0.area < $1.area }) else {
                model.message = "Dieser Körper hat keine ebene Fläche als Grundfläche."
                return
            }
            cmd.setItems(faceInput, [.face(FaceRef(body: edge.body, face: largest.face))])
            suggest(cmd, model)
            return
        }
        guard let face = baseFace(cmd) else { return }
        guard !isPlate(cmd, model) else {
            model.message = "Ebene Platte: keine Biegekanten. Zum Wählen „Ebene Platte“ ausschalten."
            return
        }
        let topology = SheetConvertTopology.topology(of: face.body, cmd, model)
        var found = topology.edges.first { $0.edge == edge.edge }
        if model.hasPreview {
            found = nil
            let point = SheetEdgePicks.midpoint(edge, model: model) ?? tap.point
            if let point {
                let thickness = baseRule(cmd, model).thickness
                var best: (SheetModelEdge, Double)?
                for candidate in topology.edges {
                    let distance = SheetEdgePicks.segmentDistance(point, candidate.start, candidate.end)
                    if distance < (best?.1 ?? .infinity) { best = (candidate, distance) }
                }
                if let best, best.1 < thickness * 2 + 0.2 { found = best.0 }
            }
        }
        guard var target = found else {
            model.message = "Diese Kante gehört nicht zum Körper der Grundfläche."
            return
        }
        // Kante einer modellierten Biegung (Zylinder, Fasenstreifen): steht für deren Vertreterkante
        if !target.isCandidate, let bend = topology.edges.first(where: { edge in
            edge.isCandidate && edge.bendFace.map { target.faces.contains($0) } == true
        }) {
            target = bend
        }
        guard target.isCandidate else {
            model.message = "Diese Kante liegt nicht zwischen zwei ebenen Wänden – sie bleibt offen."
            return
        }
        flip(target.edge, cmd, model)
    }

    /// Kante der Haut zwischen offen und Biegung umschalten
    @MainActor static func flip(_ edge: Int, _ cmd: ModelCommand, _ model: ModelStore) {
        guard skinCandidates(cmd, model).contains(where: { $0.edge == edge }) else {
            model.message = "Diese Kante liegt auf der anderen Seite des Blechs – sie gehört nicht zur Grundfläche."
            return
        }
        var open = openEdges(cmd)
        if open.contains(edge) {
            open.remove(edge)
        } else {
            open.insert(edge)
        }
        setOpen(open, cmd, model)
    }

    // MARK: Vorschau und OK

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        reconcile(cmd, model)
        guard let face = baseFace(cmd) else {
            model.dropPreview()
            SheetCommandState.of(cmd).warning = nil
            return nil
        }
        guard !model.isSheetBody(face.body) else {
            model.dropPreview()
            return "„\(model.bodies[face.body].name)“ ist schon ein Blechkörper."
        }
        check(cmd, model)
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        let plate = isPlate(cmd, model)
        if model.convertToSheet(face.body, baseFace: face.face, openEdges: plate ? [] : modelOpen(cmd, model),
                                rule: cmd.sheetRuleName, plateOnly: plate, gap: gap(cmd), preview: true) {
            return nil
        }
        return SheetPick.failure(model, "Umwandeln mit dieser Wahl nicht möglich.")
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.commit(ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.cancel(ws)
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetConvertRows(cmd: cmd, workspace: ws, model: ws.model, document: ws.model.sheetDocument,
                                 state: SheetCommandState.of(cmd)))
    }
}

// MARK: - Panel

/// Zeilen wie SolidCraft „In Blech umwandeln“ (Körper, Regel) plus Kantenwahl: Modus, Vorschlag, Zählung, Liste der
/// offenen Kanten mit Spalt, Warnung, Vorschau.
private struct SheetConvertRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var document: SheetDocument
    @ObservedObject var state: SheetCommandState

    var body: some View {
        let face = SheetConvertDriver.baseFace(cmd)
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            if let face, model.bodies.indices.contains(face.body) {
                SheetInfoRow(title: "Körper", text: model.bodies[face.body].name)
            }
            SheetRuleMenuRow(cmd: cmd, document: document, workspace: workspace)
            if face != nil {
                CheckRow(title: "Ebene Platte", icon: "square", isOn: Binding(get: {
                    SheetConvertDriver.isPlate(cmd, model)
                }, set: { value in
                    cmd.flags["plate"] = value
                    if !value, SheetConvertDriver.openEdges(cmd).isEmpty { SheetConvertDriver.suggest(cmd, model) }
                    CommandCache.refreshNow(cmd, workspace)
                    workspace.objectWillChange.send()
                }))
                if SheetConvertDriver.isPlate(cmd, model) {
                    CommandStatusRow(title: "Kanten", text: "Ebene Platte – keine Biegungen", isDone: true)
                } else {
                    edgeRows
                }
            } else {
                CommandStatusRow(title: "Grundfläche", text: "Ebene Fläche antippen")
            }
            if let warning = state.warning {
                SheetWarningRow(text: warning)
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
                PaletteHint(text: "Vorschau aus: nur die Kanten im Ansichtsfenster. OK wandelt trotzdem um.")
            }
        }
        // „×“ in den Auswahlfeldern: Wahl angleichen und neu prüfen
        .onChange(of: cmd.inputs.map(\.items.count)) { _, _ in
            CommandCache.refreshNow(cmd, workspace)
            workspace.objectWillChange.send()
        }
    }

    @ViewBuilder private var edgeRows: some View {
        let open = SheetConvertDriver.openCandidates(cmd, model)
        let bends = SheetConvertDriver.bendEdges(cmd, model)
        CommandSegmentRow(title: "Kanten antippen", options: SheetConvertDriver.modes,
                          selected: cmd.option("mode", default: "open")) { id in
            cmd.choices["mode"] = id
            SheetConvertDriver.syncEdgeItems(cmd, model)
            workspace.objectWillChange.send()
        }
        PrimaryWideButton(title: "Vorschlag", systemImage: "wand.and.stars", isPrimary: false) {
            SheetConvertDriver.suggest(cmd, model)
            CommandCache.refreshNow(cmd, workspace)
            workspace.objectWillChange.send()
        }
        .hoverTip("Vorschlag", "Offene Kanten und Biegekanten automatisch festlegen (ab der Grundfläche)")
        SheetLegendRow(color: FlatPatternColors.up, dashed: false, text: "\(bends.count) Biegekanten")
        SheetLegendRow(color: SketchTheme.error, dashed: true, text: "\(open.count) offene Kanten")
        SheetCommandOptionalRow(title: "Spalt", cmd: cmd, key: "gap", placeholder: gapPlaceholder, workspace: workspace)
        if !open.isEmpty {
            CommandSection("Offene Kanten", command: SheetConvertDriver.id, section: "open", expanded: false) {
                ForEach(open) { edge in
                    openEdgeRow(edge)
                }
                PaletteHint(text: "Der Spalt gilt für alle offenen Kanten.")
            }
        }
    }

    private var gapPlaceholder: String {
        SheetConvertDriver.baseRule(cmd, model).gap.map { "Regel: \(SheetFormat.length($0))" } ?? "aus der Regel"
    }

    private var gapText: String {
        if let gap = cmd.optionalNumber("gap") { return SheetFormat.length(gap) }
        return SheetConvertDriver.baseRule(cmd, model).gap.map(SheetFormat.length) ?? "Regel"
    }

    /// Offene Kante: Nummer, Länge, Spalt; Knopf macht sie zur Biegung
    private func openEdgeRow(_ edge: SheetModelEdge) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Kante \(edge.edge)")
                    .font(.footnote)
                Text("\(SheetFormat.length(simd_distance(edge.start, edge.end))) · Spalt \(gapText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Button {
                var open = SheetConvertDriver.openEdges(cmd)
                open.remove(edge.edge)
                SheetConvertDriver.setOpen(open, cmd, model)
                CommandCache.refreshNow(cmd, workspace)
                workspace.objectWillChange.send()
            } label: {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 14))
                    .foregroundStyle(FlatPatternColors.up)
                    .frame(width: PaletteStyle.touch, height: PaletteStyle.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kante \(edge.edge) biegen statt öffnen")
        }
    }
}

/// Legendenzeile: Linie (durchgezogen bzw. gestrichelt) in der Farbe des Ansichtsfensters und Text
struct SheetLegendRow: View {
    let color: Color
    let dashed: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: dashed ? [5, 4] : []))
            }
            .frame(width: 22, height: 10)
            .accessibilityHidden(true)
            Text(text)
                .font(.footnote.monospacedDigit())
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }
}
