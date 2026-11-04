import XCTest
import simd
@testable import PencilCAD

/// Build 43 (Kai): Linie endet nach dem Strich (Maße bleiben änderbar, Weiterzeichnen am Linienende) und
/// Farbhinweise beim Zeichnen (grün = gleiche Richtung, gelb = gleiche Länge, beides zugleich).
@MainActor
final class SketchBuild43Tests: XCTestCase {
    private var savedSingleStroke: Any?
    private var savedAutoConstrain: Any?

    override func setUp() {
        super.setUp()
        savedSingleStroke = UserDefaults.standard.object(forKey: "lineSingleStroke")
        savedAutoConstrain = UserDefaults.standard.object(forKey: "autoConstrain")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedSingleStroke, forKey: "lineSingleStroke")
        UserDefaults.standard.set(savedAutoConstrain, forKey: "autoConstrain")
        super.tearDown()
    }

    private func lineSketch(_ entities: [SketchEntity] = []) -> SketchController {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: entities)
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.lineSingleStroke = true
        return sketch
    }

    private func stroke(_ sketch: SketchController, _ a: Point2, _ b: Point2) {
        sketch.clickBegan(at: a, tolerance: 1)
        sketch.clickMoved(to: (a + b) / 2, tolerance: 1)
        sketch.clickMoved(to: b, tolerance: 1)
        sketch.clickEnded(at: b, tolerance: 1)
    }

    // MARK: Punkt 1 – Einzelstrich

    func testStrokeEndsLineAndKeepsLengthAndAngleEditable() throws {
        let sketch = lineSketch()
        sketch.snapEnabled = false
        stroke(sketch, [0, 0], [10, 5])
        XCTAssertEqual(sketch.entities.count, 1)
        XCTAssertTrue(sketch.click.points.isEmpty, "Nach dem Strich läuft kein Linienzug weiter")
        XCTAssertFalse(sketch.isInProgress)
        let shown = sketch.visibleDimensions
        XCTAssertTrue(shown.contains { $0.kind == .length && $0.isEditable }, "Länge bleibt änderbar")
        let angle = try XCTUnwrap(shown.first { $0.id.hasSuffix("-absangle") }, "Winkel zur Waagerechten fehlt")
        XCTAssertTrue(angle.isEditable)
        XCTAssertEqual(angle.value, atan2(5, 10) * 180 / .pi, accuracy: 1e-6)
    }

    func testTappingLineEndContinuesFromExactEnd() throws {
        let sketch = lineSketch()
        sketch.snapEnabled = false
        stroke(sketch, [0, 0], [10, 5])
        // Knapp neben dem Ende angesetzt (Fang aus): der neue Strich beginnt genau am Ende
        stroke(sketch, [10.1, 5.05], [20, 5])
        XCTAssertEqual(sketch.entities.count, 2)
        guard case .line(let start, _) = sketch.entities[1] else { return XCTFail("Zweite Linie fehlt") }
        XCTAssertEqual(simd_distance(start, [10, 5]), 0, accuracy: 1e-9)
        XCTAssertTrue(sketch.click.points.isEmpty)
    }

    func testChainModeStillContinuesWhenSwitchedOff() {
        let sketch = lineSketch()
        sketch.lineSingleStroke = false
        sketch.snapEnabled = false
        stroke(sketch, [0, 0], [10, 5])
        XCTAssertEqual(sketch.entities.count, 1)
        XCTAssertEqual(sketch.click.points.count, 1, "Linienzug-Modus: es geht am Ende weiter")
    }

    func testTypedAngleRotatesFreeLineAroundStart() throws {
        let sketch = lineSketch()
        sketch.snapEnabled = false
        stroke(sketch, [0, 0], [10, 0])
        let angle = try XCTUnwrap(sketch.visibleDimensions.first { $0.id.hasSuffix("-absangle") })
        sketch.setDimension(id: angle.id, to: 32)
        guard case .line(let a, let b) = sketch.entities[0] else { return XCTFail("Linie fehlt") }
        XCTAssertEqual(simd_distance(a, [0, 0]), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_distance(a, b), 10, accuracy: 1e-6)
        XCTAssertEqual(atan2(b.y - a.y, b.x - a.x) * 180 / .pi, 32, accuracy: 1e-4)
        // Eine waagerechte Bedingung aus dem Achsfang darf das Drehen nicht blockieren
        XCTAssertFalse(sketch.constraints.contains { if case .horizontal = $0.variant { return true } else { return false } })
        // Negativ = schräg nach unten
        let again = try XCTUnwrap(sketch.visibleDimensions.first { $0.id.hasSuffix("-absangle") })
        sketch.setDimension(id: again.id, to: -30)
        guard case .line(let a2, let b2) = sketch.entities[0] else { return XCTFail("Linie fehlt") }
        XCTAssertEqual(atan2(b2.y - a2.y, b2.x - a2.x) * 180 / .pi, -30, accuracy: 1e-4)
    }

    // MARK: Punkt 2 – Farbhinweise

    func testLineMatchesFindsSameDirectionAndSameLength() {
        let inference = SketchInference(entities: [.line([0, 0], [10, 5]), .line([0, 10], [20, 10])],
                                        construction: [])
        let parallel = SketchController.lineMatches(from: [30, 0], to: [32, 1], curves: inference.curves)
        XCTAssertEqual(parallel.parallel.count, 1)
        XCTAssertTrue(parallel.equal.isEmpty)
        let equal = SketchController.lineMatches(from: [30, 0], to: [30, 20], curves: inference.curves)
        XCTAssertTrue(equal.parallel.isEmpty)
        XCTAssertEqual(equal.equal.count, 1)
        XCTAssertEqual(equal.equal.first?.first, [0, 10])
        let none = SketchController.lineMatches(from: [30, 0], to: [31, 3], curves: inference.curves)
        XCTAssertTrue(none.isEmpty)
    }

    func testConstructionLinesGiveNoHints() {
        let inference = SketchInference(entities: [.line([0, 0], [10, 5])], construction: [0])
        XCTAssertTrue(SketchController.lineMatches(from: [30, 0], to: [40, 5], curves: inference.curves).isEmpty)
    }

    func testParallelogramSideSnapsParallelAndEqualTogether() throws {
        let sketch = lineSketch([.line([0, 0], [10, 5])])
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.parallel, .equalLength]
        sketch.autoConstrain = true
        sketch.click.points = [SketchClickPoint(point: [20, 0], target: nil)]
        sketch.clickHover(at: [30.1, 5.02], tolerance: 1)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        guard case .parallel(let ref)? = candidate.target else { return XCTFail("Parallelfang fehlt") }
        XCTAssertEqual(ref.entity, 0)
        XCTAssertEqual(candidate.alsoEqual?.entity, 0, "Gleiche Länge muss zusätzlich einrasten")
        XCTAssertEqual(simd_distance(candidate.point, [30, 5]), 0, accuracy: 1e-6)
        let hints = sketch.lineMatchHints
        XCTAssertEqual(hints.parallel.count, 1)
        XCTAssertEqual(hints.equal.count, 1)
        sketch.clickBegan(at: [30.1, 5.02], tolerance: 1)
        sketch.clickEnded(at: [30.1, 5.02], tolerance: 1)
        XCTAssertEqual(sketch.entities.count, 2)
        XCTAssertTrue(sketch.constraints.contains { if case .parallel = $0.variant { return true } else { return false } })
        XCTAssertTrue(sketch.constraints.contains { if case .equalLength = $0.variant { return true } else { return false } })
    }
}
