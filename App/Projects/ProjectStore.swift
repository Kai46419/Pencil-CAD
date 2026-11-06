import Foundation

/// Ein Projekt: Ordner unter Documents/Projects/<id> mit project.json, model.step, bodies.json und thumbnail.png.
struct Project: Identifiable, Hashable {
    let id: UUID
    var name: String
    var modified: Date

    var folder: URL { ProjectStore.root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    var thumbnailURL: URL { folder.appending(path: "thumbnail.png") }
    var infoURL: URL { folder.appending(path: "project.json") }
}

/// Eigenständige Kopie eines Projekts, die auch nach dessen Löschung erhalten bleibt.
struct ProjectBackup: Identifiable {
    let id: UUID
    let originalProjectID: UUID
    let name: String
    let created: Date
    let folder: URL
}

private struct ProjectBackupInfo: Codable {
    let id: UUID
    let originalProjectID: UUID
    let name: String
    let created: Date
}

private enum ProjectBackupError: LocalizedError {
    case missingProject
    case missingBackup

    var errorDescription: String? {
        switch self {
        case .missingProject: "Projekt nicht gefunden."
        case .missingBackup: "Sicherung nicht gefunden."
        }
    }
}

/// Liste aller Projekte, neueste zuerst.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var backups: [ProjectBackup] = []
    /// Erhöht sich, wenn sich Vorschaubilder geändert haben.
    @Published private(set) var thumbnailRevision = 0
    /// Erhöht sich, wenn sich Hänger-Marken geändert haben könnten (HangGuard.swift, Hinweis auf der Startseite)
    @Published var markerRevision = 0
    @Published private(set) var lastWriteError: String?

    nonisolated static var root: URL { URL.documentsDirectory.appending(path: "Projects", directoryHint: .isDirectory) }
    nonisolated static var backupRoot: URL { URL.documentsDirectory.appending(path: "ProjectBackups", directoryHint: .isDirectory) }

    private struct Info: Codable {
        var name: String
        var modified: Date
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        removeIncompleteCopies()
        migrateAutosave()
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        projects = folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let info = (try? Data(contentsOf: folder.appending(path: "project.json")))
                .flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
            return Project(id: id, name: info?.name ?? "Titelloses Projekt", modified: info?.modified ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
        reloadBackups()
    }

    func reloadBackups() {
        let parents = (try? FileManager.default.contentsOfDirectory(at: Self.backupRoot, includingPropertiesForKeys: nil)) ?? []
        backups = parents.flatMap { parent -> [ProjectBackup] in
            let folders = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            return folders.compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appending(path: "backup.json")),
                      let info = try? JSONDecoder().decode(ProjectBackupInfo.self, from: data),
                      folder.lastPathComponent == info.id.uuidString,
                      parent.lastPathComponent == info.originalProjectID.uuidString else { return nil }
                return ProjectBackup(id: info.id, originalProjectID: info.originalProjectID,
                                     name: info.name, created: info.created, folder: folder)
            }
        }.sorted { $0.created > $1.created }
    }

    /// Sichert den gesamten Projektordner einschließlich Verlauf und Geometrie.
    @discardableResult
    func makeBackup(_ id: UUID) throws -> ProjectBackup {
        guard let project = project(id), FileManager.default.fileExists(atPath: project.folder.path) else {
            throw ProjectBackupError.missingProject
        }
        let parent = Self.backupRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let backupID = UUID()
        let folder = parent.appending(path: backupID.uuidString, directoryHint: .isDirectory)
        // N7 (Build 41): erst in einen versteckten Arbeitsordner kopieren, dann umbenennen – ein Abbruch hinterlässt
        // höchstens „.backup-…“, das removeIncompleteCopies beim nächsten Start entfernt
        let staging = parent.appending(path: "\(Self.backupStagingPrefix)\(backupID.uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.copyItem(at: project.folder, to: staging)
            let info = ProjectBackupInfo(id: backupID, originalProjectID: id,
                                         name: project.name, created: .now)
            try JSONEncoder().encode(info).write(to: staging.appending(path: "backup.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: folder)
            reloadBackups()
            return ProjectBackup(id: info.id, originalProjectID: id, name: info.name,
                                 created: info.created, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static let backupStagingPrefix = ".backup-"

    /// Stellt die Sicherung als neues Projekt her; das vorhandene Projekt bleibt unberührt.
    @discardableResult
    func restoreBackup(_ id: UUID) throws -> Project {
        guard let backup = backups.first(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: backup.folder.path) else {
            throw ProjectBackupError.missingBackup
        }
        let restored = Project(id: UUID(), name: backup.name + " (wiederhergestellt)", modified: .now)
        let staging = Self.root.appending(path: ".restore-\(restored.id.uuidString)")
        do {
            try FileManager.default.copyItem(at: backup.folder, to: staging)
            try? FileManager.default.removeItem(at: staging.appending(path: "backup.json"))
            try JSONEncoder().encode(Info(name: restored.name, modified: restored.modified))
                .write(to: staging.appending(path: "project.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: restored.folder)
            reload()
            return restored
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: restored.folder)
            throw error
        }
    }

    func deleteBackup(_ id: UUID) throws {
        guard let backup = backups.first(where: { $0.id == id }) else {
            throw ProjectBackupError.missingBackup
        }
        try FileManager.default.removeItem(at: backup.folder)
        reloadBackups()
    }

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func create(name: String? = nil) -> Project {
        let project = Project(id: UUID(), name: name ?? nextName(), modified: .now)
        try? FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        write(project)
        reload()
        return project
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var project = project(id), !trimmed.isEmpty else { return }
        project.name = trimmed
        write(project)
        reload()
    }

    /// Änderungsdatum setzen (beim Schließen) und Vorschaubilder neu laden.
    func touch(_ id: UUID) {
        guard var project = project(id) else { return }
        project.modified = .now
        write(project)
        reload()
        thumbnailRevision += 1
    }

    func duplicate(_ id: UUID) {
        guard let original = project(id) else { return }
        let copy = Project(id: UUID(), name: "\(original.name) Kopie", modified: .now)
        let staging = Self.root.appending(path: ".duplicate-\(copy.id.uuidString)")
        do {
            try FileManager.default.copyItem(at: original.folder, to: staging)
            try JSONEncoder().encode(Info(name: copy.name, modified: copy.modified))
                .write(to: staging.appending(path: "project.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: copy.folder)
            lastWriteError = nil
        } catch {
            try? FileManager.default.removeItem(at: staging)
            lastWriteError = "Projektkopie konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
        reload()
    }

    func delete(_ id: UUID) {
        guard let project = project(id) else { return }
        try? FileManager.default.removeItem(at: project.folder)
        reload()
    }

    /// Mehrere Projekte auf einmal löschen (Auswahlmodus der Startseite).
    func delete(_ ids: Set<UUID>) {
        for id in ids {
            if let project = project(id) { try? FileManager.default.removeItem(at: project.folder) }
        }
        reload()
    }

    // MARK: Intern

    private func removeIncompleteCopies() {
        let manager = FileManager.default
        for folder in (try? manager.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
            let name = folder.lastPathComponent
            let prefix = name.hasPrefix(".duplicate-") ? ".duplicate-" : ".restore-"
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            try? manager.removeItem(at: folder)
        }
        // N7 (Build 41): abgebrochene Sicherungen – Arbeitsordner „.backup-<id>“ und (ältere Versionen) Sicherungs-
        // ordner ohne backup.json, die reloadBackups nie zeigt
        let parents = (try? manager.contentsOfDirectory(at: Self.backupRoot, includingPropertiesForKeys: nil)) ?? []
        for parent in parents where UUID(uuidString: parent.lastPathComponent) != nil {
            for folder in (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                let name = folder.lastPathComponent
                let staging = name.hasPrefix(Self.backupStagingPrefix)
                    && UUID(uuidString: String(name.dropFirst(Self.backupStagingPrefix.count))) != nil
                let unfinished = UUID(uuidString: name) != nil
                    && !manager.fileExists(atPath: folder.appending(path: "backup.json").path(percentEncoded: false))
                if staging || unfinished { try? manager.removeItem(at: folder) }
            }
        }
    }

    private func write(_ project: Project) {
        do {
            try JSONEncoder().encode(Info(name: project.name, modified: project.modified))
                .write(to: project.infoURL, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = "Projektinformationen konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func nextName() -> String {
        let names = Set(projects.map(\.name))
        if !names.contains("Titelloses Projekt") { return "Titelloses Projekt" }
        var number = 2
        while names.contains("Titelloses Projekt \(number)") { number += 1 }
        return "Titelloses Projekt \(number)"
    }

    /// Frühere Versionen speicherten alles in Documents/Autosave.step. Das wird zum ersten Projekt.
    private func migrateAutosave() {
        let old = URL.documentsDirectory.appending(path: "Autosave.step")
        guard FileManager.default.fileExists(atPath: old.path(percentEncoded: false)) else { return }
        let project = Project(id: UUID(), name: "Titelloses Projekt", modified: .now)
        do {
            try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: old, to: project.folder.appending(path: "model.step"))
            write(project)
        } catch {
            try? FileManager.default.removeItem(at: project.folder)
        }
    }
}
