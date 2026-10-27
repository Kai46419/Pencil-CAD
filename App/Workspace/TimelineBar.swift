import SwiftUI

// Zeitleiste des parametrischen Verlaufs (SolidCraft/Fusion 360 unten): Features von links nach rechts, fehlgeschlagene
// rot, unterdrückte durchgestrichen, hinter der Rückrollmarke blass. Doppeltippen bearbeitet die Werte (Zahl oder
// Formel mit Projektvariablen), dazu Unterdrücken, Umbenennen und Löschen – jeweils mit Nachbau der folgenden Schritte.

/// Ein- und Ausblenden der Zeitleiste (Menü „…“). Automatisch: sichtbar ab zwei Features.
enum TimelineVisibility: Int {
    case automatic = 0
    case shown = 1
    case hidden = 2

    static let storageKey = "timelineVisibility"

    func isVisible(featureCount: Int) -> Bool {
        switch self {
        case .automatic: featureCount > 1
        case .shown: true
        case .hidden: false
        }
    }
}

/// Verlauf unten nach SolidCraft (B.3): links „Verlauf“ und |◀ ◀ ▶ ▶|, dann die Features in Reihenfolge mit
/// Rückrollmarke (ziehbar, zeigt den Stand bis dorthin), rechts „N Features“. Antippen wählt, Doppeltippen bearbeitet
/// (Eigenschaften-Panel, sonst das kleine Fenster), langes Drücken: Bearbeiten · Unterdrücken · Umbenennen · Löschen.
struct TimelineBar: View {
    @ObservedObject var model: ModelStore
    /// Für Bearbeiten im Panel und die Kapsel „· bearbeiten“.
    /// TODO-MERGE: WorkspaceView – `TimelineBar(model: model, workspace: workspace)` übergeben.
    var workspace: Workspace? = nil

    /// Kleines Fenster mit den Werten (Fallback, feste Stände, „Schnell ändern“)
    @State private var editing: UUID?
    /// Ausgewählter Schritt (Antippen)
    @State private var selected: UUID?
    /// Rückrollmarke: Zahl der Schritte davor; nil = am Ende (alles gilt)
    @State private var marker: Int?
    /// Marke beim Beginn des Ziehens
    @State private var dragStart: Int?
    /// Die angezeigte Vorschau ist der zurückgerollte Stand (nur Ansicht, wird nie übernommen)
    @State private var showsRollback = false
    @State private var renaming: UUID?
    @State private var nameDraft = ""
    @State private var deleting: Feature?

    /// Breite eines Schritts samt Abstand (Ziehen der Marke rastet je Schritt)
    private let step: CGFloat = 68

    private var count: Int { model.features.count }
    private var markerIndex: Int { min(marker ?? count, count) }

    var body: some View {
        HStack(spacing: 6) {
            header
            if model.features.isEmpty {
                Text("Noch keine Schritte – Extrudieren, Abrunden … erscheinen hier.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
                    .frame(height: 52)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(model.features.enumerated()), id: \.element.id) { index, feature in
                                if index == markerIndex { rollbackMarker }
                                chip(feature, number: index + 1)
                                    .opacity(index >= markerIndex ? 0.42 : 1)
                                    .id(feature.id)
                            }
                            if markerIndex >= count { rollbackMarker }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 14)
                    }
                    .onAppear { scrollToEnd(proxy) }
                    .onChange(of: model.features.count) {
                        // Neuer bzw. gelöschter Schritt: Marke wieder ans Ende
                        resetMarker()
                        scrollToEnd(proxy)
                    }
                }
                Text(count == 1 ? "1 Feature" : "\(count) Features")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .padding(.trailing, 14)
                    .hoverTip("Verlauf", "Marke ziehen zum Zurückrollen (nur Ansicht).")
            }
        }
        .frame(height: 64)
        .floatingSurface(in: Capsule(), elevation: .floating)
        .alert("Schritt umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Umbenennen") { rename() }
        }
        .confirmationDialog(deleting.map { "„\($0.name)“ aus dem Verlauf löschen?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let feature = deleting { model.deleteFeature(feature.id) }
                deleting = nil
            }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        } message: {
            Text("Die folgenden Schritte werden neu berechnet; was davon abhängt, kann fehlschlagen.")
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 2) {
            Text("Verlauf")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .padding(.trailing, 4)
            if !model.features.isEmpty {
                stepButton("backward.end.fill", "Zum Anfang", enabled: markerIndex > 0) { moveMarker(to: 0) }
                stepButton("backward.frame.fill", "Ein Schritt zurück", enabled: markerIndex > 0) {
                    moveMarker(to: markerIndex - 1)
                }
                stepButton("forward.frame.fill", "Ein Schritt vor", enabled: markerIndex < count) {
                    moveMarker(to: markerIndex + 1)
                }
                stepButton("forward.end.fill", "Zum Ende", enabled: markerIndex < count) { moveMarker(to: count) }
            }
        }
    }

    private func stepButton(_ icon: String, _ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(title)
        .hoverTip(title)
    }

    // MARK: Rückrollmarke

    private var rollbackMarker: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7, weight: .bold))
            Capsule()
                .frame(width: 3, height: 36)
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 20, height: 46)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag in
                    let start = dragStart ?? markerIndex
                    if dragStart == nil { dragStart = start }
                    let shift = Int((drag.translation.width / step).rounded())
                    let target = min(max(start + shift, 0), count)
                    if target != markerIndex { moveMarker(to: target) }
                }
                .onEnded { _ in dragStart = nil }
        )
        .accessibilityLabel("Rückrollmarke")
        .accessibilityValue("nach Schritt \(markerIndex)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: moveMarker(to: markerIndex + 1)
            case .decrement: moveMarker(to: markerIndex - 1)
            @unknown default: break
            }
        }
    }

    /// Marke setzen und den Stand bis dorthin zeigen (aus dem Zwischenspeicher des Nachbaus, nur Ansicht: eine schlichte
    /// Vorschau wird beim Übernehmen verworfen). Neues entsteht weiter am Ende.
    private func moveMarker(to index: Int) {
        let target = min(max(index, 0), count)
        guard target < count else {
            resetMarker()
            return
        }
        // Eine offene Vorschau eines Werkzeugs nicht überschreiben
        if model.hasPreview, !showsRollback {
            model.message = "Erst das laufende Werkzeug abschließen, dann zurückrollen."
            return
        }
        let bodies: [SceneBody]
        if target == 0 {
            bodies = []
        } else if let cached = model.featureRecorder.cache[model.features[target - 1].id] {
            bodies = cached
        } else {
            model.message = "Dieser Stand ist noch nicht berechnet."
            return
        }
        marker = target
        showsRollback = true
        model.showPreview(bodies, name: "Zurückgerollt", plain: true)
    }

    private func resetMarker() {
        marker = nil
        dragStart = nil
        if showsRollback {
            showsRollback = false
            model.dropPreview()
        }
    }

    // MARK: Schritte

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.features.last?.id else { return }
        withAnimation(Theme.snappy) { proxy.scrollTo(last, anchor: .trailing) }
    }

    /// Doppeltippen bzw. „Bearbeiten“: im Eigenschaften-Panel, sonst im kleinen Fenster
    private func edit(_ feature: Feature) {
        selected = feature.id
        resetMarker()
        if let workspace, workspace.editFeatureInPanel(feature) { return }
        editing = feature.id
    }

    private func rename() {
        defer { renaming = nil }
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        guard let id = renaming, !name.isEmpty, let index = model.features.firstIndex(where: { $0.id == id }) else { return }
        model.features[index].name = name
        model.saveFeatures()
    }

    private func chip(_ feature: Feature, number: Int) -> some View {
        let isOpen = Binding(get: { editing == feature.id }, set: { if !$0 { editing = nil } })
        let isEditing = workspace?.editingFeatureID == feature.id
        return VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                ToolIcon(feature.systemImage, size: 22)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: 26)
                    // Unterdrückt: farbiges Bild grau und blass (SF Symbols färbt chipColor)
                    .saturation(feature.isSuppressed ? 0 : 1)
                    .opacity(feature.isSuppressed && ToolIcon.isCustom(feature.systemImage) ? 0.5 : 1)
                if feature.failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .offset(x: 4, y: -2)
                } else if feature.usesFormulas {
                    Text("ƒ")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .offset(x: 4, y: -2)
                }
            }
            Text(feature.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .strikethrough(feature.isSuppressed)
        }
        .frame(width: 66, height: 46)
        .foregroundStyle(chipColor(feature))
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous)
                .fill(chipBackground(feature))
        }
        .overlay {
            if selected == feature.id || isEditing {
                RoundedRectangle(cornerRadius: Theme.Radius.label, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .top) {
            // Kapsel „<Name> · bearbeiten“ über dem Schritt, der gerade im Panel bearbeitet wird
            if isEditing {
                Text("\(feature.name) · bearbeiten")
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .offset(y: -13)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit(feature) }
        .onTapGesture { selected = selected == feature.id ? nil : feature.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Schritt \(number): \(feature.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Bearbeiten") { edit(feature) }
        .hoverTip(feature.name, feature.problem ?? (feature.kind == .snapshot ? "Fester Stand (direkte Änderung)"
                                                    : "Doppeltippen: bearbeiten"))
        .popover(isPresented: isOpen) {
            FeatureEditor(model: model, feature: feature) { editing = nil }
        }
        .contextMenu {
            Button("Bearbeiten", systemImage: "slider.horizontal.3") { edit(feature) }
            Button(feature.isSuppressed ? "Aktivieren" : "Unterdrücken",
                   systemImage: feature.isSuppressed ? "eye" : "eye.slash") {
                resetMarker()
                model.setFeatureSuppressed(!feature.isSuppressed, id: feature.id)
            }
            Button("Umbenennen", systemImage: "character.cursor.ibeam") {
                nameDraft = feature.name
                renaming = feature.id
            }
            Button("Löschen", systemImage: "trash", role: .destructive) {
                resetMarker()
                deleting = feature
            }
        }
    }

    private func chipColor(_ feature: Feature) -> Color {
        if feature.failed { return .red }
        if feature.isSuppressed { return Color.secondary.opacity(0.5) }
        return feature.kind == .snapshot ? Color.secondary : Color.primary
    }

    private func chipBackground(_ feature: Feature) -> Color {
        if editing == feature.id || selected == feature.id { return Theme.rowHighlight }
        if feature.failed { return Color.red.opacity(0.1) }
        return Color.clear
    }
}

/// Fenster eines Features: Werte (Zahl oder Formel), Unterdrücken, Löschen.
struct FeatureEditor: View {
    @ObservedObject var model: ModelStore
    let feature: Feature
    let close: () -> Void

    @State private var drafts: [String: String] = [:]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ToolIcon(feature.systemImage, size: 22)
                    .foregroundStyle(feature.failed ? Color.red : Color.accentColor)
                Text(feature.name)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            if feature.failed {
                Label(feature.problem ?? "Beim Nachbau fehlgeschlagen.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if feature.kind == .snapshot {
                Text("Fester Stand: Dieser Schritt (z. B. Import, Fläche versetzen) lässt sich nicht nachrechnen. "
                     + "Beim Nachbau gelten ab hier die gespeicherten Körper.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if feature.parameters.isEmpty {
                Text("Keine änderbaren Werte.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(feature.parameters) { parameter in
                HStack(spacing: 8) {
                    Text(parameter.title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    TextField(parameter.title, text: draft(parameter.key))
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 130)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(apply)
                    Text(Self.unitLabel(parameter.unit))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)
                }
            }
            if !feature.parameters.isEmpty {
                Text("Zahl oder Formel mit Variablen, z. B. „breite / 2“ oder „10 mm + wand“.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Divider()
            HStack(spacing: 10) {
                Button(feature.isSuppressed ? "Aktivieren" : "Unterdrücken",
                       systemImage: feature.isSuppressed ? "eye" : "eye.slash") {
                    close()
                    model.setFeatureSuppressed(!feature.isSuppressed, id: feature.id)
                }
                Button("Löschen", systemImage: "trash", role: .destructive) {
                    close()
                    model.deleteFeature(feature.id)
                }
                Spacer(minLength: 0)
                if !feature.parameters.isEmpty {
                    Button("Übernehmen", action: apply)
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { drafts = initialTexts }
    }

    private func draft(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private var initialTexts: [String: String] {
        var texts: [String: String] = [:]
        for parameter in feature.parameters {
            texts[parameter.key] = Self.text(for: parameter)
        }
        return texts
    }

    /// Formel bzw. Zahl in der Projekteinheit.
    static func text(for parameter: FeatureParameter) -> String {
        if let formula = parameter.formula { return formula }
        switch parameter.unit {
        case .length: return LengthUnit.current.number(parameter.value)
        case .angle: return NumberField.format(parameter.value)
        case .count: return String(Int(parameter.value.rounded()))
        }
    }

    static func unitLabel(_ unit: FeatureUnit) -> String {
        switch unit {
        case .length: LengthUnit.current.symbol
        case .angle: "°"
        case .count: "×"
        }
    }

    /// Geänderte Felder ausrechnen; Formeln bleiben verknüpft, reine Zahlen lösen die Verknüpfung.
    private func apply() {
        let initial = initialTexts
        let values = model.variableValues
        var parameters = feature.parameters
        var changed = false
        for index in parameters.indices {
            let key = parameters[index].key
            let text = (drafts[key] ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != initial[key] else { continue }
            do {
                let value = try parameters[index].unit.evaluate(text, variables: values)
                guard value.isFinite else { throw ExpressionError("Ergebnis ist keine Zahl.") }
                parameters[index].value = value
                parameters[index].formula = Formula.isPlainNumber(text) ? nil : text
                changed = true
            } catch {
                problem = "\(parameters[index].title): \(error.localizedDescription)"
                return
            }
        }
        problem = nil
        close()
        if changed {
            model.updateFeature(feature.id, parameters: parameters)
        }
    }
}
