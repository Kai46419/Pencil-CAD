import SwiftUI

// Projekteinheit wählen (Ebenen › Dokumenteinstellungen) und beim Öffnen des Projekts übernehmen.

extension Workspace {
    /// Beim Öffnen: Einheit des Projekts lesen, Fangraster passend zur Einheit.
    func loadLengthUnit() {
        let unit = LengthUnit.stored(in: project.folder)
        LengthUnit.current = unit
        if !unit.gridSteps.contains(where: { abs($0 - sketch.gridStep) < 1e-9 }) {
            sketch.gridStep = unit.nearestGridStep(to: sketch.gridStep)
        }
    }

    /// Fenster wird (wieder) aktiv: Die Einheit dieses Projekts gilt. LengthUnit.current ist global – mit zwei
    /// Fenstern (iPad) würde sonst das zuletzt geöffnete Projekt die Einheit des anderen bestimmen.
    func activateLengthUnit() {
        let unit = LengthUnit.stored(in: project.folder)
        guard unit != LengthUnit.current else { return }
        LengthUnit.current = unit
        objectWillChange.send()
        sketch.objectWillChange.send()
    }

    /// Projekt geschlossen: zurück auf mm, damit die Einheit nicht in Startseite bzw. nächstes Projekt durchsickert.
    static func resetLengthUnit() {
        LengthUnit.current = .mm
    }

    /// Einheit des Projekts ändern: nur Anzeige und Eingabe der Maße, die Geometrie bleibt unverändert (mm).
    func setLengthUnit(_ unit: LengthUnit) {
        guard unit != LengthUnit.current else { return }
        LengthUnit.current = unit
        unit.store(in: project.folder)
        sketch.gridStep = unit.nearestGridStep(to: sketch.gridStep)
        // Alles, was Maße zeigt, neu aufbauen
        objectWillChange.send()
        sketch.objectWillChange.send()
        model.message = "Einheit: \(unit.title) – Maße werden in \(unit.symbol) angezeigt und eingegeben."
    }
}

extension LayersPanel {
    /// Zeile „Einheiten“ in den Dokumenteinstellungen: antippen wählt mm, cm oder Zoll.
    var unitsRow: some View {
        Menu {
            Picker("Einheiten", selection: Binding(get: { LengthUnit.current },
                                                   set: { workspace.setLengthUnit($0) })) {
                ForEach(LengthUnit.allCases) { unit in
                    Text("\(unit.title) (\(unit.symbol))").tag(unit)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "ruler")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text("Einheiten: \(LengthUnit.current.symbol)")
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
