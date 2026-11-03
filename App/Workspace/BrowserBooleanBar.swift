import SwiftUI

// Browser „Ebenen“ › Ordner „Körper“: Auswählen-Modus und Kombinieren direkt aus der Liste (Kai).
// Die Auswahl ist dieselbe wie im Viewport (ModelStore.selectedBodies); gerechnet wird mit dem
// vorhandenen applyBoolean (ein Rückgängig-Schritt, Verlaufseintrag wie bei Kombinieren).

struct BrowserBooleanBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @Binding var picking: Bool

    private var chosen: [Int] { model.selectedBodies.filter { model.bodies.indices.contains($0) } }

    /// Kombinieren nur im Auswahlwerkzeug (ein offener Befehl hat seine eigene Leiste)
    private var canCombine: Bool { chosen.count >= 2 && workspace.tool == .select }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if canCombine {
                targetRow
                actions
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { picking.toggle() }
            } label: {
                Label(picking ? "Fertig" : "Auswählen",
                      systemImage: picking ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTip("Mehrere Körper wählen", "Häkchen setzen, dann Vereinigen, Subtrahieren oder Schneiden.")
            Spacer(minLength: 0)
            if !chosen.isEmpty {
                Text("\(chosen.count) gewählt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.resetSelection()
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hoverTip("Auswahl aufheben")
            }
        }
    }

    /// Ziel beim Subtrahieren (erster gewählter Körper), mit Tauschen auf den nächsten.
    private var targetRow: some View {
        HStack(spacing: 6) {
            Text("Ziel:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(chosen.first.map { model.bodies[$0].name } ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                swapTarget()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTip("Ziel tauschen", "Der nächste gewählte Körper wird Ziel, die übrigen Werkzeuge.")
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            actionButton(.union, title: "Vereinigen")
            actionButton(.subtract, title: "Subtrahieren")
            actionButton(.intersect, title: "Schneiden")
        }
    }

    private func actionButton(_ kind: BooleanKind, title: String) -> some View {
        Button {
            combine(kind)
        } label: {
            VStack(spacing: 2) {
                ToolIcon(kind.systemImage, size: 18)
                    .frame(height: 20)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Ziel weiterschalten: [A, B, C] → [B, C, A]
    private func swapTarget() {
        let list = chosen
        guard let first = list.first, list.count > 1 else { return }
        model.selectBodies(Array(list.dropFirst()) + [first])
    }

    /// Erster gewählter Körper = Ziel, die weiteren = Werkzeuge; ein Rückgängig-Schritt.
    private func combine(_ kind: BooleanKind) {
        let list = chosen
        guard let target = list.first, list.count > 1 else { return }
        let revision = model.revision
        model.dropPreview()
        model.applyBoolean(kind, target: target, tools: Array(list.dropFirst()), keepTools: false,
                           clearance: workspace.booleanClearance(kind))
        // Fehlgeschlagen (Meldung steht oben): Auswahl behalten, damit Kai es anders versuchen kann
        guard model.revision != revision else { return }
        model.resetSelection()
        picking = false
    }
}
