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

/// Liste aller Projekte, neueste zuerst.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    /// Erhöht sich, wenn sich Vorschaubilder geändert haben.
    @Published private(set) var thumbnailRevision = 0

    nonisolated static var root: URL { URL.documentsDirectory.appending(path: "Projects", directoryHint: .isDirectory) }

    private struct Info: Codable {
        var name: String
        var modified: Date
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
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
        try? FileManager.default.copyItem(at: original.folder, to: copy.folder)
        write(copy)
        reload()
    }

    func delete(_ id: UUID) {
        guard let project = project(id) else { return }
        try? FileManager.default.removeItem(at: project.folder)
        reload()
    }

    // MARK: Intern

    private func write(_ project: Project) {
        if let data = try? JSONEncoder().encode(Info(name: project.name, modified: project.modified)) {
            try? data.write(to: project.infoURL)
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
