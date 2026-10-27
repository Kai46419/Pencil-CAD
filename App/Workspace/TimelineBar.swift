import SwiftUI

// Zeitleiste des parametrischen Verlaufs (wie Fusion 360 unten): Features von links nach rechts, fehlgeschlagene
// rot, unterdrückte ausgegraut. Antippen öffnet ein kleines Fenster zum Ändern der Werte (Zahl oder Formel mit
// Projektvariablen), Unterdrücken und Löschen – jeweils mit Nachbau der folgenden Schritte.

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

struct TimelineBar: View {
    @ObservedObject var model: ModelStore
    @State private var editing: UUID?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .accessibilityLabel("Verlauf")
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
                                chip(feature, number: index + 1)
                                    .id(feature.id)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .onAppear { scrollToEnd(proxy) }
                    .onChange(of: model.features.count) { scrollToEnd(proxy) }
                }
            }
        }
        .frame(height: 56)
        .floatingSurface(in: Capsule(), elevation: .floating)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.features.last?.id else { return }
        withAnimation(Theme.snappy) { proxy.scrollTo(last, anchor: .trailing) }
    }

    private func chip(_ feature: Feature, number: Int) -> some View {
        let isOpen = Binding(get: { editing == feature.id }, set: { if !$0 { editing = nil } })
        return Button {
            editing = feature.id
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: feature.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 26)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Schritt \(number): \(feature.name)")
        .hoverTip(feature.name, feature.problem ?? (feature.kind == .snapshot ? "Fester Stand (direkte Änderung)" : nil))
        .popover(isPresented: isOpen) {
            FeatureEditor(model: model, feature: feature) { editing = nil }
        }
        .contextMenu {
            Button(feature.isSuppressed ? "Aktivieren" : "Unterdrücken",
                   systemImage: feature.isSuppressed ? "eye" : "eye.slash") {
                model.setFeatureSuppressed(!feature.isSuppressed, id: feature.id)
            }
            Button("Aus Verlauf löschen", systemImage: "trash", role: .destructive) {
                model.deleteFeature(feature.id)
            }
        }
    }

    private func chipColor(_ feature: Feature) -> Color {
        if feature.failed { return .red }
        if feature.isSuppressed { return Color.secondary.opacity(0.5) }
        return feature.kind == .snapshot ? Color.secondary : Color.primary
    }

    private func chipBackground(_ feature: Feature) -> Color {
        if editing == feature.id { return Theme.rowHighlight }
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
                Image(systemName: feature.systemImage)
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
