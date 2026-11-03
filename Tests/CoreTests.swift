import Foundation
import simd

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum CoreTests {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Bedingung nicht erfüllt") throws {
        if try !condition() { throw CheckFailure(description: message) }
    }

    static func close(_ actual: Double, _ expected: Double, tolerance: Double = 1e-6) throws {
        try check(actual.isFinite && abs(actual - expected) <= tolerance, "\(actual) statt \(expected)")
    }

    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw CheckFailure(description: "Ungültige Eingabe wurde akzeptiert")
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    static func main() {
        formulas()
        geometry()
        extrusion()
        solver()
        imports()
        print("RESULT: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

    static func formulas() {
        let cases: [(String, Double)] = [
            ("10 + 2*3", 16), ("(40 - 2 * 3) / 2", 17), ("1,5 cm", 15),
            (".5", 0.5), (",5", 0.5), ("1e-3", 0.001), ("2.5E+2 mm", 250),
            ("1,25e2", 125), ("-2^2", -4), ("(-2)^2", 4), ("2^-3", 0.125),
            ("2^3^2", 512), ("-2^-2", -0.25), ("2(3+1)", 8),
            ("2pi", 2 * .pi), ("pi(2)", 2 * .pi), ("2e", 2 * M_E),
            ("sin(30)", 0.5), ("sqrt(9)", 3), ("min(4;2)", 2),
            ("max(1, 3)", 3), ("mean(2;4)", 3), ("ceiling(1.2)", 2),
            ("2 in", 50.8), ("50%", 0.5), ("180 deg", 180)
        ]
        for (expression, expected) in cases {
            test("Formel \(expression)") { try close(Formula.evaluate(expression), expected) }
        }
        test("Variable vor Klammer") { try close(Formula.evaluate("breite(2+1)", variables: ["breite": 4]), 12) }
        for expression in ["1/0", "sqrt(-1)", "min(acos(2);1)", "sign(acos(2))", "1e999", "(2+3", "unbekannt"] {
            test("Formelfehler \(expression)") { try rejects { _ = try Formula.evaluate(expression) } }
        }
        test("Nichtendliche Zahl ist kein einfacher Zahlenwert") {
            try check(!Formula.isPlainNumber("nan") && !Formula.isPlainNumber("inf") && Formula.isPlainNumber("1e-3"))
        }
        test("Reservierte Funktionsnamen und Konstanten") {
            for name in Formula.functionNames + ["π", "pi", "e", "mm"] { try check(!Formula.isValidName(name)) }
            try check(Formula.isValidName("wand_2"))
        }
        test("Variablenabhängigkeiten und Zyklen") {
            let values = Formula.resolve([
                ProjectVariable(name: "breite", expression: "wand * 3"),
                ProjectVariable(name: "wand", expression: "2 mm"),
                ProjectVariable(name: "kreis_a", expression: "kreis_b + 1"),
                ProjectVariable(name: "kreis_b", expression: "kreis_a + 1")
            ])
            try close(values["breite"] ?? .nan, 6)
            try check(values["kreis_a"] == nil && values["kreis_b"] == nil)
        }
        test("Zollprojekt: implizite und explizite Einheiten") {
            LengthUnit.current = .inch
            defer { LengthUnit.current = .mm }
            try close(Formula.evaluateLength("2"), 50.8)
            try close(Formula.evaluateLength("5 mm"), 5)
            try close(Formula.evaluateLength("wand * 2", variables: ["wand": 10]), 20)
        }
        test("Längenumrechnung weist Überlauf zurück") {
            LengthUnit.current = .inch
            defer { LengthUnit.current = .mm }
            try rejects { _ = try Formula.evaluateLength("1e308") }
        }
    }

    static func geometry() {
        test("Offener Bogen hat keinen Bereich") {
            let result = findRegions(in: [.arc(start: [0, 0], mid: [5, 5], end: [10, 0])])
            try check(result.regions.isEmpty && result.loops.isEmpty)
        }
        test("Offene Spline hat keinen Bereich") {
            try check(findRegions(in: [.spline(points: [[0, 0], [5, 5], [10, 0]], kind: .fit, closed: false)]).regions.isEmpty)
        }
        test("Rechteck erkennt Fläche") {
            let regions = findRegions(in: [.rectangle(corner: [0, 0], size: [20, 10])]).regions
            try check(regions.count == 1)
            try close(abs(signedArea(regions[0].polygon)), 200)
        }
        test("Linienkontur bleibt geschlossen") {
            let lines: [SketchEntity] = [.line([0, 0], [10, 0]), .line([10, 0], [10, 10]),
                                        .line([10, 10], [0, 10]), .line([0, 10], [0, 0])]
            try check(findRegions(in: lines).regions.count == 1)
        }
        test("Bogen mit schließender Sehne") {
            let entities: [SketchEntity] = [.arc(start: [0, 0], mid: [5, 5], end: [10, 0]), .line([10, 0], [0, 0])]
            try check(findRegions(in: entities).regions.count == 1)
        }
        test("Ring behält Innenkontur") {
            let regions = findRegions(in: [.circle(center: [0, 0], radius: 10), .circle(center: [0, 0], radius: 4)]).regions
            try check(regions.contains { $0.holes.count == 1 })
        }
        test("Leere und einpunktige Splines lassen sich nicht versetzen") {
            try check(SketchOffset.segment(.bspline([]), distance: 2, sign: 1) == nil)
            try check(SketchOffset.segment(.bspline([[1, 1]]), distance: 2, sign: 1) == nil)
        }
        test("Polygon mit Loch trianguliert ohne Lochfüllung") {
            let vertices = triangulate(outer: [[0, 0], [10, 0], [10, 10], [0, 10]],
                                       holes: [[[3, 3], [3, 7], [7, 7], [7, 3]]])
            var area = 0.0
            for index in stride(from: 0, to: vertices.count, by: 3) {
                area += abs(signedArea(Array(vertices[index..<(index + 3)])))
            }
            try close(area, 84)
        }
    }

    static func extrusion() {
        let cases: [(String, Double, ExtrudeDirection, Double, Double, Bool, Double, Double)] = [
            ("Einseitig positiv", 10, .oneSide, 0, 1, false, 0, 10),
            ("Einseitig negativ", -10, .oneSide, 0, 1, false, 0, -10),
            ("Schnitt positiv mit Überstand", 10, .oneSide, 0, 1, true, -0.01, 10.01),
            ("Schnitt negativ mit Überstand", -10, .oneSide, 0, 1, true, 0.01, -10.01),
            ("Schnitt auf Körperfläche", 10, .oneSide, 0, -1, true, 0.01, -10.01),
            ("Symmetrisch je Seite", 10, .symmetric, 0, 1, false, -10, 20),
            ("Symmetrisch negativ", -10, .symmetric, 0, 1, false, 10, -20),
            ("Zweiseitig", 10, .twoSides, 4, 1, false, -4, 14),
            ("Zweiseitig umgekehrt", -10, .twoSides, 4, 1, false, 4, -14)
        ]
        for (name, distance, direction, second, sign, cut, start, length) in cases {
            test("Extrusion: \(name)") {
                guard let span = ExtrusionSpan.make(distance: distance, direction: direction,
                                                   secondDistance: second, sign: sign, isCut: cut) else {
                    throw CheckFailure(description: "Kein gültiger Extrusionsbereich")
                }
                try close(span.start, start)
                try close(span.length, length)
            }
        }
        test("Extrusion: Null, NaN und Überlauf werden abgelehnt") {
            for distance in [0, Double.nan, .infinity, .greatestFiniteMagnitude] {
                try check(ExtrusionSpan.make(distance: distance, direction: .symmetric,
                                             secondDistance: 0, sign: 1, isCut: false) == nil)
            }
            try check(ExtrusionSpan.make(distance: 10, direction: .twoSides,
                                         secondDistance: .infinity, sign: 1, isCut: false) == nil)
        }
    }

    static func solver() {
        let line = SketchEntity.line([0, 0], [10, 1])
        let horizontal = SketchConstraint(variant: .horizontal(SketchCurveRef(entity: 0, index: 0)))
        test("Horizontale Linie lösen") {
            guard let solved = ConstraintSolver.solve([line], constraints: [horizontal]) else {
                throw CheckFailure(description: "Keine Lösung")
            }
            try check(ConstraintSolver.satisfies([horizontal], in: solved))
        }
        test("Ungültiger Punktindex wird abgelehnt") {
            let invalid = SketchConstraint(variant: .lock(SketchPointRef(entity: 0, index: 8), at: .zero))
            try check(ConstraintSolver.solve([line], constraints: [invalid]) == nil)
            try check(ConstraintSolver.constraintRank([line], constraints: [invalid]) == nil)
            try check(ConstraintSolver.determined([line], constraints: [invalid]).isEmpty)
        }
        test("Gelöschtes Element wird lokal nicht übersprungen") {
            let invalid = SketchConstraint(variant: .horizontal(SketchCurveRef(entity: 9, index: 0)))
            try check(ConstraintSolver.solveLocally([line], constraints: [horizontal, invalid], focus: [0]) == nil)
        }
        test("Ungültiger fremder Punkt wird lokal nicht übersprungen") {
            let invalid = SketchConstraint(variant: .lock(SketchPointRef(entity: 1, index: 8), at: .zero))
            try check(ConstraintSolver.solveLocally([line, .line([20, 0], [30, 0])],
                                                    constraints: [horizontal, invalid], focus: [0]) == nil)
        }
        test("Lokaler Löser bestätigt keine verletzte fremde Sperre") {
            let lock = SketchConstraint(variant: .lock(SketchPointRef(entity: 1, index: 0), at: [30, 0]))
            try check(ConstraintSolver.solveLocally([line, .line([20, 0], [30, 0])],
                                                    constraints: [horizontal, lock], focus: [0], allowGlobal: false) == nil)
        }
        test("Unbeteiligte gültige Geometrie bleibt unverändert") {
            let other = SketchEntity.line([20, 0], [30, 0])
            guard let solved = ConstraintSolver.solveLocally([line, other], constraints: [horizontal], focus: [0]) else {
                throw CheckFailure(description: "Keine lokale Lösung")
            }
            try check(solved.entities[1].parameters == other.parameters && !solved.isGlobal)
        }
        test("Suspendierte Bedingung blockiert nicht") {
            var invalid = SketchConstraint(variant: .horizontal(SketchCurveRef(entity: 9, index: 0)))
            invalid.isSuspended = true
            try check(ConstraintSolver.solveLocally([line], constraints: [horizontal, invalid], focus: [0]) != nil)
        }
        test("Widersprüchliche feste Maße werden abgelehnt") {
            let first = SketchPointRef(entity: 0, index: 0), second = SketchPointRef(entity: 0, index: 1)
            let constraints = [SketchConstraint(variant: .distance(first, second, value: 10)),
                               SketchConstraint(variant: .distance(first, second, value: 20))]
            try check(ConstraintSolver.solve([line], constraints: constraints) == nil)
        }
        test("NaN-Maß wird abgelehnt") {
            let invalid = SketchConstraint(variant: .distance(SketchPointRef(entity: 0, index: 0),
                                                              SketchPointRef(entity: 0, index: 1), value: .nan))
            try check(ConstraintSolver.solve([line], constraints: [invalid]) == nil)
        }
        test("Verbundenes Linienpaar erhält Anschluss und Länge") {
            let entities: [SketchEntity] = [.line([0, 0], [15, 0]), .line([10, 0], [10, 10])]
            let join = SketchConstraint(variant: .coincident(SketchPointRef(entity: 0, index: 1), SketchPointRef(entity: 1, index: 0)))
            let length = SketchConstraint(variant: .distance(SketchPointRef(entity: 0, index: 0), SketchPointRef(entity: 0, index: 1), value: 15))
            guard let solved = ConstraintSolver.solveLocally(entities, constraints: [join, length], focus: [0], locked: [0]) else {
                throw CheckFailure(description: "Keine Lösung für Anschluss")
            }
            try check(ConstraintSolver.satisfies([join, length], in: solved.entities))
            try check(solved.entities[0].parameters == entities[0].parameters)
        }
    }

    static func imports() {
        let triangle = "solid test\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid test\n"
        test("ASCII-STL lesen") { try check(try MeshFileReader.stl(Data(triangle.utf8), name: "test").soup.count == 3) }
        test("Binäres STL mit solid-Kopf lesen") {
            try check(try MeshFileReader.stl(binaryTriangle(), name: "test").soup.count == 3)
        }
        test("STL mit NaN wird abgelehnt") {
            try rejects { _ = try MeshFileReader.stl(Data(triangle.replacingOccurrences(of: "vertex 1", with: "vertex nan").utf8), name: "test") }
        }
        test("Binäres STL mit Infinity wird abgelehnt") {
            try rejects { _ = try MeshFileReader.stl(binaryTriangle(first: .infinity), name: "test") }
        }
        test("Unvollständiger ASCII-Eckpunkt wird abgelehnt") {
            try rejects { _ = try MeshFileReader.stl(Data(triangle.replacingOccurrences(of: "vertex 1 0 0", with: "vertex 1 0").utf8), name: "test") }
        }
        test("Abgeschnittenes binäres STL wird abgelehnt") {
            try rejects { _ = try MeshFileReader.stl(binaryTriangle().dropLast(12), name: "test") }
        }
        test("3MF in Zoll mit Transformation") {
            let xml = modelXML(unit: "inch", transform: "1 0 0 0 1 0 0 0 1 2 0 0")
            let objects = try MeshFileReader.threeMF(storedZIP(xml), name: "test")
            try check(objects.count == 1 && objects[0].soup.count == 3)
            try close(objects[0].soup[0].x, 50.8)
            try close(objects[0].soup[1].x, 76.2)
        }
        test("Beschädigtes 3MF-XML wird abgelehnt") {
            try rejects { _ = try MeshFileReader.threeMF(storedZIP(String(modelXML().dropLast(8))), name: "test") }
        }
        test("Deflate-komprimiertes 3MF lesen") {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/triangle-deflated.3mf"))
            let objects = try MeshFileReader.threeMF(data, name: "test")
            try check(objects.count == 1 && objects[0].soup.count == 3)
            try close(objects[0].soup[1].x, 1)
        }
        test("ZIP-Prüfsummenfehler wird erkannt") {
            var archive = storedZIP(modelXML())
            let payloadStart = 30 + "3D/3dmodel.model".utf8.count
            archive[payloadStart + 1] ^= 1
            try rejects { _ = try MeshFileReader.threeMF(archive, name: "test") }
        }
        test("Negativer 3MF-Dreiecksindex wird abgelehnt") {
            let xml = modelXML().replacingOccurrences(of: "v3=\"2\"", with: "v3=\"-1\"")
            try rejects { _ = try MeshFileReader.threeMF(storedZIP(xml), name: "test") }
        }
        test("Fehlende 3MF-Koordinate wird abgelehnt") {
            try rejects { _ = try MeshFileReader.threeMF(storedZIP(modelXML().replacingOccurrences(of: "x=\"0\"", with: "")), name: "test") }
        }
        test("Ungültige 3MF-Transformation wird abgelehnt") {
            try rejects { _ = try MeshFileReader.threeMF(storedZIP(modelXML(transform: "1 2 3")), name: "test") }
        }
        test("3MF mit fehlendem Dreieckspunkt wird abgelehnt") {
            try rejects { _ = try MeshFileReader.threeMF(storedZIP(modelXML().replacingOccurrences(of: "v3=\"2\"", with: "v3=\"99\"")), name: "test") }
        }
        test("ZIP64-Offset über Int-Maximum führt nicht zum Absturz") {
            let entry = Zip.Entry(name: "test", method: 0, compressedSize: 1, size: 1, localOffset: Int.max)
            try check(Zip.extract(entry, from: Array(storedZIP(modelXML()))) == nil)
        }
        test("ZIP-Größenüberlauf führt nicht zum Absturz") {
            let entry = Zip.Entry(name: "test", method: 0, compressedSize: Int.max, size: 1, localOffset: 0)
            try check(Zip.extract(entry, from: Array(storedZIP(modelXML()))) == nil)
        }
        test("Übermäßige Entpackgröße wird abgelehnt") {
            let entry = Zip.Entry(name: "test", method: 8, compressedSize: 1, size: Int.max, localOffset: 0)
            try check(Zip.extract(entry, from: Array(storedZIP(modelXML()))) == nil)
        }
    }

    static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    static func binaryTriangle(first: Float = 0) -> Data {
        var data = Data("solid binary".utf8)
        data.append(Data(count: 80 - data.count))
        append32(1, to: &data)
        for value: Float in [0, 0, 1, first, 0, 0, 1, 0, 0, 0, 1, 0] { append32(value.bitPattern, to: &data) }
        append16(0, to: &data)
        return data
    }

    static func modelXML(unit: String = "millimeter", transform: String = "1 0 0 0 1 0 0 0 1 0 0 0") -> String {
        """
        <model unit="\(unit)"><resources><object id="1" type="model"><mesh><vertices>
        <vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/>
        </vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object></resources>
        <build><item objectid="1" transform="\(transform)"/></build></model>
        """
    }

    static func storedZIP(_ xml: String) -> Data {
        let name = Data("3D/3dmodel.model".utf8), payload = Data(xml.utf8)
        let size = UInt32(payload.count)
        var crc: UInt32 = .max
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        crc = ~crc
        var data = Data()
        append32(0x04034b50, to: &data)
        for value: UInt16 in [20, 0, 0, 0, 0] { append16(value, to: &data) }
        for value in [crc, size, size] { append32(value, to: &data) }
        append16(UInt16(name.count), to: &data)
        append16(0, to: &data)
        data.append(name)
        data.append(payload)
        let centralOffset = UInt32(data.count)
        append32(0x02014b50, to: &data)
        for value: UInt16 in [20, 20, 0, 0, 0, 0] { append16(value, to: &data) }
        for value in [crc, size, size] { append32(value, to: &data) }
        for value: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { append16(value, to: &data) }
        append32(0, to: &data)
        append32(0, to: &data)
        data.append(name)
        let centralSize = UInt32(data.count) - centralOffset
        append32(0x06054b50, to: &data)
        for value: UInt16 in [0, 0, 1, 1] { append16(value, to: &data) }
        append32(centralSize, to: &data)
        append32(centralOffset, to: &data)
        append16(0, to: &data)
        return data
    }
}
