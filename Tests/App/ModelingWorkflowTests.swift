import XCTest
import simd
@testable import PencilCAD

@MainActor
final class ModelingWorkflowTests: XCTestCase {
    func testHoleAndOpenShellProduceClosedBodies() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.previewInsert(.box, size: [20, 20, 20], at: .zero)
        model.commitPreview()
        let top = try XCTUnwrap((1...model.bodies[0].shape.faceCount).first {
            model.plane(of: FaceRef(body: 0, face: $0)).map { $0.normal.z > 0.99 } ?? false
        })
        var spec = HoleSpec()
        spec.diameter = 4
        spec.clearance = 0
        spec.through = false
        spec.depth = 12
        let topFace = FaceRef(body: 0, face: top)
        let center = try XCTUnwrap(model.mesh.centroid(of: topFace))
        model.previewHoles([(face: topFace, point: SIMD3<Double>(center))], spec: spec)
        XCTAssertTrue(model.hasPreview)
        XCTAssertTrue(try XCTUnwrap(model.shownBodies.first?.shape).isClosedSolid)
        XCTAssertEqual(try XCTUnwrap(model.shownBodies.first?.shape).volume,
                       8_000 - .pi * 4 * 12, accuracy: 1)
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 1)

        let shellModel = ModelStore(folder: nil)
        shellModel.previewInsert(.box, size: [20, 20, 20], at: .zero)
        shellModel.commitPreview()
        let shellTop = try XCTUnwrap((1...shellModel.bodies[0].shape.faceCount).first {
            shellModel.plane(of: FaceRef(body: 0, face: $0)).map { $0.normal.z > 0.99 } ?? false
        })
        shellModel.select(face: FaceRef(body: 0, face: shellTop))
        shellModel.previewShell(thickness: 2)
        XCTAssertTrue(shellModel.hasPreview)
        let shell = try XCTUnwrap(shellModel.shownBodies.first?.shape)
        XCTAssertTrue(shell.isBRepValid)
        XCTAssertTrue(shell.isClosedSolid)
        XCTAssertLessThan(shell.volume, 8_000)
        XCTAssertGreaterThan(shell.volume, 0)
    }

    func testPatternAndMirrorKeepOriginalsAndUndo() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.previewInsert(.box, size: [10, 10, 10], at: .zero)
        model.commitPreview()
        model.selectBodies([0])
        model.previewLinearPattern(count: 3, spacing: 20, direction: [1, 0, 0])
        XCTAssertEqual(model.shownBodies.count, 3)
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 3)
        XCTAssertEqual(model.features.last?.kind, .pattern)
        model.selectBodies([0])
        model.previewMirror(.yz, keepOriginal: true, at: (origin: [-10, 0, 0], normal: [1, 0, 0]))
        XCTAssertEqual(model.shownBodies.count, 4)
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 4)
        XCTAssertEqual(model.features.last?.kind, .mirror)
        model.undo()
        XCTAssertEqual(model.bodies.count, 3)
    }

    func testSweepAndLoftKernelsCreateValidSolids() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        func circle(_ z: Double, _ radius: Double) -> [NSNumber] {
            [3, 0, 0, NSNumber(value: z), 0, 0, 1, NSNumber(value: radius)]
        }
        let path: [NSNumber] = [0, 0, 0, 0, 0, 0, 20]
        let sweep = try XCTUnwrap(PCKShape.sweep(profileWires: [circle(0, 3)], path: path))
        XCTAssertTrue(sweep.isBRepValid)
        XCTAssertTrue(sweep.isClosedSolid)
        XCTAssertEqual(sweep.volume, .pi * 9 * 20, accuracy: 2)

        let loft = try XCTUnwrap(PCKShape.loft(sections: [circle(0, 3), circle(20, 5)]))
        XCTAssertTrue(loft.isBRepValid)
        XCTAssertTrue(loft.isClosedSolid)
        XCTAssertGreaterThan(loft.volume, 0)
        XCTAssertLessThan(loft.volume, .pi * 25 * 20)
    }

    func testInvalidExtrusionClearsOldPreviewBeforeCommit() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.storeSketch(plane: .ground, entities: [.rectangle(corner: [0, 0], size: [10, 10])], replacing: nil)
        XCTAssertEqual(model.sketches[0].regions.count, 1)
        model.selectRegions([RegionRef(sketch: 0, region: 0)])
        model.setRegionValue(10)
        XCTAssertTrue(model.hasPreview)
        XCTAssertEqual(model.shownBodies.first?.shape.volume ?? 0, 1_000, accuracy: 0.01)

        model.regionTaper = 95 // nicht zulässig: die alte Vorschau darf nicht als neuer Wert gelten
        XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.bodies.count, 0)
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 0)

        model.regionTaper = 0
        XCTAssertTrue(model.hasPreview)
        model.setRegionValue(.infinity)
        XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.message, "Extrusionsabstand ungültig.")
    }

    func testSweepPathRequiresOneConnectedChain() throws {
        let model = ModelStore(folder: nil)
        model.storeSketch(plane: .ground,
                          entities: [.line([0, 0], [10, 0]), .line([30, 0], [40, 0])], replacing: nil)
        XCTAssertNil(model.sweepPath(fromSketch: 0))
        model.storeSketch(plane: .ground,
                          entities: [.line([0, 0], [10, 0]), .line([10, 0], [10, 5])], replacing: 0)
        XCTAssertEqual(model.sweepPath(fromSketch: 0)?.count, 14)
    }

    func testRevolveRejectsZeroAxisAndBuildsValidRing() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.storeSketch(plane: .ground, entities: [.rectangle(corner: [5, 0], size: [5, 5])], replacing: nil)
        model.selectRegions([RegionRef(sketch: 0, region: 0)])
        model.setRegionValue(2)
        XCTAssertTrue(model.hasPreview)
        model.previewRevolve(axisOrigin: .zero, axis: .zero, degrees: 360, mode: .newBody)
        XCTAssertFalse(model.hasPreview)
        XCTAssertEqual(model.bodies.count, 0)
        XCTAssertEqual(model.message, "Drehachse oder Winkel ungültig.")

        model.previewRevolve(axisOrigin: .zero, axis: [0, 1, 0], degrees: 360, mode: .newBody)
        XCTAssertTrue(model.hasPreview)
        let ring = try XCTUnwrap(model.shownBodies.first?.shape)
        XCTAssertTrue(ring.isBRepValid)
        XCTAssertTrue(ring.isClosedSolid)
        XCTAssertEqual(ring.volume, .pi * (100 - 25) * 5, accuracy: 2)
    }

    func testBooleanPreviewCommitUndoAndReopen() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable && PCKShape.stepAvailable)
        let project = Project(id: UUID(), name: "3D-Referenz", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = ModelStore(folder: project.folder)
        model.previewInsert(.box, size: [20, 20, 20], at: .zero)
        model.commitPreview()
        model.previewInsert(.box, size: [20, 20, 20], at: [10, 0, 0])
        model.commitPreview()
        XCTAssertEqual(model.bodies.count, 2)
        model.previewBoolean(.subtract, target: 0, tools: [1], clearance: 0)
        XCTAssertTrue(model.hasPreview)
        XCTAssertEqual(model.shownBodies[0].shape.volume, 4_000, accuracy: 0.1)
        model.applyBoolean(.subtract, target: 0, tools: [1])
        XCTAssertEqual(model.bodies.count, 1)
        XCTAssertEqual(model.bodies[0].shape.volume, 4_000, accuracy: 0.1)
        XCTAssertTrue(model.bodies[0].shape.isClosedSolid)
        XCTAssertEqual(model.features.last?.kind, .boolean)

        let reopened = ModelStore(folder: project.folder)
        XCTAssertEqual(reopened.bodies.count, 1)
        XCTAssertEqual(reopened.bodies[0].shape.volume, 4_000, accuracy: 0.1)
        XCTAssertEqual(reopened.features.last?.kind, .boolean)
        model.undo()
        XCTAssertEqual(model.bodies.count, 2)
    }
}
