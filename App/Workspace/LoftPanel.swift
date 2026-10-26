import SwiftUI

/// Loft-Karte, zweiter Teil: Führungen hinzufügen bzw. entfernen und Tangentenbedingung
/// (eingebunden in ParameterCard.loftCard, Logik in LoftGuides.swift).
struct LoftGuideControls: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore

    private static let guideSymbol = "point.topleft.down.to.point.bottomright.curvepath"
    private static let guideTip = "Skizzenkurve, an der der Loft entlangläuft. Die erste Führung führt die Querschnitte, "
        + "eine zweite steuert die Verdrehung. Sie sollte am ersten Querschnitt beginnen und durch alle Querschnitte laufen."

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.pathSketches, id: \.self) { index in
                    Section(model.sketches[index].name) {
                        Button("Alle offenen Kurven", systemImage: Self.guideSymbol) {
                            add(LoftGuide(sketch: index))
                        }
                        ForEach(model.loftGuideCandidates(inSketch: index)) { candidate in
                            Button(candidate.title) {
                                add(LoftGuide(sketch: index, entities: [candidate.entity]))
                            }
                        }
                    }
                }
            } label: {
                Label("Führung hinzufügen", systemImage: Self.guideSymbol)
            }
            .disabled(workspace.loft.guides.count >= LoftSettings.maxGuides || model.pathSketches.isEmpty)
            .fixedSize()
            .hoverTip("Führung hinzufügen", Self.guideTip)
            ForEach(Array(workspace.loft.guides.enumerated()), id: \.element.id) { number, guide in
                guideChip(guide, number: number)
            }
            Toggle("Start tangential", isOn: binding(\.tangentStart))
                .fixedSize()
                .hoverTip("Start tangential", "Der Loft verlässt den ersten Querschnitt senkrecht zu dessen Skizzenebene.")
            Toggle("Ende tangential", isOn: binding(\.tangentEnd))
                .fixedSize()
                .hoverTip("Ende tangential", "Der Loft läuft senkrecht zur Skizzenebene in den letzten Querschnitt ein.")
        }
    }

    private func guideChip(_ guide: LoftGuide, number: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: number == 0 ? Self.guideSymbol : "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.accentColor)
            Text(model.loftGuideTitle(guide))
                .lineLimit(1)
            Button {
                remove(guide)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .fixedSize()
        .hoverTip(number == 0 ? "Leitkurve" : "Hilfsleitkurve (Verdrehung)")
    }

    private func add(_ guide: LoftGuide) {
        guard !workspace.loft.guides.contains(guide), workspace.loft.guides.count < LoftSettings.maxGuides else { return }
        workspace.loft.guides.append(guide)
        workspace.updatePreview()
    }

    private func remove(_ guide: LoftGuide) {
        workspace.loft.guides.removeAll { $0 == guide }
        workspace.updatePreview()
    }

    private func binding(_ keyPath: WritableKeyPath<LoftSettings, Bool>) -> Binding<Bool> {
        Binding(get: { workspace.loft[keyPath: keyPath] }, set: { value in
            workspace.loft[keyPath: keyPath] = value
            workspace.updatePreview()
        })
    }
}
