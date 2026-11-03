import SwiftUI

// Eigenschaften-Panel im Modellmodus nach SolidCraft (MIT, crates/ui-egui/src/dialogs.rs:2747-2990 Rahmen,
// dialogs_dense.rs Zeilen, docs/design/ux-redesign/model-floating.png). Kai: „Werkzeug angeklickt, und auf der
// rechten Seite kommen die Eigenschaften der Werkzeuge zu stehen.“
// Aufbau: Kopf (Symbol, Titel bzw. „… bearbeiten“, ⓘ, Menü, ×) · Auswahlfelder mit Hinweis · Werte und Abschnitte
// des Treibers · Fehlerzeile · fester Fuß Abbrechen · OK. Dieselben Bausteine, Farben und dieselbe Breite wie die
// Skizzenpalette (SketchPaletteControls.swift), damit Skizzen- und Modellmodus gleich aussehen.

/// Rechtes Fenster eines offenen Modellbefehls (`workspace.command`): dieselbe schlanke Form wie im
/// Skizzenmodus – oben Ansichtswürfel, Fang und Raster (und der große Haken bzw. das Kreuz), darunter der Befehl.
struct FeaturePanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var command: ModelCommand
    @Binding var panel: SidePanel?
    let screenshot: () -> Void

    @State private var showsInfo = false
    @AppStorage(CornerConfirm.storageKey) private var cornerConfirm = true

    private var driver: ModelCommandDriver.Type? { ModelCommands.driver(command.id) }

    var body: some View {
        PaletteWindow {
            VStack(spacing: 8) {
                PaletteViewControls(workspace: workspace, sketch: workspace.sketch, panel: $panel, screenshot: screenshot)
                // Großer Haken und großes Kreuz unter dem Ansichtswürfel (CornerConfirm.swift)
                CornerConfirm(workspace: workspace, model: model, command: command)
            }
        } header: {
            header
        } middle: {
            middle
        } footer: {
            footer
        }
        .background { keyboardShortcuts }
    }

    // MARK: Kopf

    private var title: String {
        let name = driver?.title ?? command.id.rawValue
        guard let id = command.editing else { return name }
        let featureName = model.features.first { $0.id == id }?.name ?? name
        return "\(featureName) bearbeiten"
    }

    /// Symbol und Knöpfe (ⓘ, Menü, ×) in einer Zeile, der Titel darunter – nebeneinander passt es nicht.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                ToolIcon(driver?.icon ?? "sc.select", size: 20)
                Spacer(minLength: 0)
                headerButtons
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if command.editing != nil {
                Text("Verlauf · Werte ändern, OK baut neu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var headerButtons: some View {
        if let text = driver?.explanation {
            Button {
                showsInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: PaletteStyle.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Erklärung")
            .popover(isPresented: $showsInfo) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: 300)
            }
        }
        Menu {
            Toggle(isOn: previewBinding) {
                Label("Vorschau", systemImage: "eye")
            }
            Toggle(isOn: $cornerConfirm) {
                Label("OK und Abbrechen in der Ecke", systemImage: "checkmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: PaletteStyle.iconButton)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Einstellungen des Panels")
        Button {
            workspace.cancelCommand()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: PaletteStyle.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abbrechen")
    }

    /// Schalter „Vorschau“ (SolidCraft `preview_enabled`): aus = erst bei OK rechnen
    private var previewBinding: Binding<Bool> {
        Binding(get: { command.previewEnabled }, set: { on in
            command.previewEnabled = on
            if on {
                workspace.refreshCommandPreview()
            } else {
                model.dropPreview()
            }
        })
    }

    // MARK: Mitte

    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !command.inputs.isEmpty {
                VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                    ForEach(command.inputs.indices, id: \.self) { index in
                        PickChip(input: command.inputs[index], isActive: index == command.activeInput, model: model,
                                 activate: { workspace.activateCommandInput(index) },
                                 clear: { workspace.clearCommandInput(index) })
                    }
                    if command.inputs.indices.contains(command.activeInput) {
                        PaletteHint(text: command.inputs[command.activeInput].hint)
                    }
                }
                PaletteRule()
            }
            if let driver {
                driver.rows(command, workspace)
            }
            if let error = command.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(SketchTheme.error)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if command.previewSeconds > 0.8 {
                // SolidCraft „Rechnet … 3 s“: die Vorschau läuft hier im Hauptthread, daher die letzte Dauer
                Label("Vorschau rechnet \(command.previewSeconds.formatted(.number.precision(.fractionLength(1)))) s",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Fuß

    /// Abbrechen · (Übernehmen) · OK; bei drei Knöpfen die ersten beiden nur als Symbol (schmales Fenster).
    private var footer: some View {
        let canCommit = workspace.canConfirmCommand
        let repeatable = driver?.repeatable == true && command.editing == nil
        return HStack(spacing: PaletteStyle.spacing) {
            PrimaryWideButton(title: "Abbrechen", systemImage: repeatable ? "xmark" : nil, isPrimary: false,
                              showsTitle: !repeatable) {
                workspace.cancelCommand()
            }
            .hoverTip("Abbrechen", "Nichts wird geändert (Esc).")
            if repeatable {
                PrimaryWideButton(title: "Übernehmen", systemImage: "plus.square.on.square", isPrimary: false,
                                  showsTitle: false) {
                    workspace.confirmCommand(keepOpen: true)
                }
                .disabled(!canCommit)
                .opacity(canCommit ? 1 : 0.45)
                .hoverTip("Übernehmen", "Ergebnis anlegen und den Befehl für das nächste offen lassen.")
            }
            PrimaryWideButton(title: "OK", systemImage: "checkmark") {
                workspace.confirmCommand()
            }
            .disabled(!canCommit)
            .opacity(canCommit ? 1 : 0.45)
        }
    }

    /// Enter = OK, Esc = Abbrechen (SolidCraft `docs/ui-kit.md:130`), auch mit Hardware-Tastatur am iPad.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("OK") { workspace.confirmCommand() }
                .keyboardShortcut(.defaultAction)
            Button("Abbrechen") { workspace.cancelCommand() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Bausteine der Panelzeilen

/// Eine Wahl in einer Segmentzeile.
struct SegmentOption: Identifiable {
    let id: String
    let label: String
}

/// Segmente mit Text (SolidCraft `ui_kit::segmented`), 32 pt hoch; Titel darüber, damit die Segmente die ganze
/// Breite haben.
struct PanelSegmentRow: View {
    let title: String?
    let options: [SegmentOption]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Kurze Wahlen in einer Reihe, längere zu zweit umbrechend (schmales Fenster)
            LazyVGrid(columns: paletteSegmentColumns(options.map(\.label)), spacing: 3) {
                ForEach(options) { option in
                    segment(option)
                }
            }
            .padding(3)
            .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                    .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
            }
        }
    }

    private func segment(_ option: SegmentOption) -> some View {
        let isSelected = option.id == selected
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius - 2, style: .continuous)
        return Button {
            pick(option.id)
        } label: {
            Text(option.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 2)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton - 4)
                .background(isSelected ? SketchTheme.accent : Color.clear, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Wertzeile eines Befehls: Ausdrucksfeld wie die Skizzenpalette (Variablen, Einheit), dazu Fokus von außen
/// (Antippen des Werts am Pfeil im Viewport setzt `command.focusKey`).
struct CommandValueRow: View {
    let title: String
    let key: String
    @ObservedObject var command: ModelCommand
    var unit = "mm"
    let value: Double
    let set: (Double) -> Void

    @Environment(\.variableValues) private var variables
    @State private var text = ""
    @State private var error: String?
    /// Ziffernblock offen bzw. Textfeld aktiv (statt der großen Bildschirmtastatur)
    @State private var isEditing = false

    var body: some View {
        PaletteLabeled(title: title) {
            PaletteFieldBox(isLocked: false, hasError: error != nil) {
                KeypadField(title: title, text: $text, isEditing: $isEditing,
                            unitSymbol: PaletteExpression.unitSymbol(unit), step: stepped, onCommit: commit)
                    .onChange(of: value) { _, newValue in
                        if !isEditing { text = PaletteExpression.shown(newValue, unit: unit) }
                    }
                    .onAppear {
                        text = PaletteExpression.shown(value, unit: unit)
                        takeFocusIfRequested(command.focusKey)
                    }
                if !unit.isEmpty {
                    Text(PaletteExpression.unitSymbol(unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .help(error ?? "")
        .onChange(of: command.focusKey) { _, requested in
            takeFocusIfRequested(requested)
        }
    }

    private func takeFocusIfRequested(_ requested: String?) {
        guard requested == key else { return }
        isEditing = true
        command.focusKey = nil
    }

    /// Schritt um eine Einheit (Länge: eine Projekteinheit) vom eingegebenen Wert aus
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
            text = PaletteExpression.shown(value, unit: unit)
            error = nil
            return
        }
        do {
            let result = try PaletteExpression.evaluate(trimmed, unit: unit, variables: variables)
            error = nil
            if result != value { set(result) }
            text = PaletteExpression.shown(result, unit: unit)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Aufklappbarer Abschnitt (OPTIONEN, ERWEITERT); der Zustand wird je Werkzeug gemerkt
/// (UserDefaults „panel.<Werkzeug>.<Abschnitt>“). forceOpen: belegte Abschnitte öffnen sich (SolidCraft).
struct CommandSection<Content: View>: View {
    let title: String
    let storageKey: String
    let content: Content
    @State private var isExpanded: Bool

    init(_ title: String, command: ModelCommandID, section: String, expanded: Bool = true, forceOpen: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        storageKey = "panel.\(command.rawValue).\(section)"
        self.content = content()
        let stored = UserDefaults.standard.object(forKey: "panel.\(command.rawValue).\(section)") as? Bool
        _isExpanded = State(initialValue: forceOpen || (stored ?? expanded))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            Button {
                withAnimation(Theme.snappy) { isExpanded.toggle() }
                UserDefaults.standard.set(isExpanded, forKey: storageKey)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: PaletteStyle.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Aufgeklappt" : "Zugeklappt")
            if isExpanded {
                content
            }
        }
    }
}

/// Auswahlliste mit Beschriftung (für lange Listen wie Skizzen, Achsen, Vorlagen).
struct PanelMenuRow<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: Content

    var body: some View {
        PaletteLabeled(title: title) {
            Menu {
                content
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton)
                .background(PaletteStyle.field,
                            in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                        .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Gemeinsame Auswahlen

/// Operation (SolidCraft „Neuer Körper · Verbinden · Schneiden · Schnittmenge“) auf ExtrudeMode.
enum CommandOperation {
    static let options: [SegmentOption] = [
        SegmentOption(id: ExtrudeMode.newBody.rawValue, label: "Neu"),
        SegmentOption(id: ExtrudeMode.union.rawValue, label: "Verbinden"),
        SegmentOption(id: ExtrudeMode.cut.rawValue, label: "Schneiden"),
        SegmentOption(id: ExtrudeMode.intersect.rawValue, label: "Schnitt"),
    ]

    static func mode(_ cmd: ModelCommand, default fallback: ExtrudeMode = .newBody) -> ExtrudeMode {
        ExtrudeMode(rawValue: cmd.choice("operation", default: fallback.rawValue)) ?? fallback
    }

    /// Zeile „Operation“; eine Wahl von Hand beendet die Automatik
    @MainActor
    static func row(_ cmd: ModelCommand, _ ws: Workspace, default fallback: ExtrudeMode = .newBody) -> some View {
        PanelSegmentRow(title: "Operation", options: options, selected: mode(cmd, default: fallback).rawValue) { id in
            cmd.choices["operation"] = id
            cmd.autoOperation = false
            ws.refreshCommandPreview()
        }
    }
}

/// Richtung (Eine Seite · Zwei Seiten · Symmetrisch) auf ExtrudeDirection.
enum CommandDirection {
    static let options: [SegmentOption] = [
        SegmentOption(id: ExtrudeDirection.oneSide.rawValue, label: "Eine Seite"),
        SegmentOption(id: ExtrudeDirection.twoSides.rawValue, label: "Zwei Seiten"),
        SegmentOption(id: ExtrudeDirection.symmetric.rawValue, label: "Symmetrisch"),
    ]

    static func direction(_ cmd: ModelCommand) -> ExtrudeDirection {
        ExtrudeDirection(rawValue: cmd.choice("direction", default: ExtrudeDirection.oneSide.rawValue)) ?? .oneSide
    }
}

/// Bindung an einen Schalter des Befehls, die danach die Vorschau neu rechnet.
@MainActor
func commandFlag(_ key: String, _ cmd: ModelCommand, _ ws: Workspace) -> Binding<Bool> {
    Binding(get: { cmd.flag(key) }, set: { value in
        cmd.flags[key] = value
        ws.refreshCommandPreview()
    })
}
