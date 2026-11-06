import XCTest
import simd
@testable import PencilCAD

/// Build 64 (Kai): Schweben über zwei Punkten zeigt wieder die fangbare Mitte; die Verbindung optional als
/// Konstruktionslinie („Mehr › Schwebepunkte verbinden“).
@MainActor
final class SketchBuild64Tests: XCTestCase {
    private func hoverSketch(connect: Bool) -> SketchController {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.line([0, 0], [20, 0]), .line([0, 10], [0, 30])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.pairConstructionLine = connect
        return sketch
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "pairConstructionLine")
        super.tearDown()
    }

    func testHoverPairSetsSnappableMidpointWithoutLine() throws {
        let sketch = hoverSketch(connect: false)
        XCTAssertTrue(sketch.captureHovered(at: [20, 0], tolerance: 1))
        XCTAssertTrue(sketch.captureHovered(at: [0, 30], tolerance: 1))
        let middle = try XCTUnwrap(sketch.marks.first)
        XCTAssertEqual(middle.x, 10, accuracy: 1e-8)
        XCTAssertEqual(middle.y, 15, accuracy: 1e-8)
        XCTAssertEqual(sketch.entities.count, 2, "Ohne Schalter keine Linie anlegen")
        XCTAssertTrue(sketch.guideLines.isEmpty)
        // Die Mitte ist fangbar
        let snapped = sketch.solidCraftSnap([10.2, 15.1], tolerance: 1, prev: nil, lineTool: true)
        XCTAssertEqual(simd_distance(snapped.point, middle), 0, accuracy: 1e-8)
    }

    func testHoverPairAddsConstructionLineWhenEnabled() throws {
        let sketch = hoverSketch(connect: true)
        XCTAssertTrue(sketch.captureHovered(at: [20, 0], tolerance: 1))
        XCTAssertTrue(sketch.captureHovered(at: [0, 30], tolerance: 1))
        XCTAssertEqual(sketch.entities.count, 3)
        XCTAssertTrue(sketch.construction.contains(2))
        guard case .line(let a, let b) = sketch.entities[2] else { return XCTFail("Verbindung muss eine Linie sein") }
        XCTAssertEqual(simd_distance(a, [20, 0]), 0, accuracy: 1e-8)
        XCTAssertEqual(simd_distance(b, [0, 30]), 0, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(sketch.marks.first).y, 15, accuracy: 1e-8)
    }
}
