import XCTest
import simd
@testable import PencilCAD

@MainActor
final class FeatureTimelinePersistenceTests: XCTestCase {
    func testFailedFilletDoesNotBlockMoveOnAnotherBody() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let project = Project(id: UUID(), name: "Rundung und unabhängiger Körper", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = ModelStore(folder: project.folder)
        model.previewInsert(.box, size: [10, 10, 10], at: .zero)
        model.commitPreview()
        model.previewInsert(.box, size: [5, 5, 5], at: [30, 0, 0])
        model.commitPreview()
        model.selectBodies([1])
        model.setMoveOffset([0, 2, 0])
        model.commitPreview()

        var invalidFillet = Feature(name: "Abrunden", kind: .fillet)
        invalidFillet.data.target = 0
        invalidFillet.data.edges = [try XCTUnwrap(ModelStore.edgeSignature(model.bodies[0].shape,
                                                                             edge: 1, body: 0))]
        invalidFillet.parameters = [.length("radius", "Radius", 0)]
        var list = model.features
        list.insert(invalidFillet, at: 2)
        let run = try XCTUnwrap(model.runFeatures(&list, from: 2, sketches: model.sketches,
                                                 values: model.variableValues))
        XCTAssertTrue(list[2].failed)
        XCTAssertFalse(list[3].failed)
        XCTAssertEqual(run.bodies.count, 2)
        let box = try XCTUnwrap(run.bodies[1].shape.boundingBox).map(\.doubleValue)
        XCTAssertEqual(box[1], -0.5, accuracy: 1e-5)
        XCTAssertNil(model.featureRecorder.cache[list[3].id],
                     "Ein teilweise ungültiger Stand darf keine Cachebasis werden")
    }

    func testSkippedMultiBodyStepBlocksLaterOtherwiseIndependentMove() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let project = Project(id: UUID(), name: "Abhängigkeiten über mehrere Körper", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = ModelStore(folder: project.folder)
        model.previewInsert(.box, size: [10, 10, 10], at: .zero)
        model.commitPreview()
        model.previewInsert(.box, size: [5, 5, 5], at: [30, 0, 0])
        model.commitPreview()
        model.selectBodies([1])
        model.setMoveOffset([0, 2, 0])
        model.commitPreview()

        var failedMove = Feature(name: "Ungültige Verschiebung", kind: .move)
        failedMove.data.bodies = [0]
        failedMove.parameters = [.length("x", "X", 0)]
        failedMove.parameters[0].formula = "unbekannt"
        var combined = Feature(name: "Zusammenführen", kind: .boolean)
        combined.data.target = 0
        combined.data.tools = [1]
        var list = model.features
        list.insert(contentsOf: [failedMove, combined], at: 2)
        let run = try XCTUnwrap(model.runFeatures(&list, from: 2, sketches: model.sketches,
                                                 values: model.variableValues))
        XCTAssertTrue(list[2].failed)
        XCTAssertTrue(list[3].failed)
        XCTAssertTrue(list[4].failed, "Der übersprungene Mehrkörper-Schritt könnte die Körperindizes ändern")
        XCTAssertEqual(run.bodies.count, 2)
    }

    func testIndependentBodyReplaysAfterLocalFailureAndRecovers() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let project = Project(id: UUID(), name: "Unabhängiger Verlauf", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = ModelStore(folder: project.folder)
        model.previewInsert(.box, size: [10, 10, 10], at: .zero)
        model.commitPreview()
        model.previewInsert(.box, size: [5, 5, 5], at: [30, 0, 0])
        model.commitPreview()
        for (body, offset) in [(0, SIMD3<Double>(1, 0, 0)),
                               (1, SIMD3<Double>(0, 2, 0)),
                               (0, SIMD3<Double>(0, 0, 3))] {
            model.selectBodies([body])
            model.setMoveOffset(offset)
            model.commitPreview()
        }
        XCTAssertEqual(model.features.map(\.kind), [.primitive, .primitive, .move, .move, .move])
        var broken = model.features
        let parameter = try XCTUnwrap(broken[2].parameters.firstIndex { $0.key == "x" })
        broken[2].parameters[parameter].formula = "unbekannt"
        let run = try XCTUnwrap(model.runFeatures(&broken, from: 2, sketches: model.sketches,
                                                 values: model.variableValues))
        XCTAssertTrue(broken[2].failed)
        XCTAssertFalse(broken[3].failed, "Körper B ist von der fehlgeschlagenen Änderung an A unabhängig")
        XCTAssertTrue(broken[4].failed, "Spätere Änderungen an A bleiben gesperrt")
        XCTAssertEqual(run.bodies.count, 2)
        let second = try XCTUnwrap(run.bodies[1].shape.boundingBox).map(\.doubleValue)
        XCTAssertEqual(second[1], -0.5, accuracy: 1e-5)

        broken[2].parameters[parameter].formula = nil
        broken[2].parameters[parameter].value = 1
        model.replayFeatures(from: 2, features: broken, sketches: nil, name: "Parameter reparieren")
        XCTAssertTrue(model.features.allSatisfy { !$0.failed })
        let first = try XCTUnwrap(model.bodies[0].shape.boundingBox).map(\.doubleValue)
        XCTAssertEqual(first[0], -4, accuracy: 1e-5)
        XCTAssertEqual(first[2], 3, accuracy: 1e-5)
        let ids = model.features.map(\.id)
        let reopened = ModelStore(folder: project.folder)
        XCTAssertEqual(reopened.features.map(\.id), ids)
        XCTAssertTrue(reopened.features.allSatisfy { !$0.failed })
        XCTAssertEqual(reopened.bodies.count, 2)
    }

    func testFullSnapshotResumesAfterEarlierFailure() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable && PCKShape.stepAvailable)
        let project = Project(id: UUID(), name: "Snapshot-Erholung", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = ModelStore(folder: project.folder)
        model.previewInsert(.box, size: [10, 10, 10], at: .zero)
        model.commitPreview()
        model.previewInsert(.box, size: [5, 5, 5], at: [30, 0, 0])
        model.commitPreview()
        model.commit([model.bodies[0]], name: "Gespeicherter Stand")
        model.previewInsert(.box, size: [4, 4, 4], at: [50, 0, 0])
        model.commitPreview()
        XCTAssertEqual(model.features.map(\.kind), [.primitive, .primitive, .snapshot, .primitive])
        XCTAssertEqual(model.features[2].data.snapshot?.full, true)
        var changed = model.features
        let x = try XCTUnwrap(changed[0].parameters.firstIndex { $0.key == "x" })
        changed[0].parameters[x].value = -1
        let run = try XCTUnwrap(model.runFeatures(&changed, from: 0, sketches: model.sketches,
                                                 values: model.variableValues))
        XCTAssertTrue(changed[0].failed)
        XCTAssertTrue(changed[1].failed)
        XCTAssertFalse(changed[2].failed, "Der vollständige gespeicherte Stand kann den Zustand wiederherstellen")
        XCTAssertFalse(changed[3].failed)
        XCTAssertEqual(run.bodies.count, 2)
        if run.bodies.count == 2 {
            XCTAssertEqual(run.bodies[0].shape.volume, 1_000, accuracy: 1e-5)
            XCTAssertEqual(run.bodies[1].shape.volume, 64, accuracy: 1e-5)
        }
    }

    func testProject14ScrewTapOverridesFilletAndCanMove() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable && PCKShape.stepAvailable)
        let project = Project(id: UUID(), name: "Projekt-14-Regression", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        for name in ["model.step", "bodies.json", "features.json"] {
            let parts = name.split(separator: ".")
            let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: String(parts[0]),
                                                                withExtension: String(parts[1])))
            try FileManager.default.copyItem(at: resource, to: project.folder.appending(path: name))
        }
        let workspace = Workspace(project: project)
        XCTAssertEqual(workspace.model.bodies.count, 5)
        XCTAssertEqual(workspace.model.bodies[4].name, "ISO 4762 M3×12")
        XCTAssertNotNil(workspace.model.bodies[4].effectiveStandardPart)
        let box = try XCTUnwrap(workspace.model.bodies[4].shape.boundingBox).map(\.doubleValue)
        let hit = (0..<11).lazy.flatMap { x in
            (0..<11).compactMap { y in
                let origin = SIMD3<Float>(Float(box[0] + (box[3] - box[0]) * (Double(x) + 0.5) / 11),
                                          Float(box[1] + (box[4] - box[1]) * (Double(y) + 0.5) / 11),
                                          Float(box[5] + 10))
                return workspace.model.pick(origin: origin, direction: [0, 0, -1])
            }
        }.first { $0.face.body == 4 }
        let screwHit = try XCTUnwrap(hit, "Die sichtbare Schraube muss im Viewport als Normteil getroffen werden")

        workspace.start(.fillet)
        XCTAssertNotNil(workspace.command)
        // In der Nähe des Schraubenkopfs kann der großzügige Kantenpicker eine Plattenkante finden.
        workspace.tapped(face: screwHit.face, edge: EdgeRef(body: 0, edge: 1))
        XCTAssertNil(workspace.command)
        XCTAssertEqual(workspace.tool, .move)
        XCTAssertEqual(workspace.model.selectedBodies, [4])
        XCTAssertTrue(workspace.model.selectedEdges.isEmpty)

        workspace.model.setMoveOffset([1.5, 0, 0])
        XCTAssertTrue(workspace.model.hasPreview)
    }

    func testLegacyScrewNameKeepsUnknownPropertiesExplicit() throws {
        let spec = try XCTUnwrap(StandardPartSpec.recognizedLegacyName("ISO 4762 M3×12"))
        XCTAssertEqual(spec.metric.name, "M3")
        XCTAssertEqual(spec.length, 12)
        XCTAssertFalse(spec.threadGeometryKnown)
        XCTAssertEqual(spec.propertyClass, "Nicht festgelegt")
        XCTAssertNil(StandardPartSpec.recognizedLegacyName("Beliebiger Körper M3×12"))
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.previewGenerated(PartBuilder.build(StandardPartSpec()), step: "Altes Normteil")
        model.commitPreview()
        XCTAssertNil(model.bodies[0].standardPart)
        model.setStandardPartClass("12.9", body: 0)
        XCTAssertEqual(model.bodies[0].standardPart?.propertyClass, "12.9")
        XCTAssertEqual(model.bodies[0].standardPart?.threadGeometryKnown, false)
    }

    func testScrewIsSelectedAsOneBodyByEdgeAndBox() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let project = Project(id: UUID(), name: "Normteil-Auswahl", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let workspace = Workspace(project: project)
        workspace.model.previewInsert(.box, size: [20, 20, 5], at: .zero)
        workspace.model.commitPreview()
        let spec = StandardPartSpec()
        workspace.model.previewGenerated(PartBuilder.build(spec), step: "Normteil einfügen", standardPart: spec)
        workspace.model.commitPreview()
        XCTAssertEqual(workspace.model.bodies.count, 2)

        workspace.tapped(face: FaceRef(body: 0, face: 1), edge: EdgeRef(body: 1, edge: 1))
        XCTAssertEqual(workspace.model.selectedBodies, [1])
        XCTAssertEqual(workspace.tool, .move)
        XCTAssertTrue(workspace.model.selectedEdges.isEmpty)

        workspace.activate(.select)
        workspace.boxSelected([1], crossing: false)
        XCTAssertEqual(workspace.model.selectedBodies, [1])
        XCTAssertEqual(workspace.tool, .move)
    }

    func testScrewPlacementAndPropertiesSurviveReopen() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable && PCKShape.stepAvailable)
        let project = Project(id: UUID(), name: "Normteil-Platzierung", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = Workspace(project: project).model
        model.previewInsert(.box, size: [20, 20, 5], at: .zero)
        model.commitPreview()
        let spec = StandardPartSpec()
        model.previewGenerated(PartBuilder.build(spec), step: "Normteil einfügen", standardPart: spec)
        model.commitPreview()
        let top = try XCTUnwrap((1...model.bodies[0].shape.faceCount).first {
            model.plane(of: FaceRef(body: 0, face: $0)).map { $0.normal.z > 0.99 } ?? false
        })
        let face = FaceRef(body: 0, face: top)
        let center = try XCTUnwrap(model.mesh.centroid(of: face))
        let normal = try XCTUnwrap(model.plane(of: face)?.normal)
        XCTAssertTrue(model.placeScrew(1, on: face, at: SIMD3<Double>(center), anchor: .headSeat, offset: 0))
        XCTAssertEqual(model.selectedBodies, [1])
        let body = model.bodies[1]
        let origin = SIMD3(body.placement.columns.3.x, body.placement.columns.3.y, body.placement.columns.3.z)
        let axis = SIMD3(body.placement.columns.2.x, body.placement.columns.2.y, body.placement.columns.2.z)
        XCTAssertLessThan(simd_distance(origin, SIMD3<Double>(center)), 1e-5)
        XCTAssertGreaterThan(simd_dot(axis, normal), 0.999)
        model.setStandardPartClass("12.9", body: 1)
        XCTAssertEqual(model.features.last?.kind, .snapshot)

        let reopened = Workspace(project: project).model
        XCTAssertEqual(reopened.bodies[1].standardPart?.propertyClass, "12.9")
        XCTAssertEqual(reopened.bodies[1].standardPart?.metric.name, "M3")
        let saved = reopened.bodies[1].placement.columns.3
        XCTAssertEqual(saved.x, origin.x, accuracy: 1e-5)
        XCTAssertEqual(saved.y, origin.y, accuracy: 1e-5)
        XCTAssertEqual(saved.z, origin.z, accuracy: 1e-5)
        let stage = try XCTUnwrap(reopened.bodies(afterFeatures: reopened.features.count))
        XCTAssertEqual(stage[1].standardPart?.propertyClass, "12.9")
    }

    func testScrewCanBePlacedAgainAfterMoveOnSideFace() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.previewInsert(.box, size: [20, 20, 5], at: .zero)
        model.commitPreview()
        let spec = StandardPartSpec()
        model.previewGenerated(PartBuilder.build(spec), step: "Normteil einfügen", standardPart: spec)
        model.commitPreview()
        model.selectBodies([1])
        model.setMoveOffset([8, 0, 0])
        model.commitPreview()
        let side = try XCTUnwrap((1...model.bodies[0].shape.faceCount).first {
            model.plane(of: FaceRef(body: 0, face: $0)).map { $0.normal.x > 0.99 } ?? false
        })
        let face = FaceRef(body: 0, face: side)
        let center = SIMD3<Double>(try XCTUnwrap(model.mesh.centroid(of: face)))
        let normal = try XCTUnwrap(model.plane(of: face)?.normal)
        XCTAssertTrue(model.placeScrew(1, on: face, at: center, anchor: .headTop, offset: 1.5))
        let placement = model.bodies[1].placement
        let origin = SIMD3(placement.columns.3.x, placement.columns.3.y, placement.columns.3.z)
        let axis = SIMD3(placement.columns.2.x, placement.columns.2.y, placement.columns.2.z)
        XCTAssertLessThan(simd_distance(origin, center + normal * (1.5 - spec.metric.headHeight)), 1e-5)
        XCTAssertGreaterThan(simd_dot(axis, normal), 0.999)
    }

    func testReopenRestoresSelectableFeatureStages() throws {
        let project = Project(id: UUID(), name: "Timeline-Reopen", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }

        let original = Workspace(project: project).model
        original.previewInsert(.box, size: [20, 20, 20], at: .zero)
        original.commitPreview()

        // Eine direkte Geometrieänderung wird als fester Stand gespeichert.
        let moved = try XCTUnwrap(original.bodies.first?.shape.translated(by: [10, 0, 0]))
        original.commit([original.bodies[0].with(moved)], name: "Direkt verschieben")
        original.previewInsert(.box, size: [8, 8, 8], at: [40, 0, 0])
        original.commitPreview()

        let expectedIDs = original.features.map(\.id)
        XCTAssertEqual(original.features.map(\.kind), [.primitive, .snapshot, .primitive])
        XCTAssertEqual(original.bodies.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.folder.appending(path: "features.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.folder.appending(path: "features/\(expectedIDs[1].uuidString).step").path))

        let reopened = Workspace(project: project).model
        XCTAssertEqual(reopened.features.map(\.id), expectedIDs)
        XCTAssertEqual(reopened.bodies.count, 2)
        for (step, expectedBodyCount) in [(1, 1), (2, 1), (3, 2)] {
            let stage = try XCTUnwrap(reopened.bodies(afterFeatures: step),
                                      "Verlaufsstufe \(step) muss nach erneutem Öffnen anwählbar sein")
            XCTAssertEqual(stage.count, expectedBodyCount)
        }
    }
}
