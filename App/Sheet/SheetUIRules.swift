import SwiftUI

// Blech › REGELN nach SolidCraft (dialogs_sheet.rs `Sm::Rules` mit Makro `rule_editor`, `sheet.rules`;
// COMMANDS.md §8–9):
// - Blechregeln: Regel wählen bzw. „Neue Regel…“ (Name, Vorschlag „Regel<n+1>“, Werte der aktiven Regel), dann Dicke,
//   K-Faktor, Biegeradius, Freistichbreite, Freistichtiefe, Form der Eckenentlastung, Eckenentlastung, Saumspalt,
//   Flanschspalt, Winkelanzeige, Aktive Regel; „Regel löschen“ bei vorhandener Regel. Leere Felder = Vorgabe der Engine.
//   OK speichert (ModelStore.setSheetRule – geänderte Regeln rechnen ihre Blechkörper neu).
// - Blechregeln auflisten: alle Regeln mit Werten, „Aktiv setzen“ und „Bearbeiten“.

// MARK: - Blechregeln

enum SheetRulesDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetRules
    static let title = "Blechregeln"
    static let icon = "sc.sheet_rules"
    static var explanation: String? {
        "Dicke, Biegeradius, K-Faktor und Freistiche. Neue Blechkörper nehmen die aktive Regel; eine geänderte Regel "
            + "rechnet alle Blechkörper mit dieser Regel neu."
    }

    /// choices["rule"]: Name der bearbeiteten Regel, „“ = neue Regel
    static let newRule = ""

    static let shapes = [SheetOption("notch", "Ausklinkung"), SheetOption("round", "Rund"),
                         SheetOption("rectangular", "Rechteckig"), SheetOption("tear", "Reißen")]
    static let angleDisplays = [CommandChoice(id: "bend", title: "Biegung"), CommandChoice(id: "included", title: "Enthalten")]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let cmd = ModelCommand(id, inputs: [])
        // Ohne Auswahlfelder läuft Antippen über das Auswahlwerkzeug (ModelCommands.usesLegacyTaps)
        load(ws.model.sheetDocument.activeRule, into: cmd, document: ws.model.sheetDocument)
        return cmd
    }

    /// Werte einer Regel in den Befehl übernehmen
    @MainActor static func load(_ rule: SheetRule, into cmd: ModelCommand, document: SheetDocument) {
        cmd.choices["rule"] = rule.name
        fill(rule, cmd, document: document)
    }

    /// „Neue Regel…“: Werte der aktiven Regel, Name „Regel<n+1>“ (SolidCraft „Rule<n+1>“)
    @MainActor static func startNew(_ cmd: ModelCommand, document: SheetDocument) {
        cmd.choices["rule"] = newRule
        var number = document.rules.count + 1
        while document.rule(named: "Regel\(number)") != nil { number += 1 }
        var rule = document.activeRule
        rule.name = "Regel\(number)"
        fill(rule, cmd, document: document)
        cmd.flags["active"] = false
    }

    @MainActor private static func fill(_ rule: SheetRule, _ cmd: ModelCommand, document: SheetDocument) {
        cmd.values["name"] = rule.name
        cmd.putNumber("thickness", rule.thickness)
        cmd.putNumber("kFactor", rule.kFactor)
        cmd.putOptionalNumber("bendRadius", rule.bendRadius)
        cmd.putOptionalNumber("reliefWidth", rule.reliefWidth)
        cmd.putOptionalNumber("reliefDepth", rule.reliefDepth)
        cmd.putOptionalNumber("cornerRelief", rule.cornerRelief)
        cmd.putOptionalNumber("hemGap", rule.hemGap)
        cmd.putOptionalNumber("gap", rule.gap)
        cmd.choices["shape"] = rule.cornerReliefShape ?? "notch"
        cmd.choices["angleDisplay"] = rule.angleDisplay ?? "bend"
        cmd.flags["active"] = document.activeRuleName == rule.name
    }

    /// Regel aus den Feldern
    @MainActor static func current(_ cmd: ModelCommand) -> SheetRule {
        let name = (cmd.values["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var rule = SheetRule(name: name, thickness: cmd.number("thickness", default: 2.5),
                             kFactor: cmd.number("kFactor", default: 0.44),
                             bendRadius: cmd.optionalNumber("bendRadius"))
        rule.reliefWidth = cmd.optionalNumber("reliefWidth")
        rule.reliefDepth = cmd.optionalNumber("reliefDepth")
        rule.cornerRelief = cmd.optionalNumber("cornerRelief")
        rule.hemGap = cmd.optionalNumber("hemGap")
        rule.gap = cmd.optionalNumber("gap")
        let shape = cmd.option("shape", default: "notch")
        rule.cornerReliefShape = shape
        rule.angleDisplay = cmd.option("angleDisplay", default: "bend")
        return rule
    }

    /// Prüfen wie SolidCraft (Name, Dicke > 0, K-Faktor 0…1, Radius ≥ 0); keine Vorschau
    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let rule = current(cmd)
        if rule.name.isEmpty { return "Der Regel einen Namen geben." }
        if rule.name.count > 128 { return "Der Name ist zu lang (höchstens 128 Zeichen)." }
        if cmd.option("rule", default: newRule) == newRule, ws.model.sheetDocument.rule(named: rule.name) != nil {
            return "Eine Regel „\(rule.name)“ gibt es schon."
        }
        if !(rule.thickness > 0) { return "Die Dicke muss größer als 0 sein." }
        if !(0...1).contains(rule.kFactor) { return "Der K-Faktor liegt zwischen 0 und 1." }
        if let radius = rule.bendRadius, radius < 0 { return "Der Biegeradius darf nicht negativ sein." }
        for (value, title) in [(rule.reliefWidth, "Freistichbreite"), (rule.reliefDepth, "Freistichtiefe"),
                               (rule.cornerRelief, "Eckenentlastung"), (rule.hemGap, "Saumspalt"), (rule.gap, "Flanschspalt")] {
            if let value, value < 0 { return "\(title) darf nicht negativ sein." }
        }
        return nil
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool { cmd.error == nil }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        let model = ws.model
        let rule = current(cmd)
        let old = cmd.option("rule", default: newRule)
        let active = cmd.isOn("active", default: false)
        model.setSheetRule(rule, active: active)
        // Umbenannt: neue Regel angelegt, die alte bleibt (Körper behalten ihre Kopie der Regel)
        LegacyFinish.cancel(ws)
        model.message = old != newRule && old != rule.name
            ? "Regel „\(rule.name)“ angelegt – „\(old)“ bleibt bestehen."
            : "Regel „\(rule.name)“ gespeichert."
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetRulesRows(cmd: cmd, workspace: ws, model: ws.model, document: ws.model.sheetDocument))
    }
}

private struct SheetRulesRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var document: SheetDocument

    private var options: [SheetOption] {
        document.rules.map { SheetOption($0.name, $0.name) } + [SheetOption(SheetRulesDriver.newRule, "Neue Regel…")]
    }

    private var isNew: Bool { cmd.option("rule", default: SheetRulesDriver.newRule) == SheetRulesDriver.newRule }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetMenuRow(title: "Regel", options: options,
                         selected: cmd.option("rule", default: SheetRulesDriver.newRule)) { id in
                if id == SheetRulesDriver.newRule {
                    SheetRulesDriver.startNew(cmd, document: document)
                } else if let rule = document.rule(named: id) {
                    SheetRulesDriver.load(rule, into: cmd, document: document)
                }
                CommandCache.refreshNow(cmd, workspace)
            }
            // Name nur bei „Neue Regel…“ (SolidCraft rule_editor, REVIEW 34)
            if isNew {
                nameRow
            } else {
                SheetInfoRow(title: "Name", text: cmd.values["name"] ?? "")
            }
            CommandNumberRow(title: "Dicke", cmd: cmd, key: "thickness", fallback: 2.5, workspace: workspace)
            CommandNumberRow(title: "K-Faktor", cmd: cmd, key: "kFactor", fallback: 0.44, unit: "", workspace: workspace)
            // Leer = „Thickness“ wie SolidCraft (folgt der Dicke, REVIEW 33)
            SheetCommandOptionalRow(title: "Biegeradius", cmd: cmd, key: "bendRadius", placeholder: "= Dicke",
                                    workspace: workspace)
            SheetCommandOptionalRow(title: "Freistichbreite", cmd: cmd, key: "reliefWidth", placeholder: "= Dicke",
                                    workspace: workspace)
            SheetCommandOptionalRow(title: "Freistichtiefe", cmd: cmd, key: "reliefDepth", placeholder: "= Dicke × 0,5",
                                    workspace: workspace)
            SheetMenuRow(title: "Form der Eckenentlastung", options: SheetRulesDriver.shapes,
                         selected: cmd.option("shape", default: "notch")) { id in
                cmd.choices["shape"] = id
                CommandCache.refreshNow(cmd, workspace)
            }
            SheetCommandOptionalRow(title: "Eckenentlastung", cmd: cmd, key: "cornerRelief", placeholder: "= Dicke × 4",
                                    workspace: workspace)
            SheetCommandOptionalRow(title: "Saumspalt", cmd: cmd, key: "hemGap", placeholder: "0,01 mm", workspace: workspace)
            SheetCommandOptionalRow(title: "Flanschspalt", cmd: cmd, key: "gap", placeholder: "= Dicke", workspace: workspace)
            CommandOptionRow(title: "Winkelanzeige", cmd: cmd, key: "angleDisplay", options: SheetRulesDriver.angleDisplays,
                             fallback: "bend", workspace: workspace)
            CommandFlagRow(title: "Aktive Regel", icon: "checkmark.seal", cmd: cmd, key: "active", workspace: workspace)
            if !isNew, document.rules.count > 1 {
                PrimaryWideButton(title: "Regel löschen", systemImage: "trash", isPrimary: false) {
                    let name = cmd.option("rule", default: SheetRulesDriver.newRule)
                    model.deleteSheetRule(name)
                    SheetRulesDriver.load(document.activeRule, into: cmd, document: document)
                    CommandCache.refreshNow(cmd, workspace)
                    model.message = "Regel „\(name)“ gelöscht – Blechkörper behalten ihre Werte."
                }
                .accessibilityLabel("Regel löschen")
            }
            PaletteHint(text: "Leere Felder: Vorgabe aus der Dicke.")
        }
    }

    private var nameRow: some View {
        PaletteLabeled(title: "Name") {
            PaletteFieldBox(isLocked: false, hasError: (cmd.values["name"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty) {
                TextField("Name", text: Binding(get: { cmd.values["name"] ?? "" }, set: { cmd.values["name"] = $0 }))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { CommandCache.refreshNow(cmd, workspace) }
            }
        }
        .onChange(of: cmd.values["name"]) { _, _ in
            CommandCache.refreshNow(cmd, workspace)
        }
    }
}

// MARK: - Blechregeln auflisten

enum SheetRuleListDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetRuleList
    static let title = "Blechregeln auflisten"
    static let icon = "sc.sheet_rules"
    static var explanation: String? { "Alle Blechregeln des Projekts mit ihren Werten; die aktive ist markiert." }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        ModelCommand(id, inputs: [])
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? { nil }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool { true }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        LegacyFinish.cancel(ws)
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetRuleListRows(workspace: ws, model: ws.model, document: ws.model.sheetDocument))
    }
}

private struct SheetRuleListRows: View {
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var document: SheetDocument

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetInfoRow(title: "Aktive Regel", text: document.activeRuleName)
            ForEach(document.rules) { rule in
                row(rule)
            }
            PrimaryWideButton(title: "Neue Regel…", systemImage: "plus", isPrimary: false) {
                SheetUI.start(.sheetRules, workspace)
                if let cmd = workspace.command, cmd.id == .sheetRules {
                    SheetRulesDriver.startNew(cmd, document: document)
                    CommandCache.refreshNow(cmd, workspace)
                }
            }
        }
    }

    private func row(_ rule: SheetRule) -> some View {
        let isActive = rule.name == document.activeRuleName
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(rule.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            Text(values(rule))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PaletteStyle.spacing) {
                if !isActive {
                    PrimaryWideButton(title: "Aktiv", systemImage: "checkmark", isPrimary: false) {
                        model.setActiveSheetRule(rule.name)
                    }
                    .accessibilityLabel("\(rule.name) aktiv setzen")
                }
                PrimaryWideButton(title: "Bearbeiten", systemImage: "pencil", isPrimary: false) {
                    SheetUI.start(.sheetRules, workspace)
                    if let cmd = workspace.command, cmd.id == .sheetRules {
                        SheetRulesDriver.load(rule, into: cmd, document: document)
                        CommandCache.refreshNow(cmd, workspace)
                    }
                }
                .accessibilityLabel("\(rule.name) bearbeiten")
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius))
    }

    /// „Dicke 2,5 mm · K 0,44 · R 2,5 mm …“
    private func values(_ rule: SheetRule) -> String {
        var parts = ["Dicke \(SheetFormat.length(rule.thickness))",
                     "K \(rule.kFactor.formatted(.number.precision(.fractionLength(0...3))))",
                     "R \(SheetFormat.length(rule.effectiveBendRadius))"]
        if let gap = rule.gap { parts.append("Spalt \(SheetFormat.length(gap))") }
        if let shape = rule.cornerReliefShape, let title = SheetRulesDriver.shapes.first(where: { $0.id == shape })?.title {
            parts.append("Ecke \(title)")
        }
        return parts.joined(separator: " · ")
    }
}
