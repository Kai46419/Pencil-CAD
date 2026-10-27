import SwiftUI

// Blech › ABWICKLUNG und AUSGABE nach SolidCraft (dialogs_sheet.rs `Sm::Unfold`, `Sm::Refold`, `Sm::FlatPattern`;
// SheetKit/COMMANDS.md §6, §10–12):
// - Entfalten / Wieder falten: Auswahl „Körper (letzter, wenn keiner)“, sonst keine Zeilen; Vorschau im Ansichtsfenster.
// - Flachmuster erstellen: keine Vorschau im Modell; die 2D-Ansicht (FlatPatternView.swift) ersetzt das Ansichtsfenster,
//   das Panel zeigt Körper, Abwicklungsgröße, Biegungen (Auf/Ab, Winkel, Radius) und die Exporte (Teilen-Dialog).

// MARK: - Gemeinsam

@MainActor
enum SheetBodyPick {
    static let input = "body"

    static func make(_ ws: Workspace) -> PickInput {
        let pre = Preselection(ws.model)
        let picked = pre.anyBodies.filter { ws.model.isSheetBody($0) }.prefix(1).map { Pick.body($0) }
        return PickInput(id: input, title: "Körper (letzter, wenn keiner)", accepts: [.bodies, .faces],
                         multiple: false, items: picked, hint: "Blechkörper antippen.", isOptional: true)
    }

    /// Gewählter Blechkörper bzw. der letzte passende; Fehlertext, wenn der gewählte kein Blechkörper ist.
    static func body(_ cmd: ModelCommand, _ model: ModelStore, where accept: (Int) -> Bool = { _ in true })
        -> (body: Int?, error: String?) {
        if let picked = CommandPicks.bodies(cmd, input, model: model).first {
            guard model.isSheetBody(picked) else { return (nil, "Das ist kein Blechkörper.") }
            return (picked, nil)
        }
        if let last = model.sheetBodies.last(where: accept) { return (last, nil) }
        return (nil, nil)
    }
}

// MARK: - Entfalten / Wieder falten

/// Entfalten (unfold = true) bzw. Wieder falten: ein Schritt im Rezept des Blechkörpers.
@MainActor
enum SheetFoldState {
    static func refresh(_ cmd: ModelCommand, _ ws: Workspace, unfold: Bool) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        // Ohne Wahl: Entfalten nimmt den letzten gefalteten, Wieder falten den letzten entfalteten Blechkörper
        let found = SheetBodyPick.body(cmd, model) { body in model.sheetInfo(body)?.isUnfolded == !unfold }
        if let error = found.error {
            model.dropPreview()
            return error
        }
        guard let body = found.body else {
            model.dropPreview()
            return unfold ? "Kein gefalteter Blechkörper im Projekt." : "Kein entfalteter Blechkörper im Projekt."
        }
        guard model.sheetInfo(body)?.isUnfolded != unfold else {
            model.dropPreview()
            return unfold ? "„\(model.bodies[body].name)“ ist schon entfaltet."
                : "„\(model.bodies[body].name)“ ist nicht entfaltet."
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        if model.appendSheetCommand(unfold ? .unfold : .refold, to: body, preview: true) { return nil }
        return SheetPick.failure(model, unfold ? "Entfalten nicht möglich." : "Wieder falten nicht möglich.")
    }

    /// Körper, der gerade gemeint ist (Panelzeile)
    static func shownBody(_ cmd: ModelCommand, _ model: ModelStore, unfold: Bool) -> String {
        let found = SheetBodyPick.body(cmd, model) { body in model.sheetInfo(body)?.isUnfolded == !unfold }
        guard let body = found.body, model.bodies.indices.contains(body) else { return "–" }
        return model.bodies[body].name
    }
}

enum SheetUnfoldDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetUnfold
    static let title = "Entfalten"
    static let icon = "sc.unfold"
    static var explanation: String? { "Alle Biegungen des Blechkörpers flach legen (Wieder falten macht es rückgängig)." }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let cmd = ModelCommand(id, inputs: [SheetBodyPick.make(ws)])
        ws.model.resetSelection()
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        SheetFoldState.refresh(cmd, ws, unfold: true)
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetFoldStateRows(cmd: cmd, workspace: ws, model: ws.model, unfold: true))
    }
}

enum SheetRefoldDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetRefold
    static let title = "Wieder falten"
    static let icon = "sc.refold"
    static var explanation: String? { "Einen entfalteten Blechkörper wieder in seine gebogene Form bringen." }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let cmd = ModelCommand(id, inputs: [SheetBodyPick.make(ws)])
        ws.model.resetSelection()
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        SheetFoldState.refresh(cmd, ws, unfold: false)
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetFoldStateRows(cmd: cmd, workspace: ws, model: ws.model, unfold: false))
    }
}

private struct SheetFoldStateRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    let unfold: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetInfoRow(title: "Körper", text: SheetFoldState.shownBody(cmd, model, unfold: unfold))
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

// MARK: - Flachmuster erstellen

enum SheetFlatPatternDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetFlatPattern
    static let title = "Flachmuster erstellen"
    static let icon = "sc.flat"
    static var explanation: String? {
        "Abwicklung des Blechkörpers mit Biegelinien (auf/ab) und Biegetabelle. Export als DXF (Laser) bzw. CSV."
    }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let cmd = ModelCommand(id, inputs: [SheetBodyPick.make(ws)])
        cmd.flags["bendNotes"] = false
        cmd.flags["bendLines"] = true
        cmd.flags["singleLayer"] = false
        cmd.flags["etchText"] = false
        cmd.flags["exactCurves"] = true
        ws.model.resetSelection()
        return cmd
    }

    /// Flachmuster rechnen (nur bei anderem Körper bzw. geänderter Form); keine Vorschau im Modell.
    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let state = SheetCommandState.of(cmd)
        model.dropPreview()
        guard model.sheetAvailable else {
            state.flat = nil
            state.flatError = model.sheetUnavailableReason
            return model.sheetUnavailableReason
        }
        let found = SheetBodyPick.body(cmd, model)
        if let error = found.error {
            state.flat = nil
            state.flatError = error
            state.flatKey = nil
            return error
        }
        guard let body = found.body, model.bodies.indices.contains(body) else {
            state.flat = nil
            state.flatError = "kein Blechkörper"
            state.flatKey = nil
            return nil
        }
        let key = "\(body)#\(ObjectIdentifier(model.bodies[body].shape).hashValue)"
        if state.flatKey == key { return state.flatError }
        state.flatKey = key
        do {
            state.flat = try model.flatPattern(of: body)
            state.flatError = nil
        } catch {
            state.flat = nil
            state.flatError = error.localizedDescription
        }
        return state.flatError
    }

    /// Kein Modellschritt: OK schließt nur
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool { true }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.cancel(ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.cancel(ws)
    }

    /// Körper des Flachmusters (für die Exporte)
    @MainActor static func body(_ cmd: ModelCommand, _ model: ModelStore) -> Int? {
        SheetBodyPick.body(cmd, model).body
    }

    @MainActor static func options(_ cmd: ModelCommand) -> SheetDXFOptions {
        var options = SheetDXFOptions()
        options.exactCurves = cmd.isOn("exactCurves", default: true)
        options.bendNotes = cmd.isOn("bendNotes", default: false)
        options.bendLines = cmd.isOn("bendLines", default: true)
        options.singleLayer = cmd.isOn("singleLayer", default: false)
        options.etchText = cmd.isOn("etchText", default: false)
        return options
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetFlatRows(cmd: cmd, workspace: ws, model: ws.model, state: SheetCommandState.of(cmd)))
    }
}

/// Panel wie SolidCraft `Sm::FlatPattern`: Körper, Abwicklungsgröße, Biegungen (je Zeile „Biegung N · Auf 90° R2,5“
/// in Biegefarbe), Exporte; DXF-Einstellungen aufklappbar.
private struct SheetFlatRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var state: SheetCommandState

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            if let body = SheetFlatPatternDriver.body(cmd, model), model.bodies.indices.contains(body) {
                SheetInfoRow(title: "Körper", text: model.bodies[body].name)
            }
            if let flat = state.flat {
                SheetInfoRow(title: "Abwicklungsgröße", text: FlatPatternFormat.size(flat))
                SheetInfoRow(title: "Biegungen", text: "\(flat.bends.count)")
                ForEach(flat.bends.prefix(50)) { bend in
                    HStack(spacing: 4) {
                        Text("Biegung \(bend.index)")
                            .font(.caption)
                        Spacer(minLength: 0)
                        Text(FlatPatternFormat.bend(bend))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(FlatPatternColors.bend(up: bend.up))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .combine)
                }
                if flat.perforationCount > 0 {
                    SheetInfoRow(title: "Perforation", text: "\(flat.perforationCount) Löcher")
                }
            } else if let error = state.flatError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(SketchTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryWideButton(title: "DXF exportieren…", systemImage: "square.and.arrow.up", isPrimary: true) {
                SheetUI.exportDXF(workspace, options: SheetFlatPatternDriver.options(cmd),
                                  body: SheetFlatPatternDriver.body(cmd, model))
            }
            .disabled(state.flat == nil)
            PrimaryWideButton(title: "Biegetabelle exportieren…", systemImage: "tablecells", isPrimary: false) {
                SheetUI.exportBendTable(workspace, body: SheetFlatPatternDriver.body(cmd, model))
            }
            .disabled(state.flat == nil)
            CommandSection("DXF", command: SheetFlatPatternDriver.id, section: "dxf", expanded: false) {
                CommandFlagRow(title: "Exakte Kurven", icon: "point.topleft.down.to.point.bottomright.curvepath", cmd: cmd,
                               key: "exactCurves", fallback: true, workspace: workspace)
                CommandFlagRow(title: "Biegelinien", icon: "line.diagonal", cmd: cmd, key: "bendLines", fallback: true,
                               workspace: workspace)
                CommandFlagRow(title: "Biegenotizen", icon: "text.alignleft", cmd: cmd, key: "bendNotes",
                               workspace: workspace)
                CommandFlagRow(title: "Text gravieren", icon: "textformat", cmd: cmd, key: "etchText", workspace: workspace)
                CommandFlagRow(title: "Ein Layer", icon: "square.3.layers.3d.down.right", cmd: cmd, key: "singleLayer",
                               workspace: workspace)
            }
        }
    }
}

/// Texte des Flachmusters (Panel und 2D-Ansicht)
enum FlatPatternFormat {
    /// „w × h × t“ mit einer Nachkommastelle (SolidCraft)
    static func size(_ flat: FlatPattern) -> String {
        let unit = LengthUnit.current
        return "\(unit.number(flat.size.x)) × \(unit.number(flat.size.y)) × \(unit.number(flat.thickness)) \(unit.symbol)"
    }

    /// „Auf 90° R2,5“ (SolidCraft „Up/Down 90.0°  R2.5“)
    static func bend(_ bend: FlatBend) -> String {
        "\(bend.up ? "Auf" : "Ab") \(SheetFormat.degrees(bend.angle)) R\(LengthUnit.current.number(bend.radius))"
    }
}
