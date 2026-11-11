import XCTest
@testable import PencilCAD

/// Build 61 (Kai): offene Skizze überlebt ein App-Update (Beenden ohne „Fertig“).
@MainActor
final class SketchDraftTests: XCTestCase {
    func testOpenSketchIsRestoredAfterRestart() throws {
        let project = Project(id: UUID(), name: "Entwurf", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        let first = Workspace(project: project)
        first.sketch.isActive = true
        first.sketch.load(plane: .ground, entities: [.line([0, 0], [10, 0])])
        first.saveSketchDraft()
        // App „abgeschossen“: kein Fertig. Neu öffnen stellt die Skizze her.
        let second = Workspace(project: project)
        XCTAssertTrue(second.model.sketches.isEmpty)
        second.restoreSketchDraft()
        XCTAssertEqual(second.model.sketches.count, 1)
        XCTAssertEqual(second.model.sketches.first?.entities.count, 1)
        // Danach ist der Entwurf weg
        let third = Workspace(project: project)
        third.restoreSketchDraft()
        XCTAssertEqual(third.model.sketches.count, 1)
    }
}
