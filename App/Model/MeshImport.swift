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
            }
        }
        if soup.isEmpty {
            soup = asciiSTL(bytes)
        }
        guard soup.count >= 3 else { throw MeshImportError(text: "In der STL-Datei wurden keine Dreiecke gefunden.") }
        return ImportedMeshObject(name: name, color: nil, soup: soup)
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
    private static func asciiSTL(_ input: [UInt8]) -> [SIMD3<Double>] {
        var bytes = input
        bytes.append(0)
        var soup: [SIMD3<Double>] = []
        var loop: [SIMD3<Double>] = []
        func flush() {
            if loop.count >= 3 {
                for k in 1..<(loop.count - 1) {
                    soup.append(loop[0])
                    soup.append(loop[k])
                    soup.append(loop[k + 1])
                }
            }
            loop.removeAll(keepingCapacity: true)
        }
        bytes.withUnsafeBufferPointer { buffer in
            guard let start = buffer.baseAddress else { return }
            start.withMemoryRebound(to: CChar.self, capacity: buffer.count) { base in
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
                        }
                    } else if length == 7, matches(buffer, tokenStart, "endloop") {
                        flush()
                    } else if length == 8, matches(buffer, tokenStart, "endfacet") {
                        flush()
                    }
                }
            }
        }
        flush()
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
            let parsed = ThreeMFModel.parse(content)
            models[path] = parsed
            return parsed
        }
        guard let root = model(rootPath) else {
            throw MeshImportError(text: "In der 3MF-Datei fehlt das 3D-Modell (3D/3dmodel.model).")
        }
        let scale = root.unitScale

        /// Dreiecke eines Objekts samt Komponenten in Weltlage anhängen.
        func collect(_ id: String, path: String, transform: simd_double4x4, depth: Int,
                     into soup: inout [SIMD3<Double>], color: inout SIMD3<Float>?) {
            guard depth < 16, let file = model(path), let object = file.objects[id] else { return }
            if color == nil { color = file.color(of: object) }
            let mirrored = simd_determinant(transform) < 0
            let count = object.positions.count
            var t = 0
            while t + 2 < object.triangles.count {
                let a = Int(object.triangles[t]), b = Int(object.triangles[t + 1]), c = Int(object.triangles[t + 2])
                t += 3
                guard a < count, b < count, c < count else { continue }
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
                collect(component.objectID, path: childPath, transform: childTransform, depth: depth + 1,
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
            collect(item.objectID, path: path, transform: item.transform, depth: 0, into: &soup, color: &color)
            guard soup.count >= 3 else { continue }
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
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { break }
            let method = Int(u16(b, p + 10))
            var compressed = UInt64(u32(b, p + 20))
            var size = UInt64(u32(b, p + 24))
            let nameLength = Int(u16(b, p + 28)), extraLength = Int(u16(b, p + 30))
            let commentLength = Int(u16(b, p + 32))
            var offset = UInt64(u32(b, p + 42))
            let nameEnd = min(b.count, p + 46 + nameLength)
            let name = String(decoding: b[(p + 46)..<nameEnd], as: UTF8.self)
            // ZIP64: echte Größen im Zusatzfeld 0x0001
            var q = p + 46 + nameLength
            let extraEnd = min(b.count, q + extraLength)
            while q + 4 <= extraEnd {
                let id = u16(b, q), length = Int(u16(b, q + 2))
                if id == 1 {
                    var r = q + 4
                    if size == 0xFFFF_FFFF {
                        size = u64(b, r)
                        r += 8
                    }
                    if compressed == 0xFFFF_FFFF {
                        compressed = u64(b, r)
                        r += 8
                    }
                    if offset == 0xFFFF_FFFF { offset = u64(b, r) }
                }
                q += 4 + length
            }
            result[name] = Entry(name: name, method: method, compressedSize: Int(clamping: compressed),
                                 size: Int(clamping: size), localOffset: Int(clamping: offset))
            p += 46 + nameLength + extraLength + commentLength
        }
        return result.isEmpty ? nil : result
    }

    /// Inhalt eines Eintrags (entpackt). nil bei unbekannter Methode oder Fehler.
    static func extract(_ entry: Entry, from b: [UInt8]) -> Data? {
        let local = entry.localOffset
        guard local >= 0, local + 30 <= b.count, u32(b, local) == 0x0403_4B50 else { return nil }
        let start = local + 30 + Int(u16(b, local + 26)) + Int(u16(b, local + 28))
        let stop = start + entry.compressedSize
        guard start <= stop, stop <= b.count else { return nil }
        let slice = b[start..<stop]
        switch entry.method {
        case 0:
            return Data(slice)
        case 8:
            return inflate(slice, size: entry.size)
        default:
            return nil
        }
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
        guard written > 0 else { return nil }
        if written < size { output.removeLast(size - written) }
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

    static func parse(_ data: Data) -> ThreeMFModel {
        let model = ThreeMFModel()
        let parser = XMLParser(data: data)
        parser.delegate = model
        parser.parse()
        return model
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
    private static func transform(_ text: String?) -> simd_double4x4 {
        guard let text else { return matrix_identity_double4x4 }
        let values: [Double] = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .compactMap { Double($0) }
        guard values.count == 12 else { return matrix_identity_double4x4 }
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

    private static func number(_ text: String?) -> Double {
        text.flatMap { Double($0) } ?? 0
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch Self.localName(elementName) {
        case "vertex":
            guard currentID != nil else { return }
            let x = Self.number(attributeDict["x"]), y = Self.number(attributeDict["y"]), z = Self.number(attributeDict["z"])
            current.positions.append(SIMD3(x, y, z))
        case "triangle":
            guard currentID != nil, let a = attributeDict["v1"].flatMap({ UInt32($0) }),
                  let b = attributeDict["v2"].flatMap({ UInt32($0) }),
                  let c = attributeDict["v3"].flatMap({ UInt32($0) }) else { return }
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
            current.components.append(Reference(objectID: id, path: Self.attribute(attributeDict, "path"),
                                                transform: Self.transform(attributeDict["transform"])))
        case "item":
            guard let id = attributeDict["objectid"] else { return }
            items.append(Reference(objectID: id, path: Self.attribute(attributeDict, "path"),
                                   transform: Self.transform(attributeDict["transform"])))
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

// MARK: - Umwandeln

/// Ergebnis eines Netzimports, im Hintergrund berechnet.
struct MeshImportResult {
    struct Part {
        var name: String
        var color: SIMD3<Float>?
        var shape: PCKShape
        var closed: Bool
    }

    var parts: [Part] = []
    var report = MeshRepairReport()
    var triangles = 0
    var error: String?
}

enum MeshImporter {
    /// Teile mit weniger Dreiecken (Splitter) fallen weg; mehr Teile als maxParts bleiben ein Körper.
    static let minimumPartTriangles = 4
    static let maxParts = 32

    /// Datei lesen, reparieren, bei Bedarf reduzieren und in Körper umwandeln (langsam: im Hintergrund aufrufen).
    static func convert(_ data: Data, name: String, fileExtension: String) -> MeshImportResult {
        var result = MeshImportResult()
        let objects: [ImportedMeshObject]
        do {
            objects = try MeshFileReader.read(data, name: name, fileExtension: fileExtension)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        let total = objects.reduce(0) { $0 + $1.soup.count / 3 }
        for object in objects {
            let repaired = MeshRepair.repair(soup: object.soup)
            var mesh = repaired.mesh
            var report = repaired.report
            // Anteil dieses Objekts an der Höchstzahl (mehrere Objekte teilen sich die Grenze)
            let share = max(1, object.soup.count / 3)
            let budget = max(2000, MeshSolid.maxTriangles * share / max(1, total))
            if mesh.triangles.count > budget {
                report.reducedFrom = mesh.triangles.count
                mesh = MeshRepair.simplify(mesh, target: budget)
                report.reducedTo = mesh.triangles.count
            }
            result.report.add(report)
            result.triangles += mesh.triangles.count
            let parts = MeshRepair.components(mesh).filter { $0.triangles.count >= minimumPartTriangles }
            if parts.count > 1, parts.count <= maxParts {
                for (index, part) in parts.enumerated() {
                    guard let shape = MeshSolid.shape(from: part) else { continue }
                    result.parts.append(MeshImportResult.Part(name: "\(object.name) \(index + 1)", color: object.color,
                                                              shape: shape, closed: shape.isClosedSolid))
                }
            } else if parts.count > maxParts {
                let shapes: [PCKShape] = parts.compactMap { MeshSolid.shape(from: $0) }
                if let combined = PCKShape.compound(shapes) {
                    let closed = shapes.allSatisfy { $0.isClosedSolid }
                    result.parts.append(MeshImportResult.Part(name: object.name, color: object.color, shape: combined,
                                                              closed: closed))
                }
            } else if let only = parts.first, let shape = MeshSolid.shape(from: only) {
                result.parts.append(MeshImportResult.Part(name: object.name, color: object.color, shape: shape,
                                                          closed: shape.isClosedSolid))
            }
        }
        if result.parts.isEmpty, result.error == nil {
            result.error = "Das Netz ließ sich nicht in einen Körper umwandeln."
        }
        return result
    }
}

extension ModelStore {
    /// STL- bzw. 3MF-Datei als Körper einfügen (Lesen und Umwandeln im Hintergrund). done läuft danach
    /// (z. B. Ansicht einpassen).
    func importMesh(from url: URL, done: (() -> Void)? = nil) {
        guard requireKernel() else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if accessing { url.stopAccessingSecurityScopedResource() }
        let fileExtension = url.pathExtension.lowercased()
        let kind = fileExtension == "3mf" ? "3MF" : "STL"
        guard let data else {
            message = "\(kind)-Datei konnte nicht gelesen werden."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        message = "\(kind) wird gelesen und in einen Körper umgewandelt …"
        Task {
            let box = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<MeshImportResult> in
                UncheckedBox(MeshImporter.convert(data, name: name, fileExtension: fileExtension))
            }.value
            self.finishMeshImport(box.value, kind: kind)
            done?()
        }
    }

    private func finishMeshImport(_ result: MeshImportResult, kind: String) {
        guard result.error == nil, !result.parts.isEmpty else {
            message = result.error ?? "\(kind)-Import fehlgeschlagen."
            return
        }
        commitPreview()
        var list = bodies
        var number = bodies.count
        for part in result.parts {
            number += 1
            let color: SIMD3<Float> = part.color ?? SceneBody.palette[(number - 1) % SceneBody.palette.count]
            list.append(SceneBody(shape: part.shape, name: part.name, color: color))
        }
        commit(list, name: "\(kind) importieren")
        var notes: [String] = []
        let count = result.parts.count
        notes.append(count == 1 ? "\(kind) importiert (\(result.triangles) Dreiecke)"
                     : "\(kind) importiert: \(count) Körper (\(result.triangles) Dreiecke)")
        let repair = result.report.summary
        if !repair.isEmpty { notes.append(repair) }
        let open = result.parts.filter { !$0.closed }.count
        if open > 0 {
            notes.append(open == 1 ? "Netz nicht geschlossen – als Fläche eingefügt (Bohren und Vereinigen gehen erst geschlossen)"
                         : "\(open) Netze nicht geschlossen – als Flächen eingefügt")
        }
        message = notes.joined(separator: " · ")
    }
}
