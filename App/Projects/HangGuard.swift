import Foundation

/// Sicherheitsnetz gegen Hänger und Abstürze (Kai: variable Rundungen, die ineinanderlaufen, hingen in OCCT).
///
/// Vor dem Öffnen eines Projekts und vor jedem Feature des Nachbaus liegt im Projektordner die kleine Datei
/// „haenger.json“ (Phase, Feature). Nach Erfolg wird sie wieder gelöscht. Eine Datei statt UserDefaults, weil sie
/// sofort auf dem Datenträger steht – auch wenn iOS die eingefrorene App danach hart beendet.
///
/// Liegt die Datei beim nächsten Öffnen noch da, hing (oder stürzte) der letzte Versuch: Das Projekt wird im
/// sicheren Modus geöffnet (ModelStore.openSafely): Verlauf ohne model.step bis vor das hängende Feature
/// nachbauen, dieses und alle folgenden unterdrücken. Gelöscht wird nichts; model.step und features.json werden
/// vorher gesichert.
enum HangGuard {
    enum Phase: String, Codable {
        /// Projekt wird geladen (model.step lesen, Netz rechnen, erste Darstellung)
        case open
        /// Ein Feature wird nachgebaut (runFeatures)
        case replay
    }

    struct Marker: Codable {
        var phase: Phase
        var featureID: UUID?
        var featureName: String?
        /// Nachbau lief während des Öffnens: danach wieder die Öffnen-Marke setzen statt löschen
        var duringOpen = false
        var date = Date()
    }

    static func url(in folder: URL) -> URL {
        folder.appending(path: "haenger.json")
    }

    /// Übrig gebliebene Marke (= der letzte Versuch hing bzw. stürzte ab); nil = alles in Ordnung.
    static func marker(in folder: URL?) -> Marker? {
        guard let folder, let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        // Unlesbare Marke: trotzdem als Hänger werten (sicherer Modus mit dem letzten Feature)
        return (try? JSONDecoder().decode(Marker.self, from: data)) ?? Marker(phase: .open)
    }

    static func hasMarker(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: folder).path(percentEncoded: false))
    }

    private static func write(_ marker: Marker, in folder: URL) {
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: url(in: folder), options: .atomic)
        }
    }

    static func clear(in folder: URL?) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: url(in: folder))
    }

    // MARK: Öffnen

    /// Vor dem Laden eines Projekts.
    static func beginOpen(in folder: URL) {
        write(Marker(phase: .open), in: folder)
    }

    /// Projekt geladen und dargestellt.
    static func endOpen(in folder: URL) {
        if marker(in: folder)?.phase == .open { clear(in: folder) }
    }

    /// Startseite „Sicher öffnen“: wie nach einem Hänger beim Öffnen (letztes Feature wird unterdrückt).
    static func requestSafeOpen(in folder: URL) {
        if !hasMarker(in: folder) { write(Marker(phase: .open), in: folder) }
    }

    // MARK: Nachbau

    /// Vor dem Nachrechnen eines Features (runFeatures). Darf auch außerhalb des Hauptthreads laufen.
    static func willRun(_ feature: Feature, in folder: URL?) {
        guard let folder else { return }
        let current = marker(in: folder)
        if current?.phase == .replay, current?.featureID == feature.id { return }
        let duringOpen = current.map { $0.phase == .open || $0.duringOpen } ?? false
        write(Marker(phase: .replay, featureID: feature.id, featureName: feature.name, duringOpen: duringOpen), in: folder)
    }

    /// Nachbau beendet (erfolgreich oder mit gemeldetem Fehler – beides ist kein Hänger).
    static func didRun(in folder: URL?) {
        guard let folder, let current = marker(in: folder), current.phase == .replay else { return }
        if current.duringOpen {
            write(Marker(phase: .open), in: folder)
        } else {
            clear(in: folder)
        }
    }

    // MARK: Sicherung

    /// model.step und features.json einmalig sichern, bevor der sichere Modus sie neu schreibt.
    static func backupFiles(in folder: URL?) {
        guard let folder else { return }
        let manager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for name in ["model.step", "features.json", "bodies.json"] {
            let source = folder.appending(path: name)
            guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let target = folder.appending(path: "sicherung-\(stamp)-\(name)")
            try? manager.copyItem(at: source, to: target)
        }
    }
}

/// Plan des sicheren Öffnens: gespeicherter Verlauf und das Feature, ab dem unterdrückt wird.
struct SafeOpenPlan {
    var features: [Feature]
    /// Erstes unterdrücktes Feature; nil = nichts unterdrücken (nur aus den festen Ständen nachbauen)
    var hangIndex: Int?
}

/// Nur zum Lesen von features.json im sicheren Modus (FeatureFile in FeatureHistory.swift ist privat).
private struct SafeFeatureFile: Decodable {
    var features: [Feature]
}

extension ModelStore {
    /// Plan zum übrig gebliebenen Marker. nil = normal öffnen (das hängende Feature wurde nie gespeichert,
    /// z. B. eine Vorschau, oder es gibt keinen Verlauf zum Nachbauen).
    func safeOpenPlan(for marker: HangGuard.Marker) -> SafeOpenPlan? {
        guard PCKShape.stepAvailable, PCKShape.kernelAvailable,
              let url = folder?.appending(path: "features.json"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SafeFeatureFile.self, from: data),
              !file.features.isEmpty else { return nil }
        let list = file.features
        if marker.phase == .replay, let id = marker.featureID {
            // Hängendes Feature nicht im gespeicherten Verlauf: es wurde nie übernommen, model.step ist davor
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            return SafeOpenPlan(features: list, hangIndex: index)
        }
        // Hänger beim Öffnen: das neueste aktive Feature (kein fester Stand) gilt als Ursache
        let index = list.lastIndex { $0.kind != .snapshot && !$0.isSuppressed }
        return SafeOpenPlan(features: list, hangIndex: index)
    }

    /// Sicherer Modus (nach load ohne model.step): Verlauf bis vor das hängende Feature nachbauen, dieses und alle
    /// folgenden unterdrücken. Nichts wird gelöscht; die Dateien werden vorher gesichert.
    func openSafely(_ plan: SafeOpenPlan) {
        var list = plan.features
        var hangName: String?
        var following = 0
        if let start = plan.hangIndex, list.indices.contains(start) {
            hangName = list[start].name
            for index in start..<list.count where !list[index].isSuppressed {
                list[index].isSuppressed = true
                if index > start { following += 1 }
            }
        }
        features = list
        featureRecorder.cache = [:]
        HangGuard.backupFiles(in: folder)
        guard let run = runFeatures(&list, from: 0, sketches: sketches, values: variableValues), !run.bodies.isEmpty else {
            message = "Sicherer Modus: Der Verlauf ließ sich nicht nachbauen. Deine Dateien sind unverändert und "
                + "zusätzlich als „sicherung-…“ im Projektordner gesichert."
            return
        }
        featureRecorder.replacement = list
        commit(run.bodies, name: "Sicher geöffnet")
        if let hangName {
            let more = following > 0 ? " Die \(following) Features danach sind ebenfalls unterdrückt." : ""
            message = "Das Projekt hing beim Feature „\(hangName)“ – es wurde unterdrückt. "
                + "Du kannst es im Verlauf bearbeiten oder löschen.\(more)"
        } else {
            message = "Projekt im sicheren Modus aus dem Verlauf nachgebaut."
        }
    }
}
