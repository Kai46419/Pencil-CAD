import SwiftUI

// Build 81 (Kai): Kante im Auswählen-Werkzeug angetippt → die Werte zum Abrunden bzw. Fasen stehen rechts im
// Eigenschaftenfenster (wie bei den Befehlen), nicht mehr als Karte unten im Bild. Die Oberflächen-Schnellwahl
// erscheint dort nur noch über den Knopf „Oberfläche“ in der rechten Leiste.

struct EdgeSelectionPanel: View {
    @ObservedObject var model: ModelStore
    /// Build 83: zuklappbar
    @AppStorage("edgePanel.collapsed") private var collapsed = false

    @ViewBuilder private var edgeScopeRow: some View {
        let chain = model.tangentChainEdges
        HStack(spacing: 6) {
            scopeButton("Kette", "link") { model.selectTangentChain() }
            scopeButton("Umlauf", "square.dashed") { model.selectEdgeLoop() }
            scopeButton("Alle", "cube") { model.selectAllEdges() }
        }
        if chain.count > model.selectedEdges.count, model.canBlendOnlySelectedEdges {
            // Build 104: ohne Tangentenkette selbst runden/fasen
            Button {
                model.blendOnlySelectedEdges()
            } label: {
                Label(model.edgeOperation == .chamfer ? "Nur diese Kante fasen" : "Nur diese Kante runden",
                      systemImage: "scissors")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        if chain.count > model.selectedEdges.count {
            Label("Glatt anschließende Kanten werden mitgenommen: \(chain.count) statt \(model.selectedEdges.count). "
                  + "Das macht der CAD-Kern bei tangentialen Übergängen immer.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scopeButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                HStack(spacing: 8) {
                    Image(systemName: model.edgeOperation == .fillet ? "circle.bottomrighthalf.pattern.checkered" : "triangle.bottomhalf.filled")
                        .frame(width: 25, height: 25)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KANTE").font(.system(size: 11, weight: .bold)).tracking(0.6)
                        Text(model.selectedEdges.count == 1 ? "1 Kante gewählt" : "\(model.selectedEdges.count) Kanten gewählt")
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                    if model.isBlendComputing {
                        ProgressView()
                    }
                    Button {
                        withAnimation(Theme.snappy) { collapsed.toggle() }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !collapsed {
                // Build 100 (Kai): gezielt wählen statt Überraschung – Kette, Umlauf, alle Kanten
                edgeScopeRow
                Picker("Operation", selection: $model.edgeOperation) {
                    ForEach(EdgeOperation.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                NumberField(title: model.edgeOperation == .fillet ? "Radius"
                            : model.edgeSecondValue == nil ? "Breite" : "Abstand 1", value: model.edgeValue, width: 96) {
                    model.setEdgeValue($0)
                }
                if model.edgeOperation == .fillet {
                    filletRows
                } else {
                    chamferRows
                }
                Divider()
                Text("Pfeil am Modell ziehen oder Wert eintippen · weitere Kanten antippen, auch innenliegende (Kehle).")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(PaletteStyle.inset)
        }
        .frame(width: PaletteStyle.width)
        .frame(maxHeight: 520)
        .background(PaletteStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous))
    }

    @ViewBuilder private var filletRows: some View {
        Button("Größter Radius", systemImage: "arrow.up.to.line") {
            model.searchLargestFillet { model.setEdgeValue($0) }
        }
        .buttonStyle(.bordered)
        .disabled(model.selectedEdges.count != 1 || model.edgeEndValue != nil || model.edgePartialRange != nil
                  || model.isBlendComputing || model.isBlendMaximumComputing || model.effectiveBlendOptions != nil)
        .hoverTip("Maximal gültiger Radius", "Prüft die gewählte Kante und übernimmt den größten gültigen Radius.")
        Toggle("Variabel", isOn: Binding(get: { model.edgeEndValue != nil }, set: { on in
            if on { model.setEdgePartialRange(nil, update: false) }
            model.setEdgeEndValue(on ? max(model.edgeValue * 2, 1) : nil)
        }))
        .hoverTip("Variabel", "Radius am Kantenanfang und am Kantenende verschieden, z. B. 1 → 5 mm.")
        if let end = model.edgeEndValue {
            NumberField(title: "Ende", value: end, width: 96) { model.setEdgeEndValue($0) }
        }
        Toggle("Teilweise", isOn: Binding(get: { model.edgePartialRange != nil }, set: { on in
            model.setEdgePartialRange(on ? 0.2...0.8 : nil)
        }))
        .disabled(model.selectedEdges.count != 1)
        .hoverTip("Teilweise", "Nur einen Abschnitt der Kante abrunden (Start und Ende in Prozent).")
        if let range = model.edgePartialRange {
            NumberField(title: "Start", value: range.lowerBound * 100, unit: "%", width: 96) { value in
                model.setEdgePartialRange((min(max(value, 0), range.upperBound * 100 - 5) / 100)...range.upperBound)
            }
            NumberField(title: "Ende", value: range.upperBound * 100, unit: "%", width: 96) { value in
                model.setEdgePartialRange(range.lowerBound...(max(min(value, 100), range.lowerBound * 100 + 5) / 100))
            }
        }
    }

    @ViewBuilder private var chamferRows: some View {
        Toggle("Zwei Abstände", isOn: Binding(get: { model.edgeSecondValue != nil }, set: { on in
            model.setEdgeSecondValue(on ? model.edgeValue : nil)
        }))
        .hoverTip("Zwei Abstände", "Die Fase ist auf beiden Nachbarflächen verschieden breit, z. B. 2 × 4 mm.")
        if let second = model.edgeSecondValue {
            NumberField(title: "Abstand 2", value: second, width: 96) { model.setEdgeSecondValue($0) }
        }
    }
}
