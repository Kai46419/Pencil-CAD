import SwiftUI

// „OK und Abbrechen in der Ecke der Ansicht“ nach SolidCraft (docs/book/src/guide/ui-tour.md, dialogs.rs:2742-2745,
// :2953-2962): großer Haken und großes Kreuz oben rechts unter dem Ansichtswürfel, solange ein Modellbefehl offen
// ist. Auf dem iPad standardmäßig an (Kai) – mit dem Stift schneller erreichbar als der Panel-Fuß.

struct CornerConfirm: View {
    /// AppStorage-Schlüssel des Schalters (Panel-Menü „OK und Abbrechen in der Ecke“)
    static let storageKey = "panel.cornerConfirm"

    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var command: ModelCommand
    @AppStorage(Self.storageKey) private var isOn = true

    var body: some View {
        if isOn {
            let canCommit = workspace.canConfirmCommand
            HStack(spacing: 12) {
                Button {
                    workspace.cancelCommand()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .floatingSurface(Theme.surface, in: Circle(), elevation: .floating)
                }
                .accessibilityLabel("Abbrechen")
                .hoverTip("Abbrechen", "Nichts wird geändert (Esc).")
                Button {
                    workspace.confirmCommand()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .floatingSurface(canCommit ? SketchTheme.accent : Color.gray, in: Circle(), elevation: .floating)
                }
                .disabled(!canCommit)
                .accessibilityLabel("OK")
                .hoverTip("OK", "Übernehmen – ein Schritt zum Rückgängigmachen (Enter).")
            }
            .buttonStyle(.pressable)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
