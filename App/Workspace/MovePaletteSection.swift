import SwiftUI

/// Build 89 (Kai): Verschieben/Drehen eines Normteils rechts im Normteil-Fenster statt in der Karte unten.
/// Gleiche Werte wie ParameterCard.moveCard: Versatz X/Y/Z, Drehen um ±90°, Kopieren (mit × / ÷ Reihe).
struct MovePaletteSection: View {
    @ObservedObject var model: ModelStore

    private let axes = ["X", "Y", "Z"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VERSCHIEBEN (\(LengthUnit.current.rawValue))")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { axis in
                    NumberField(title: axes[axis], value: model.moveOffset[axis], unit: "", width: 56) { value in
                        var offset = model.moveOffset
                        offset[axis] = value
                        model.setMoveOffset(offset)
                    }
                }
            }
            .font(.caption)
            Text("DREHEN UM 90°")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<3, id: \.self) { axis in
                    GridRow {
                        Text(axes[axis])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(axisColor(axis))
                            .frame(width: 16)
                        rotateButton(axis, -90, "arrow.counterclockwise")
                        rotateButton(axis, 90, "arrow.clockwise")
                    }
                }
            }
            Toggle(isOn: Binding(get: { model.moveCopies }, set: { copies in
                model.moveCopies = copies
                if model.moveOffset != .zero { model.setMoveOffset(model.moveOffset) }
            })) {
                Label("Kopieren", systemImage: "plus.square.on.square")
                    .font(.caption)
            }
            .controlSize(.small)
            if model.moveCopies {
                HStack(spacing: 8) {
                    Picker("Reihe", selection: Binding(get: { model.moveArrayDivides }, set: { divides in
                        model.moveArrayDivides = divides
                        if model.moveOffset != .zero { model.setMoveOffset(model.moveOffset) }
                    })) {
                        Text("×").tag(false)
                        Text("÷").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 72)
                    Stepper("\(model.moveArrayCount)", value: Binding(get: { model.moveArrayCount }, set: { count in
                        model.moveArrayCount = max(1, min(count, 200))
                        if model.moveOffset != .zero { model.setMoveOffset(model.moveOffset) }
                    }), in: 1...200)
                    .monospacedDigit()
                    .font(.caption)
                }
            }
            Text("Pfeil ziehen oder Wert eingeben, unten „Fertig“.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func axisColor(_ axis: Int) -> Color {
        [Color.red, Color.green, Color.blue][axis]
    }

    private func rotateButton(_ axis: Int, _ degrees: Double, _ icon: String) -> some View {
        Button {
            var vector = SIMD3<Double>(0, 0, 0)
            vector[axis] = 1
            model.rotateSelected(axis: vector, degrees: degrees)
        } label: {
            Label(degrees < 0 ? "−90°" : "+90°", systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.selectedBodies.isEmpty)
    }
}
