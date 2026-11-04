import XCTest
@testable import PencilCAD

/// Build 42, Teil B: Rundungsoptionen (Setback, G2, Profil) in Worker-Protokoll, Merk-Schlüsseln und Verlauf.
@MainActor
final class BlendOptionsModelTests: XCTestCase {
    private let setback = BlendOptions(corner: .setback, setback: 3)
    private let g2 = BlendOptions(continuity: .g2)

    private func makeStore() throws -> (ModelStore, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "PencilCAD-Build42-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (ModelStore(folder: folder), folder)
    }

    private func json(_ feature: Feature) throws -> String {
        String(decoding: try JSONEncoder().encode(feature), as: UTF8.self)
    }

    // MARK: Werttyp

    func testStandardNormalizationAndValidity() {
        XCTAssertTrue(BlendOptions.standard.isStandard)
        XCTAssertTrue(BlendOptions.standard.isValid)
        XCTAssertNil(BlendOptions.standard.normalized)
        // Setback-Abstand ohne Setback-Ecke wirkt nicht: gleich Standard
        XCTAssertNil(BlendOptions(corner: .rollingBall, setback: 3).normalized)
        XCTAssertEqual(BlendOptions(continuity: .g2, rho: 0.4).normalized, g2, "rho gilt nur beim Kegelschnitt")
        XCTAssertFalse(BlendOptions(corner: .setback).isValid, "Setback braucht einen Abstand")
        XCTAssertFalse(BlendOptions(corner: .setback, setback: 0).isValid)
        XCTAssertFalse(BlendOptions(corner: .setback, setback: Double.infinity).isValid)
        XCTAssertFalse(BlendOptions(profile: .conic, rho: 0.5).isValid, "Kegelschnitt nur mit G2")
        XCTAssertFalse(BlendOptions(continuity: .g2, profile: .conic, rho: 0.95).isValid)
        XCTAssertTrue(BlendOptions(continuity: .g2, profile: .conic, rho: 0.3).isValid)
        XCTAssertEqual(BlendOptions.defaultSetback(radius: 2), 3, accuracy: 1e-12)
    }

    func testKernelMappingMatchesSwiftValue() {
        let options = BlendOptions(corner: .setback, setback: 3, continuity: .g2, profile: .conic, rho: 0.3,
                                   overflow: .keepEdge)
        let kernel = options.kernel
        XCTAssertEqual(kernel.corner, .setback)
        XCTAssertEqual(kernel.setback, 3, accuracy: 1e-12)
        XCTAssertEqual(kernel.continuity, .g2)
        XCTAssertEqual(kernel.profile, .conic)
        XCTAssertEqual(kernel.rho, 0.3, accuracy: 1e-12)
        XCTAssertEqual(kernel.overflow, .keepEdge)
        XCTAssertEqual(kernel.isStandard, options.isStandard)
        XCTAssertEqual(kernel.isValid, options.isValid)
        XCTAssertTrue(BlendOptions.standard.kernel.isStandard)
        XCTAssertFalse(BlendOptions(corner: .setback).kernel.isValid)
        XCTAssertTrue(PCKShape.supports(blendOptions: BlendOptions.standard.kernel), "Standard geht immer")
    }

    // MARK: Worker-Protokoll

    func testRequestWithoutOptionsStillDecodes() throws {
        let old = Data(#"{"shape":"","edges":[1],"mode":0,"value":2}"#.utf8)
        let request = try JSONDecoder().decode(BlendWorkerRequest.self, from: old)
        XCTAssertNil(request.options)
        XCTAssertEqual(request.edges, [1])

        let plain = BlendWorkerRequest(shape: Data(), edges: [1], mode: 0, value: 2, second: nil, start: nil,
                                       stop: nil, radii: nil)
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(encoded.contains("options"), "Standard: kein neuer Schlüssel im Protokoll")

        let withOptions = BlendWorkerRequest(shape: Data(), edges: [1], mode: 0, value: 2, second: nil, start: nil,
                                             stop: nil, radii: nil, options: setback)
        let decoded = try JSONDecoder().decode(BlendWorkerRequest.self, from: try JSONEncoder().encode(withOptions))
        XCTAssertEqual(decoded.options, setback)
    }

    func testOptionsDecodeWithMissingKeys() throws {
        let options = try JSONDecoder().decode(BlendOptions.self, from: Data(#"{"continuity":"g2"}"#.utf8))
        XCTAssertEqual(options, g2)
    }

    func testCrashWithOptionsDoesNotBlockStandard() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Worker erst ab iPadOS 26") }
        let box = PCKShape.box(width: 20, depth: 20, height: 12)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        XCTAssertNil(IsolatedBlend.run(shape: box, edges: [edge], mode: 99, value: 2, options: setback))
        XCTAssertTrue(IsolatedBlend.wasBlocked(shape: box, edges: [edge], mode: 99, options: setback))
        XCTAssertFalse(IsolatedBlend.wasBlocked(shape: box, edges: [edge], mode: 99),
                       "Ein Absturz mit Setback sperrt die Standard-Rundung derselben Auswahl nicht")
        XCTAssertFalse(IsolatedBlend.wasTimedOut(shape: box, edges: [edge], mode: 99, value: 2, options: setback))
    }

    func testOptionsAreRejectedOutsideConstantFillet() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        // Variabel bzw. Fase mit Optionen: startet gar nicht (kein Rückfall, kein Zeitlimit, kein Absturz)
        let variable = IsolatedBlend.runReporting(shape: box, edges: [edge], mode: 3, value: 2, second: 3,
                                                  options: setback)
        XCTAssertNil(variable.shape)
        XCTAssertEqual(variable.outcome, .notStarted)
        let invalid = IsolatedBlend.runReporting(shape: box, edges: [edge], mode: 0, value: 2,
                                                 options: BlendOptions(corner: .setback))
        XCTAssertEqual(invalid.outcome, .notStarted)

        let input = BlendJobInput(operation: .fillet, shape: box, edges: [edge], value: 2, second: nil, end: 3,
                                  partialRange: nil, options: setback)
        let result = BlendKernel.run(input)
        XCTAssertNil(result.shape)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.crashed)
    }

    // MARK: Merk-Schlüssel

    func testKeysDistinguishOptions() {
        let plain = OrderedAttemptKey(operation: .fillet, value: 2, second: nil, end: nil)
        var withSetback = plain
        withSetback.options = setback.normalized
        XCTAssertNotEqual(plain, withSetback)
        var rollingWithDistance = plain
        rollingWithDistance.options = BlendOptions(corner: .rollingBall, setback: 3).normalized
        XCTAssertEqual(plain, rollingWithDistance, "Gleiche Wirkung, gleicher Schlüssel")

        let job = BlendJobKey(edges: [], operation: .fillet, value: 2, second: nil, end: nil, partialRange: nil,
                              featureIDs: [], options: nil)
        var jobG2 = job
        jobG2.options = g2
        XCTAssertNotEqual(job, jobG2)
    }

    // MARK: Verlauf

    func testOldFeatureJSONLoadsAsStandard() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Abrunden","kind":"fillet","#
            + #""parameters":[{"key":"radius","title":"Radius","value":2,"unit":"length"}],"#
            + #""data":{"target":0},"isSuppressed":false,"failed":false}"#
        let feature = try JSONDecoder().decode(Feature.self, from: Data(old.utf8))
        XCTAssertEqual(feature.blendOptions, .standard)
        XCTAssertNil(feature.blendOptions.normalized)
    }

    func testStandardFeatureWritesNoNewKeys() throws {
        let keys = ["blendCorner", "blendContinuity", "blendProfile", "blendOverflow", "setback", "rhoPercent"]
        for options in [nil, BlendOptions.standard, BlendOptions(corner: .rollingBall, setback: 3)] {
            let text = try json(ModelStore.blendFeature(.fillet, value: 2, options: options))
            for key in keys { XCTAssertFalse(text.contains(key), "\(key) bei Standard") }
        }
        let plain = ModelStore.blendFeature(.fillet, value: 2)
        var standard = ModelStore.blendFeature(.fillet, value: 2, options: .standard)
        standard.id = plain.id
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(plain), try encoder.encode(standard), "Standard = gleiche Datei wie Build 41")
    }

    func testNonStandardFeatureRoundTrips() throws {
        let options = BlendOptions(corner: .setback, setback: 3, continuity: .g2, profile: .conic, rho: 0.3)
        let feature = ModelStore.blendFeature(.fillet, value: 2, options: options)
        XCTAssertEqual(feature.data.blendCorner, "setback")
        XCTAssertEqual(feature.data.blendContinuity, "g2")
        XCTAssertEqual(feature.data.blendProfile, "conic")
        XCTAssertNil(feature.data.blendOverflow)
        XCTAssertEqual(feature.value("setback") ?? 0, 3, accuracy: 1e-12)
        XCTAssertEqual(feature.value("rhoPercent") ?? 0, 30, accuracy: 1e-9)
        let decoded = try JSONDecoder().decode(Feature.self, from: try JSONEncoder().encode(feature))
        XCTAssertEqual(decoded.blendOptions.normalized, options.normalized)
        // Fase kennt keine Optionen
        let chamfer = ModelStore.blendFeature(.chamfer, value: 2, options: options)
        XCTAssertNil(chamfer.data.blendCorner)
        XCTAssertEqual(chamfer.blendOptions, .standard)
    }

    func testApplyBlendOptionsNormalizes() {
        var feature = ModelStore.blendFeature(.fillet, value: 2, options: setback)
        XCTAssertNotNil(feature.value("setback"))
        feature.applyBlendOptions(BlendOptions(corner: .rollingBall, setback: 3))
        XCTAssertNil(feature.data.blendCorner)
        XCTAssertNil(feature.value("setback"), "Standard entfernt den Setback-Parameter")
        XCTAssertEqual(feature.parameters.map(\.key), ["radius"])
        // Formel am unveränderten Setback bleibt erhalten
        feature.applyBlendOptions(setback)
        let index = feature.parameters.firstIndex { $0.key == "setback" }!
        feature.parameters[index].formula = "r * 1.5"
        feature.applyBlendOptions(setback)
        XCTAssertEqual(feature.parameters[index].formula, "r * 1.5")
        feature.applyBlendOptions(BlendOptions(corner: .setback, setback: 4))
        XCTAssertNil(feature.parameters[index].formula)
        XCTAssertEqual(feature.value("setback") ?? 0, 4, accuracy: 1e-12)
    }

    func testUnknownRawValueIsInvalidNotStandard() {
        var feature = ModelStore.blendFeature(.fillet, value: 2)
        feature.data.blendCorner = "chamferCorner"
        XCTAssertNotNil(feature.blendOptions.normalized)
        XCTAssertFalse(feature.blendOptions.isValid, "Kein stiller Rückfall auf Rolling Ball")
    }

    func testUpdateFeatureRejectsOptionsOnVariableFillet() throws {
        let (model, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var variable = ModelStore.blendFeature(.fillet, value: 2, end: 4)
        variable.data.target = 0
        model.features = [variable]
        model.updateFeature(variable.id, parameters: variable.parameters, blendOptions: setback)
        XCTAssertEqual(model.message, ModelStore.blendOptionsConstantOnlyMessage)
        XCTAssertNil(model.features[0].data.blendCorner)
        XCTAssertNil(model.features[0].value("setback"))

        model.message = nil
        model.updateFeature(variable.id, parameters: variable.parameters, blendOptions: BlendOptions(corner: .setback))
        XCTAssertEqual(model.message, ModelStore.blendOptionsInvalidMessage)
    }

    // MARK: ModelStore

    func testSetEdgeBlendOptions() throws {
        let (model, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(model.edgeBlendOptions, .standard)
        model.setEdgeBlendOptions(BlendOptions(corner: .setback, setback: -1), update: false)
        XCTAssertEqual(model.message, ModelStore.blendOptionsInvalidMessage)
        XCTAssertEqual(model.edgeBlendOptions, .standard)
        model.setEdgeBlendOptions(BlendOptions(corner: .setback, setback: 3, rho: 0.7), update: false)
        XCTAssertEqual(model.edgeBlendOptions, setback, "normalisiert gespeichert")
        XCTAssertEqual(model.effectiveBlendOptions, setback)
        model.edgeOperation = .chamfer
        XCTAssertNil(model.effectiveBlendOptions, "Fase hat keine Optionen")
        model.edgeOperation = .fillet
        model.setEdgeEndValue(4, update: false)
        XCTAssertEqual(model.blendOptionsProblem(), ModelStore.blendOptionsConstantOnlyMessage)
        model.cancelPreview()
        XCTAssertEqual(model.edgeBlendOptions, .standard, "gilt wie der Endradius nur für diese Rundung")
    }

    func testMessages() {
        XCTAssertEqual(ModelStore.blendSetbackFailedMessage,
                       "Setback-Ecke hier nicht möglich – Setback-Abstand ändern oder Ecken auf ‚Rolling Ball‘ stellen.")
        XCTAssertEqual(ModelStore.blendG2FailedMessage,
                       "G2-Rundung hier nicht möglich – Stetigkeit G1 wählen oder Radius ändern.")
        XCTAssertEqual(ModelStore.blendOptionsConstantOnlyMessage,
                       "Setback und G2 nur bei konstanter Rundung (nicht Variabel/Teilweise).")
        XCTAssertEqual(ModelStore.blendOptionsUnsupportedMessage,
                       "Diese Rundungsoption kann der Geometriekernel noch nicht.")
        XCTAssertEqual(ModelStore.blendMergeOptionsDiffer("Abrunden 2"),
                       "Gemeinsame Rundung mit ‚Abrunden 2‘ hat andere Ecken-/Stetigkeitsoptionen – Optionen angleichen.")
        XCTAssertEqual(ModelStore.blendOptionsFailureMessage(setback), ModelStore.blendSetbackFailedMessage)
        XCTAssertEqual(ModelStore.blendOptionsFailureMessage(g2), ModelStore.blendG2FailedMessage)
        XCTAssertEqual(ModelStore.blendOptionsFailureMessage(g2, constantOnly: true),
                       ModelStore.blendOptionsConstantOnlyMessage)
    }
}
