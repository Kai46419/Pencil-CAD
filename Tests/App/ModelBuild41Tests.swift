import XCTest
@testable import PencilCAD

/// Build 41, Teil B (Modell, Skizze, Verlauf, Daten): Absturzschutz bei Anzahlen, Formel-Grenzfälle, Ladefehler.
@MainActor
final class ModelBuild41Tests: XCTestCase {
    // MARK: C1/N2 – Anzahl aus Gleitkommazahl

    func testClampedCountRejectsHugeNaNAndNegativeValues() {
        XCTAssertEqual(clampedCount(1e20), 10_000)
        XCTAssertEqual(clampedCount(-1e20), 1)
        XCTAssertEqual(clampedCount(.nan), 1)
        XCTAssertEqual(clampedCount(.infinity), 1)
        XCTAssertEqual(clampedCount(-5), 1)
        XCTAssertEqual(clampedCount(4.4), 4)
        XCTAssertEqual(clampedCount(4.6), 5)
        XCTAssertEqual(clampedCount(1e20, min: 3, max: 200), 200)
        XCTAssertEqual(clampedCount(-5, min: 3, max: 200), 3)
    }

    func testCountParameterIsClampedBeforeConversion() throws {
        XCTAssertEqual(try FeatureUnit.count.evaluate("1e20", variables: [:]), 10_000)
        XCTAssertEqual(try FeatureUnit.count.evaluate("-5", variables: [:]), 1)
        XCTAssertEqual(try FeatureUnit.count.evaluate("2.6", variables: [:]), 3)
    }

    // MARK: Schwacher Bugfix 3 – Formeln

    func testExponentWithoutDigitsIsAnError() {
        XCTAssertThrowsError(try Formula.evaluate("2e"))
        XCTAssertThrowsError(try Formula.evaluate("2e+"))
        XCTAssertEqual(try Formula.evaluate("2e3"), 2000, accuracy: 1e-9)
        XCTAssertEqual(try Formula.evaluate("2e-1"), 0.2, accuracy: 1e-12)
        // Ausdrücklich mit Malzeichen bleibt e die Eulersche Zahl
        XCTAssertEqual(try Formula.evaluate("2*e"), 2 * M_E, accuracy: 1e-12)
        // Name, der mit e beginnt: unsichtbares Mal wie bisher
        XCTAssertEqual(try Formula.evaluate("2eps", variables: ["eps": 3]), 6, accuracy: 1e-12)
    }

    func testSecondDecimalSeparatorIsAnError() {
        XCTAssertThrowsError(try Formula.evaluate("1,5,3"))
        XCTAssertThrowsError(try Formula.evaluate("1.5.3"))
        XCTAssertEqual(try Formula.evaluate("1,5"), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try Formula.evaluate("max(1,5; 3)"), 3, accuracy: 1e-12)
    }

    func testUnaryMinusBindsWeakerThanPower() throws {
        XCTAssertEqual(try Formula.evaluate("-2^2"), -4, accuracy: 1e-12)
        XCTAssertEqual(try Formula.evaluate("(-2)^2"), 4, accuracy: 1e-12)
    }

    func testUnitlessVariablesAreNotScaledInInchProject() throws {
        let previous = LengthUnit.current
        defer { LengthUnit.current = previous }
        let variables = [ProjectVariable(name: "abstand", expression: "10 mm"),
                         ProjectVariable(name: "n", expression: "4"),
                         ProjectVariable(name: "doppelt", expression: "abstand * 2")]
        let values = Formula.resolve(variables)
        XCTAssertEqual(Formula.unitlessVariableNames, ["n"])
        LengthUnit.current = .inch
        // abstand ist eine Länge (10 mm), n eine reine Zahl: 4 × 10 mm = 40 mm
        XCTAssertEqual(try Formula.evaluateLength("abstand * n", variables: values), 40, accuracy: 1e-9)
        XCTAssertEqual(try Formula.evaluateLength("doppelt", variables: values), 20, accuracy: 1e-9)
        // Zahl ohne Einheit zählt in der Projekteinheit
        XCTAssertEqual(try Formula.evaluateLength("n", variables: values), 4 * 25.4, accuracy: 1e-9)
    }

    // MARK: N1/C3 – Ladefehler sperrt das Speichern (ohne Kernel: defekte JSON-Datei)

    func testDefectiveSketchFileBlocksSavingAndKeepsCopy() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "PencilCAD-Build41-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = Data("[{\"kaputt\":".utf8)
        let sketches = folder.appending(path: "sketches.json")
        try broken.write(to: sketches)

        let model = ModelStore(folder: folder)
        XCTAssertTrue(model.loadFailed)
        XCTAssertTrue(model.sketches.isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix("sketches.json.defekt-") }
        XCTAssertEqual(copies.count, 1)

        // Eine Änderung, die speichert: die defekte Datei darf nicht durch „[]“ ersetzt werden
        model.setVariables([ProjectVariable(name: "a", expression: "1")])
        XCTAssertEqual(try Data(contentsOf: sketches), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "variables.json")
            .path(percentEncoded: false)))
        XCTAssertEqual(model.message, ModelStore.loadFailedSaveMessage)
    }

    func testClosedStoreDoesNotSave() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "PencilCAD-Build41-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ModelStore(folder: folder)
        model.close()
        model.setVariables([ProjectVariable(name: "a", expression: "1")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "variables.json")
            .path(percentEncoded: false)))
    }

    func testDeletedProjectFolderIsNotRecreated() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "PencilCAD-Build41-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ModelStore(folder: folder)
        try FileManager.default.removeItem(at: folder)
        model.setVariables([ProjectVariable(name: "a", expression: "1")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    func testNewerStoreForSameFolderWinsOverOlderOne() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "PencilCAD-Build41-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = ModelStore(folder: folder)
        let reopened = ModelStore(folder: folder)
        reopened.setVariables([ProjectVariable(name: "neu", expression: "2")])
        old.setVariables([ProjectVariable(name: "alt", expression: "1")])
        let data = try Data(contentsOf: folder.appending(path: "variables.json"))
        let stored = try JSONDecoder().decode([ProjectVariable].self, from: data)
        XCTAssertEqual(stored.map(\.name), ["neu"])
    }
}
