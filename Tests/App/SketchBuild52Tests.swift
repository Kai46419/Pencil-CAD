import XCTest
import simd
@testable import PencilCAD

/// Build 52 (Kai): Finger aufgelegt = Stift rastet an Punkten in großer Weite ein (Linienenden), andere Fänge ruhen.
@MainActor
final class SketchBuild52Tests: XCTestCase {
    func testHeldFingerLocksOntoFarEndpoint() {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.line([0, 0], [10, 0])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        let tolerance = 1.0
        let metrics = sketch.snapMetrics(tolerance)
        // Doppelte normale Punktfangweite neben dem Ende: ohne Finger kein Punktfang, mit Finger das Ende
        let raw: Point2 = [10 + metrics.pointPick * 2, 0.0]
        let free = sketch.solidCraftSnap(raw, tolerance: tolerance, prev: nil, lineTool: true)
        XCTAssertGreaterThan(simd_distance(free.point, [10, 0]), 1e-6)
        sketch.arcModifier = true
        let locked = sketch.solidCraftSnap(raw, tolerance: tolerance, prev: nil, lineTool: true)
        XCTAssertEqual(simd_distance(locked.point, [10, 0]), 0, accuracy: 1e-9)
        // Weit weg bleibt der Stift frei
        let far: Point2 = [10 + metrics.pointPick * 5, 0.0]
        XCTAssertEqual(simd_distance(sketch.solidCraftSnap(far, tolerance: tolerance, prev: nil, lineTool: true).point, far),
                       0, accuracy: 1e-9)
    }
}

/// Build 53 (Kai): gelbe Linie + Finger = Länge fest, Stift dreht nur; Richtung rastet parallel ein.
@MainActor
final class SketchBuild53Tests: XCTestCase {
    func testFingerKeepsEqualLengthAndSnapsDirection() throws {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.line([0, 0], [6, 8])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.click.points = [SketchClickPoint(point: [20, 0], target: nil)]
        // Länge 10 wie die vorhandene Linie (gelb)
        sketch.click.hover = SnapCandidate(point: [30, 0], target: nil, guide: nil, label: "")
        sketch.arcModifier = true
        let lock = try XCTUnwrap(sketch.fingerLengthLock)
        XCTAssertEqual(lock.length, 10, accuracy: 1e-9)
        XCTAssertEqual(lock.ref?.entity, 0)
        // Stift weit draußen, knapp neben der Richtung (6, 8): Länge bleibt 10, Richtung parallel
        let snapped = sketch.lengthLockedCandidate([20 + 31, 41], from: [20, 0], lock: lock)
        XCTAssertEqual(simd_distance(snapped.point, [26, 8]), 0, accuracy: 1e-9)
        guard case .parallel(let ref)? = snapped.target else { return XCTFail("Parallelfang fehlt") }
        XCTAssertEqual(ref.entity, 0)
        XCTAssertEqual(snapped.alsoEqual?.entity, 0)
        // Frei gedreht: nur die Länge bleibt
        let free = sketch.lengthLockedCandidate([20 - 30, 30], from: [20, 0], lock: lock)
        XCTAssertEqual(simd_distance(free.point, [20, 0]), 10, accuracy: 1e-9)
        sketch.arcModifier = false
        XCTAssertNil(sketch.fingerLengthLock)
    }
}
