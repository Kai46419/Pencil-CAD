import XCTest
@testable import PencilCAD

/// Build 42 (Agent C): Rundungsoptionen in der Oberfläche – Befehl ↔ BlendOptions, Setback folgt dem Radius,
/// Variabel/Teilweise erzwingen Standard, Bearbeiten aus dem Verlauf lädt und schreibt die Optionen.
@MainActor
final class BlendOptionsUITests: XCTestCase {
    private func filletCommand(radius: Double = 2) -> ModelCommand {
        let cmd = ModelCommand(.fillet, inputs: [])
        cmd.putNumber("radius", radius)
        BlendOptionsForm.setDefaults(cmd, radius: radius)
        return cmd
    }

    private func setbackOptions(_ value: Double) -> BlendOptions {
        var options = BlendOptions.standard
        options.corner = .setback
        options.setback = value
        return options
    }

    // MARK: Setback-Vorgabe

    func testDefaultsAreStandardWithSetbackOneAndAHalfRadius() {
        let cmd = filletCommand(radius: 2)
        XCTAssertTrue(BlendOptionsForm.options(cmd).isStandard)
        XCTAssertEqual(cmd.number(BlendOptionKeys.setback, default: 0), 3, accuracy: 1e-9)
        XCTAssertEqual(BlendOptionsForm.rhoValue(cmd), 0.5, accuracy: 1e-9)
        XCTAssertFalse(BlendOptionsForm.isSetbackManual(cmd))
    }

    func testSetbackFollowsRadiusUntilManualEntry() {
        let cmd = filletCommand(radius: 2)
        cmd.choices[BlendOptionKeys.corner] = BlendOptions.Corner.setback.rawValue
        cmd.putNumber("radius", 4)
        BlendOptionsForm.followRadius(cmd, radius: 4)
        XCTAssertEqual(BlendOptionsForm.setbackValue(cmd), 6, accuracy: 1e-9)
        XCTAssertEqual(BlendOptionsForm.options(cmd).setback ?? 0, 6, accuracy: 1e-9)

        BlendOptionsForm.setManualSetback(2.5, in: cmd)
        cmd.putNumber("radius", 10)
        BlendOptionsForm.followRadius(cmd, radius: 10)
        XCTAssertEqual(BlendOptionsForm.setbackValue(cmd), 2.5, accuracy: 1e-9, "Handeingabe bleibt stehen")

        BlendOptionsForm.resetSetback(in: cmd)
        XCTAssertEqual(BlendOptionsForm.setbackValue(cmd), 15, accuracy: 1e-9, "zurück auf 1,5 × Radius")
    }

    // MARK: Befehl → BlendOptions

    func testCommandMapsToOptions() {
        let cmd = filletCommand(radius: 2)
        cmd.choices[BlendOptionKeys.corner] = "setback"
        cmd.choices[BlendOptionKeys.continuity] = "g2"
        cmd.choices[BlendOptionKeys.profile] = "conic"
        cmd.putNumber(BlendOptionKeys.rho, 0.3)
        let options = BlendOptionsForm.options(cmd)
        XCTAssertEqual(options.corner, .setback)
        XCTAssertEqual(options.setback ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(options.continuity, .g2)
        XCTAssertEqual(options.profile, .conic)
        XCTAssertEqual(options.rho ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertFalse(options.isStandard)
        XCTAssertEqual(BlendOptionsForm.summary(options), "Ecken: Setback \(LengthUnit.current.format(3)) · G2 · Rho 0,3")
        XCTAssertEqual(BlendOptionsForm.badge(options), "SB·G2ρ")
    }

    func testConicWithoutG2IsCleanedToCircle() {
        let cmd = filletCommand()
        cmd.choices[BlendOptionKeys.profile] = "conic"
        let options = BlendOptionsForm.options(cmd)
        XCTAssertEqual(options.profile, .circle)
        XCTAssertNil(options.rho)
        XCTAssertNil(options.setback)
        XCTAssertTrue(options.isStandard)
    }

    func testRhoIsClamped() {
        let cmd = filletCommand()
        cmd.putNumber(BlendOptionKeys.rho, 5)
        XCTAssertEqual(BlendOptionsForm.rhoValue(cmd), 0.9, accuracy: 1e-9)
        cmd.putNumber(BlendOptionKeys.rho, -1)
        XCTAssertEqual(BlendOptionsForm.rhoValue(cmd), 0.1, accuracy: 1e-9)
    }

    func testVariableAndPartialForceStandard() {
        let cmd = filletCommand()
        cmd.choices[BlendOptionKeys.corner] = "setback"
        cmd.choices[BlendOptionKeys.continuity] = "g2"
        XCTAssertFalse(BlendOptionsForm.effectiveOptions(cmd).isStandard)
        cmd.flags["variable"] = true
        XCTAssertTrue(BlendOptionsForm.effectiveOptions(cmd).isStandard)
        cmd.flags["variable"] = false
        cmd.flags["partial"] = true
        XCTAssertTrue(BlendOptionsForm.effectiveOptions(cmd).isStandard)
        // Die Wahl bleibt gespeichert: zurück auf Konstant gilt sie wieder
        cmd.flags["partial"] = false
        XCTAssertEqual(BlendOptionsForm.effectiveOptions(cmd).corner, .setback)
    }

    func testCarryKeepsOptionsAcrossArrowSwitch() {
        let fillet = filletCommand()
        fillet.choices[BlendOptionKeys.continuity] = "g2"
        BlendOptionsForm.setManualSetback(1.25, in: fillet)
        let chamfer = ModelCommand(.chamfer, inputs: [])
        BlendOptionsForm.carry(from: fillet, to: chamfer)
        let back = filletCommand()
        BlendOptionsForm.carry(from: chamfer, to: back)
        XCTAssertEqual(back.choices[BlendOptionKeys.continuity], "g2")
        XCTAssertTrue(BlendOptionsForm.isSetbackManual(back))
        XCTAssertEqual(back.number(BlendOptionKeys.setback, default: 0), 1.25, accuracy: 1e-9)
    }

    // MARK: Freigabe und Fehlschlag

    func testVariantFollowsKernelSupport() {
        let wanted = setbackOptions(3)
        let variant = BlendOptionsForm.variant(of: .standard) {
            $0.corner = .setback
            $0.setback = 3
        }
        if PCKShape.supports(blendOptions: wanted.kernel) {
            XCTAssertEqual(variant?.corner, .setback)
        } else {
            XCTAssertNil(variant, "Was der Kernel nicht kann, bleibt grau")
        }
        XCTAssertTrue(BlendOptionsForm.isSupported(.standard))
        XCTAssertNotNil(BlendOptionsForm.variant(of: .standard) { $0.corner = .rollingBall })
    }

    func testFixesMatchModelMessages() {
        var options = setbackOptions(3)
        options.continuity = .g2
        XCTAssertEqual(BlendOptionsForm.fixes(for: ModelStore.blendSetbackFailedMessage, options: options), [.rollingBall])
        XCTAssertEqual(BlendOptionsForm.fixes(for: ModelStore.blendG2FailedMessage, options: options), [.g1])
        XCTAssertEqual(BlendOptionsForm.fixes(for: ModelStore.blendSetbackFailedMessage, options: .standard), [])
        XCTAssertEqual(BlendOptionsForm.fixes(for: nil, options: options), [])

        let cmd = filletCommand()
        BlendOptionsForm.store(options, in: cmd)
        BlendOptionsForm.apply(.g1, to: cmd)
        XCTAssertEqual(BlendOptionsForm.options(cmd).continuity, .g1)
        XCTAssertEqual(BlendOptionsForm.options(cmd).corner, .setback)
        BlendOptionsForm.apply(.rollingBall, to: cmd)
        XCTAssertTrue(BlendOptionsForm.options(cmd).isStandard)
    }

    // MARK: Bearbeiten aus dem Verlauf

    func testFeatureEditLoadsOptions() {
        var feature = ModelStore.blendFeature(.fillet, value: 2)
        feature.applyBlendOptions(setbackOptions(4))
        let cmd = FeatureEdit.command(.fillet, feature)
        XCTAssertEqual(cmd.choices[BlendOptionKeys.corner], "setback")
        XCTAssertEqual(cmd.choices[BlendOptionKeys.continuity], "g1")
        XCTAssertEqual(cmd.values[BlendOptionKeys.setback], LengthUnit.current.number(4))
        XCTAssertEqual(cmd.values[BlendOptionKeys.rhoPercent], "50")
        XCTAssertTrue(FeatureEdit.isBlendOptionParameter(BlendOptionKeys.setback, of: feature))
    }

    func testFeatureEditStandardFeatureLoadsDefaults() {
        let feature = ModelStore.blendFeature(.fillet, value: 2)
        let cmd = FeatureEdit.command(.fillet, feature)
        XCTAssertEqual(cmd.choices[BlendOptionKeys.corner], "rollingBall")
        XCTAssertEqual(cmd.values[BlendOptionKeys.setback], LengthUnit.current.number(3))
        XCTAssertTrue(FeatureEdit.allowsBlendOptions(feature))
        XCTAssertFalse(FeatureEdit.allowsBlendOptions(ModelStore.blendFeature(.fillet, value: 2, end: 4)))
        XCTAssertFalse(FeatureEdit.allowsBlendOptions(ModelStore.blendFeature(.chamfer, value: 1)))
    }

    func testFeatureEditWritesOptions() throws {
        let feature = ModelStore.blendFeature(.fillet, value: 2)
        var parameters = feature.parameters
        let chosen = setbackOptions(1)
        let wanted = setbackOptions(5)
        if PCKShape.supports(blendOptions: wanted.kernel) {
            let result = try XCTUnwrap(FeatureEdit.resolveBlendOptions(chosen, setbackText: "5", rhoPercentText: "50",
                                                                       feature: feature, parameters: &parameters,
                                                                       variables: [:]))
            XCTAssertTrue(result.changed)
            XCTAssertEqual(result.options.corner, .setback)
            XCTAssertEqual(result.options.setback ?? 0, LengthUnit.current.millimeters * 5, accuracy: 1e-9)
            XCTAssertNotNil(parameters.first { $0.key == BlendOptionKeys.setback })
        } else {
            XCTAssertThrowsError(try FeatureEdit.resolveBlendOptions(chosen, setbackText: "5", rhoPercentText: "50",
                                                                     feature: feature, parameters: &parameters,
                                                                     variables: [:]))
        }
        // Zurück auf Standard: Setback-Parameter verschwindet, „unverändert“ ohne Änderung
        var standardParameters = feature.parameters + [.length(BlendOptionKeys.setback, "Setback-Abstand", 3)]
        let standard = try XCTUnwrap(FeatureEdit.resolveBlendOptions(.standard, setbackText: nil, rhoPercentText: nil,
                                                                     feature: feature, parameters: &standardParameters,
                                                                     variables: [:]))
        XCTAssertTrue(standard.options.isStandard)
        XCTAssertFalse(standard.changed)
        XCTAssertNil(standardParameters.first { $0.key == BlendOptionKeys.setback })
        // Fase: keine Optionen
        var chamferParameters: [FeatureParameter] = []
        XCTAssertNil(try FeatureEdit.resolveBlendOptions(.standard, setbackText: nil, rhoPercentText: nil,
                                                         feature: ModelStore.blendFeature(.chamfer, value: 1),
                                                         parameters: &chamferParameters, variables: [:]))
    }
}
