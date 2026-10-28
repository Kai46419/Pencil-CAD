import SwiftUI
import UIKit
import simd

// Oberfläche des Blechmoduls (Punkt 16) nach SolidCraft (MIT/Apache-2.0, crates/ui-egui/src/dialogs_sheet.rs,
// crates/ui-egui/src/workspace.rs Reiter „SHEET METAL“, assets/locales/de.json, SheetKit/COMMANDS.md).
//
// Aufteilung:
// - SheetUI.swift: Ribbon-Gruppe „Blech“, Befehlssuche, Register der Treiber, gemeinsame Bausteine
//   (Kantenwahl über Kantenmitten, Skizzenlinien, Zahlenfelder mit „aus der Regel“, Teilen-Dialog)
// - SheetUITools.swift: Werkzeugliste (Ribbon, Suche), Blechteil aus Skizze, Lasche, Profil biegen, Frage
//   „In Blech umwandeln?“, Mini-Vorschaubilder
// - SheetUIFlange.swift: Flansch (Grund-, Kanten-, Konturflansch), Pfadflansch, Umkantung, Falten, Perforieren
// - SheetUIConvert.swift: In Blech umwandeln mit Wahl der offenen Kanten (Kais Wunsch)
// - SheetUIFlat.swift: Entfalten, Wieder falten, Flachmuster erstellen, DXF- und Biegetabellen-Export
// - SheetUIRules.swift: Blechregeln (verwalten) und Blechregeln auflisten
// - SheetUIOverlay.swift: Linien im Viewport (gewählte Kanten, Biege-/offene Kanten, Skizzenlinien)
// - FlatPatternView.swift: 2D-Ansicht des Flachmusters über dem Viewport
//
// Gerechnet wird ausschließlich über die Modell-API (App/Sheet/SheetModel.swift, SheetKit/API.md).

// MARK: - Register

extension ModelCommands {
    /// Treiber des Blechmoduls (aufgerufen aus registerAll())
    static func registerSheet() {
        // Der freie „Flansch“ (SheetFlangeDriver, Typ folgt der Auswahl) steht nicht mehr im Ribbon: an seiner Stelle
        // die drei Werkzeuge mit festem Typ (Punkt 6); sie öffnen auch die Flansche aus der Zeitleiste.
        let list: [ModelCommandDriver.Type] = [
            SheetBaseFlangeDriver.self, SheetEdgeFlangeDriver.self, SheetContourFlangeDriver.self, SheetKantenDriver.self,
            SheetBoxDriver.self,
            SheetPathFlangeDriver.self, SheetHemDriver.self, SheetFoldDriver.self,
            SheetPerforateDriver.self, SheetConvertDriver.self,
            SheetUnfoldDriver.self, SheetRefoldDriver.self, SheetFlatPatternDriver.self,
            SheetRulesDriver.self, SheetRuleListDriver.self,
        ]
        for driver in list { register(driver) }
    }
}

// MARK: - Ribbon und Suche

@MainActor
enum SheetUI {
    /// Hinweis ohne gebautes Blechmodul (SheetKernelError.notBuilt)
    static let notBuiltText = "Blechmodul nicht gebaut – im Terminal ./scripts/build-sheet-ios.sh ausführen"

    /// Befehle der Gruppe „Blech“ in SolidCraft-Reihenfolge (workspace.rs: SKETCH · CREATE · FLAT · OUTPUT · RULES).
    static func ribbonCommands(_ ws: Workspace) -> [RibbonCommand] {
        let model = ws.model
        let available = model.sheetAvailable
        var list: [RibbonCommand] = []
        if !available {
            // Ohne Blechmodul: Hinweis statt Absturz, die Befehle bleiben sichtbar, aber gesperrt
            let reason = model.sheetUnavailableReason ?? notBuiltText
            list.append(RibbonCommand(id: "sheet.unavailable", title: "Blechmodul nicht gebaut",
                                      subtitle: reason, icon: "exclamationmark.triangle", heading: "HINWEIS") {
                model.message = reason
            })
        }
        list.append(RibbonCommand(id: "sheet.sketch", title: "Neue Skizze", subtitle: "Profil für den Grundflansch",
                                  icon: "sc.sketch", heading: "SKIZZE", isActive: ws.sketch.isActive) {
            ws.startSketch()
        })
        func command(_ entry: SheetToolEntry) -> RibbonCommand {
            RibbonCommand(id: entry.id.rawValue, title: entry.title, subtitle: entry.subtitle, icon: entry.icon,
                          heading: entry.heading, featured: entry.featured, isActive: ws.command?.id == entry.id,
                          isEnabled: available) {
                SheetTools.start(entry, ws)
            }
        }
        // Werkzeugliste (SheetUITools.swift); Regeln nach der Ausgabe
        list += SheetTools.catalog.filter { $0.heading != "REGELN" }.map(command)
        list.append(RibbonCommand(id: "sheet.exportDXF", title: "DXF exportieren", subtitle: "Abwicklung mit Bemaßung",
                                  icon: "sc.dxf", heading: "AUSGABE", isEnabled: available) {
            exportDXF(ws)
        })
        list.append(RibbonCommand(id: "sheet.flatDrawing", title: "Abwicklungszeichnung",
                                  subtitle: "Blatt mit Abwicklung, Biegetabelle, Ansichten (PDF)", icon: "doc.richtext",
                                  heading: "AUSGABE", isEnabled: available) {
            FlatDrawingPresenter.present(ws)
        })
        list.append(RibbonCommand(id: "sheet.exportBendTable", title: "Biegetabelle", subtitle: "Biegungstabelle als CSV",
                                  icon: "sc.bendtable", heading: "AUSGABE", isEnabled: available) {
            exportBendTable(ws)
        })
        list += SheetTools.catalog.filter { $0.heading == "REGELN" }.map(command)
        return list
    }

    /// „In Blech umwandeln“ zusätzlich in der Gruppe „Ändern“ (SolidCraft MODEL → MODIFY, REVIEW 45); ohne
    /// Blechmodul sichtbar, aber gesperrt. Eigene ID, damit die Stecknadel nicht mit der Gruppe „Blech“ geteilt wird.
    static func modifyCommand(_ ws: Workspace) -> RibbonCommand {
        RibbonCommand(id: "modify.sheetConvert", title: "In Blech umwandeln", subtitle: "Körper zu Blech",
                      icon: "sc.convert_sheet", heading: "BLECH", isActive: ws.command?.id == .sheetConvert,
                      isEnabled: ws.model.sheetAvailable) {
            start(.sheetConvert, ws)
        }
    }

    /// Einträge der Befehlssuche (CommandSearch.swift)
    static func searchItems(_ ws: Workspace) -> [CommandItem] {
        func item(_ entry: SheetToolEntry) -> CommandItem {
            CommandItem(id: "sheet.\(entry.id.rawValue)", title: entry.title, subtitle: entry.search,
                        systemImage: entry.icon, keywords: "blech sheet metal flansch flange " + entry.keywords) { [weak ws] in
                guard let ws else { return }
                SheetTools.start(entry, ws)
            }
        }
        let tools = SheetTools.catalog.filter { $0.heading != "REGELN" }.map(item)
        let rules = SheetTools.catalog.filter { $0.heading == "REGELN" }.map(item)
        return tools + [
            CommandItem(id: "sheet.exportDXF", title: "Flachmuster als DXF exportieren", subtitle: "Blech: DXF für Laser",
                        systemImage: "sc.dxf", keywords: "blech sheet dxf export laser zuschnitt") { [weak ws] in
                guard let ws else { return }
                exportDXF(ws)
            },
            CommandItem(id: "sheet.flatDrawing", title: "Abwicklungszeichnung", subtitle: "Blech: Blatt als PDF und DXF",
                        systemImage: "doc.richtext",
                        keywords: "blech sheet abwicklung zeichnung pdf bemaßung biegetabelle fertigung") { [weak ws] in
                guard let ws else { return }
                FlatDrawingPresenter.present(ws)
            },
            CommandItem(id: "sheet.exportBendTable", title: "Biegungstabelle exportieren", subtitle: "Blech: CSV",
                        systemImage: "sc.bendtable", keywords: "blech sheet biegetabelle bend table csv") { [weak ws] in
                guard let ws else { return }
                exportBendTable(ws)
            },
        ] + rules
    }

    /// Blechbefehl starten; ohne Blechmodul nur der Hinweis.
    static func start(_ id: ModelCommandID, _ ws: Workspace) {
        guard ws.model.sheetAvailable else {
            ws.model.message = ws.model.sheetUnavailableReason ?? notBuiltText
            return
        }
        ws.startCommand(id)
    }

    /// Blechkörper für Befehle ohne Auswahl: gewählter Blechkörper, sonst der letzte (SolidCraft „last if none“).
    static func targetSheetBody(_ model: ModelStore, picked: Int? = nil) -> Int? {
        if let picked, model.isSheetBody(picked) { return picked }
        if let selected = model.selectedBody, model.isSheetBody(selected) { return selected }
        for body in model.selectedBodies where model.isSheetBody(body) { return body }
        return model.sheetBodies.last
    }

    // MARK: Ausgabe (Ribbon AUSGABE: direkt Teilen-Dialog für den letzten bzw. gewählten Blechkörper)

    static func exportDXF(_ ws: Workspace, options: SheetDXFOptions = SheetDXFOptions(), body picked: Int? = nil) {
        let model = ws.model
        guard model.sheetAvailable else {
            model.message = model.sheetUnavailableReason ?? notBuiltText
            return
        }
        guard let body = targetSheetBody(model, picked: picked) else {
            model.message = "Kein Blechkörper im Projekt – erst einen Flansch erstellen oder einen Körper in Blech umwandeln."
            return
        }
        do {
            // Mit Bemaßung: Abwicklungszeichnung (FlatDrawing.swift), sonst die reine Laserdatei von SolidCraft
            let url = try options.withDrawing ? model.exportFlatDrawingDXF(of: body, options: options)
                : model.exportFlatPatternDXF(of: body, options: options)
            SheetShare.present([url])
        } catch {
            model.message = "DXF: \(error.localizedDescription)"
        }
    }

    static func exportBendTable(_ ws: Workspace, body picked: Int? = nil) {
        let model = ws.model
        guard model.sheetAvailable else {
            model.message = model.sheetUnavailableReason ?? notBuiltText
            return
        }
        guard let body = targetSheetBody(model, picked: picked) else {
            model.message = "Kein Blechkörper im Projekt – erst einen Flansch erstellen oder einen Körper in Blech umwandeln."
            return
        }
        do {
            let url = try model.exportBendTableCSV(of: body)
            SheetShare.present([url])
        } catch {
            model.message = "Biegetabelle: \(error.localizedDescription)"
        }
    }
}

// MARK: - Zustand je offenem Befehl

/// Daten eines offenen Blechbefehls, die nicht in ModelCommand passen (Warnung, Flachmuster, Kantenlinien).
/// Wie CommandCache.anchors je Befehl gemerkt und bei OK/Abbrechen vergessen.
@MainActor
final class SheetCommandState: ObservableObject {
    /// Warnung (z. B. Überlappung im Flachmuster beim Umwandeln) – hält OK nicht auf
    @Published var warning: String?
    /// Flachmuster (Flachmuster erstellen)
    @Published var flat: FlatPattern?
    @Published var flatError: String?
    /// Stand, zu dem flat gehört (Körper, Modellstand)
    var flatKey: String?
    /// Meldung nach einem Export
    @Published var status: String?
    /// Angetippter Vollkörper, wo Blech erwartet wird: Frage „In Blech umwandeln?“ im Panel (SheetConvertQuestion)
    @Published var convertBody: Int?
    /// Topologie für „In Blech umwandeln“ (Körper, Modellstand)
    var topologyKey: String?
    var topology: (faces: [SheetModelFace], edges: [SheetModelEdge]) = ([], [])
    /// Stand der letzten Probe-Wiedergabe beim Umwandeln (Grundfläche, offene Kanten, Regel)
    var checkKey: String?
    /// Bearbeiten aus der Zeitleiste (SheetUIEdit.swift): Körper, Schritt im Rezept, Ausgangswerte
    var editBody: Int?
    var editStep: SheetStep?
    var editOriginal: [String: String] = [:]

    private static var states: [ObjectIdentifier: SheetCommandState] = [:]

    static func of(_ cmd: ModelCommand) -> SheetCommandState {
        let key = ObjectIdentifier(cmd)
        if let state = states[key] { return state }
        let state = SheetCommandState()
        states[key] = state
        return state
    }

    /// Zustand des gerade offenen Befehls (Overlay, Flachmuster-Ansicht), nil ohne
    static func existing(_ cmd: ModelCommand) -> SheetCommandState? {
        states[ObjectIdentifier(cmd)]
    }

    static func forget(_ cmd: ModelCommand) {
        states[ObjectIdentifier(cmd)] = nil
    }
}

// MARK: - Kantenwahl über Kantenmitten

/// Eine gewählte Blechkante: Punkt auf der Kante (Mitte, Weltkoordinaten – so erwartet SolidCraft Kanten),
/// Körper und Kantennummer beim Antippen (nur für die Anzeige), Linienzug zum Hervorheben und eigene Werte
/// (Kantenflansch „Pro Kante“: leer = Werte des Flanschs).
struct SheetEdgePick: Codable, Hashable {
    var point: SIMD3<Double>
    var body: Int
    var edge: Int
    var lines: [[SIMD3<Double>]] = []
    var angle: Double?
    var height: Double?
}

/// Liste gewählter Kanten, als Text in `cmd.values[key]` (gehört damit zur Signatur der Vorschau).
@MainActor
enum SheetEdgePicks {
    static func list(_ cmd: ModelCommand, _ key: String) -> [SheetEdgePick] {
        guard let text = cmd.values[key], let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([SheetEdgePick].self, from: data) else { return [] }
        return list
    }

    static func store(_ list: [SheetEdgePick], _ cmd: ModelCommand, _ key: String, inputID: String) {
        if list.isEmpty {
            cmd.values[key] = nil
        } else if let data = try? JSONEncoder().encode(list) {
            cmd.values[key] = String(decoding: data, as: UTF8.self)
        }
        // Auswahlfeld zeigt je Kante einen Eintrag („Kante · Körper“ bzw. „N ausgewählt“)
        let others = cmd.items(inputID).filter { pick in
            if case .edge = pick { return false }
            return true
        }
        CommandPicks.setItems(others + list.map { Pick.edge(EdgeRef(body: $0.body, edge: $0.edge)) }, cmd, inputID)
    }

    /// Auswahlfeld mit „×“ geleert: Liste mit leeren
    static func reconcile(_ cmd: ModelCommand, _ key: String, inputID: String) -> [SheetEdgePick] {
        let list = Self.list(cmd, key)
        let hasEdges = cmd.items(inputID).contains { pick in
            if case .edge = pick { return true }
            return false
        }
        if !list.isEmpty, !hasEdges {
            cmd.values[key] = nil
            return []
        }
        return list
    }

    /// Mitte einer Kante in Weltkoordinaten: Kernel (Kantenmitte), sonst Mitte des angezeigten Linienzugs.
    static func midpoint(_ edge: EdgeRef, model: ModelStore) -> SIMD3<Double>? {
        let shown = model.shownBodies
        if shown.indices.contains(edge.body), let handle = shown[edge.body].shape.handle(ofEdge: edge.edge),
           handle.count >= 3 {
            let point = SIMD3<Double>(handle[0].doubleValue, handle[1].doubleValue, handle[2].doubleValue)
            if point.x.isFinite, point.y.isFinite, point.z.isFinite { return point }
        }
        return polylineMidpoint(model.edgePolylines(edge))
    }

    static func polylineMidpoint(_ lines: [[SIMD3<Double>]]) -> SIMD3<Double>? {
        guard let line = lines.max(by: { length($0) < length($1) }), let first = line.first else { return nil }
        var rest = length(line) / 2
        for (a, b) in zip(line, line.dropFirst()) {
            let step = simd_distance(a, b)
            if step >= rest, step > 0 { return a + (b - a) * (rest / step) }
            rest -= step
        }
        return first
    }

    static func length(_ line: [SIMD3<Double>]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    /// Abstand eines Punkts zu Linienzügen
    static func distance(_ point: SIMD3<Double>, to lines: [[SIMD3<Double>]]) -> Double {
        var best = Double.infinity
        for line in lines {
            if line.count == 1 { best = min(best, simd_distance(point, line[0])) }
            for (a, b) in zip(line, line.dropFirst()) {
                best = min(best, segmentDistance(point, a, b))
            }
        }
        return best
    }

    static func segmentDistance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-18 else { return simd_distance(p, a) }
        let t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1)
        return simd_distance(p, a + ab * t)
    }

    /// Angetippte Kante hinzufügen bzw. wieder abwählen (gespeicherter Punkt liegt auf ihr).
    /// single: nur eine Kante (Pfadflansch). Rückgabe: Kante gewählt (true) bzw. abgewählt (false).
    @discardableResult
    static func toggle(_ edge: EdgeRef, _ cmd: ModelCommand, _ ws: Workspace, key: String, inputID: String,
                       single: Bool = false) -> Bool {
        let model = ws.model
        var list = reconcile(cmd, key, inputID: inputID)
        let lines = model.edgePolylines(edge)
        let tolerance = 0.05
        if let index = list.firstIndex(where: { pick in
            distance(pick.point, to: lines) < tolerance || (pick.body == edge.body && pick.edge == edge.edge && !model.hasPreview)
        }) {
            list.remove(at: index)
            store(list, cmd, key, inputID: inputID)
            return false
        }
        guard let mid = midpoint(edge, model: model) else {
            model.message = "Diese Kante lässt sich nicht verwenden."
            return false
        }
        if single { list = [] }
        list.append(SheetEdgePick(point: mid, body: edge.body, edge: edge.edge, lines: lines))
        store(list, cmd, key, inputID: inputID)
        return true
    }

    /// Kante aus der Liste nehmen (Papierkorb in „Pro Kante“)
    static func remove(at index: Int, _ cmd: ModelCommand, key: String, inputID: String) {
        var list = Self.list(cmd, key)
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        store(list, cmd, key, inputID: inputID)
    }

    /// Eigene Werte einer Kante setzen (nil = Wert des Flanschs)
    static func setOwn(at index: Int, angle: Double??, height: Double??, _ cmd: ModelCommand, key: String,
                       inputID: String) {
        var list = Self.list(cmd, key)
        guard list.indices.contains(index) else { return }
        if let angle { list[index].angle = angle }
        if let height { list[index].height = height }
        store(list, cmd, key, inputID: inputID)
    }
}

// MARK: - Skizzenlinien (Konturflansch, Pfadflansch, Falten)

/// Linie einer Skizze, die ein Blechbefehl nehmen kann (.line bzw. offener Linienzug), in Weltkoordinaten.
struct SheetSketchLine: Identifiable, Hashable {
    /// Index in StoredSketch.entities
    var entity: Int
    /// Lokale Punkte (Linie: zwei, Linienzug: alle)
    var local: [SIMD2<Double>]
    var world: [SIMD3<Double>]
    var length: Double
    var isPolyline: Bool

    var id: Int { entity }
}

@MainActor
enum SheetLines {
    /// Wählbare Linien einer Skizze (keine Konstruktionslinien)
    static func lines(_ model: ModelStore, sketch: Int) -> [SheetSketchLine] {
        guard model.sketches.indices.contains(sketch) else { return [] }
        let stored = model.sketches[sketch]
        var result: [SheetSketchLine] = []
        for (index, entity) in stored.entities.enumerated() where !stored.construction.contains(index) {
            switch entity {
            case .line(let a, let b):
                result.append(line(index, [a, b], stored.plane, polyline: false))
            case .polyline(let points, let closed) where !closed && points.count >= 2:
                result.append(line(index, points, stored.plane, polyline: true))
            default:
                continue
            }
        }
        return result
    }

    private static func line(_ index: Int, _ local: [SIMD2<Double>], _ plane: SketchPlane, polyline: Bool) -> SheetSketchLine {
        let world = local.map { plane.world($0) }
        let length = zip(local, local.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        return SheetSketchLine(entity: index, local: local, world: world, length: length, isPolyline: polyline)
    }

    /// Skizze der Linienwahl (choices[sketchKey]) bzw. nil
    static func sketch(_ cmd: ModelCommand, _ model: ModelStore, key: String = "lineSketch") -> Int? {
        guard let text = cmd.choices[key], let index = Int(text), model.sketches.indices.contains(index) else { return nil }
        return index
    }

    /// Gewählte Elemente (values[linesKey] = "3,4,5") in Wahlreihenfolge
    static func selected(_ cmd: ModelCommand, key: String = "lines") -> [Int] {
        (cmd.values[key] ?? "").split(separator: ",").compactMap { Int($0) }
    }

    static func setSelected(_ entities: [Int], _ cmd: ModelCommand, key: String = "lines") {
        cmd.values[key] = entities.isEmpty ? nil : entities.map(String.init).joined(separator: ",")
    }

    /// Alle Linien, die an `entity` Ende an Ende hängen (SolidCraft: ein Klick nimmt die ganze Kette).
    static func connectedChain(_ lines: [SheetSketchLine], from entity: Int) -> [Int] {
        guard lines.contains(where: { $0.entity == entity }) else { return [] }
        var chain: Set<Int> = [entity]
        var grew = true
        while grew {
            grew = false
            for line in lines where !chain.contains(line.entity) {
                let ends = [line.local.first, line.local.last].compactMap { $0 }
                let touches = lines.contains { other in
                    guard chain.contains(other.entity) else { return false }
                    let otherEnds = [other.local.first, other.local.last].compactMap { $0 }
                    return ends.contains { a in otherEnds.contains { b in simd_distance(a, b) < 1e-4 } }
                }
                if touches {
                    chain.insert(line.entity)
                    grew = true
                }
            }
        }
        return lines.map(\.entity).filter { chain.contains($0) }
    }

    /// Gewählte Linien als Kette ordnen, beginnend am Ende nahe `start` (Weltpunkt, z. B. die Kante des
    /// Pfadflanschs). nil, wenn sie keine zusammenhängende offene Kette bilden.
    static func orderedChain(_ lines: [SheetSketchLine], selected: [Int], plane: SketchPlane,
                             start: SIMD3<Double>?) -> [Int]? {
        let chosen = selected.compactMap { id in lines.first { $0.entity == id } }
        guard !chosen.isEmpty else { return nil }
        if chosen.count == 1 { return [chosen[0].entity] }
        func ends(_ line: SheetSketchLine) -> (SIMD2<Double>, SIMD2<Double>) {
            (line.local.first ?? .zero, line.local.last ?? .zero)
        }
        func degree(_ p: SIMD2<Double>) -> Int {
            chosen.reduce(0) { count, line in
                let (a, b) = ends(line)
                return count + (simd_distance(a, p) < 1e-4 ? 1 : 0) + (simd_distance(b, p) < 1e-4 ? 1 : 0)
            }
        }
        // Freie Enden der Kette (genau zwei)
        var free: [SIMD2<Double>] = []
        for line in chosen {
            let (a, b) = ends(line)
            for p in [a, b] where degree(p) == 1 && !free.contains(where: { simd_distance($0, p) < 1e-4 }) {
                free.append(p)
            }
        }
        guard free.count == 2 else { return nil }
        var current = free[0]
        if let start {
            let local = plane.local(start)
            if simd_distance(free[1], local) < simd_distance(free[0], local) { current = free[1] }
        }
        var rest = chosen
        var order: [Int] = []
        while !rest.isEmpty {
            guard let index = rest.firstIndex(where: { line in
                let (a, b) = ends(line)
                return simd_distance(a, current) < 1e-4 || simd_distance(b, current) < 1e-4
            }) else { return nil }
            let line = rest.remove(at: index)
            let (a, b) = ends(line)
            current = simd_distance(a, current) < 1e-4 ? b : a
            order.append(line.entity)
        }
        return order
    }

    /// Weltlinien der gewählten Elemente (Overlay)
    static func worldLines(_ model: ModelStore, sketch: Int, selected: [Int]) -> [[SIMD3<Double>]] {
        lines(model, sketch: sketch).filter { selected.contains($0.entity) }.map(\.world)
    }
}

/// Linienwahl im Panel: Skizze wählen, dann Linien antippen (Haken); „Ganze Kette“ nimmt alle verbundenen.
struct SheetLinePicker: View {
    let title: String
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    /// Nur eine Linie (Falten)
    var single = false
    /// Antippen einer Linie nimmt die ganze Kette (Pfadflansch)
    var chains = false
    /// Nach jeder Änderung (z. B. Typwechsel des Flanschs)
    var changed: () -> Void = {}

    private var sketchIndex: Int? { SheetLines.sketch(cmd, model) }

    var body: some View {
        let selected = SheetLines.selected(cmd)
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PanelMenuRow(title: title, value: sketchIndex.map { model.sketches[$0].name } ?? "Skizze wählen") {
                ForEach(model.sketches.indices, id: \.self) { index in
                    Button(model.sketches[index].name) {
                        cmd.choices["lineSketch"] = String(index)
                        SheetLines.setSelected([], cmd)
                        changed()
                        CommandCache.refreshNow(cmd, workspace)
                        workspace.objectWillChange.send()
                    }
                }
            }
            if let sketchIndex {
                let lines = SheetLines.lines(model, sketch: sketchIndex)
                if lines.isEmpty {
                    PaletteHint(text: "Diese Skizze hat keine offenen Linien.")
                }
                ForEach(Array(lines.enumerated()), id: \.element.entity) { number, line in
                    let isOn = selected.contains(line.entity)
                    Button {
                        toggle(line.entity, lines: lines, isOn: isOn)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .font(.system(size: 16))
                                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.isPolyline ? "Linienzug \(number + 1)" : "Linie \(number + 1)")
                                    .font(.footnote)
                                Text(LengthUnit.current.format(line.length))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: PaletteStyle.iconButton)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(line.isPolyline ? "Linienzug \(number + 1)" : "Linie \(number + 1)")
                    .accessibilityValue(isOn ? "Gewählt" : "Nicht gewählt")
                }
                if !single, !lines.isEmpty {
                    HStack(spacing: PaletteStyle.spacing) {
                        PrimaryWideButton(title: "Ganze Kette", systemImage: "link", isPrimary: false) {
                            let start = selected.first ?? lines[0].entity
                            SheetLines.setSelected(SheetLines.connectedChain(lines, from: start), cmd)
                            changed()
                            CommandCache.refreshNow(cmd, workspace)
                            workspace.objectWillChange.send()
                        }
                        .accessibilityLabel("Ganze Kette wählen")
                        if !selected.isEmpty {
                            PrimaryWideButton(title: "Keine", systemImage: "xmark", isPrimary: false, showsTitle: false) {
                                SheetLines.setSelected([], cmd)
                                changed()
                                CommandCache.refreshNow(cmd, workspace)
                                workspace.objectWillChange.send()
                            }
                            .accessibilityLabel("Linien abwählen")
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ entity: Int, lines: [SheetSketchLine], isOn: Bool) {
        var selected = SheetLines.selected(cmd)
        if isOn {
            selected.removeAll { $0 == entity }
        } else if single {
            selected = [entity]
        } else if chains {
            for id in SheetLines.connectedChain(lines, from: entity) where !selected.contains(id) { selected.append(id) }
        } else {
            selected.append(entity)
        }
        SheetLines.setSelected(selected, cmd)
        changed()
        CommandCache.refreshNow(cmd, workspace)
        workspace.objectWillChange.send()
    }
}

// MARK: - Panelbausteine

/// Hinweis ohne Blechmodul (oben im Panel jedes Blechbefehls); sonst die Warnung der Engine zur gezeigten Vorschau
/// (sheetDocument.lastWarning: Entlastung ausgelassen, Ecke offen …).
struct SheetUnavailableRow: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        if model.sheetUnavailableReason == nil, model.hasPreview, let warning = model.sheetDocument.lastWarning {
            SheetWarningRow(text: warning)
        }
        if let reason = model.sheetUnavailableReason {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(reason)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(SketchTheme.error)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Warnung (orange), hält OK nicht auf
struct SheetWarningRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(SketchTheme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Zeile „Titel · Text“ ohne Symbol (Typ, Abwicklungsgröße …)
struct SheetInfoRow: View {
    let title: String
    let text: String
    var color: Color = .primary

    var body: some View {
        PaletteLabeled(title: title) {
            Text(text)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Eintrag einer Auswahlliste
struct SheetOption: Identifiable, Hashable {
    let id: String
    let title: String

    init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }
}

/// Auswahl aus einer kurzen Liste als Menü (lange Beschriftungen wie „Tangential an Kante“ passen nicht als Segmente).
struct SheetMenuRow: View {
    let title: String
    let options: [SheetOption]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        PanelMenuRow(title: title, value: options.first { $0.id == selected }?.title ?? selected) {
            ForEach(options) { option in
                Button {
                    pick(option.id)
                } label: {
                    if option.id == selected {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        }
    }
}

/// Zahlenfeld, das leer bleiben darf (SolidCraft `hint_row`: leer = „aus der Regel“). Zahl oder Formel mit
/// Variablen; `set(nil)` = leer.
struct SheetOptionalValueRow: View {
    let title: String
    let value: Double?
    var placeholder = "aus der Regel"
    var unit = "mm"
    let set: (Double?) -> Void

    @Environment(\.variableValues) private var variables
    @State private var text = ""
    @State private var error: String?
    /// Ziffernblock offen bzw. Textfeld aktiv (Punkt 7: kleiner Ziffernblock statt Bildschirmtastatur)
    @State private var isEditing = false

    var body: some View {
        PaletteLabeled(title: title) {
            PaletteFieldBox(isLocked: false, hasError: error != nil) {
                KeypadField(title: title, text: $text, isEditing: $isEditing, placeholder: placeholder,
                            unitSymbol: PaletteExpression.unitSymbol(unit), step: stepped, onCommit: commit)
                    .onChange(of: value) { _, newValue in
                        if !isEditing { text = shown(newValue) }
                    }
                    .onAppear { text = shown(value) }
                if !unit.isEmpty {
                    Text(PaletteExpression.unitSymbol(unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .help(error ?? "")
    }

    private func shown(_ value: Double?) -> String {
        value.map { PaletteExpression.shown($0, unit: unit) } ?? ""
    }

    /// Schritt um eine Einheit vom eingegebenen bzw. gespeicherten Wert aus (leer und ohne Wert: keiner)
    private func stepped(_ direction: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let current: Double? = trimmed.isEmpty ? value
            : (try? PaletteExpression.evaluate(trimmed, unit: unit, variables: variables))
        guard let current else { return nil }
        let size = unit == "mm" ? LengthUnit.current.millimeters : 1
        return PaletteExpression.shown(current + Double(direction) * size, unit: unit)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = nil
            if value != nil { set(nil) }
            return
        }
        do {
            let result = try PaletteExpression.evaluate(trimmed, unit: unit, variables: variables)
            error = nil
            if result != value { set(result) }
            text = shown(result)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ModelCommand {
    /// Zahl unter key, nil wenn leer (Feld „aus der Regel“)
    func optionalNumber(_ key: String) -> Double? {
        guard let text = values[key], !text.isEmpty else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    func putOptionalNumber(_ key: String, _ value: Double?) {
        if let value { putNumber(key, value) } else { values[key] = nil }
    }
}

/// Zeile für eine optionale Zahl des Befehls (`values[key]`), rechnet danach die Vorschau neu.
struct SheetCommandOptionalRow: View {
    let title: String
    @ObservedObject var cmd: ModelCommand
    let key: String
    var placeholder = "aus der Regel"
    var unit = "mm"
    let workspace: Workspace

    var body: some View {
        SheetOptionalValueRow(title: title, value: cmd.optionalNumber(key), placeholder: placeholder, unit: unit) { value in
            cmd.putOptionalNumber(key, value)
            CommandCache.refreshNow(cmd, workspace)
            workspace.objectWillChange.send()
        }
    }
}

/// Regelwahl „(aktive Regel)“ + Regeln des Projekts (SolidCraft `rule_combo`), `choices["rule"]`, leer = aktive.
struct SheetRuleMenuRow: View {
    @ObservedObject var cmd: ModelCommand
    @ObservedObject var document: SheetDocument
    let workspace: Workspace

    private var options: [SheetOption] {
        [SheetOption("", "(aktive Regel: \(document.activeRule.name))")] + document.rules.map { SheetOption($0.name, $0.name) }
    }

    var body: some View {
        SheetMenuRow(title: "Regel", options: options, selected: cmd.option("rule", default: "")) { id in
            cmd.choices["rule"] = id
            CommandCache.refreshNow(cmd, workspace)
            workspace.objectWillChange.send()
        }
    }
}

extension ModelCommand {
    /// Gewählte Regel (nil = aktive Regel)
    var sheetRuleName: String? {
        let name = choices["rule"] ?? ""
        return name.isEmpty ? nil : name
    }
}

// MARK: - Teilen-Dialog

/// Dateien über den Teilen-Dialog weitergeben (Sichern in Dateien, AirDrop, Mail …). Auf dem iPad braucht der Dialog
/// einen Ankerpunkt, sonst stürzt UIKit ab.
@MainActor
enum SheetShare {
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty, let root = topController() else { return }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = root.view
            let bounds = root.view.bounds
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(controller, animated: true)
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

// MARK: - Formate

enum SheetFormat {
    static func degrees(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "°"
    }

    static func length(_ value: Double) -> String {
        LengthUnit.current.format(value)
    }
}
