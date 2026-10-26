import Foundation
import simd
import UniformTypeIdentifiers

// Export einzelner Körper oder aller Körper: STL, 3MF (für Slicer wie Bambu Studio, PrusaSlicer, Cura),
// OBJ und STEP. Netzformate werden aus der Kernel-Triangulierung erzeugt, gleiche Punkte verschweißt,
// damit Slicer ein geschlossenes Netz bekommen.

extension UTType {
    static let threeMF = UTType(filenameExtension: "3mf", conformingTo: .data) ?? .data
    static let objFile = UTType(filenameExtension: "obj", conformingTo: .data) ?? .data
    static let dxfFile = UTType(filenameExtension: "dxf", conformingTo: .data) ?? .data
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case threeMF = "3MF"
    case stl = "STL"
    case obj = "OBJ"
    case step = "STEP"
    case usdz = "USDZ"

    var id: Self { self }

    var type: UTType {
        switch self {
        case .threeMF: .threeMF
        case .stl: .stl
        case .obj: .objFile
        case .step: .stepFile
        case .usdz: .usdz
        }
    }

    var subtitle: String {
        switch self {
        case .threeMF: "3D-Druck, mit Farbe"
        case .stl: "3D-Druck, Netz"
        case .obj: "Netz für 3D-Programme"
        case .step: "CAD, exakte Geometrie"
        case .usdz: "AR, Keynote, Nachrichten"
        }
    }

    var systemImage: String {
        switch self {
        case .threeMF: "printer"
        case .stl: "triangle"
        case .obj: "cube.transparent"
        case .step: "doc.badge.gearshape"
        case .usdz: "arkit"
        }
    }
}

/// Geschlossenes Dreiecksnetz eines Körpers (verschweißte Punkte) für den Export.
struct ExportMesh {
    var name: String
    var color: SIMD3<Float>
    var positions: [SIMD3<Float>] = []
    var triangles: [SIMD3<UInt32>] = []

    init(name: String, color: SIMD3<Float>, mesh: Mesh) {
        self.name = name
        self.color = color
        var lookup: [SIMD3<Int32>: UInt32] = [:]
        func index(_ p: SIMD3<Float>) -> UInt32 {
            // Auf 0,0001 mm gerundet: Flächen teilen sich ihre Randpunkte
            let key = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()),
                                   Int32((p.z * 10_000).rounded()))
            if let existing = lookup[key] { return existing }
            let new = UInt32(positions.count)
            positions.append(p)
            lookup[key] = new
            return new
        }
        for t in 0..<mesh.triangleCount {
            let a = index(mesh.vertices[Int(mesh.indices[t * 3])].position)
            let b = index(mesh.vertices[Int(mesh.indices[t * 3 + 1])].position)
            let c = index(mesh.vertices[Int(mesh.indices[t * 3 + 2])].position)
            guard a != b, b != c, a != c else { continue }
            triangles.append(SIMD3(a, b, c))
        }
    }
}

enum MeshExport {
    static func stl(_ meshes: [ExportMesh]) -> Data {
        var data = Data(count: 80)
        let count = meshes.reduce(0) { $0 + $1.triangles.count }
        append(UInt32(count), to: &data)
        for mesh in meshes {
            for t in mesh.triangles {
                let a = mesh.positions[Int(t.x)], b = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
                let cross = simd_cross(b - a, c - a)
                let normal = simd_length(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 0, 0)
                for v in [normal, a, b, c] {
                    append(v.x.bitPattern, to: &data)
                    append(v.y.bitPattern, to: &data)
                    append(v.z.bitPattern, to: &data)
                }
                append(UInt16(0), to: &data)
            }
        }
        return data
    }

    static func obj(_ meshes: [ExportMesh]) -> Data {
        var text = "# PencilCAD, Einheit mm\n"
        var offset: UInt32 = 1
        for mesh in meshes {
            text += "o \(mesh.name.replacingOccurrences(of: " ", with: "_"))\n"
            for p in mesh.positions {
                text += "v \(number(p.x)) \(number(p.y)) \(number(p.z))\n"
            }
            for t in mesh.triangles {
                text += "f \(t.x + offset) \(t.y + offset) \(t.z + offset)\n"
            }
            offset += UInt32(mesh.positions.count)
        }
        return Data(text.utf8)
    }

    /// 3MF: ZIP mit Inhaltstypen, Beziehung und dem Modell (ein Objekt je Körper, Farbe als Grundmaterial).
    static func threeMF(_ meshes: [ExportMesh]) -> Data {
        var model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="de-DE" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <metadata name="Application">PencilCAD</metadata>
         <resources>
          <basematerials id="1">

        """
        for mesh in meshes {
            model += "   <base name=\"\(escape(mesh.name))\" displaycolor=\"\(hex(mesh.color))\"/>\n"
        }
        model += "  </basematerials>\n"
        for (index, mesh) in meshes.enumerated() {
            model += "  <object id=\"\(index + 2)\" type=\"model\" name=\"\(escape(mesh.name))\" pid=\"1\" pindex=\"\(index)\">\n"
            model += "   <mesh>\n    <vertices>\n"
            for p in mesh.positions {
                model += "     <vertex x=\"\(number(p.x))\" y=\"\(number(p.y))\" z=\"\(number(p.z))\"/>\n"
            }
            model += "    </vertices>\n    <triangles>\n"
            for t in mesh.triangles {
                model += "     <triangle v1=\"\(t.x)\" v2=\"\(t.y)\" v3=\"\(t.z)\"/>\n"
            }
            model += "    </triangles>\n   </mesh>\n  </object>\n"
        }
        model += " </resources>\n <build>\n"
        for index in meshes.indices {
            model += "  <item objectid=\"\(index + 2)\"/>\n"
        }
        model += " </build>\n</model>\n"

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\
        </Types>
        """
        let relationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Target="/3D/3dmodel.model" Id="rel0" \
        Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\
        </Relationships>
        """
        return StoredZip.archive([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(relationships.utf8)),
            ("3D/3dmodel.model", Data(model.utf8)),
        ])
    }

    private static func number(_ value: Float) -> String {
        String(format: "%.5f", value)
    }

    private static func hex(_ color: SIMD3<Float>) -> String {
        let c = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255
        return String(format: "#%02X%02X%02X", Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    fileprivate static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Minimales ZIP ohne Kompression (Methode „stored“), wie es 3MF-Leser akzeptieren.
enum StoredZip {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = UInt32(out.count)
            // Lokaler Kopf
            put(UInt32(0x0403_4B50), &out)
            put(UInt16(20), &out)
            put(UInt16(0), &out)
            put(UInt16(0), &out)
            put(UInt16(0), &out)
            put(UInt16(0x21), &out)
            put(crc, &out)
            put(UInt32(file.data.count), &out)
            put(UInt32(file.data.count), &out)
            put(UInt16(name.count), &out)
            put(UInt16(0), &out)
            out.append(name)
            out.append(file.data)
            // Eintrag im Inhaltsverzeichnis
            put(UInt32(0x0201_4B50), &central)
            put(UInt16(20), &central)
            put(UInt16(20), &central)
            put(UInt16(0), &central)
            put(UInt16(0), &central)
            put(UInt16(0), &central)
            put(UInt16(0x21), &central)
            put(crc, &central)
            put(UInt32(file.data.count), &central)
            put(UInt32(file.data.count), &central)
            put(UInt16(name.count), &central)
            put(UInt16(0), &central)
            put(UInt16(0), &central)
            put(UInt16(0), &central)
            put(UInt16(0), &central)
            put(UInt32(0), &central)
            put(offset, &central)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        put(UInt32(0x0605_4B50), &out)
        put(UInt16(0), &out)
        put(UInt16(0), &out)
        put(UInt16(files.count), &out)
        put(UInt16(files.count), &out)
        put(UInt32(central.count), &out)
        put(centralOffset, &out)
        put(UInt16(0), &out)
        return out
    }

    private static func put<T: FixedWidthInteger>(_ value: T, _ data: inout Data) {
        MeshExport.append(value, to: &data)
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
