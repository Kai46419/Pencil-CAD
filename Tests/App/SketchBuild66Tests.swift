import XCTest
import simd
@testable import PencilCAD

/// Build 66 (Kai): Verlängerung schräger Linien bis zur nächsten Kurve (gestrichelt, fängt in derselben Richtung);
/// Fingertipp sperrt gelb = Länge bzw. grün = Winkel, Doppeltipp hebt die Sperre auf.
@MainActor
final class SketchBuild66Tests: XCTestCase {
    private func lineSketch(_ entities: [SketchEntity]) -> SketchController {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: entities)
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.lineSingleStroke = true
        return sketch
    }

    func testObliqueLineShowsDashedExtensionToNextLine() throws {
        let sketch = lineSketch([.line([20, -50], [20, 50])])
        sketch.click.points = [SketchClickPoint(point: [0, 0], target: nil)]
        sketch.clickHover(at: [10, 5], tolerance: 1)
        let hit = try XCTUnwrap(sketch.click.forwardHit, "Gestrichelte Verlängerung fehlt")
        XCTAssertEqual(hit.to.x, 20, accuracy: 1e-6)
        // Richtung bleibt: Treffer liegt auf der Geraden durch Start und Stiftende
        let end = try XCTUnwrap(sketch.currentCandidate).point
        XCTAssertEqual(end.x * hit.to.y - end.y * hit.to.x, 0, accuracy: 1e-6)
    }

    func testEndJustBeforeLineSnapsOntoItInSameDirection() throws {
        let sketch = lineSketch([.line([20, -50], [20, 50])])
        sketch.click.points = [SketchClickPoint(point: [0, 0], target: nil)]
        sketch.clickHover(at: [19.2, 9.6], tolerance: 1)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(candidate.point.x, 20, accuracy: 1e-6)
        if case .onCurve(let ref)? = candidate.target { XCTAssertEqual(ref.entity, 0) } else {
            XCTFail("Ende muss auf der getroffenen Linie liegen")
        }
    }

    func testHorizontalLineHasNoExtensionHint() {
        let sketch = lineSketch([.line([20, -50], [20, 50])])
        sketch.click.points = [SketchClickPoint(point: [0, 0], target: nil)]
        sketch.clickHover(at: [10, 0], tolerance: 1)
        XCTAssertNil(sketch.click.forwardHit)
    }

    func testTapLatchesLengthUntilDoubleTap() throws {
        let sketch = lineSketch([.line([0, 0], [30, 40])])
        sketch.click.points = [SketchClickPoint(point: [100, 0], target: nil)]
        sketch.clickHover(at: [100, 30], tolerance: 1)
        let snapshot = SketchController.FingerLockSnapshot(length: (50, nil), direction: nil)
        XCTAssertTrue(sketch.latchFingerLocks(snapshot))
        XCTAssertTrue(sketch.hasFingerLocks)
        sketch.clickHover(at: [100, 10], tolerance: 1)
        let point = try XCTUnwrap(sketch.currentCandidate).point
        XCTAssertEqual(simd_distance(point, [100, 0]), 50, accuracy: 1e-6, "Länge bleibt gesperrt")
        XCTAssertTrue(sketch.clearFingerLocks())
        XCTAssertFalse(sketch.clearFingerLocks())
        XCTAssertFalse(sketch.hasFingerLocks)
    }

    func testTapLatchesDirectionPenSetsLength() throws {
        let sketch = lineSketch([.line([0, 0], [30, 40])])
        let ref = try XCTUnwrap(sketch.inference.curves.first).ref
        sketch.click.points = [SketchClickPoint(point: [100, 0], target: nil)]
        sketch.clickHover(at: [103, 4], tolerance: 1)
        let u = simd_normalize(Point2(3, 4))
        XCTAssertTrue(sketch.latchFingerLocks(.init(length: nil, direction: (u, .parallel(ref)))))
        sketch.clickHover(at: [120, 10], tolerance: 1)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        let w = candidate.point - Point2(100, 0)
        XCTAssertEqual(w.x * u.y - w.y * u.x, 0, accuracy: 1e-6, "Richtung bleibt gesperrt")
        XCTAssertGreaterThan(simd_length(w), 5)
        if case .parallel? = candidate.target {} else { XCTFail("Gesperrte Richtung bleibt parallel (grün)") }
        // Endpunkt setzen: Sperre endet mit dem Linienstück
        sketch.clickBegan(at: [120, 10], tolerance: 1)
        sketch.clickEnded(at: [120, 10], tolerance: 1)
        XCTAssertEqual(sketch.entities.count, 2)
        XCTAssertFalse(sketch.hasFingerLocks)
    }

    func testSnapshotSeesYellowLine() throws {
        let sketch = lineSketch([.line([0, 0], [30, 40])])
        sketch.snapKinds = [.equalLength]
        sketch.click.points = [SketchClickPoint(point: [100, 0], target: nil)]
        sketch.clickHover(at: [100, 50.2], tolerance: 1)
        let snapshot = try XCTUnwrap(sketch.fingerLockSnapshot())
        XCTAssertEqual(try XCTUnwrap(snapshot.length).length, 50, accuracy: 1e-6)
    }
}
