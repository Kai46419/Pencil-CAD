import SwiftUI

// Gewählten Skizzentext ändern und Texte im Browser „Ebenen“ zeigen (Logik in SketchTextEdit.swift).

/// Leiste für den gewählten Text (Auswahlwerkzeug): dieselben Felder wie bei der Eingabe (TextEntrySheet) –
/// Inhalt, Schrift, Höhe, Ausrichtung – plus Drehwinkel. Jede Änderung erzeugt die Umrisse an derselben Stelle neu.
struct SketchTextEditor: View {
    @ObservedObject var sketch: SketchController
    let index: Int
    /// Untereinander statt nebeneinander (schmales Fenster rechts)
    var stacked = false

    @State private var content = ""
    /// Stand, zu dem content gehört: Inhalt des Texts und Anzahl der Elemente beim Laden. Nur wenn beides noch
    /// passt, wird getippter Inhalt übernommen (sonst wurde der Text gelöscht bzw. steht ein anderer an index).
    @State private var loadedString = ""
    @State private var loadedCount = -1
    @FocusState private var isFocused: Bool

    var body: some View {
        if let text = sketch.sketchText(at: index) {
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                Image(systemName: "textformat")
                    .foregroundStyle(.secondary)
                TextField("Inhalt", text: $content)
                    .focused($isFocused)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(width: stacked ? PaletteStyle.contentWidth : 140)
                    .onSubmit { commitContent(at: index) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitContent(at: index) }
                    }
                FontPickerButton(selection: fontBinding, fullWidth: stacked)
                    .frame(width: stacked ? PaletteStyle.contentWidth : nil)
                if stacked {
                    // Schmales Fenster rechts: je Feld eine Zeile, Beschriftung darüber, nichts mit „…“ gekürzt
                    stackedFields(text)
                } else {
                    NumberField(title: "Höhe", value: text.height, width: 56, set: setHeight)
                    NumberField(title: "Winkel", value: text.rotationDegrees, unit: "°", width: 52, set: setAngle)
                    Picker("Ausrichtung", selection: alignmentBinding) {
                        ForEach(TextAlignmentOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .onAppear { load(index) }
            // Anderer Text gewählt: Getipptes erst beim bisherigen Text übernehmen (Kai tippt oft gleich weiter)
            .onChange(of: index) { old, new in
                commitContent(at: old)
                load(new)
            }
            // Antippen in den Viewport schließt die Leiste, ohne dass das Feld den Fokus verliert
            .onDisappear { commitContent(at: index) }
            // Rückgängig: Feld nachziehen, solange nicht getippt wird
            .onChange(of: currentString) { _, _ in
                if !isFocused { load(index) }
            }
        }
    }

    private var currentString: String { sketch.sketchText(at: index)?.string ?? "" }

    @ViewBuilder private func stackedFields(_ text: SketchText) -> some View {
        PaletteNumberRow(title: "Höhe", value: text.height, set: setHeight)
        PaletteNumberRow(title: "Winkel", value: text.rotationDegrees, unit: "°", set: setAngle)
        CommandSegmentRow(title: "Ausrichtung",
                          options: TextAlignmentOption.allCases.map { CommandChoice(id: $0.rawValue, title: $0.rawValue) },
                          selected: text.alignment.rawValue) { id in
            if let alignment = TextAlignmentOption(rawValue: id) { alignmentBinding.wrappedValue = alignment }
        }
    }

    private func setHeight(_ value: Double) {
        guard value > 0 else { return }
        sketch.updateText(at: index) { $0.with(height: value) }
    }

    private func setAngle(_ value: Double) {
        let radians: Double = value * .pi / 180
        sketch.updateText(at: index) { $0.with(rotation: radians) }
    }

    private func load(_ at: Int) {
        let string = sketch.sketchText(at: at)?.string ?? ""
        content = string
        loadedString = string
        loadedCount = sketch.entities.count
    }

    /// Getippten Inhalt beim Text an Stelle at übernehmen – nur einmal (danach gleich, also kein zweiter
    /// Rückgängig-Schritt) und nur, wenn dort noch derselbe Text steht.
    private func commitContent(at: Int) {
        guard let current = sketch.sketchText(at: at), sketch.entities.count == loadedCount,
              current.string == loadedString, content != current.string else { return }
        sketch.updateText(at: at) { $0.with(string: content) }
        // Übernommen bzw. abgelehnt (leer): das Feld zeigt den gültigen Inhalt
        let string = sketch.sketchText(at: at)?.string ?? current.string
        loadedString = string
        if at == index { content = string }
    }

    private var fontBinding: Binding<String> {
        Binding(get: { sketch.sketchText(at: index)?.fontName ?? SketchText.fonts[0].name },
                set: { name in sketch.updateText(at: index) { $0.with(fontName: name) } })
    }

    private var alignmentBinding: Binding<TextAlignmentOption> {
        Binding(get: { sketch.sketchText(at: index)?.alignment ?? .left },
                set: { alignment in sketch.updateText(at: index) { $0.with(alignment: alignment) } })
    }
}

/// Texte einer Skizze im Browser „Ebenen“. Ist genau diese Skizze offen, zählen ihre aktuellen Elemente (sonst
/// passten die Indizes nach Änderungen nicht mehr), sonst die gespeicherten.
struct SketchTextLayerList: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController
    let sketchIndex: Int
    let stored: StoredSketch

    var body: some View {
        ForEach(items) { item in
            SketchTextLayerRow(workspace: workspace, sketch: sketch, sketchIndex: sketchIndex, item: item)
        }
    }

    private var items: [SketchTextItem] {
        if sketch.isActive && workspace.editingSketchIndex == sketchIndex {
            return SketchTextItem.items(sketch.entities, construction: sketch.construction)
        }
        return stored.textItems
    }
}

/// Text einer gespeicherten Skizze als Unterpunkt im Browser „Ebenen“: antippen öffnet die Skizze und wählt
/// den Text (dann lässt er sich verschieben und in der Leiste ändern).
struct SketchTextLayerRow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController
    let sketchIndex: Int
    let item: SketchTextItem

    var body: some View {
        HStack(spacing: 6) {
            // Platz des Auges: Texte lassen sich nicht einzeln ausblenden, nur mit der ganzen Skizze
            Color.clear
                .frame(width: 30, height: 30)
            Image(systemName: "textformat")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text("Text: \(item.text.shortLabel)")
                .lineLimit(1)
                .foregroundStyle(item.isConstruction ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .hoverTip("Text bearbeiten", "Öffnet die Skizze und wählt den Text: ziehen verschiebt ihn, die Leiste ändert Inhalt, Schrift, Höhe und Winkel.")
        .contextMenu {
            Button("Text bearbeiten", systemImage: "pencil", action: open)
        }
    }

    private var isSelected: Bool {
        sketch.isActive && workspace.editingSketchIndex == sketchIndex && sketch.selectedTextIndex == item.entity
    }

    private func open() {
        if !(sketch.isActive && workspace.editingSketchIndex == sketchIndex) {
            // Eine andere offene Skizze wird erst übernommen (wie mit dem grünen Haken), nicht verworfen
            if sketch.isActive { workspace.finishSketch() }
            workspace.editSketch(sketchIndex)
        }
        sketch.selectText(at: item.entity)
    }
}
