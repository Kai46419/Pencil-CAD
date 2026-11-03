import SwiftUI
import simd

// MARK: - Gewinde: Umschalter „Modelliert / Kosmetisch“, Toleranz-Vorlagen, Ringe kosmetischer Gewinde im Viewport

/// Umschalter „Modelliert / Kosmetisch“ (Karte des Gewinde-Werkzeugs und Gewindebohrung).
struct ThreadModePicker: View {
    let cosmetic: Bool
    let set: (Bool) -> Void

    var body: some View {
        Picker("Ausführung", selection: Binding(get: { cosmetic }, set: { set($0) })) {
            Text("Modelliert").tag(false)
            Text("Kosmetisch").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .hoverTip("Modelliert / Kosmetisch", "Modelliert: echtes, druckbares Gewinde. Kosmetisch: keine Gewindegeometrie (schnell) – Bohrungen bekommen nur das Kernloch, Bolzen bleiben unverändert; das Gewinde steht als Eigenschaft am Körper und wird als dünne Ringe gezeigt.")
    }
}

/// Menü neben dem Druckspiel: Vorlagen für Fertigungsverfahren; die letzte Wahl wird gemerkt.
struct ThreadTolerancePresetMenu: View {
    let value: Double
    let apply: (Double) -> Void

    @AppStorage("thread.tolerancePreset") private var chosen = ""

    var body: some View {
        Menu {
            ForEach(ThreadTolerancePreset.allCases) { preset in
                let current: Bool = chosen == preset.rawValue && abs(value - preset.clearance) < 1e-9
                Button {
                    chosen = preset.rawValue
                    apply(preset.clearance)
                } label: {
                    if current {
                        Label("\(preset.title) mm", systemImage: "checkmark")
                    } else {
                        Text("\(preset.title) mm")
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .fixedSize()
        .hoverTip("Toleranz-Vorlagen", "Druckspiel je Verfahren: FDM 0,3 mm, Harz (SLA) 0,1 mm, Fräsen bzw. Schneiden nach ISO 6H/6g 0 mm. Die letzte Wahl gilt für neue Gewinde; im Feld ist jeder Wert möglich.")
    }
}

extension ViewportView {
    /// Kosmetische Gewinde: dünne Ringe im Abstand der Steigung entlang der Gewindelänge (ThreadNotes.swift).
    func addCosmeticThreads(to groups: inout [LineGroup]) {
        guard let model = workspace?.model else { return }
        let lines: [[SIMD3<Float>]] = CosmeticThreadOverlay.shared.lines(for: model.shownBodies)
        guard !lines.isEmpty else { return }
        groups.append(LineGroup(polylines: lines, color: SIMD3<Float>(0.32, 0.34, 0.4), width: 1, onTop: false))
    }
}
