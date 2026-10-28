import Foundation
#if PENCIL_SHEETKIT
import PencilSheet
#endif

// Swift-Brücke zum Blechmodul (SheetKit/API.md): dünne Hülle um die C-Funktionen der eingebetteten
// SolidCraft-Engine (Vendor/PencilSheet.xcframework). Ohne PENCIL_SHEETKIT (Fallback-Build bzw. xcframework noch
// nicht gebaut) gibt es dieselbe Schnittstelle, isAvailable ist dann false und init() wirft.

// MARK: - JSON

/// JSON-Wert für Befehlsparameter und Ergebnisse der SolidCraft-Engine.
enum SheetJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SheetJSON])
    case object([String: SheetJSON])

    /// Wert unter key eines Objekts (nil bei anderen Werten oder fehlendem Schlüssel).
    subscript(key: String) -> SheetJSON? {
        get {
            if case .object(let dict) = self { return dict[key] }
            return nil
        }
        set {
            guard case .object(var dict) = self else { return }
            dict[key] = newValue
            self = .object(dict)
        }
    }

    /// Element index eines Felds (nil außerhalb).
    subscript(index: Int) -> SheetJSON? {
        if case .array(let list) = self, list.indices.contains(index) { return list[index] }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var asDouble: Double? {
        switch self {
        case .number(let value): return value
        case .string(let text): return Double(text)
        default: return nil
        }
    }

    var asInt: Int? {
        guard let value = asDouble, value.isFinite else { return nil }
        return Int(value.rounded())
    }

    var asBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var asString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var asArray: [SheetJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var asObject: [String: SheetJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Punkt [x, y] (nil bei anderer Form).
    var asPoint2: SIMD2<Double>? {
        guard let list = asArray, list.count >= 2, let x = list[0].asDouble, let y = list[1].asDouble else { return nil }
        return SIMD2(x, y)
    }

    /// Punkt [x, y, z] (nil bei anderer Form).
    var asPoint3: SIMD3<Double>? {
        guard let list = asArray, list.count >= 3, let x = list[0].asDouble, let y = list[1].asDouble,
              let z = list[2].asDouble else { return nil }
        return SIMD3(x, y, z)
    }

    /// Punktliste [[x, y], …].
    var asPoints2: [SIMD2<Double>] { (asArray ?? []).compactMap(\.asPoint2) }

    init(_ point: SIMD3<Double>) {
        self = .array([.number(point.x), .number(point.y), .number(point.z)])
    }

    init(_ point: SIMD2<Double>) {
        self = .array([.number(point.x), .number(point.y)])
    }

    /// Kompakter JSON-Text (UTF-8) für die C-Schnittstelle.
    func jsonString() throws -> String {
        // Nicht-endliche Zahlen kann JSON nicht darstellen
        if let bad = firstNonFinite {
            throw SheetKernelError("Ungültige Zahl (\(bad)) in den Befehlsparametern.")
        }
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON-Text lesen (Ergebnis der C-Schnittstelle).
    static func parse(_ text: String) throws -> SheetJSON {
        do {
            return try JSONDecoder().decode(SheetJSON.self, from: Data(text.utf8))
        } catch {
            throw SheetKernelError("Antwort des Blechmoduls nicht lesbar: \(error.localizedDescription)")
        }
    }

    private var firstNonFinite: Double? {
        switch self {
        case .number(let value): return value.isFinite ? nil : value
        case .array(let list): return list.lazy.compactMap(\.firstNonFinite).first
        case .object(let dict): return dict.values.lazy.compactMap(\.firstNonFinite).first
        default: return nil
        }
    }
}

extension SheetJSON: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SheetJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SheetJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension SheetJSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: SheetJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, SheetJSON)...) {
        var dict: [String: SheetJSON] = [:]
        for (key, value) in elements { dict[key] = value }
        self = .object(dict)
    }
}

// MARK: - Befehl und Fehler

/// Ein SolidCraft-Befehl, z. B. command = "sheet.flange", params = {"edges": [[50, 0, 2]], "height": 20}.
struct SheetCommand: Codable, Hashable, Sendable {
    var command: String
    var params: SheetJSON

    init(_ command: String, _ params: SheetJSON = [:]) {
        self.command = command
        self.params = params
    }

    init(command: String, params: SheetJSON) {
        self.command = command
        self.params = params
    }

    var json: SheetJSON { ["command": .string(command), "params": params] }
}

/// Fehler des Blechmoduls (Meldung der Engine, bei Skripten mit der Nummer des gescheiterten Befehls).
struct SheetKernelError: LocalizedError, Sendable {
    let message: String
    var index: Int?
    /// Zeitlimit der Hintergrundrechnung überschritten (SheetWorker)
    var timedOut = false

    init(_ message: String, index: Int? = nil) {
        self.message = message
        self.index = index
    }

    init(message: String, index: Int? = nil) {
        self.message = message
        self.index = index
    }

    init(_ message: String, timedOut: Bool) {
        self.message = message
        self.timedOut = timedOut
    }

    var errorDescription: String? { message }

    static let notBuilt = SheetKernelError("Blechmodul nicht gebaut – im Terminal ./scripts/build-sheet-ios.sh ausführen")
}

// MARK: - Sitzung

/// Eine SolidCraft-Sitzung (Einheiten mm). Nicht threadsicher: eine Sitzung gehört einem Aufrufer.
final class SheetKernel {
    /// false ohne PENCIL_SHEETKIT (Blechmodul nicht eingebaut)
    static var isAvailable: Bool {
        #if PENCIL_SHEETKIT
        return true
        #else
        return false
        #endif
    }

    /// Version der eingebetteten Engine (leer ohne Blechmodul).
    static var version: String {
        #if PENCIL_SHEETKIT
        // Optional-Bindung über eine Variable: gilt mit und ohne Nullability-Angaben im Header
        let raw: UnsafePointer<CChar>? = psk_version()
        guard let text = raw else { return "" }
        return String(cString: text)
        #else
        return ""
        #endif
    }

    #if PENCIL_SHEETKIT
    private let session: OpaquePointer

    init() throws {
        let raw: OpaquePointer? = psk_session_new()
        guard let session = raw else {
            throw SheetKernelError("Blechmodul: Sitzung konnte nicht angelegt werden.")
        }
        self.session = session
    }

    deinit {
        psk_session_free(session)
    }

    /// Antwort der C-Schnittstelle lesen und freigeben.
    private func take(_ raw: UnsafeMutablePointer<CChar>?) throws -> SheetJSON {
        guard let raw else { throw SheetKernelError("Blechmodul: keine Antwort.") }
        let text = String(cString: raw)
        psk_string_free(raw)
        return try SheetJSON.parse(text)
    }

    @discardableResult
    func execute(_ cmd: SheetCommand) throws -> SheetJSON {
        let params = try cmd.params.jsonString()
        let reply = try take(psk_execute(session, cmd.command, params))
        guard reply["ok"]?.asBool == true else {
            throw SheetKernelError(reply["error"]?.asString ?? "\(cmd.command) fehlgeschlagen.")
        }
        return reply["result"] ?? .null
    }

    @discardableResult
    func run(_ cmds: [SheetCommand]) throws -> [SheetJSON] {
        guard !cmds.isEmpty else { return [] }
        let script: SheetJSON = ["commands": .array(cmds.map(\.json))]
        let reply = try take(psk_run_script(session, try script.jsonString()))
        guard reply["ok"]?.asBool == true else {
            throw SheetKernelError(reply["error"]?.asString ?? "Skript fehlgeschlagen.", index: reply["index"]?.asInt)
        }
        return reply["results"]?.asArray ?? []
    }

    func checkpoint() -> UInt64 {
        psk_checkpoint(session)
    }

    func restore(_ id: UInt64) throws {
        guard psk_restore(session, id) == 0 else {
            throw SheetKernelError("Blechmodul: Zwischenstand \(id) nicht vorhanden.")
        }
    }
    #else
    init() throws {
        throw SheetKernelError.notBuilt
    }

    @discardableResult
    func execute(_ cmd: SheetCommand) throws -> SheetJSON {
        throw SheetKernelError.notBuilt
    }

    @discardableResult
    func run(_ cmds: [SheetCommand]) throws -> [SheetJSON] {
        throw SheetKernelError.notBuilt
    }

    func checkpoint() -> UInt64 { 0 }

    func restore(_ id: UInt64) throws {
        throw SheetKernelError.notBuilt
    }
    #endif

    /// Körper der Sitzung (psk.bodies).
    func bodies() throws -> [(name: String, sheet: Bool, unfolded: Bool)] {
        let result = try execute(SheetCommand("psk.bodies"))
        return (result["bodies"]?.asArray ?? []).compactMap { entry in
            guard let name = entry["name"]?.asString else { return nil }
            return (name, entry["sheet"]?.asBool ?? false, entry["unfolded"]?.asBool ?? false)
        }
    }

    /// Exakter Körper (B-Rep) als OCCT-Körper: psk.export_step in eine temporäre Datei, dann PCKShape.readSTEP.
    func shape(of body: String) throws -> PCKShape {
        guard PCKShape.stepAvailable else {
            throw SheetKernelError("Blechkörper brauchen OpenCASCADE mit STEP (siehe README).")
        }
        let url = Self.temporaryURL("step")
        defer { try? FileManager.default.removeItem(at: url) }
        let path = url.path(percentEncoded: false)
        try execute(SheetCommand("psk.export_step", ["body": .string(body), "path": .string(path)]))
        guard let shapes = PCKShape.readSTEP(path: path), !shapes.isEmpty else {
            throw SheetKernelError("Blechkörper „\(body)“ ließ sich nicht übernehmen (STEP leer).")
        }
        if shapes.count == 1 { return shapes[0] }
        guard let compound = PCKShape.compound(shapes) else {
            throw SheetKernelError("Blechkörper „\(body)“ ließ sich nicht übernehmen.")
        }
        return compound
    }

    /// PencilCAD-Körper in die Sitzung holen (psk.import_step) – für „In Blech umwandeln“. Liefert die Namen.
    func importBody(_ shape: PCKShape, name: String) throws -> [String] {
        guard PCKShape.stepAvailable else {
            throw SheetKernelError("In Blech umwandeln braucht OpenCASCADE mit STEP (siehe README).")
        }
        let url = Self.temporaryURL("step")
        defer { try? FileManager.default.removeItem(at: url) }
        let path = url.path(percentEncoded: false)
        guard PCKShape.writeSTEP([shape], path: path) else {
            throw SheetKernelError("Körper ließ sich nicht als STEP schreiben.")
        }
        let result = try execute(SheetCommand("psk.import_step", ["path": .string(path), "name": .string(name)]))
        return (result["bodies"]?.asArray ?? []).compactMap(\.asString)
    }

    /// Eindeutige Datei im temporären Ordner der App.
    static func temporaryURL(_ ext: String, name: String? = nil) -> URL {
        let base = name ?? "pencil-sheet-\(UUID().uuidString)"
        return FileManager.default.temporaryDirectory.appending(path: "\(base).\(ext)")
    }
}
