import XCTest
@testable import PencilCAD

@MainActor
final class ProjectSaveTransactionTests: XCTestCase {
    func testInterruptedModelWriteRestoresPreviousSnapshotOnReopen() throws {
        let store = ProjectStore()
        let project = store.create(name: "Transaktionstest \(UUID().uuidString)")
        defer { store.delete(project.id) }

        let model = Workspace(project: project).model
        model.previewInsert(.box, size: [20, 30, 10], at: .zero)
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 1)
        XCTAssertNil(model.message)

        let names = ["model.step", "bodies.json", "features.json", "sketches.json"]
        let previous = try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: project.folder.appending(path: name)))
        })
        try ProjectSaveTransaction.begin(in: project.folder)
        try Data("unterbrochene STEP-Datei".utf8).write(to: project.folder.appending(path: "model.step"))
        try Data("{".utf8).write(to: project.folder.appending(path: "bodies.json"))
        try Data("{".utf8).write(to: project.folder.appending(path: "features.json"))
        try FileManager.default.createDirectory(at: project.folder.appending(path: "features"),
                                                withIntermediateDirectories: true)
        let orphan = project.folder.appending(path: "features/\(UUID().uuidString).step")
        try Data("abgebrochener Snapshot".utf8).write(to: orphan)
        let abandonedSTEP = project.folder.appending(path: ".model-\(UUID().uuidString).step")
        try Data("unvollständig".utf8).write(to: abandonedSTEP)
        let abandonedPreparation = project.folder.appending(path: ".model-save-preparing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: abandonedPreparation, withIntermediateDirectories: false)

        let reopened = Workspace(project: project).model
        XCTAssertEqual(reopened.bodies.count, 1)
        XCTAssertEqual(reopened.features.count, 1)
        XCTAssertEqual(reopened.bodies[0].name, model.bodies[0].name)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: project.folder.appending(path: name)), previous[name])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedSTEP.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedPreparation.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.folder.appending(path: ".model-save-pending").path))

        reopened.previewInsert(.box, size: [8, 8, 8], at: [40, 0, 0])
        reopened.commitPreview()
        XCTAssertEqual(Workspace(project: project).model.bodies.count, 2)
    }

    func testProjectDuplicatePublishesCompleteReopenableCopy() throws {
        let store = ProjectStore()
        let original = store.create(name: "Kopiertest \(UUID().uuidString)")
        var copiedID: UUID?
        defer {
            if let copiedID { store.delete(copiedID) }
            store.delete(original.id)
        }
        let model = Workspace(project: original).model
        model.previewInsert(.box, size: [12, 12, 12], at: .zero)
        model.commitPreview()

        store.duplicate(original.id)
        XCTAssertNil(store.lastWriteError)
        let copied = try XCTUnwrap(store.projects.first { $0.name == original.name + " Kopie" })
        copiedID = copied.id
        XCTAssertEqual(Workspace(project: copied).model.bodies.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.infoURL.path))

        let incompleteCopy = ProjectStore.root.appending(path: ".duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: incompleteCopy, withIntermediateDirectories: false)
        let restartedStore = ProjectStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: incompleteCopy.path))
        XCTAssertTrue(restartedStore.projects.contains { $0.id == copied.id })
    }

    func testCommittedMarkerKeepsNewFilesOnReopen() throws {
        let store = ProjectStore()
        let project = store.create(name: "Commit-Marke \(UUID().uuidString)")
        defer { store.delete(project.id) }
        let model = Workspace(project: project).model
        model.previewInsert(.box, size: [10, 10, 10], at: .zero)
        model.commitPreview()

        try ProjectSaveTransaction.begin(in: project.folder)
        let changedMeta = Data("[{\"name\":\"Nach Commit\",\"color\":[0.5,0.5,0.5],\"isHidden\":false}]".utf8)
        try changedMeta.write(to: project.folder.appending(path: "bodies.json"), options: .atomic)
        try Data().write(to: project.folder.appending(path: ".model-save-pending/committed"), options: .atomic)

        let reopened = Workspace(project: project).model
        XCTAssertEqual(reopened.bodies.first?.name, "Nach Commit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.folder.appending(path: ".model-save-pending").path))
    }
}
