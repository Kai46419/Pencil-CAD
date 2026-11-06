import XCTest
import simd
@testable import PencilCAD

/// Build 45 (Kai): Bezugslinie per Schweben bzw. Fingertipp – die nächste Linie rastet an ihr stärker ein.
@MainActor
final class SketchBuild45Tests: XCTestCase {
    private var savedSingleStroke: Any?

    override func setUp() {
        super.setUp()
        savedSingleStroke = UserDefaults.standard.object(forKey: "lineSingleStroke")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedSingleStroke, forKey: "lineSingleStroke")
        super.tearDown()
    }

    private func lineSketch(_ entities: [SketchEntity]) -> SketchController {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: entities)
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.lineSingleStroke = true
        return sketch
    }

    func testToggleReferenceLineOnLineButNotAtEnds() {
        let sketch = lineSketch([.line([0, 0], [10, 10])])
        XCTAssertFalse(sketch.toggleReferenceLine(at: [0.2, 0.1], tolerance: 1), "am Ende bleibt das Punktmerken")
        XCTAssertNil(sketch.referenceLine)
        XCTAssertTrue(sketch.toggleReferenceLine(at: [5, 5.3], tolerance: 1))
        XCTAssertEqual(sketch.validReferenceLine, SketchCurveRef(entity: 0, index: 0))
        XCTAssertNotNil(sketch.referenceLinePolyline)
        XCTAssertTrue(sketch.toggleReferenceLine(at: [5, 5.3], tolerance: 1), "noch einmal nimmt den Bezug weg")
        XCTAssertNil(sketch.referenceLine)
        XCTAssertFalse(sketch.toggleReferenceLine(at: [30, 0], tolerance: 1))
    }

    func testReferenceLengthSnapsFromFurtherAway() {
        let inference = SketchInference(entities: [.line([0, 0], [10, 0])], construction: [])
        let ref = SketchCurveRef(entity: 0, index: 0)
        // 2 mm zu lang bei 1 mm Fangabstand: ohne Bezug kein Fang, mit Bezug (dreifach) schon
        XCTAssertNil(inference.equalLength(from: [0, 5], toward: [12, 5], raw: [12, 5], tolerance: 1))
        let match = inference.equalLength(from: [0, 5], toward: [12, 5], raw: [12, 5], tolerance: 1, reference: ref)
        XCTAssertEqual(match?.target, .equalLength(ref))
        XCTAssertEqual(match?.point.x ?? 0, 10, accuracy: 1e-9)
    }

    func testMissingReferenceLineIsIgnored() {
        let sketch = lineSketch([.line([0, 0], [10, 10])])
        sketch.referenceLine = SketchCurveRef(entity: 3, index: 0)
        XCTAssertNil(sketch.validReferenceLine, "gelöschte bzw. fehlende Linie gilt nicht als Bezug")
    }
}
