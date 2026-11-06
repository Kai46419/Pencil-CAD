import XCTest
import simd
@testable import PencilCAD

/// Build 41 (Prüfung Build 40, Teil 3): Biegerechnung über 90°, Überlappung mit Ausschnitten, Perforationsgrenze,
/// Messbezug der Kantung, Basisregel abgeleiteter Regeln, Regelvergleich mit Vorgabewerten.
@MainActor
final class SheetBuild41Tests: XCTestCase {
    // MARK: D1 – beforeLeg

    func testBeforeLegAt90DegreesMatchesTangentFormula() {
        let radius = 2.0, thickness = 1.5
        XCTAssertEqual(SheetBendMath.beforeLeg(angle: 90, radius: radius, thickness: thickness, outer: true),
                       (radius + thickness) * tan(45 * .pi / 180), accuracy: 1e-12)
        XCTAssertEqual(SheetBendMath.beforeLeg(angle: 90, radius: radius, thickness: thickness, outer: false),
                       radius * tan(45 * .pi / 180), accuracy: 1e-12)
    }

    func testBeforeLegAt135DegreesUsesTangentOfHalfAngle() {
        // SolidCraft `HeightFrom::before_leg`: (R + T)·tan(θ/2) bzw. R·tan(θ/2) – auch über 90°
        let radius = 2.0, thickness = 1.5
        let half = 135.0 / 2 * .pi / 180
        let outer = SheetBendMath.beforeLeg(angle: 135, radius: radius, thickness: thickness, outer: true)
        let inner = SheetBendMath.beforeLeg(angle: 135, radius: radius, thickness: thickness, outer: false)
        XCTAssertEqual(outer, (radius + thickness) * tan(half), accuracy: 1e-12)
        XCTAssertEqual(inner, radius * tan(half), accuracy: 1e-12)
        // Vorher galt über 90° nur R + T bzw. R
        XCTAssertGreaterThan(outer, radius + thickness + 1)
        // Mindestflanke folgt derselben Formel
        XCTAssertEqual(SheetBendMath.minimumHeight(angle: 135, radius: radius, thickness: thickness, outer: true),
                       outer + 0.01, accuracy: 1e-12)
        // Gegen 180° begrenzt (endlich)
        XCTAssertTrue(SheetBendMath.beforeLeg(angle: 180, radius: radius, thickness: thickness, outer: true).isFinite)
    }

    // MARK: S2 – Überlappung mit Ausschnitten

    func testOverlapCheckIncludesCutouts() {
        let square: SheetJSON = [[0, 0], [10, 0], [10, 10], [0, 10]]
        let valid = FlatPattern(json: ["outline": [square], "cutouts": [[[2, 2], [4, 2], [4, 4], [2, 4]]]])
        XCTAssertNil(ModelStore.sheetOverlapProblem(valid))

        let crossingCutout = FlatPattern(json: ["outline": [square], "cutouts": [[[2, 2], [6, 6], [2, 6], [6, 2]]]])
        XCTAssertNotNil(ModelStore.sheetOverlapProblem(crossingCutout), "Selbstschnitt im Ausschnitt muss auffallen.")

        let outside = FlatPattern(json: ["outline": [square], "cutouts": [[[20, 20], [22, 20], [22, 22], [20, 22]]]])
        XCTAssertNotNil(ModelStore.sheetOverlapProblem(outside), "Ausschnitt außerhalb der Abwicklung muss auffallen.")

        let nested = FlatPattern(json: ["outline": [square],
                                        "cutouts": [[[1, 1], [9, 1], [9, 9], [1, 9]], [[3, 3], [5, 3], [5, 5], [3, 5]]]])
        XCTAssertNotNil(ModelStore.sheetOverlapProblem(nested), "Ausschnitte übereinander müssen auffallen.")
    }

    func testOverlapCheckWarnsInsteadOfSkippingLargeContours() {
        // Kreis mit mehr Punkten als die Prüfgrenze: kein Problem, aber ein Hinweis statt stillem Überspringen
        let count = ModelStore.sheetOverlapPointLimit + 10
        let circle: [SheetJSON] = (0..<count).map { k in
            let angle = Double(k) / Double(count) * 2 * .pi
            return [.number(50 + 40 * cos(angle)), .number(50 + 40 * sin(angle))]
        }
        let flat = FlatPattern(json: ["outline": [.array(circle)]])
        let check = ModelStore.sheetOverlapCheck(flat)
        XCTAssertNil(check.problem)
        XCTAssertNotNil(check.warning)
    }

    // MARK: D10 – Perforationsanzahl

    func testPerforationHoleEstimate() {
        // 150 × 100 mm, Teilung 6 mm: etwa 417 Löcher – erlaubt
        let small = SheetPerforateDriver.estimatedHoleCount(area: 150 * 100, pitch: 6)
        XCTAssertEqual(small, 15_000.0 / 36, accuracy: 1e-9)
        XCTAssertLessThan(small, Double(SheetPerforateDriver.maxHoles))
        // 1 × 1 m, Teilung 5 mm: 40 000 Löcher – abgelehnt
        let large = SheetPerforateDriver.estimatedHoleCount(area: 1000 * 1000, pitch: 5)
        XCTAssertEqual(large, 40_000, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(large, Double(SheetPerforateDriver.maxHoles))
        XCTAssertEqual(SheetPerforateDriver.maxHoles, 20_000)
        XCTAssertEqual(SheetPerforateDriver.estimatedHoleCount(area: 0, pitch: 5), 0)
    }

    // MARK: D2 – Messbezug der Kantung

    func testFoldReferenceRecomputesLineForChangedAngle() throws {
        let reference = SheetFoldReference(a: [0, 0, 0], b: [100, 0, 0], mid: [50, 0, 0], inward: [0, 1, 0],
                                           height: 40, outer: true, thickness: 2, kFactor: 0.44, radius: 2)
        func line(_ angle: Double) throws -> Double {
            let offset = try XCTUnwrap(SheetBendMath.lineOffset(height: 40, angle: angle, radius: 2, thickness: 2,
                                                                kFactor: 0.44, outer: true))
            var step = SheetStep("Kanten", .fold(from: [0, 1, 0], to: [100, 1, 0], angle: angle, radius: nil,
                                                 position: "centerline", fixed: [50, 2, 0]))
            step.foldReference = reference
            let refolded = step.refoldedFromReference()
            let points = try XCTUnwrap(refolded.command.params["points"]?.asArray)
            let from = try XCTUnwrap(points.first?.asPoint3)
            XCTAssertEqual(from.y, offset, accuracy: 1e-9)
            return from.y
        }
        XCTAssertNotEqual(try line(90), try line(135), accuracy: 1e-6)
        // Alte Daten ohne Messbezug bleiben unverändert
        let old = SheetStep("Kanten", .fold(from: [0, 1, 0], to: [100, 1, 0], angle: 90))
        XCTAssertEqual(old.refoldedFromReference(), old)
        // Gespeicherte Schritte ohne das neue Feld lassen sich lesen
        var encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "foldReference")
        object.removeValue(forKey: "baseRule")
        encoded = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(SheetStep.self, from: encoded).foldReference)
    }

    // MARK: D5 – Basisregel

    func testDerivedRuleKeepsBaseRuleName() throws {
        let base = SheetRule(name: "Stahl (mm)")
        let steps = ModelStore.sheetConvertSteps(rule: base, basePoint: .zero, bendPoints: [], plateOnly: true, gap: 0.5)
        let ruleStep = try XCTUnwrap(steps.first)
        XCTAssertEqual(ruleStep.baseRule, "Stahl (mm)")
        let name = try XCTUnwrap(ruleStep.command.params["name"]?.asString)
        XCTAssertNotEqual(name, base.name)
        XCTAssertEqual(ModelStore.sheetBaseRuleName(ruleStep, name: name), "Stahl (mm)")
        // Alte Daten ohne baseRule: aus dem Namen
        var old = ruleStep
        old.baseRule = nil
        XCTAssertEqual(ModelStore.sheetBaseRuleName(old, name: name), "Stahl (mm)")
    }

    // MARK: D7 – Regelvergleich

    func testRuleComparisonTreatsDefaultsAsEqual() {
        let stored = SheetRule(name: "Regel1")
        var edited = stored
        edited.cornerReliefShape = "notch"
        edited.angleDisplay = "bend"
        XCTAssertNotEqual(stored, edited)
        XCTAssertTrue(stored.isEquivalent(to: edited))
        edited.thickness = 3
        XCTAssertFalse(stored.isEquivalent(to: edited))
    }
}
