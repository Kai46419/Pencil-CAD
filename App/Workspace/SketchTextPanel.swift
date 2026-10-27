import SwiftUI

// Gewählten Skizzentext ändern und Texte im Browser „Ebenen“ zeigen (Logik in SketchTextEdit.swift).

/// Leiste für den gewählten Text (Auswahlwerkzeug): dieselben Felder wie bei der Eingabe (TextEntrySheet) –
/// Inhalt, Schrift, Höhe, Ausrichtung – plus Drehwinkel. Jede Änderung erzeugt die Umrisse an derselben Stelle neu.
struct SketchTextEditor: View {
    @ObservedObject var sketch: SketchController
    let index: Int

    @State private var content = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if let text = sketch.sketchText(at: index) {
            HStack(spacing: 14) {
                Image(systemName: "textformat")
                    .foregroundStyle(.secondary)
                TextField("Inhalt", text: $content)
                    .focused($isFocused)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(width: 140)
                    .onSubmit(commitContent)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitContent() }
                    }
                Picker("Schrift", selection: fontBinding) {
                    ForEach(SketchText.fonts) { Text($0.title).tag($0.name) }
                }
                .fixedSize()
                NumberField(title: "Höhe", value: text.height, width: 56) { value in
                    guard value > 0 else { return }
                    sketch.updateText(at: index) { $0.with(height: value) }
                }
                NumberField(title: "Winkel", value: text.rotationDegrees, unit: "°", width: 52) { value in
                    let radians: Double = value * .pi / 180
                    sketch.updateText(at: index) { $0.with(rotation: radians) }
                }
                Picker("Ausrichtung", selection: alignmentBinding) {
                    ForEach(TextAlignmentOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .onAppear { content = text.string }
            .onChange(of: index) { _, _ in content = currentString }
            // Rückgängig bzw. anderer Text gewählt: Feld nachziehen, solange nicht getippt wird
            .onChange(of: currentString) { _, newValue in
                if !isFocused { content = newValue }
            }
        }
    }

    private var currentString: String { sketch.sketchText(at: index)?.string ?? "" }

    private func commitContent() {
        guard content != currentString else { return }
        sketch.updateText(at: index) { $0.with(string: content) }
        // Abgelehnt (leer): wieder den gültigen Inhalt zeigen
        if content != currentString { content = currentString }
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
