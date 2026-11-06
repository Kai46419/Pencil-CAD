import XCTest
import simd
@testable import PencilCAD

/// Build 57 (Kai): Winkel an der gewählten Linie (Auswahlwerkzeug) und Eckwinkel an verbundenen Linien.
@MainActor
final class SketchBuild57Tests: XCTestCase {
    private func lineSketch() -> SketchController {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.lineSingleStroke = true
        sketch.snapEnabled = false
        return sketch
    }

    private func stroke(_ sketch: SketchController, _ a: Point2, _ b: Point2) {
        sketch.clickBegan(at: a, tolerance: 1)
        sketch.clickMoved(to: (a + b) / 2, tolerance: 1)
        sketch.clickMoved(to: b, tolerance: 1)
        sketch.clickEnded(at: b, tolerance: 1)
    }

    func testSelectedSlantedLineShowsAngle() {
        let sketch = lineSketch()
        stroke(sketch, [0, 0], [10, 10])
        sketch.tool = .select
        sketch.began(at: [5, 5], tolerance: 1)
        sketch.ended(at: [5, 5], tolerance: 1)
        XCTAssertTrue(sketch.visibleDimensions.contains { $0.kind == .angle && $0.isEditable },
                      "Gewählte Linie: Winkel fehlt – \(sketch.visibleDimensions.map(\.id))")
    }

    func testLineAttachedToEndShowsCornerAngle() {
        let sketch = lineSketch()
        stroke(sketch, [0, 0], [10, 10])
        stroke(sketch, [10, 10], [25, 10])
        XCTAssertEqual(sketch.entities.count, 2)
        XCTAssertTrue(sketch.visibleDimensions.contains { $0.kind == .angle && $0.isEditable },
                      "Eckwinkel fehlt – \(sketch.visibleDimensions.map(\.id))")
    }

    func testLineAttachedToStartShowsCornerAngle() {
        let sketch = lineSketch()
        stroke(sketch, [0, 0], [10, 10])
        stroke(sketch, [0, 0], [15, 0])
        XCTAssertEqual(sketch.entities.count, 2)
        XCTAssertTrue(sketch.visibleDimensions.contains { $0.kind == .angle && $0.isEditable },
                      "Eckwinkel fehlt – \(sketch.visibleDimensions.map(\.id))")
    }

    func testSelectedConnectedLineShowsCornerAngle() {
        let sketch = lineSketch()
        stroke(sketch, [0, 0], [10, 10])
        stroke(sketch, [10, 10], [25, 10])
        sketch.tool = .select
        sketch.began(at: [5, 5], tolerance: 1)
        sketch.ended(at: [5, 5], tolerance: 1)
        XCTAssertTrue(sketch.visibleDimensions.contains { $0.kind == .angle && $0.isEditable },
                      "Gewählte verbundene Linie: Winkel fehlt – \(sketch.visibleDimensions.map(\.id))")
    }
}
