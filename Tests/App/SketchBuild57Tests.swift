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

/// Build 60 (Kai): 3-Tangenten-Kreis bei sehr kleinen Maßen liegt genau an.
@MainActor
final class SketchBuild60Tests: XCTestCase {
    func testTinyTangentCircleTouchesExactly() throws {
        let lines: [SketchEntity] = [.line([0, 0], [0.03, 0]), .line([0, 0], [0, 0.03]), .line([0.03, 0], [0, 0.03])]
        let circle: SketchEntity = .circle(center: [0.008, 0.009], radius: 0.007)
        let constraints = (0..<3).map {
            SketchConstraint(variant: .tangent(SketchCurveRef(entity: $0, index: 0), SketchCurveRef(entity: 3, index: 0),
                                               outside: true))
        }
        let solved = try XCTUnwrap(ConstraintSolver.solve(lines + [circle], constraints: constraints, locked: [0, 1, 2]))
        guard case .circle(let c, let r) = solved[3] else { return XCTFail("Kreis fehlt") }
        // Inkreis des rechtwinkligen Dreiecks mit Katheten 0,03: r = (a + b − c) / 2
        let expected = (0.03 + 0.03 - 0.03 * 2.0.squareRoot()) / 2
        XCTAssertEqual(r, expected, accuracy: 1e-9)
        XCTAssertEqual(c.x, expected, accuracy: 1e-9)
        XCTAssertEqual(c.y, expected, accuracy: 1e-9)
    }
}
