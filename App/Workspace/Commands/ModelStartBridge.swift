import SwiftUI

// Brücke zwischen Leiste (Ribbon, ModelRibbon.swift) und Befehlsrahmen (Paket M1): Solange `workspace.start(_:)`
// und `workspace.command` noch fehlen, baut startCommand den Befehl über seinen Treiber (der dabei das bisherige
// Werkzeug startet) bzw. startet ohne Treiber das bisherige Werkzeug direkt. Nach dem Zusammenführen ruft
// startCommand nur noch `start(id)` auf.

extension ModelCommands {
    /// Befehle, bei denen Antippen im Viewport weiter über Workspace.tapped läuft (eigene Regeln: Messen,
    /// Konstruieren, Druckprüfung …); das Panel zeigt nur Werte. Wird in registerModify() gefüllt.
    /// TODO-MERGE: workspace.tapped – bei offenem Befehl mit dieser ID (oder ohne Auswahlfelder) den bisherigen Weg
    /// nehmen statt `command.pick`.
    static var legacyTapIDs: Set<ModelCommandID> = []

    /// Treiber, die Features des Verlaufs bearbeiten (Doppeltippen in der Zeitleiste). Wird in registerModify()
    /// gefüllt.
    static var editors: [FeatureKind: ModelCommandID] = [:]

    /// Läuft Antippen bei diesem Befehl über den bisherigen Weg?
    static func usesLegacyTaps(_ cmd: ModelCommand) -> Bool {
        if drivers.isEmpty { registerAll() }
        return legacyTapIDs.contains(cmd.id) || cmd.inputs.isEmpty
    }
}

/// Zuletzt über die Brücke gebauter Befehl, solange `workspace.command` (M1) fehlt.
@MainActor
enum ModelCommandBridge {
    static var pending: ModelCommand?
}

extension Workspace {
    /// Befehl aus Leiste, Kontextmenü oder Werkzeugrad starten.
    func startCommand(_ id: ModelCommandID) {
        // TODO-MERGE: workspace.start – nach dem Zusammenführen mit M1 nur noch:
        //     start(id)
        //     return
        if let driver = ModelCommands.driver(id) {
            // Der Treiber startet das bisherige Werkzeug und übernimmt die Vorauswahl; ohne FeaturePanel zeigt die
            // bisherige Karte unten die Werte.
            ModelCommandBridge.pending = driver.make(self)
        } else {
            ModelCommandBridge.pending = nil
            startLegacyCommand(id)
        }
    }

    /// Feature aus dem Verlauf im Eigenschaften-Panel bearbeiten. false = (noch) nicht möglich, die Zeitleiste zeigt
    /// dann das kleine Fenster mit den Werten.
    func editFeatureInPanel(_ feature: Feature) -> Bool {
        guard feature.kind != .snapshot, !sketch.isActive else { return false }
        if ModelCommands.drivers.isEmpty { ModelCommands.registerAll() }
        guard let id = ModelCommands.editors[feature.kind], let driver = ModelCommands.driver(id),
              driver.load(feature, into: self) != nil else { return false }
        // TODO-MERGE: workspace.command – nach dem Zusammenführen mit M1:
        //     cancelCommand()
        //     command = driver.load(feature, into: self)
        //     return command != nil
        return false
    }

    /// Feature, das gerade im Panel bearbeitet wird (Kapsel „· bearbeiten“ in der Zeitleiste).
    var editingFeatureID: UUID? {
        // TODO-MERGE: workspace.command – command?.editing
        nil
    }

    /// Bisheriges Werkzeug eines Befehls (nil = Auswahlwerkzeug bzw. eigener Ablauf).
    static func legacyModelTool(for id: ModelCommandID) -> ModelTool? {
        switch id {
        case .revolve: return .revolve
        case .sweep: return .sweep
        case .loft: return .loft
        case .hole: return .hole
        case .thread: return .part(.thread)
        case .box: return .insert(.box)
        case .cylinder: return .insert(.cylinder)
        case .sphere: return .insert(.sphere)
        case .torus: return .insert(.torus)
        case .cone: return .insert(.cone)
        case .helix: return .part(.helix)
        case .thinExtrude: return .part(.thinLines)
        case .shell: return .shell
        case .draft: return .part(.draft)
        case .offsetFace: return .offsetFace
        case .replaceFace: return .replaceFace
        case .combine: return .boolean(.union)
        case .splitBody: return .split
        case .scale: return .scale
        case .move, .copy: return .move
        case .translate: return .translate
        case .align: return .align
        case .mirror: return .mirror
        case .patternRect: return .pattern(.linear)
        case .patternCircular: return .pattern(.circular)
        case .constructPlane: return .construct(.plane)
        case .constructAxis: return .construct(.axis)
        case .constructPoint: return .construct(.point)
        case .measure: return .measure
        case .section: return .section
        case .wrap: return .wrap
        case .imprint: return .imprint
        case .offsetEdges: return .offsetEdges
        case .mold: return .mold
        case .printCheck: return .printCheck
        case .meshSculpt: return .meshSculpt
        case .extrude, .fillet, .chamfer, .pressPull, .deleteFace: return nil
        }
    }

    /// Bisheriger Weg ohne Treiber (wie die frühere Werkzeugleiste).
    func startLegacyCommand(_ id: ModelCommandID) {
        switch id {
        case .extrude, .pressPull:
            // Wie Shapr3D: Skizzenbereich oder ebene Fläche antippen, dann am Pfeil ziehen
            if tool != .select || sketch.isActive { activate(.select) }
            if model.faceHandle == nil, model.selectedRegions.isEmpty {
                model.message = model.sketches.isEmpty
                    ? "Erst eine Skizze mit geschlossenem Profil zeichnen, oder eine ebene Fläche antippen."
                    : "Skizzenbereich oder ebene Fläche antippen, dann am blauen Pfeil ziehen."
            }
        case .fillet:
            startEdgeOperation(.fillet)
        case .chamfer:
            startEdgeOperation(.chamfer)
        case .move:
            activate(.move)
            model.moveCopies = false
        case .copy:
            activate(.move)
            // Skizzen werden nur verschoben, nie kopiert
            model.moveCopies = model.movingSketch == nil
        case .hole:
            activate(.hole)
            if holeSpec.thread != nil { setHoleThread(nil) }
        case .deleteFace:
            model.message = "Fläche löschen braucht noch eine Kernel-Funktion – vorerst „Fläche ersetzen“ nutzen."
        default:
            if let legacy = Self.legacyModelTool(for: id) { activate(legacy) }
        }
    }

    /// Gewindebohrung (Bohrung mit Gewinde), wie bisher „Löcher › Gewindebohrung“.
    func startTappedHole() {
        activate(.hole)
        setHoleThread(holeSpec.thread ?? HoleThread())
    }
}
