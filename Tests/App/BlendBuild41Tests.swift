import XCTest
@testable import PencilCAD

/// Build 41: Abrunden/Fasen ohne stille Teilbearbeitung, Diagnose störender Kanten, geprüfte Boolesche Operationen.
@MainActor
final class BlendBuild41Tests: XCTestCase {
    private func cylinder() throws -> PCKShape {
        try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
    }

    /// Obere Fläche des Quaders (Normale +Z, Ebene bei z = Höhe).
    private func topFace(_ shape: PCKShape) throws -> Int {
        let face = (1...shape.faceCount).first { number in
            guard let plane = shape.plane(ofFace: number)?.map(\.doubleValue), plane.count == 6 else { return false }
            return plane[5] > 0.99 && plane[2] > 5
        }
        return try XCTUnwrap(face)
    }

    // MARK: Zylinder: Kreis + Naht

    func testCylinderCircleWithSeamIsRejectedAndSeamIsNamed() throws {
        let shape = try cylinder()
        XCTAssertNotNil(shape.filleting(edges: [1], radius: 2), "Die Kreiskante allein lässt sich abrunden")
        XCTAssertNil(shape.filleting(edges: [1, 2], radius: 2),
                     "Die Naht darf nicht still aus der Auswahl fallen (keine Teilrundung nur am Kreis)")
        XCTAssertEqual(shape.unblendableEdges([1, 2], value: 2, chamfer: false).map(\.intValue), [2])
        XCTAssertEqual(shape.unblendableEdges([1], value: 2, chamfer: false), [])
    }

    func testIsolatedDiagnosisNamesSeam() throws {
        let shape = try cylinder()
        guard #available(iOS 26.0, *) else { throw XCTSkip("Worker erst ab iPadOS 26") }
        XCTAssertEqual(IsolatedBlend.unblendableEdges(shape: shape, edges: [1, 2], value: 2, chamfer: false), [2])
        XCTAssertEqual(IsolatedBlend.unblendableEdges(shape: shape, edges: [1, 2], value: 2, chamfer: true), [2])
    }

    func testDiagnosisMessageNamesEdge() {
        XCTAssertEqual(BlendKernel.unblendableMessage([7], chamfer: false),
                       "Kante 7 ist eine Naht- oder tangentiale Kante und kann nicht abgerundet werden – aus der Auswahl entfernen.")
        XCTAssertNil(BlendKernel.unblendableMessage([], chamfer: true))
        XCTAssertTrue(BlendKernel.unblendableMessage([3, 7], chamfer: true)?.contains("Kanten 3, 7") ?? false)
    }

    // MARK: Fase mit Naht

    func testChamferWithSeamIsRejected() throws {
        let shape = try cylinder()
        XCTAssertNotNil(shape.chamfering(edges: [1], distance: 2))
        XCTAssertNil(shape.chamfering(edges: [1, 2], distance: 2))
        XCTAssertNil(shape.chamfering(edges: [1, 2], distance: 2, distance2: 1))
        XCTAssertEqual(shape.unblendableEdges([1, 2], value: 2, chamfer: true).map(\.intValue), [2])
    }

    func testVariableFilletWithSeamIsRejected() throws {
        XCTAssertNil(try cylinder().filleting(edges: [1, 2], radius: 2, endRadius: 1))
    }

    // MARK: Quader: vier Deckkanten gemeinsam

    func testFourTopEdgesOfBoxBlendTogetherAsValidSolid() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edges = box.edgeNumbers(ofFace: try topFace(box))
        XCTAssertEqual(edges.count, 4)
        let rounded = try XCTUnwrap(box.filleting(edges: edges, radius: 2))
        XCTAssertTrue(rounded.isBRepValid)
        XCTAssertTrue(rounded.isClosedSolid)
        XCTAssertTrue(rounded.isValidBlendPreview(from: box))
        // Je Kante fällt höchstens r²(1 − π/4) · 20 ≈ 17,2 mm³ weg (Ecken überlappen): alle vier wirklich gerundet
        XCTAssertLessThan(rounded.volume, box.volume - 30)
        XCTAssertGreaterThan(rounded.volume, box.volume - 70)

        let chamfered = try XCTUnwrap(box.chamfering(edges: edges, distance: 2))
        XCTAssertTrue(chamfered.isBRepValid)
        XCTAssertLessThan(chamfered.volume, box.volume - 50, "Fase 2 × 2 an allen vier Deckkanten")
    }

    func testFourTopEdgesInWorker() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Worker erst ab iPadOS 26") }
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edges = box.edgeNumbers(ofFace: try topFace(box))
        let rounded = try XCTUnwrap(IsolatedBlend.run(shape: box, edges: edges, mode: 0, value: 2))
        XCTAssertTrue(rounded.isClosedSolid)
        XCTAssertLessThan(rounded.volume, box.volume - 30)
    }

    // MARK: Gemeinsame Rundung mit der letzten Rundung: kein Rückfall

    func testFailedMergeDoesNotFallBackToDirectFillet() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        let input = BlendJobInput(operation: .fillet, shape: box, edges: [edge], value: 2,
                                  second: nil, end: nil, partialRange: nil,
                                  mergeShape: box, mergeEdges: [NSNumber(value: Int.max)])
        let result = BlendKernel.run(input)
        XCTAssertNil(result.shape, "Scheitert die gemeinsame Rundung, gibt es keinen Fillet auf der gerundeten Fläche")
        XCTAssertTrue(result.mergeFailed)
        XCTAssertFalse(result.merged)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(IsolatedBlend.wasBlocked(shape: box, edges: [NSNumber(value: Int.max)], mode: 0))
    }

    // MARK: Sperrschlüssel über den BRep-Inhalt (N1)

    func testCrashBlocksOnlyTheSameBody() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Worker erst ab iPadOS 26") }
        let first = PCKShape.box(width: 20, depth: 20, height: 10)
        let second = PCKShape.box(width: 20, depth: 20, height: 11)
        let edge = try XCTUnwrap(first.edgeNumbers(ofFace: 1).first)
        XCTAssertNil(IsolatedBlend.run(shape: first, edges: [edge], mode: 99, value: 2))
        XCTAssertTrue(IsolatedBlend.wasBlocked(shape: first, edges: [edge], mode: 99))
        XCTAssertFalse(IsolatedBlend.wasBlocked(shape: second, edges: [edge], mode: 99),
                       "Ein anderer Körper gleicher Größe darf nicht mitgesperrt werden")
        XCTAssertFalse(IsolatedBlend.wasTimedOut(shape: first, edges: [edge], mode: 99, value: 2),
                       "Ein Absturz ist kein Zeitlimit")
    }

    // MARK: Boolesche Operationen

    func testBooleanResultsAreValidSolids() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let pin = try XCTUnwrap(PCKShape.cylinder(base: [0, 0, -1], axis: [0, 0, 1], radius: 3, height: 12))
        let cut = try XCTUnwrap(box.cutting(pin))
        XCTAssertTrue(cut.isBRepValid)
        XCTAssertTrue(cut.isClosedSolid)
        XCTAssertEqual(cut.volume, 4_000 - Double.pi * 9 * 10, accuracy: 0.5)

        let shifted = try XCTUnwrap(box.translated(by: [10, 0, 0]))
        let fused = try XCTUnwrap(box.fusing(shifted))
        XCTAssertTrue(fused.isBRepValid)
        XCTAssertEqual(fused.volume, 6_000, accuracy: 0.5)

        let common = try XCTUnwrap(box.intersecting(shifted))
        XCTAssertTrue(common.isBRepValid)
        XCTAssertEqual(common.volume, 2_000, accuracy: 0.5)

        // Leere Schnittmenge bleibt ein leeres Ergebnis (Aufrufer prüfen das Volumen), kein nil
        let far = try XCTUnwrap(box.translated(by: [100, 0, 0]))
        let none = try XCTUnwrap(box.intersecting(far))
        XCTAssertEqual(none.volume, 0, accuracy: 1e-9)

        let tooled = try XCTUnwrap(box.cutting(pin, fuzzy: 0))
        XCTAssertTrue(tooled.isBRepValid)
    }

    // MARK: Richtungen (B9)

    func testNonFiniteDirectionsAreRejected() {
        XCTAssertNil(PCKShape.cylinder(base: .zero, axis: [.nan, 0, 1], radius: 2, height: 5))
        XCTAssertNil(PCKShape.cylinder(base: .zero, axis: [0, 0, .infinity], radius: 2, height: 5))
        XCTAssertNil(PCKShape.prism(pointsXYZ: [0, 0, 0, 1, 0, 0, 0, 1, 0], direction: [0, 0, .nan]))
    }
}
