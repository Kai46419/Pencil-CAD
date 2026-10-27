import SwiftUI

// Eigenschaften-Panel im Modellmodus nach SolidCraft (MIT, crates/ui-egui/src/dialogs.rs:2747-2990 Rahmen,
// dialogs_dense.rs Zeilen, docs/design/ux-redesign/model-floating.png). Kai: „Werkzeug angeklickt, und auf der
// rechten Seite kommen die Eigenschaften der Werkzeuge zu stehen.“
// Aufbau: Kopf (Symbol, Titel bzw. „… bearbeiten“, ⓘ, Menü, ×) · Auswahlfelder mit Hinweis · Werte und Abschnitte
// des Treibers · Fehlerzeile · fester Fuß Abbrechen · OK. Dieselben Bausteine, Farben und dieselbe Breite wie die
// Skizzenpalette (SketchPaletteControls.swift), damit Skizzen- und Modellmodus gleich aussehen.

/// Rechtes Panel eines offenen Modellbefehls (`workspace.command`).
struct FeaturePanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var command: ModelCommand

    /// Höhe des scrollbaren Mittelteils; kurze Inhalte machen das Panel nicht unnötig hoch
    @State private var contentHeight: CGFloat = 320
    @State private var showsInfo = false
    @AppStorage(CornerConfirm.storageKey) private var cornerConfirm = true

    private var driver: ModelCommandDriver.Type? { ModelCommands.driver(command.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(12)
                .background(PaletteStyle.header)
            PaletteRule()
            ScrollView(showsIndicators: true) {
                middle
                    .padding(12)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: FeaturePanelHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: contentHeight)
            .onPreferenceChange(FeaturePanelHeightKey.self) { contentHeight = $0 }
            PaletteRule()
            footer
                .padding(12)
                .background(PaletteStyle.header)
        }
        .frame(width: PaletteStyle.width)
        .background(PaletteStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous)
                .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
        }
        .elevationShadow(.floating)
        .background { keyboardShortcuts }
        // Wie die Skizzenpalette dunkel (Anthrazit): Text, Systemfarben und „sc.*“-Bilder passend dazu
        .environment(\.colorScheme, .dark)
    }

    // MARK: Kopf

    private var title: String {
        let name = driver?.title ?? command.id.rawValue
        guard let id = command.editing else { return name }
        let featureName = model.features.first { $0.id == id }?.name ?? name
        return "\(featureName) bearbeiten"
    }

    private var header: some View {
        HStack(spacing: 6) {
            ToolIcon(driver?.icon ?? "sc.select", size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if command.editing != nil {
                    Text("Verlauf · Werte ändern, OK baut neu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let text = driver?.explanation {
                Button {
                    showsInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: PaletteStyle.touch)
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
                    .frame(width: 36, height: PaletteStyle.touch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Einstellungen des Panels")
            Button {
                workspace.cancelCommand()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: PaletteStyle.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abbrechen")
        }
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

    private var footer: some View {
        let canCommit = workspace.canConfirmCommand
        return HStack(spacing: 8) {
            PrimaryWideButton(title: "Abbrechen", isPrimary: false) {
                workspace.cancelCommand()
            }
            if driver?.repeatable == true, command.editing == nil {
                PrimaryWideButton(title: "Übernehmen", isPrimary: false) {
                    workspace.confirmCommand(keepOpen: true)
                }
                .disabled(!canCommit)
                .opacity(canCommit ? 1 : 0.45)
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

private struct FeaturePanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Bausteine der Panelzeilen

/// Beschriftung links in der Breite der Skizzenpalette.
struct PanelRowLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: PaletteStyle.labelWidth, alignment: .leading)
    }
}

/// Eine Wahl in einer Segmentzeile.
struct SegmentOption: Identifiable {
    let id: String
    let label: String
}

/// Segmente mit Text (SolidCraft `ui_kit::segmented`), 44 pt hoch; Titel darüber, damit die Segmente die ganze
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
            HStack(spacing: 3) {
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
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch - 6)
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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: PaletteStyle.spacing) {
            PanelRowLabel(title: title)
            PaletteFieldBox(isLocked: false, hasError: error != nil) {
                TextField(title, text: $text)
                    .focused($isFocused)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onChange(of: value) { _, newValue in
                        if !isFocused { text = PaletteExpression.shown(newValue, unit: unit) }
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
        isFocused = true
        command.focusKey = nil
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
        HStack(spacing: PaletteStyle.spacing) {
            PanelRowLabel(title: title)
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
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(PaletteStyle.field,
                            in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                        .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                }
                .frame(minHeight: PaletteStyle.touch)
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
