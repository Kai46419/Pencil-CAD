import SwiftUI

// Bearbeiten aus der Zeitleiste (REVIEW 25, SolidCraft: jeder Blechdialog bearbeitet sein Feature): Doppeltippen auf ein
// Blech-Feature öffnet das Panel seines Befehls mit den Werten aus dem Rezept (ModelStore.sheetStep(for:)). OK schreibt
// nur die geänderten Werte in den Schritt zurück (updateSheetStep – ein Undo-Schritt, Nachbau ab dem Feature).
// Geometrie (Kanten, Linien, Bereiche, Weitere Biegungen, Pro-Kante-Werte) bleibt, wie sie aufgezeichnet wurde.
// „In Blech umwandeln“, Entfalten und Wieder falten haben keine Panelwerte: dort bleibt der Zahlen-Editor der Zeitleiste.

/// Änderbarer Wert eines Blechschritts (Schlüssel im SolidCraft-Befehl)
struct SheetEditField {
    enum Kind {
        case length(Double)
        case angle(Double)
        case optionalLength(String)
        case choice([SheetOption], String)
        case flag
    }

    let param: String
    let title: String
    let kind: Kind
}

@MainActor
enum SheetEdit {
    /// Felder je Schritt; nil = nicht im Panel bearbeitbar
    static func fields(_ command: SheetCommand) -> [SheetEditField]? {
        let p = command.params
        switch command.command {
        case "sheet.flange":
            let type = p["type"]?.asString ?? (p["edges"] != nil ? "edge" : p["curves"] != nil ? "contour" : "base")
            switch type {
            case "edge":
                return [
                    SheetEditField(param: "height", title: "Höhe", kind: .length(10)),
                    SheetEditField(param: "angle", title: "Winkel", kind: .angle(90)),
                    SheetEditField(param: "position", title: "Biegeposition",
                                   kind: .choice(SheetFlangeDriver.positions, "inside")),
                    SheetEditField(param: "height_from", title: "Höhe ab",
                                   kind: .choice(SheetFlangeDriver.heightFrom, "outer")),
                    SheetEditField(param: "radius", title: "Biegeradius", kind: .optionalLength("aus der Regel")),
                    SheetEditField(param: "corner_relief_shape", title: "Form der Eckenentlastung",
                                   kind: .choice(SheetFlangeDriver.reliefShapes, "")),
                    SheetEditField(param: "corner_relief", title: "Eckenentlastung", kind: .optionalLength("aus der Regel")),
                    SheetEditField(param: "flip", title: "Umkehren", kind: .flag),
                ]
            case "contour":
                return [
                    SheetEditField(param: "distance", title: "Abstand", kind: .length(20)),
                    SheetEditField(param: "flip", title: "Umkehren", kind: .flag),
                    SheetEditField(param: "reverse", title: "Andere Seite", kind: .flag),
                ]
            default:
                return [SheetEditField(param: "flip", title: "Umkehren", kind: .flag)]
            }
        case "sheet.path_flange":
            return [SheetEditField(param: "radius", title: "Biegeradius", kind: .optionalLength("aus der Regel"))]
        case "sheet.hem":
            return [
                SheetEditField(param: "length", title: "Länge", kind: .length(5)),
                SheetEditField(param: "gap", title: "Spalt", kind: .optionalLength("aus der Regel")),
                SheetEditField(param: "flip", title: "Umkehren", kind: .flag),
            ]
        case "sheet.fold":
            return [
                SheetEditField(param: "position", title: "Position der Biegelinie",
                               kind: .choice(SheetFoldDriver.positions, "centerline")),
                SheetEditField(param: "angle", title: "Winkel", kind: .angle(90)),
                SheetEditField(param: "radius", title: "Biegeradius", kind: .optionalLength("aus der Regel")),
                SheetEditField(param: "flip", title: "Umkehren", kind: .flag),
            ]
        case "sheet.perforate":
            return [
                SheetEditField(param: "diameter", title: "Durchmesser", kind: .length(3)),
                SheetEditField(param: "pitch", title: "Teilung", kind: .length(6)),
                SheetEditField(param: "margin", title: "Rand", kind: .optionalLength("wie Durchmesser")),
                SheetEditField(param: "pattern", title: "Muster",
                               kind: .choice([SheetOption("staggered", "Versetzt (60°)"), SheetOption("square", "Quadratisch")],
                                             "staggered")),
            ]
        default:
            return nil
        }
    }

    /// Feature öffnen, wenn sein Hauptschritt einer der Befehle `commands` ist (sonst nil: nächster Treiber).
    static func load(_ feature: Feature, into ws: Workspace, id: ModelCommandID, commands: Set<String>) -> ModelCommand? {
        guard feature.kind == .sheetMetal, let found = ws.model.sheetStep(for: feature),
              commands.contains(found.step.command.command), let fields = fields(found.step.command) else { return nil }
        let cmd = ModelCommand(id, inputs: [])
        cmd.editing = feature.id
        let state = SheetCommandState.of(cmd)
        state.editBody = found.body
        state.editStep = found.step
        let p = found.step.command.params
        for field in fields {
            let key = "edit.\(field.param)"
            switch field.kind {
            case .length(let fallback), .angle(let fallback):
                cmd.putNumber(key, ModelStore.sheetNumber(p[field.param]) ?? fallback)
            case .optionalLength:
                cmd.putOptionalNumber(key, ModelStore.sheetNumber(p[field.param]))
            case .choice(_, let fallback):
                cmd.choices[key] = p[field.param]?.asString ?? fallback
            case .flag:
                cmd.flags[key] = p[field.param]?.asBool ?? false
            }
        }
        // Ausgangsstand merken: nur Geändertes zurückschreiben (Ausdrücke im Rezept bleiben sonst unberührt)
        state.editOriginal = signature(cmd)
        return cmd
    }

    private static func signature(_ cmd: ModelCommand) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in cmd.values where key.hasPrefix("edit.") { result["v" + key] = value }
        for (key, value) in cmd.choices where key.hasPrefix("edit.") { result["c" + key] = value }
        for (key, value) in cmd.flags where key.hasPrefix("edit.") { result["f" + key] = value ? "1" : "0" }
        return result
    }

    /// OK beim Bearbeiten: geänderte Werte in den Schritt schreiben, Verlauf ab dort neu
    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        let model = ws.model
        let state = SheetCommandState.of(cmd)
        defer { SheetCommandState.forget(cmd) }
        guard let body = state.editBody, let step = state.editStep, let fields = fields(step.command) else { return }
        let original = state.editOriginal
        let now = signature(cmd)
        var params = step.command.params
        var changed = false
        for field in fields {
            let key = "edit.\(field.param)"
            switch field.kind {
            case .length:
                guard now["v" + key] != original["v" + key] else { continue }
                params[field.param] = .number(cmd.number(key, default: 0))
            case .angle:
                guard now["v" + key] != original["v" + key] else { continue }
                params[field.param] = SheetCommand.degrees(cmd.number(key, default: 0))
            case .optionalLength:
                guard now["v" + key] != original["v" + key] else { continue }
                params[field.param] = cmd.optionalNumber(key).map { SheetJSON.number($0) }
            case .choice:
                guard now["c" + key] != original["c" + key] else { continue }
                let value = cmd.option(key, default: "")
                params[field.param] = value.isEmpty ? nil : SheetJSON.string(value)
            case .flag:
                guard now["f" + key] != original["f" + key] else { continue }
                params[field.param] = .bool(cmd.isOn(key, default: false))
            }
            changed = true
        }
        guard changed else { return }
        var command = step.command
        command.params = params
        if !model.updateSheetStep(body: body, step: step.id, command: command) {
            model.message = SheetPick.failure(model, "Dieser Schritt lässt sich mit diesen Werten nicht nachbauen.")
        }
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetEditRows(cmd: cmd, model: ws.model, state: SheetCommandState.of(cmd)))
    }
}

/// Panel beim Bearbeiten: dieselben Beschriftungen wie beim Erstellen, nur die Werte des Schritts
private struct SheetEditRows: View {
    @ObservedObject var cmd: ModelCommand
    @ObservedObject var model: ModelStore
    @ObservedObject var state: SheetCommandState

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            if let step = state.editStep, let fields = SheetEdit.fields(step.command) {
                SheetInfoRow(title: "Schritt", text: step.title)
                ForEach(fields.indices, id: \.self) { index in
                    row(fields[index])
                }
                PaletteHint(text: "Kanten, Linien und Bereiche bleiben wie aufgezeichnet. OK rechnet den Verlauf ab hier neu.")
            } else {
                PaletteHint(text: "Dieser Blechschritt ist nicht mehr im Modell.")
            }
        }
    }

    @ViewBuilder private func row(_ field: SheetEditField) -> some View {
        let key = "edit.\(field.param)"
        switch field.kind {
        case .length(let fallback):
            PaletteNumberRow(title: field.title, value: cmd.number(key, default: fallback)) { value in
                cmd.putNumber(key, max(0.01, value))
            }
        case .angle(let fallback):
            PaletteNumberRow(title: field.title, value: cmd.number(key, default: fallback), unit: "°") { value in
                cmd.putNumber(key, value)
            }
        case .optionalLength(let placeholder):
            SheetOptionalValueRow(title: field.title, value: cmd.optionalNumber(key), placeholder: placeholder) { value in
                cmd.putOptionalNumber(key, value)
            }
        case .choice(let options, let fallback):
            SheetMenuRow(title: field.title, options: options, selected: cmd.option(key, default: fallback)) { id in
                cmd.choices[key] = id
            }
        case .flag:
            CheckRow(title: field.title, icon: "arrow.left.arrow.right", isOn: Binding(get: {
                cmd.isOn(key, default: false)
            }, set: { value in
                cmd.flags[key] = value
            }))
        }
    }
}

// MARK: - Treiber, die ihr Feature bearbeiten

/// Blechtreiber mit Bearbeiten aus der Zeitleiste: Hauptschritt mit einem dieser SolidCraft-Befehle.
/// Ersetzt die allgemeinen Vorgaben von MainCommandDriver (FeatureEdit mit Feature-Parametern).
@MainActor
protocol SheetEditableDriver: MainCommandDriver {
    static var sheetCommands: Set<String> { get }
}

extension SheetEditableDriver {
    static var featureKinds: [FeatureKind] { [.sheetMetal] }

    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        SheetEdit.load(feature, into: ws, id: id, commands: sheetCommands)
    }

    @MainActor static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        cmd.editing != nil ? SheetEdit.rows(cmd, ws) : panel(cmd, ws)
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        if cmd.editing != nil {
            SheetEdit.commit(cmd, ws)
        } else {
            finish(cmd, ws)
        }
        SheetCommandState.forget(cmd)
        CommandCache.forget(cmd)
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        if cmd.editing == nil { abort(cmd, ws) }
        SheetCommandState.forget(cmd)
        CommandCache.forget(cmd)
    }
}
