import SwiftUI

// Auswahlfeld im Eigenschaften-Panel nach SolidCraft (crates/ui-egui/src/dialogs.rs:2332-2420, docs/ui-kit.md:108):
// leer „↖ Auswählen“ mit gestricheltem Umriss, gefüllt „N ausgewählt“ bzw. der Name bei Einzelauswahl, aktiv mit
// Akzentrand und getöntem Grund. Antippen macht das Feld aktiv (das nächste Antippen im Viewport füllt es),
// „×“ leert es. Titel über dem Feld (schmales Fenster), Treffer 36–38 pt.

// label ruft PickNames (Main Actor) auch außerhalb von body auf: unter Xcode 15 ist View sonst nicht isoliert
@MainActor
struct PickChip: View {
    let input: PickInput
    let isActive: Bool
    let model: ModelStore
    let activate: () -> Void
    let clear: () -> Void

    private var label: String {
        switch input.items.count {
        case 0: return input.isOptional ? "Auswählen (optional)" : "Auswählen"
        case 1: return PickNames.name(input.items[0], model: model)
        default: return "\(input.items.count) ausgewählt"
        }
    }

    var body: some View {
        PaletteLabeled(title: input.title) {
            chip
        }
        .accessibilityElement(children: .contain)
    }

    private var chip: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        let isEmpty = input.items.isEmpty
        return Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: isEmpty ? "arrow.up.left" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isActive ? SketchTheme.accent : Color.secondary)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, isEmpty ? 8 : 32)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch)
            .background(fill, in: shape)
            .overlay {
                if isActive {
                    shape.strokeBorder(SketchTheme.accent, lineWidth: 1.5)
                } else if isEmpty {
                    shape.strokeBorder(PaletteStyle.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if !isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: PaletteStyle.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(input.title) leeren")
            }
        }
        .accessibilityLabel(input.title)
        .accessibilityValue(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var fill: Color {
        if isActive { return SketchTheme.accentSoft }
        return input.items.isEmpty ? PaletteStyle.field : Color.primary.opacity(0.08)
    }
}

/// Namen für Picks im Auswahlfeld.
enum PickNames {
    @MainActor
    static func name(_ pick: Pick, model: ModelStore) -> String {
        switch pick {
        case .region(let ref):
            return model.sketches.indices.contains(ref.sketch) ? "Bereich · \(model.sketches[ref.sketch].name)" : "Bereich"
        case .face(let face):
            return "Fläche · \(bodyName(face.body, model: model))"
        case .edge(let edge):
            return "Kante · \(bodyName(edge.body, model: model))"
        case .body(let body):
            return bodyName(body, model: model)
        case .plane(let plane):
            switch plane {
            case .world(let axis): return ["YZ-Ebene", "XZ-Ebene", "XY-Ebene"][max(0, min(2, axis))]
            case .construction(let id): return model.constructions.first { $0.id == id }?.name ?? "Ebene"
            case .face: return "Ebene Fläche"
            }
        case .axis(let axis):
            switch axis {
            case .world(let index): return ["X-Achse", "Y-Achse", "Z-Achse"][max(0, min(2, index))]
            case .sketchLine(let index): return "Skizzenlinie \(index + 1)"
            case .construction(let id): return model.constructions.first { $0.id == id }?.name ?? "Achse"
            }
        case .point:
            return "Punkt"
        case .curve:
            return "Kurve"
        case .sketch(let index):
            return model.sketches.indices.contains(index) ? model.sketches[index].name : "Skizze"
        }
    }

    @MainActor
    private static func bodyName(_ body: Int, model: ModelStore) -> String {
        model.bodies.indices.contains(body) ? model.bodies[body].name : "Körper"
    }
}
