import SwiftUI

// Build 68: Lage der Auswahl im Skizzenmodus als Wertfelder (SketchSelectionTransform.swift): X und Y der
// Rahmenmitte, Skalieren in Prozent und Drehen in Grad (jeweils um die Rahmenmitte), dazu schnelle Knöpfe für
// ±90°. Jede Eingabe ist ein Rückgängig-Schritt.

struct SketchSelectionTransformFields: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        if let indices = sketch.transformSelectionIndices, let frame = sketch.selectionFrame(indices) {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                Text("Lage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PaletteNumberRow(title: "X", value: frame.center.x) { x in
                    sketch.setSelectionCenter(x: x)
                }
                PaletteNumberRow(title: "Y", value: frame.center.y) { y in
                    sketch.setSelectionCenter(y: y)
                }
                // Eingabe gilt einmal (Wert springt danach zurück auf 100 % bzw. 0°)
                PaletteNumberRow(title: "Skalieren", value: 100, unit: "%") { percent in
                    guard percent > 0 else { return }
                    sketch.scaleSelection(by: percent / 100)
                }
                PaletteNumberRow(title: "Drehen", value: 0, unit: "°") { degrees in
                    sketch.rotateSelection(by: degrees * .pi / 180)
                }
                HStack(spacing: PaletteStyle.spacing) {
                    Button {
                        sketch.rotateSelection(by: .pi / 2)
                    } label: {
                        Label("90°", systemImage: "rotate.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .hoverTip("Drehen", "Auswahl um 90° gegen den Uhrzeigersinn drehen (um ihre Mitte).")
                    Button {
                        sketch.rotateSelection(by: -.pi / 2)
                    } label: {
                        Label("90°", systemImage: "rotate.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .hoverTip("Drehen", "Auswahl um 90° im Uhrzeigersinn drehen (um ihre Mitte).")
                }
            }
        }
    }
}
