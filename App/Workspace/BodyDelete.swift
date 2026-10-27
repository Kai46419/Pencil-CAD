import SwiftUI

// Volumenkörper löschen (Kai, Punkt 11): Papierkorb in der Schnellwahl „Oberfläche“ rechts, sobald ein oder mehrere
// Körper gewählt sind, „Löschen“ im Kontextmenü (lange drücken im Viewport, BodyContextMenu.swift, und im Browser
// „Ebenen“). Gelöscht wird mit der vorhandenen Logik (ModelStore.deleteSelected): ein Rückgängig-Schritt und ein
// Lösch-Feature am Ende des Verlaufs (noteDelete). Weil es immer zuletzt steht, hängt kein späteres Feature an den
// gelöschten Körpern – darum ohne Rückfrage, mit Rückgängig-Hinweis.

extension ModelStore {
    /// Gewählte Körper; bei gewählter Fläche bzw. Kante deren Körper
    var deletableBodies: [Int] {
        let chosen: [Int] = selectedBodies.filter { bodies.indices.contains($0) }
        if !chosen.isEmpty { return chosen }
        if let body = selectedBody, bodies.indices.contains(body) { return [body] }
        return []
    }

    /// Körper löschen (ein Rückgängig-Schritt) und kurz melden, wie es sich zurücknehmen lässt.
    func deleteBodies(_ indices: [Int]) {
        var list: [Int] = []
        for index in indices where bodies.indices.contains(index) && !list.contains(index) {
            list.append(index)
        }
        guard !list.isEmpty else { return }
        let text: String = list.count == 1 ? "„\(bodies[list[0]].name)“ gelöscht" : "\(list.count) Körper gelöscht"
        if Set(list) != Set(deletableBodies) {
            selectBodies(list)
        }
        deleteSelected()
        // Körpernummern haben sich verschoben: nichts mehr gewählt
        clearSelection()
        message = text + " – zurückholen mit „Rückgängig“ (oder mit zwei Fingern tippen)."
    }

    /// Titel für Menüeinträge: „Löschen“ bzw. „3 Körper löschen“
    static func deleteTitle(count: Int) -> String {
        count > 1 ? "\(count) Körper löschen" : "Körper löschen"
    }
}

/// Papierkorb neben dem Kopf der Schnellwahl „Oberfläche“: löscht die gewählten Körper.
struct BodyTrashButton: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        let targets: [Int] = model.deletableBodies
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        Button(role: .destructive) {
            model.deleteBodies(targets)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.9))
                .frame(width: 32, height: 32)
                .background(PaletteStyle.field, in: shape)
                .overlay { shape.strokeBorder(PaletteStyle.controlBorder, lineWidth: 1) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(targets.isEmpty)
        .accessibilityLabel(ModelStore.deleteTitle(count: targets.count))
        .hoverTip(ModelStore.deleteTitle(count: targets.count), "Rückgängig holt sie zurück.")
    }
}
