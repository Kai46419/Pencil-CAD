import XCTest
@testable import PencilCAD

@MainActor
final class ProjectCycleTests: XCTestCase {
    func testSketchExtrudeFilletReopenTimelineAndSTEPRoundtrip() async throws {
        try XCTSkipUnless(PCKShape.kernelAvailable && PCKShape.stepAvailable)
        let project = Project(id: UUID(), name: "Projektzyklus", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = ModelStore(folder: project.folder)

        model.storeSketch(plane: .ground, entities: [
            .line([0, 0], [20, 0]), .line([20, 0], [20, 20]),
            .line([20, 20], [0, 20]), .line([0, 20], [0, 0]),
        ], replacing: nil)
        XCTAssertEqual(model.sketches.count, 1)
        XCTAssertEqual(model.sketches[0].regions.count, 1)

        model.toggleRegion(RegionRef(sketch: 0, region: 0))
        model.setRegionValue(10)
        XCTAssertTrue(model.hasPreview, model.message ?? "Extrusion ohne Vorschau")
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 1)
        XCTAssertEqual(model.bodies[0].shape.volume, 4_000, accuracy: 0.01)

        let shape = model.bodies[0].shape
        let edge = try XCTUnwrap(shape.edgeNumbers(ofFace: 1).first)
        model.toggleEdge(EdgeRef(body: 0, edge: edge.intValue))
        model.edgeOperation = .fillet
        model.setEdgeValue(1.5)
        for _ in 0..<200 where model.isBlendComputing {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(model.isBlendComputing)
        XCTAssertTrue(model.hasPreview, model.message ?? "Abrundung ohne Vorschau")
        model.commitPreview()
        let roundedVolume = model.bodies[0].shape.volume
        XCTAssertGreaterThan(roundedVolume, 0)
        XCTAssertLessThan(roundedVolume, 4_000)
        XCTAssertEqual(model.features.map(\.kind), [.extrude, .fillet])

        let reopened = ModelStore(folder: project.folder)
        XCTAssertEqual(reopened.sketches.count, 1)
        XCTAssertEqual(reopened.features.map(\.kind), [.extrude, .fillet])
        let storedPreBlend = try XCTUnwrap(reopened.featureRecorder.preBlendShape,
                                            "Der Körper vor dem Fillet muss nach dem Öffnen direkt bereitstehen")
        XCTAssertEqual(storedPreBlend.featureID, reopened.features[1].id)
        XCTAssertEqual(storedPreBlend.body, 0)
        XCTAssertEqual(storedPreBlend.shape.volume, 4_000, accuracy: 0.01)
        XCTAssertNil(reopened.featureRecorder.cache[reopened.features[0].id],
                     "Der Zwischenstand darf keinen Feature-Nachbau zum Öffnen brauchen")
        XCTAssertEqual(try XCTUnwrap(reopened.bodies.first).shape.volume, roundedVolume, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(reopened.bodies(afterFeatures: 1)?.first).shape.volume, 4_000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(reopened.bodies(afterFeatures: 2)?.first).shape.volume,
                       roundedVolume, accuracy: 0.01)

        let data = try XCTUnwrap(reopened.exportData(.step))
        let export = FileManager.default.temporaryDirectory.appending(path: "PencilCAD-Roundtrip-\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: export) }
        try data.write(to: export)
        let imported = try XCTUnwrap(PCKShape.readSTEP(path: export.path))
        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(imported[0].isClosedSolid)
        XCTAssertEqual(imported[0].volume, roundedVolume, accuracy: 0.01)

        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: project.folder.appending(path: "features"),
                                                                               includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("preblend-") })
        try FileManager.default.removeItem(at: cacheFile)
        let legacy = ModelStore(folder: project.folder)
        XCTAssertNil(legacy.featureRecorder.preBlendShape)
        XCTAssertEqual(try XCTUnwrap(legacy.bodies(afterFeatures: 1)?.first).shape.volume, 4_000, accuracy: 0.01)
    }
}
