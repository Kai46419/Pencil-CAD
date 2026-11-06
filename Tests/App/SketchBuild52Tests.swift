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
