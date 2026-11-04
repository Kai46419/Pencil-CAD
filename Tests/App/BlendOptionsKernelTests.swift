import XCTest
import simd
@testable import PencilCAD

/// Build 42 (Agent A): Rundungsoptionen im Kernel – Setback-Ecken (G1, Füllfläche) und G2-Rundung (Profil-Sweep).
/// Vertrag 1a: Standard = alte Methode; Nicht-Standard = Ergebnis oder nil, nie ein stiller Rückfall.
@MainActor
final class BlendOptionsKernelTests: XCTestCase {
    private func requireKernel() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable, "Nur mit OpenCASCADE")
    }

    // MARK: Hilfen

    private func options(corner: PCKBlendCorner = .rollingBall, setback: Double = 0,
                         continuity: PCKBlendContinuity = .g1, profile: PCKBlendProfile = .circle,
                         rho: Double = 0.5, overflow: PCKBlendOverflow = .automatic) -> PCKBlendOptions {
        let options = PCKBlendOptions.standard()
        options.corner = corner
        options.setback = setback
        options.continuity = continuity
        options.profile = profile
        options.rho = rho
        options.overflow = overflow
        return options
    }

    private func setback(_ distance: Double) -> PCKBlendOptions { options(corner: .setback, setback: distance) }
    private var g2: PCKBlendOptions { options(continuity: .g2) }
    private func conic(_ rho: Double) -> PCKBlendOptions { options(continuity: .g2, profile: .conic, rho: rho) }

    /// Quader 40 × 30 × 20: x −20…20, y −15…15, z 0…20; Ecke (20, 15, 20).
    private func box(height: Double = 20) -> PCKShape { PCKShape.box(width: 40, depth: 30, height: height) }

    private func edgeCount(_ shape: PCKShape) -> Int {
        var count = 0
        while count < 10_000, shape.geometry(ofEdge: count + 1) != nil { count += 1 }
        return count
    }

    private func point(_ values: [Double], _ offset: Int) -> SIMD3<Double> {
        SIMD3(values[offset], values[offset + 1], values[offset + 2])
    }

    /// Kanten mit einem Endpunkt in p.
    private func edges(_ shape: PCKShape, at p: SIMD3<Double>) -> [NSNumber] {
        (1...max(1, edgeCount(shape))).compactMap { number in
            guard let g = shape.geometry(ofEdge: number)?.map(\.doubleValue), g.count >= 11 else { return nil }
            let hit = simd_length(point(g, 2) - p) < 1e-6 || simd_length(point(g, 5) - p) < 1e-6
            return hit ? NSNumber(value: number) : nil
        }
    }

    /// Kante, deren Mitte in p liegt.
    private func edge(_ shape: PCKShape, middle p: SIMD3<Double>) throws -> NSNumber {
        let number = (1...max(1, edgeCount(shape))).first { number in
            guard let g = shape.geometry(ofEdge: number)?.map(\.doubleValue), g.count >= 11 else { return false }
            return simd_length(point(g, 8) - p) < 1e-6
        }
        return NSNumber(value: try XCTUnwrap(number))
    }

    private func cylinder() throws -> PCKShape {
        try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
    }

    /// Deckkreis (Art 1, z = 20) des Zylinders.
    private func topCircle(_ shape: PCKShape) throws -> NSNumber {
        let number = (1...max(1, edgeCount(shape))).first { number in
            guard let g = shape.geometry(ofEdge: number)?.map(\.doubleValue), g.count >= 11 else { return false }
            return Int(g[0]) == 1 && abs(g[4] - 20) < 1e-6
        }
        return NSNumber(value: try XCTUnwrap(number))
    }

    private func surfaceKinds(_ shape: PCKShape) -> [Int] {
        (1...max(1, shape.faceCount)).compactMap { shape.surface(ofFace: $0)?.first?.intValue }
    }

    private func assertValid(_ result: PCKShape?, from source: PCKShape, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) throws -> PCKShape {
        let shape = try XCTUnwrap(result, message, file: file, line: line)
        XCTAssertTrue(shape.isBRepValid, message, file: file, line: line)
        XCTAssertTrue(shape.isClosedSolid, message, file: file, line: line)
        XCTAssertTrue(shape.isValidBlendPreview(from: source), message, file: file, line: line)
        return shape
    }

    // MARK: Standard

    func testStandardOptionsMatchOldMethods() throws {
        try requireKernel()
        let shape = box()
        let corner = edges(shape, at: [20, 15, 20])
        XCTAssertEqual(corner.count, 3)
        let old = try XCTUnwrap(shape.filleting(edges: corner, radius: 2))
        let new = try XCTUnwrap(shape.filleting(edges: corner, radius: 2, options: .standard()))
        XCTAssertEqual(new.volume, old.volume, accuracy: 1e-9)
        XCTAssertEqual(new.faceCount, old.faceCount)
        let radii: [NSNumber] = [2, 3, 2]
        let oldRadii = try XCTUnwrap(shape.filleting(edges: corner, radii: radii))
        let newRadii = try XCTUnwrap(shape.filleting(edges: corner, radii: radii, options: .standard()))
        XCTAssertEqual(newRadii.volume, oldRadii.volume, accuracy: 1e-9)
        XCTAssertEqual(newRadii.faceCount, oldRadii.faceCount)
        XCTAssertTrue(PCKShape.supports(blendOptions: .standard()))
    }

    // MARK: Setback (G1)

    func testSetbackBoxCornerIsValidAndDiffersFromRollingBall() throws {
        try requireKernel()
        let shape = box()
        let corner = edges(shape, at: [20, 15, 20])
        let rolling = try XCTUnwrap(shape.filleting(edges: corner, radius: 2))
        let start = Date()
        let result = try assertValid(shape.filleting(edges: corner, radius: 2, options: setback(3)), from: shape,
                                     "Setback r = 2, s = 3")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "Ziel < 4 s")
        // Gleiche Flächenzahl (6 Ebenen + 3 Zylinder + 1 Eckfläche), aber die Kugelecke (Art 3) ist durch eine
        // Füllfläche (Art 5, B-Spline) ersetzt
        XCTAssertTrue(surfaceKinds(rolling).contains(3), "Rolling Ball: Kugelecke")
        XCTAssertFalse(surfaceKinds(result).contains(3), "Setback: keine Kugelfläche")
        XCTAssertTrue(surfaceKinds(result).contains(5), "Setback: Füllfläche")
        XCTAssertNotEqual(result.volume, rolling.volume, accuracy: 1e-3)
        XCTAssertEqual(result.volume, rolling.volume, accuracy: rolling.volume * 0.02)
        XCTAssertLessThan(result.volume, shape.volume)
    }

    func testSetbackWithUnequalRadii() throws {
        try requireKernel()
        let shape = box()
        let corner = edges(shape, at: [20, 15, 20])
        let radii: [NSNumber] = [5, 5, 3]
        _ = try assertValid(shape.filleting(edges: corner, radii: radii, options: setback(8)), from: shape,
                            "Setback 5/5/3, s = 8")
    }

    func testSetbackAtAllEightCornersOfBox() throws {
        try requireKernel()
        let shape = box()
        let all = (1...edgeCount(shape)).map { NSNumber(value: $0) }
        XCTAssertEqual(all.count, 12)
        let start = Date()
        _ = try assertValid(shape.filleting(edges: all, radius: 2, options: setback(3)), from: shape, "8 Setback-Ecken")
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "hartes Limit")
    }

    func testSetbackMixedCornerAndSingleEdge() throws {
        try requireKernel()
        let shape = box()
        var selection = edges(shape, at: [20, 15, 20])
        selection.append(try edge(shape, middle: [-20, 15, 10]))
        _ = try assertValid(shape.filleting(edges: selection, radius: 2, options: setback(3)), from: shape,
                            "Ecke mit drei Kanten Setback, Einzelkante Rolling Ball")
    }

    func testSetbackNotShorterThanEdgeIsRejected() throws {
        try requireKernel()
        let shape = box()
        let corner = edges(shape, at: [20, 15, 20])
        XCTAssertNil(shape.filleting(edges: corner, radius: 2, options: setback(20)), "s = Höhe 20")
        let flat = box(height: 4)
        XCTAssertNil(flat.filleting(edges: edges(flat, at: [20, 15, 4]), radius: 1, options: setback(4.5)))
        XCTAssertNil(shape.filleting(edges: corner, radius: 2, options: setback(1.5)), "s ≤ r: Kugelecke getroffen")
    }

    func testSetbackWithoutCornerIsRejected() throws {
        try requireKernel()
        // Keine Ecke mit drei gewählten Kanten: Setback wäre wirkungslos → nil statt still Rolling Ball
        let shape = try cylinder()
        let circle = try topCircle(shape)
        XCTAssertNotNil(shape.filleting(edges: [circle], radius: 2))
        XCTAssertNil(shape.filleting(edges: [circle], radius: 2, options: setback(3)), "Zylinder mit Naht")
        let block = box()
        let top = try [edge(block, middle: [0, 15, 20]), edge(block, middle: [20, 0, 20])]
        XCTAssertNil(block.filleting(edges: top, radius: 2, options: setback(3)), "Ecke mit nur zwei Kanten")
    }

    func testSetbackSTEPRoundTrip() throws {
        try requireKernel()
        try XCTSkipUnless(PCKShape.stepAvailable)
        let shape = box()
        let result = try XCTUnwrap(shape.filleting(edges: edges(shape, at: [20, 15, 20]), radius: 2,
                                                   options: setback(3)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("setback-\(UUID().uuidString).step")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(PCKShape.writeSTEP([result], path: url.path))
        let loaded = try XCTUnwrap(PCKShape.readSTEP(path: url.path))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(try XCTUnwrap(loaded.first).volume, result.volume, accuracy: result.volume * 0.003)
        XCTAssertTrue(try XCTUnwrap(loaded.first).isBRepValid)
    }

    // MARK: G2

    func testG2SingleBoxEdge() throws {
        try requireKernel()
        let shape = box()
        let line = try edge(shape, middle: [20, 0, 20])   // gerade Kante zwischen zwei Ebenen, L = 30
        let circle = try XCTUnwrap(shape.filleting(edges: [line], radius: 5))
        let start = Date()
        let smooth = try assertValid(shape.filleting(edges: [line], radius: 5, options: g2), from: shape, "G2 r = 5")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let wedge = 5.0 * 5.0 / 2 * 30   // Keil r²/2 · L
        XCTAssertGreaterThan(smooth.volume, shape.volume - wedge, "höchstens der Keil wird abgetragen")
        XCTAssertLessThan(smooth.volume, shape.volume, "es wird abgetragen")
        XCTAssertGreaterThan(abs(smooth.volume - circle.volume), 1, "nicht das Kreisprofil")
        // Gleiche Ansatzlinien, aber Krümmung 0 am Rand → volleres Profil als der Kreis (Prototyp: +0,2 %)
        XCTAssertGreaterThan(smooth.volume, circle.volume)
        XCTAssertEqual(smooth.faceCount, circle.faceCount)
    }

    func testG2ConicRhoIsMonotonic() throws {
        try requireKernel()
        let shape = box()
        let line = try edge(shape, middle: [20, 0, 20])
        let flat = try assertValid(shape.filleting(edges: [line], radius: 5, options: conic(0.3)), from: shape, "Rho 0,3")
        let full = try assertValid(shape.filleting(edges: [line], radius: 5, options: conic(0.7)), from: shape, "Rho 0,7")
        XCTAssertLessThan(flat.volume, full.volume, "größeres Rho = volleres Profil = weniger Abtrag")
        XCTAssertGreaterThan(flat.volume, shape.volume - 5.0 * 5.0 / 2 * 30)
    }

    func testG2CylinderTopCircle() throws {
        try requireKernel()
        let shape = try cylinder()
        let circle = try topCircle(shape)
        let round = try XCTUnwrap(shape.filleting(edges: [circle], radius: 2))
        let smooth = try assertValid(shape.filleting(edges: [circle], radius: 2, options: g2), from: shape,
                                     "G2 Deckkreis (Rotation)")
        XCTAssertGreaterThan(smooth.volume, round.volume)
        XCTAssertLessThan(smooth.volume, shape.volume)
    }

    func testG2TwoIsolatedEdgesAndRejectedCorner() throws {
        try requireKernel()
        let shape = box()
        let pair = try [edge(shape, middle: [20, 0, 20]), edge(shape, middle: [-20, 0, 0])]
        _ = try assertValid(shape.filleting(edges: pair, radii: [3, 4], options: g2), from: shape, "zwei isolierte Kanten")
        XCTAssertNil(shape.filleting(edges: edges(shape, at: [20, 15, 20]), radius: 2, options: g2),
                     "Kanten treffen sich an einer Ecke → nil")
    }

    // MARK: Ungültig / nicht unterstützt

    func testG2WithSetbackIsUnsupported() throws {
        try requireKernel()
        let both = options(corner: .setback, setback: 3, continuity: .g2)
        XCTAssertTrue(both.isValid)
        XCTAssertFalse(PCKShape.supports(blendOptions: both))
        let shape = box()
        XCTAssertNil(shape.filleting(edges: edges(shape, at: [20, 15, 20]), radius: 2, options: both))
        XCTAssertNil(shape.filleting(edges: [try edge(shape, middle: [20, 0, 20])], radius: 2, options: both))
    }

    func testInvalidValuesAreRejected() throws {
        try requireKernel()
        let shape = box()
        let corner = edges(shape, at: [20, 15, 20])
        let single = try edge(shape, middle: [20, 0, 20])
        for distance in [Double.nan, 0, -1, .infinity] {
            XCTAssertFalse(PCKShape.supports(blendOptions: setback(distance)), "Setback \(distance)")
            XCTAssertNil(shape.filleting(edges: corner, radius: 2, options: setback(distance)), "Setback \(distance)")
        }
        for rho in [1.0, 0.0, 0.95, .nan] {
            XCTAssertFalse(PCKShape.supports(blendOptions: conic(rho)), "Rho \(rho)")
            XCTAssertNil(shape.filleting(edges: [single], radius: 2, options: conic(rho)), "Rho \(rho)")
        }
        XCTAssertNil(shape.filleting(edges: corner, radius: .nan, options: setback(3)))
        XCTAssertNil(shape.filleting(edges: [single], radius: -2, options: g2))
        XCTAssertNil(shape.filleting(edges: corner, radii: [2, 2], options: setback(3)), "Anzahl Radien")
        XCTAssertNil(shape.filleting(edges: [9999], radius: 2, options: g2), "veraltete Nummer")
        let keep = options(overflow: .keepEdge)
        XCTAssertFalse(PCKShape.supports(blendOptions: keep))
        XCTAssertNil(shape.filleting(edges: [single], radius: 2, options: keep))
    }

    /// supports(blendOptions:) stimmt mit dem Verhalten am passenden Prüfkörper überein.
    func testSupportsMatchesBehavior() throws {
        try requireKernel()
        let shape = box()
        let corner = edges(shape, at: [20, 15, 20])
        let single = try edge(shape, middle: [20, 0, 20])
        let cases: [(PCKBlendOptions, Bool, [NSNumber])] = [
            (.standard(), true, corner),
            (setback(3), true, corner),
            (g2, true, [single]),
            (conic(0.5), true, [single]),
            (options(corner: .setback, setback: 3, continuity: .g2), false, corner),
            (options(corner: .setback, setback: 3, continuity: .g2, profile: .conic, rho: 0.5), false, corner),
            (options(overflow: .keepEdge), false, [single]),
            (options(corner: .setback, setback: 3, overflow: .keepEdge), false, corner),
            (options(continuity: .g2, overflow: .keepEdge), false, [single]),
        ]
        for (index, entry) in cases.enumerated() {
            let (option, supported, selection) = entry
            XCTAssertEqual(PCKShape.supports(blendOptions: option), supported, "Fall \(index)")
            let result = shape.filleting(edges: selection, radius: 2, options: option)
            XCTAssertEqual(result != nil, supported, "Fall \(index): Verhalten passt zu supports")
        }
    }
}
