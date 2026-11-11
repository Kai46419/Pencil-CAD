import Compression
import Foundation
import simd

// STL- und 3MF-Dateien einlesen (Einfügen › STEP/STL/3MF bzw. Import-Knopf). Die Dreiecke werden repariert
// (MeshRepair.swift) und im Kernel zu Volumenkörpern, damit Bohren, Schneiden, Vereinigen usw. gehen.

/// Ein Objekt aus einer Netzdatei: Dreiecke als Suppe (je drei Punkte ein Dreieck, Einheit mm).
struct ImportedMeshObject {
    var name: String
    var color: SIMD3<Float>?
    var soup: [SIMD3<Double>]
}

struct MeshImportError: LocalizedError {
    var text: String
    var errorDescription: String? { text }
}

enum MeshFileReader {
    /// Dateiendungen, die als Netz eingelesen werden.
    static let extensions: Set<String> = ["stl", "3mf"]

    static func read(_ data: Data, name: String, fileExtension: String) throws -> [ImportedMeshObject] {
        guard extensions.contains(fileExtension.lowercased()) else {
            throw MeshImportError(text: "Dieses Netzformat wird nicht unterstützt.")
        }
        if fileExtension.lowercased() == "3mf" {
            return try threeMF(data, name: name)
        }
        return [try stl(data, name: name)]
    }

    // MARK: STL

    /// Binäres oder ASCII-STL (Einheit mm).
    static func stl(_ data: Data, name: String) throws -> ImportedMeshObject {
        let bytes = [UInt8](data)
        guard bytes.count >= 15 else { throw MeshImportError(text: "Die STL-Datei ist leer.") }
        var soup: [SIMD3<Double>] = []
        if bytes.count >= 84 {
            let count = Int(Zip.u32(bytes, 80))
            let expected = 84 + count * 50
            // Auch binäre Dateien beginnen manchmal mit „solid“: die Größe entscheidet
            if expected == bytes.count || (count > 0 && expected <= bytes.count && !looksLikeText(bytes)) {
                soup = binarySTL(bytes, count: count)
            } else if expected > bytes.count, !looksLikeText(bytes) {
                throw MeshImportError(text: "Die binäre STL-Datei ist unvollständig.")
            }
        }
        if soup.isEmpty {
            soup = try asciiSTL(bytes)
        }
        guard soup.count >= 3 else { throw MeshImportError(text: "In der STL-Datei wurden keine Dreiecke gefunden.") }
        try validate(soup)
        return ImportedMeshObject(name: name, color: nil, soup: soup)
    }

    private static func validate(_ soup: [SIMD3<Double>]) throws {
        guard soup.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw MeshImportError(text: "Die Netzdatei enthält ungültige Koordinaten (NaN oder Unendlich).")
        }
    }

    private static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        let prefix = String(decoding: bytes.prefix(5), as: UTF8.self).lowercased()
        guard prefix == "solid" else { return false }
        let sample = bytes.prefix(1000)
        return String(decoding: sample, as: UTF8.self).contains("facet")
    }

    private static func binarySTL(_ bytes: [UInt8], count: Int) -> [SIMD3<Double>] {
        var soup: [SIMD3<Double>] = []
        soup.reserveCapacity(count * 3)
        bytes.withUnsafeBytes { raw in
            for t in 0..<count {
                let base = 84 + t * 50 + 12
                guard base + 36 <= raw.count else { break }
                for k in 0..<3 {
                    let offset = base + k * 12
                    let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                    let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
                    soup.append(SIMD3<Double>(Double(x), Double(y), Double(z)))
                }
            }
        }
        return soup
    }

    /// ASCII-STL: „vertex x y z“ je Punkt; Vielecke mit mehr als drei Punkten werden als Fächer zerlegt.
    private static func asciiSTL(_ input: [UInt8]) throws -> [SIMD3<Double>] {
        var bytes = input
        bytes.append(0)
        var soup: [SIMD3<Double>] = []
        var loop: [SIMD3<Double>] = []
        func flush() throws {
            guard loop.isEmpty || loop.count >= 3 else {
                throw MeshImportError(text: "Die STL-Datei enthält eine unvollständige Fläche.")
            }
            if loop.count >= 3 {
                for k in 1..<(loop.count - 1) {
                    soup.append(loop[0])
                    soup.append(loop[k])
                    soup.append(loop[k + 1])
                }
            }
            loop.removeAll(keepingCapacity: true)
        }
        try bytes.withUnsafeBufferPointer { buffer in
            guard let start = buffer.baseAddress else { return }
            try start.withMemoryRebound(to: CChar.self, capacity: buffer.count) { base in
                let end = buffer.count - 1
                var i = 0
                while i < end {
                    if isSpace(buffer[i]) {
                        i += 1
                        continue
                    }
                    let tokenStart = i
                    while i < end, !isSpace(buffer[i]) { i += 1 }
                    let length = i - tokenStart
                    if length == 6, matches(buffer, tokenStart, "vertex") {
                        var cursor: UnsafePointer<CChar> = base + i
                        var point = SIMD3<Double>(repeating: 0)
                        var ok = true
                        for k in 0..<3 {
                            var stop: UnsafeMutablePointer<CChar>?
                            let value = strtod(cursor, &stop)
                            guard let stop, UnsafePointer(stop) != cursor else {
                                ok = false
                                break
                            }
                            point[k] = value
                            cursor = UnsafePointer(stop)
                        }
                        if ok {
                            loop.append(point)
                            i = base.distance(to: cursor)
                        } else {
                            throw MeshImportError(text: "Die STL-Datei enthält einen ungültigen Eckpunkt.")
                        }
                    } else if length == 7, matches(buffer, tokenStart, "endloop") {
                        try flush()
                    } else if length == 8, matches(buffer, tokenStart, "endfacet") {
                        try flush()
                    }
                }
            }
        }
        try flush()
        return soup
    }

    @inline(__always) private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 0
    }

    private static func matches(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ word: String) -> Bool {
        var k = start
        for character in word.utf8 {
            let byte = buffer[k]
            // Groß- und Kleinschreibung egal
            let lower: UInt8 = byte >= 65 && byte <= 90 ? byte + 32 : byte
            if lower != character { return false }
            k += 1
        }
        return true
    }

    // MARK: 3MF

    /// 3MF: ZIP mit dem Modell (XML). Jedes Bauteil (build/item) wird ein Objekt; Bauteile aus Komponenten
    /// (auch in eigenen Dateien wie bei Bambu Studio und PrusaSlicer) werden mit ihren Lagen zusammengesetzt.
    /// C6 (Build 41): Obergrenzen beim Auffalten der 3MF-Komponenten (Instanzen bzw. Dreiecke aller Instanzen).
    static let maxThreeMFInstances = 10_000
    static let maxThreeMFTriangles = 200_000

    static func threeMF(_ data: Data, name: String) throws -> [ImportedMeshObject] {
        let bytes = [UInt8](data)
        guard let entries = Zip.entries(bytes) else {
            throw MeshImportError(text: "Die 3MF-Datei ist kein gültiges ZIP-Archiv.")
        }
        var rootPath = "3D/3dmodel.model"
        if let rels = entries["_rels/.rels"].flatMap({ Zip.extract($0, from: bytes) }),
           let target = ThreeMFRelationships.modelTarget(rels) {
            rootPath = normalizedPath(target)
        }
        if entries[rootPath] == nil {
            // Groß-/Kleinschreibung oder andere Ablage: erste .model-Datei im Ordner 3D
            if let found = entries.keys.sorted().first(where: { $0.lowercased() == rootPath.lowercased() })
                ?? entries.keys.sorted().first(where: { $0.lowercased().hasSuffix(".model") }) {
                rootPath = found
            }
        }
        var models: [String: ThreeMFModel] = [:]
        func model(_ path: String) -> ThreeMFModel? {
            if let cached = models[path] { return cached }
            guard let entry = entries[path] ?? entries.first(where: { $0.key.lowercased() == path.lowercased() })?.value,
                  let content = Zip.extract(entry, from: bytes) else { return nil }
            guard let parsed = ThreeMFModel.parse(content) else { return nil }
            models[path] = parsed
            return parsed
        }
        guard let root = model(rootPath) else {
            throw MeshImportError(text: "In der 3MF-Datei fehlt das 3D-Modell (3D/3dmodel.model).")
        }
        let scale = root.unitScale
        // C6 (Build 41): Komponenten werden aufgefaltet – verschachtelte Verweise vervielfachen sich exponentiell.
        // Grenzen für die ganze Datei, geprüft bevor Dreiecke angehängt werden.
        var instances = 0
        var flattenedTriangles = 0

        /// Dreiecke eines Objekts samt Komponenten in Weltlage anhängen.
        func collect(_ id: String, path: String, transform: simd_double4x4, depth: Int,
                     into soup: inout [SIMD3<Double>], color: inout SIMD3<Float>?) throws {
            guard depth < 16, let file = model(path), let object = file.objects[id] else {
                throw MeshImportError(text: "Die 3MF-Datei enthält eine fehlende oder zu tief verschachtelte Komponente.")
            }
            instances += 1
            flattenedTriangles += object.triangles.count / 3
            guard instances <= MeshFileReader.maxThreeMFInstances else {
                throw MeshImportError(text: "Die 3MF-Datei enthält mehr als \(MeshFileReader.maxThreeMFInstances) Bauteil-Instanzen.")
            }
            guard flattenedTriangles <= MeshFileReader.maxThreeMFTriangles else {
                throw MeshImportError(text: "Die 3MF-Datei ergibt aufgefaltet mehr als \(MeshFileReader.maxThreeMFTriangles) Dreiecke.")
            }
            if color == nil { color = file.color(of: object) }
            let mirrored = simd_determinant(transform) < 0
            let count = object.positions.count
            var t = 0
            while t + 2 < object.triangles.count {
                let a = Int(object.triangles[t]), b = Int(object.triangles[t + 1]), c = Int(object.triangles[t + 2])
                t += 3
                guard a < count, b < count, c < count else {
                    throw MeshImportError(text: "Eine 3MF-Fläche verweist auf einen fehlenden Eckpunkt.")
                }
                let order: [Int] = mirrored ? [a, c, b] : [a, b, c]
                for index in order {
                    let p = object.positions[index]
                    let world: SIMD4<Double> = transform * SIMD4<Double>(p.x, p.y, p.z, 1)
                    soup.append(SIMD3<Double>(world.x, world.y, world.z) * scale)
                }
            }
            for component in object.components {
                let childPath = component.path.map(normalizedPath) ?? path
                let childTransform: simd_double4x4 = transform * component.transform
                try collect(component.objectID, path: childPath, transform: childTransform, depth: depth + 1,
                        into: &soup, color: &color)
            }
        }

        var items = root.items
        if items.isEmpty {
            // Ohne Bauliste: alle Objekte, die nicht Teil eines anderen sind
            let used = Set(root.objects.values.flatMap { $0.components.map(\.objectID) })
            items = root.objectOrder.filter { !used.contains($0) }.map {
                ThreeMFModel.Reference(objectID: $0, path: nil, transform: matrix_identity_double4x4)
            }
        }
        var result: [ImportedMeshObject] = []
        for (index, item) in items.enumerated() {
            let path = item.path.map(normalizedPath) ?? rootPath
            var soup: [SIMD3<Double>] = []
            var color: SIMD3<Float>?
            try collect(item.objectID, path: path, transform: item.transform, depth: 0, into: &soup, color: &color)
            guard soup.count >= 3 else { continue }
            try validate(soup)
            let objectName = model(path)?.objects[item.objectID]?.name ?? ""
            let fallback = items.count > 1 ? "\(name) \(index + 1)" : name
            result.append(ImportedMeshObject(name: objectName.isEmpty ? fallback : objectName, color: color, soup: soup))
        }
        guard !result.isEmpty else { throw MeshImportError(text: "In der 3MF-Datei wurden keine Dreiecke gefunden.") }
        return result
    }

    /// „/3D/Objects/object_1.model“ → „3D/Objects/object_1.model“
    private static func normalizedPath(_ path: String) -> String {
        var result = path.removingPercentEncoding ?? path
        while result.hasPrefix("/") { result.removeFirst() }
        return result
    }
}

// MARK: - ZIP lesen

/// Liest ZIP-Archive (Einträge „stored“ und „deflate“, auch ZIP64-Größen) – genug für 3MF.
enum Zip {
    struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var checksum: UInt32? = nil
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 1 < b.count else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        u16(b, o) | u16(b, o + 2) << 16
    }

    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }

    /// Inhaltsverzeichnis: Name → Eintrag. nil, wenn es kein ZIP ist.
    static func entries(_ b: [UInt8]) -> [String: Entry]? {
        guard b.count >= 22 else { return nil }
        // Ende des Inhaltsverzeichnisses suchen (höchstens 64 KB Kommentar)
        var end = -1
        var o = b.count - 22
        let lowest = max(0, b.count - 22 - 65_535)
        while o >= lowest {
            if b[o] == 0x50, b[o + 1] == 0x4B, b[o + 2] == 0x05, b[o + 3] == 0x06 {
                end = o
                break
            }
            o -= 1
        }
        guard end >= 0 else { return nil }
        let count = Int(u16(b, end + 10))
        var p = Int(u32(b, end + 16))
        var result: [String: Entry] = [:]
        for _ in 0..<count {
            guard p <= b.count - 46, u32(b, p) == 0x0201_4B50 else { return nil }
            let method = Int(u16(b, p + 10))
            var compressed = UInt64(u32(b, p + 20))
            var size = UInt64(u32(b, p + 24))
            let nameLength = Int(u16(b, p + 28)), extraLength = Int(u16(b, p + 30))
            let commentLength = Int(u16(b, p + 32))
            guard nameLength + extraLength + commentLength <= b.count - p - 46 else { return nil }
            var offset = UInt64(u32(b, p + 42))
            let nameEnd = min(b.count, p + 46 + nameLength)
            let name = String(decoding: b[(p + 46)..<nameEnd], as: UTF8.self)
            // ZIP64: echte Größen im Zusatzfeld 0x0001
            var q = p + 46 + nameLength
            let extraEnd = min(b.count, q + extraLength)
            while q + 4 <= extraEnd {
                let id = u16(b, q), length = Int(u16(b, q + 2))
                guard length <= extraEnd - q - 4 else { return nil }
                if id == 1 {
                    var r = q + 4
                    let fieldEnd = r + length
                    if size == 0xFFFF_FFFF {
                        guard r <= fieldEnd - 8 else { return nil }
                        size = u64(b, r)
                        r += 8
                    }
                    if compressed == 0xFFFF_FFFF {
                        guard r <= fieldEnd - 8 else { return nil }
                        compressed = u64(b, r)
                        r += 8
                    }
                    if offset == 0xFFFF_FFFF {
                        guard r <= fieldEnd - 8 else { return nil }
                        offset = u64(b, r)
                    }
                }
                q += 4 + length
            }
            result[name] = Entry(name: name, method: method, compressedSize: Int(clamping: compressed),
                                 size: Int(clamping: size), localOffset: Int(clamping: offset), checksum: u32(b, p + 16))
            p += 46 + nameLength + extraLength + commentLength
        }
        return result.isEmpty ? nil : result
    }

    /// Inhalt eines Eintrags (entpackt). nil bei unbekannter Methode oder Fehler.
    static func extract(_ entry: Entry, from b: [UInt8]) -> Data? {
        let local = entry.localOffset
        guard b.count >= 30, local >= 0, local <= b.count - 30,
              entry.size >= 0, entry.size <= 256 * 1024 * 1024,
              entry.compressedSize >= 0, u32(b, local) == 0x0403_4B50 else { return nil }
        let start = local + 30 + Int(u16(b, local + 26)) + Int(u16(b, local + 28))
        guard start <= b.count, entry.compressedSize <= b.count - start else { return nil }
        let stop = start + entry.compressedSize
        guard start <= stop, stop <= b.count else { return nil }
        let slice = b[start..<stop]
        let output: Data
        switch entry.method {
        case 0:
            guard entry.size == slice.count else { return nil }
            output = Data(slice)
        case 8:
            guard let inflated = inflate(slice, size: entry.size) else { return nil }
            output = inflated
        default:
            return nil
        }
        if let checksum = entry.checksum, crc32(output) != checksum { return nil }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = .max
        for byte in data { checksum = (checksum >> 8) ^ crcTable[Int((checksum ^ UInt32(byte)) & 0xff)] }
        return ~checksum
    }

    /// Deflate entpacken (COMPRESSION_ZLIB ist rohes Deflate nach RFC 1951, ohne zlib-Kopf).
    private static func inflate(_ input: ArraySlice<UInt8>, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard !input.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written: Int = input.withUnsafeBufferPointer { source -> Int in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return 0 }
                return compression_decode_buffer(to, size, from, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        return Data(output)
    }
}

// MARK: - 3MF-Modell

/// Ziel der Modellbeziehung in _rels/.rels.
private final class ThreeMFRelationships: NSObject, XMLParserDelegate {
    private var target: String?

    static func modelTarget(_ data: Data) -> String? {
        let delegate = ThreeMFRelationships()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.target
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard ThreeMFModel.localName(elementName) == "Relationship", target == nil,
              let type = attributeDict["Type"], type.hasSuffix("/3dmodel"), let found = attributeDict["Target"] else { return }
        target = found
    }
}

/// Eine .model-Datei: Objekte (Netz und/oder Komponenten), Materialien und die Bauliste.
final class ThreeMFModel: NSObject, XMLParserDelegate {
    struct Reference {
        var objectID: String
        var path: String?
        var transform: simd_double4x4
    }

    struct Object {
        var name = ""
        var materialGroup: String?
        var materialIndex = 0
        var positions: [SIMD3<Double>] = []
        var triangles: [UInt32] = []
        var components: [Reference] = []
    }

    /// Faktor auf mm
    private(set) var unitScale: Double = 1
    private(set) var objects: [String: Object] = [:]
    private(set) var objectOrder: [String] = []
    private(set) var items: [Reference] = []
    /// Farben je Material- bzw. Farbgruppe
    private var colors: [String: [SIMD3<Float>]] = [:]
    private var currentID: String?
    private var current = Object()
    private var currentGroup: String?

    static func parse(_ data: Data) -> ThreeMFModel? {
        let model = ThreeMFModel()
        let parser = XMLParser(data: data)
        parser.delegate = model
        return parser.parse() ? model : nil
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// Attribut unabhängig vom Namensraum-Präfix („p:path“ = „path“).
    private static func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let value = attributes[name] { return value }
        let suffix = ":" + name
        return attributes.first(where: { $0.key.hasSuffix(suffix) })?.value
    }

    func color(of object: Object) -> SIMD3<Float>? {
        guard let group = object.materialGroup, let list = colors[group], list.indices.contains(object.materialIndex) else {
            return nil
        }
        return list[object.materialIndex]
    }

    /// „m00 m01 m02 m10 … m32“ (Zeilenvektor · Matrix) als Spaltenmatrix für M · p.
    private static func transform(_ text: String?) -> simd_double4x4? {
        guard let text else { return matrix_identity_double4x4 }
        let fields = text.split(whereSeparator: \.isWhitespace)
        let values = fields.compactMap { Double($0) }
        guard fields.count == 12, values.count == 12, values.allSatisfy(\.isFinite) else { return nil }
        let c0 = SIMD4<Double>(values[0], values[1], values[2], 0)
        let c1 = SIMD4<Double>(values[3], values[4], values[5], 0)
        let c2 = SIMD4<Double>(values[6], values[7], values[8], 0)
        let c3 = SIMD4<Double>(values[9], values[10], values[11], 1)
        return simd_double4x4(columns: (c0, c1, c2, c3))
    }

    /// „#RRGGBB“ bzw. „#RRGGBBAA“
    private static func color(_ text: String?) -> SIMD3<Float>? {
        guard var hex = text?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return nil }
        let r = Float((value >> 16) & 0xFF) / 255, g = Float((value >> 8) & 0xFF) / 255, b = Float(value & 0xFF) / 255
        return SIMD3(r, g, b)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch Self.localName(elementName) {
        case "vertex":
            guard currentID != nil else { return }
            guard let x = attributeDict["x"].flatMap(Double.init),
                  let y = attributeDict["y"].flatMap(Double.init),
                  let z = attributeDict["z"].flatMap(Double.init), x.isFinite, y.isFinite, z.isFinite else {
                parser.abortParsing()
                return
            }
            current.positions.append(SIMD3(x, y, z))
        case "triangle":
            guard currentID != nil else { return }
            guard let a = attributeDict["v1"].flatMap({ UInt32($0) }),
                  let b = attributeDict["v2"].flatMap({ UInt32($0) }),
                  let c = attributeDict["v3"].flatMap({ UInt32($0) }) else {
                parser.abortParsing()
                return
            }
            current.triangles.append(a)
            current.triangles.append(b)
            current.triangles.append(c)
            // Farbe am Dreieck, wenn das Objekt selbst keine hat
            if current.materialGroup == nil, let group = attributeDict["pid"] {
                current.materialGroup = group
                current.materialIndex = attributeDict["p1"].flatMap { Int($0) } ?? 0
            }
        case "object":
            currentID = attributeDict["id"]
            current = Object()
            current.name = attributeDict["name"] ?? ""
            current.materialGroup = attributeDict["pid"]
            current.materialIndex = attributeDict["pindex"].flatMap { Int($0) } ?? 0
        case "component":
            guard currentID != nil, let id = attributeDict["objectid"] else { return }
            guard let transform = Self.transform(attributeDict["transform"]) else { parser.abortParsing(); return }
            current.components.append(Reference(objectID: id, path: Self.attribute(attributeDict, "path"),
                                                transform: transform))
        case "item":
            guard let id = attributeDict["objectid"] else { return }
            guard let transform = Self.transform(attributeDict["transform"]) else { parser.abortParsing(); return }
            items.append(Reference(objectID: id, path: Self.attribute(attributeDict, "path"),
                                   transform: transform))
        case "basematerials", "colorgroup":
            currentGroup = attributeDict["id"]
            if let currentGroup { colors[currentGroup] = [] }
        case "base":
            guard let currentGroup else { return }
            colors[currentGroup, default: []].append(Self.color(attributeDict["displaycolor"]) ?? SIMD3(0.7, 0.7, 0.7))
        case "color":
            guard let currentGroup else { return }
            colors[currentGroup, default: []].append(Self.color(attributeDict["color"]) ?? SIMD3(0.7, 0.7, 0.7))
        case "model":
            switch (attributeDict["unit"] ?? "millimeter").lowercased() {
            case "micron": unitScale = 0.001
            case "centimeter": unitScale = 10
            case "inch": unitScale = 25.4
            case "foot": unitScale = 304.8
            case "meter": unitScale = 1000
            default: unitScale = 1
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch Self.localName(elementName) {
        case "object":
            if let currentID {
                objects[currentID] = current
                objectOrder.append(currentID)
            }
            currentID = nil
            current = Object()
        case "basematerials", "colorgroup":
            currentGroup = nil
        default:
            break
        }
    }
}
