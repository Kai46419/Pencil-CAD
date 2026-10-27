import SwiftUI

// Lage des gewählten Texts aus den Griffen (SketchTextTransform.swift) als Wertfelder im rechten Fenster:
// X und Y der Rahmenmitte, Skalierung in Prozent, Drehung um die Mitte, „Zurücksetzen“. Beschriftung über den
// Feldern, je zwei nebeneinander (schmales 160-pt-Fenster). Jede Eingabe ist ein Rückgängig-Schritt.

struct SketchTextTransformFields: View {
    @ObservedObject var sketch: SketchController
    let index: Int

    var body: some View {
        if let text = sketch.sketchText(at: index), let frame = text.frame() {
            let transform: SketchTextTransform = text.transform ?? .identity
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                Text("Lage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: PaletteStyle.spacing) {
                    PaletteNumberRow(title: "X", value: frame.center.x) { x in
                        sketch.setTextCenter(at: index, x: x)
                    }
                    PaletteNumberRow(title: "Y", value: frame.center.y) { y in
                        sketch.setTextCenter(at: index, y: y)
                    }
                }
                HStack(alignment: .bottom, spacing: PaletteStyle.spacing) {
                    PaletteNumberRow(title: "Skalierung", value: transform.scale * 100, unit: "%") { percent in
                        guard percent > 0 else { return }
                        sketch.setTextScale(at: index, to: percent / 100)
                    }
                    PaletteNumberRow(title: "Drehung", value: transform.rotation * 180 / .pi, unit: "°") { degrees in
                        sketch.setTextTurn(at: index, to: degrees * .pi / 180)
                    }
                }
                PrimaryWideButton(title: "Zurücksetzen", systemImage: "arrow.counterclockwise", isPrimary: false) {
                    sketch.resetTextTransform(at: index)
                }
                .disabled(text.transform == nil)
                .hoverTip("Zurücksetzen", "Verschieben, Skalieren und Drehen über die Griffe aufheben – der Text steht wieder, wie er geschrieben wurde.")
            }
        }
    }
}
