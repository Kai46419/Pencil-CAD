import SwiftUI
import simd

// Oberflächen (wie die „Appearance“ in Fusion 360): nur die Darstellung – Farbe, Glanz, Metall, Klarlack,
// Transparenz und ein prozedurales Muster (Holz, Beton, gebürstet, Carbon). Unabhängig vom Werkstoff
// (Materials.swift), der Dichte und Gewicht bestimmt. Gespeichert wird nur der Kurzname in SceneBody.finish
// (bodies.json); eigene Farben als „Eigene:<Glanz>:<Metall>“ mit der Körperfarbe.

/// Prozedurales Muster im Shader (Nummer = Ganzzahlteil von color.b, siehe decodeSurface in Shaders.metal).
enum SurfacePattern: Int {
    case none = 0
    case wood = 1
    case concrete = 2
    case brushed = 3
    case carbon = 4
}

/// Darstellungswerte eines Körpers, so wie der Shader sie braucht.
struct SurfaceAppearance: Equatable {
    /// Grundfarbe (linear, wie die Vertexfarbe; bei Metall die Spiegelfarbe)
    var albedo: SIMD3<Float>
    /// 0 = Spiegel, 1 = ganz matt
    var roughness: Float
    var metallic = false
    /// Glänzende Lackschicht darüber (Klavierlack, Carbon)
    var clearcoat = false
    /// Durchsichtig (Glas, Acryl)
    var transparent = false
    var pattern: SurfacePattern = .none

    /// Vertexfarbe für den Renderer: Farbe im Nachkommateil (0,002…0,995), Ganzzahlteile
    /// r = Glanzstufe 0…16 (Rauheit 1 − Stufe/16; 0 = matt wie bisher), g = Bits (1 Metall, 2 Klarlack,
    /// 4 transparent), b = Muster. Muss zu decodeSurface in Shaders.metal passen.
    var encoded: SIMD3<Float> {
        let low = SIMD3<Float>(repeating: 0.002)
        let high = SIMD3<Float>(repeating: 0.995)
        let color: SIMD3<Float> = simd_clamp(albedo, low, high)
        let clampedRoughness: Float = min(max(roughness, 0), 1)
        let level: Float = ((1 - clampedRoughness) * 16).rounded()
        var bits: Float = 0
        if metallic { bits += 1 }
        if clearcoat { bits += 2 }
        if transparent { bits += 4 }
        let codes = SIMD3<Float>(level, bits, Float(pattern.rawValue))
        return color + codes
    }
}

/// Glanzstufe für eigene Farben.
enum SurfaceGloss: Int, CaseIterable, Identifiable {
    case matte = 0
    case satin = 1
    case glossy = 2

    var id: Self { self }

    var name: String {
        switch self {
        case .matte: "Matt"
        case .satin: "Seidenmatt"
        case .glossy: "Glänzend"
        }
    }

    var roughness: Float {
        switch self {
        case .matte: 0.85
        case .satin: 0.45
        case .glossy: 0.12
        }
    }

    /// Nächste Stufe zu einer Rauheit (beim Umfärben einer fertigen Oberfläche)
    static func nearest(_ roughness: Float) -> SurfaceGloss {
        if roughness <= 0.25 { return .glossy }
        if roughness <= 0.6 { return .satin }
        return .matte
    }
}

/// Fertige Oberfläche aus der Bibliothek.
struct SurfaceFinish: Identifiable, Hashable {
    /// Kurzname, so in bodies.json gespeichert
    let id: String
    let name: String
    let category: Category
    /// Grundfarbe (linear)
    let color: SIMD3<Float>
    let roughness: Float
    var metallic = false
    var clearcoat = false
    var transparent = false
    var pattern: SurfacePattern = .none

    enum Category: String, CaseIterable, Identifiable {
        case metal = "Metall"
        case anodized = "Aluminium eloxiert"
        case paint = "Lack und RAL-Farben"
        case nature = "Holz und Stein"
        case plastic = "Kunststoff (3D-Druck)"
        case special = "Glas, Gummi, Carbon"

        var id: Self { self }

        var symbol: String {
            switch self {
            case .metal: "sparkles"
            case .anodized: "circle.lefthalf.filled"
            case .paint: "paintbrush"
            case .nature: "leaf"
            case .plastic: "printer"
            case .special: "drop"
            }
        }
    }

    static func == (lhs: SurfaceFinish, rhs: SurfaceFinish) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var appearance: SurfaceAppearance {
        SurfaceAppearance(albedo: color, roughness: roughness, metallic: metallic, clearcoat: clearcoat,
                          transparent: transparent, pattern: pattern)
    }

    static func named(_ id: String) -> SurfaceFinish? {
        all.first { $0.id == id }
    }

    // MARK: Eigene Farbe

    /// Kennung einer eigenen Farbe, z. B. „Eigene:2:1“ = glänzend, metallisch
    static func customID(gloss: SurfaceGloss, metallic: Bool) -> String {
        "Eigene:\(gloss.rawValue):\(metallic ? 1 : 0)"
    }

    /// Glanz und Metall einer eigenen Farbe; nil, wenn die Kennung keine eigene Farbe ist.
    static func custom(_ id: String) -> (gloss: SurfaceGloss, metallic: Bool)? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "Eigene", let level = Int(parts[1]),
              let gloss = SurfaceGloss(rawValue: level) else { return nil }
        return (gloss, parts[2] == "1")
    }

    static func customAppearance(color: SIMD3<Float>, gloss: SurfaceGloss, metallic: Bool) -> SurfaceAppearance {
        // Glänzender Lack bekommt eine Klarlackschicht, glänzendes Metall nicht (sonst wirkt es lackiert)
        let coat = gloss == .glossy && !metallic
        let roughness: Float = metallic ? gloss.roughness * 0.75 : gloss.roughness
        return SurfaceAppearance(albedo: color, roughness: roughness, metallic: metallic, clearcoat: coat)
    }

    /// Nach dem Umfärben: eine fertige Oberfläche wird zur eigenen Farbe mit ähnlichem Glanz.
    static func recolored(_ id: String?) -> String? {
        guard let id else { return nil }
        if custom(id) != nil { return id }
        guard let finish = named(id) else { return nil }
        return customID(gloss: SurfaceGloss.nearest(finish.roughness), metallic: finish.metallic)
    }

    // MARK: Bibliothek

    private static func metal(_ id: String, _ name: String, _ color: SIMD3<Float>, _ roughness: Float,
                              pattern: SurfacePattern = .none, category: Category = .metal) -> SurfaceFinish {
        SurfaceFinish(id: id, name: name, category: category, color: color, roughness: roughness, metallic: true,
                      pattern: pattern)
    }

    private static func paint(_ id: String, _ name: String, _ color: SIMD3<Float>, _ roughness: Float,
                              coat: Bool = false, category: Category = .paint) -> SurfaceFinish {
        SurfaceFinish(id: id, name: name, category: category, color: color, roughness: roughness, clearcoat: coat)
    }

    private static let metals: [SurfaceFinish] = [
        metal("Chrom", "Chrom", [0.62, 0.63, 0.65], 0.04),
        metal("Spiegel", "Spiegel (verspiegelt)", [0.95, 0.95, 0.93], 0.0),
        metal("Gold", "Gold", [0.98, 0.76, 0.34], 0.12),
        metal("Kupfer", "Kupfer", [0.95, 0.62, 0.50], 0.2),
        metal("Messing", "Messing", [0.90, 0.76, 0.40], 0.2),
        metal("Bronze", "Bronze", [0.78, 0.53, 0.33], 0.32),
        metal("Edelstahl gebürstet", "Edelstahl gebürstet", [0.66, 0.66, 0.65], 0.32, pattern: .brushed),
        metal("Edelstahl", "Edelstahl poliert", [0.68, 0.68, 0.67], 0.1),
        metal("Aluminium", "Aluminium natur", [0.90, 0.91, 0.92], 0.38),
        metal("Aluminium gebürstet", "Aluminium gebürstet", [0.88, 0.89, 0.90], 0.3, pattern: .brushed),
        metal("Stahl", "Stahl blank", [0.55, 0.56, 0.57], 0.36),
        metal("Titan", "Titan", [0.54, 0.50, 0.46], 0.3),
        metal("Gusseisen", "Gusseisen roh", [0.33, 0.33, 0.33], 0.75, pattern: .concrete),
        metal("Metallic silber", "Metalloptik silber", [0.75, 0.76, 0.78], 0.48),
        metal("Metallic anthrazit", "Metalloptik anthrazit", [0.18, 0.19, 0.20], 0.45),
    ]

    private static let anodized: [SurfaceFinish] = [
        metal("Eloxal silber", "Eloxiert silber", [0.82, 0.83, 0.85], 0.42, category: .anodized),
        metal("Eloxal schwarz", "Eloxiert schwarz", [0.035, 0.035, 0.04], 0.38, category: .anodized),
        metal("Eloxal rot", "Eloxiert rot", [0.62, 0.05, 0.06], 0.32, category: .anodized),
        metal("Eloxal blau", "Eloxiert blau", [0.08, 0.22, 0.62], 0.32, category: .anodized),
        metal("Eloxal gold", "Eloxiert gold", [0.82, 0.60, 0.24], 0.32, category: .anodized),
        metal("Eloxal titan", "Eloxiert titangrau", [0.28, 0.29, 0.31], 0.38, category: .anodized),
        metal("Eloxal grün", "Eloxiert grün", [0.10, 0.42, 0.18], 0.32, category: .anodized),
        metal("Eloxal violett", "Eloxiert violett", [0.32, 0.10, 0.52], 0.32, category: .anodized),
    ]

    private static let paints: [SurfaceFinish] = [
        paint("Schwarz matt", "Schwarz matt", [0.022, 0.022, 0.024], 0.85),
        paint("Schwarz glänzend", "Schwarz glänzend", [0.018, 0.018, 0.02], 0.1, coat: true),
        paint("Weiß matt", "Weiß matt", [0.85, 0.85, 0.84], 0.85),
        paint("Weiß glänzend", "Weiß glänzend", [0.86, 0.86, 0.85], 0.1, coat: true),
        paint("Marineblau", "Marineblau (Saphirblau RAL 5003)", [0.014, 0.040, 0.090], 0.4),
        paint("Enzianblau", "Enzianblau RAL 5010", [0.006, 0.030, 0.090], 0.3, coat: true),
        paint("Olivgrün", "Olivgrün RAL 6003", [0.080, 0.087, 0.045], 0.75),
        paint("Gelboliv", "Gelboliv RAL 6014 (Bundeswehr bis 1984)", [0.063, 0.051, 0.027], 0.85),
        paint("Bronzegrün", "Bronzegrün RAL 6031 (Bundeswehr Flecktarn)", [0.048, 0.068, 0.042], 0.9),
        paint("Lederbraun", "Lederbraun RAL 8027 (Flecktarn)", [0.074, 0.042, 0.025], 0.9),
        paint("Teerschwarz", "Teerschwarz RAL 9021 (Flecktarn)", [0.012, 0.014, 0.015], 0.9),
        paint("Steingrau", "Steingrau RAL 7030", [0.266, 0.262, 0.216], 0.7),
        paint("Anthrazitgrau", "Anthrazitgrau RAL 7016", [0.040, 0.048, 0.054], 0.6),
        paint("Lichtgrau", "Lichtgrau RAL 7035", [0.558, 0.571, 0.552], 0.6),
        paint("Signalrot", "Signalrot RAL 3001", [0.328, 0.018, 0.017], 0.3, coat: true),
        paint("Feuerrot", "Feuerrot RAL 3000", [0.429, 0.024, 0.013], 0.3, coat: true),
        paint("Verkehrsgelb", "Verkehrsgelb RAL 1023", [0.871, 0.591, 0.004], 0.35),
        paint("Reinorange", "Reinorange RAL 2004", [0.761, 0.087, 0.004], 0.35),
    ]

    private static let nature: [SurfaceFinish] = [
        SurfaceFinish(id: "Eiche", name: "Holz hell (Eiche)", category: .nature, color: [0.56, 0.34, 0.15],
                      roughness: 0.7, pattern: .wood),
        SurfaceFinish(id: "Nussbaum", name: "Holz dunkel (Nussbaum)", category: .nature, color: [0.19, 0.085, 0.04],
                      roughness: 0.6, pattern: .wood),
        SurfaceFinish(id: "Buche", name: "Holz (Buche)", category: .nature, color: [0.70, 0.42, 0.22], roughness: 0.7,
                      pattern: .wood),
        SurfaceFinish(id: "Kiefer", name: "Holz (Kiefer)", category: .nature, color: [0.78, 0.55, 0.29], roughness: 0.7,
                      pattern: .wood),
        SurfaceFinish(id: "Holz lackiert", name: "Holz lackiert (Kirsche)", category: .nature,
                      color: [0.42, 0.14, 0.06], roughness: 0.5, clearcoat: true, pattern: .wood),
        SurfaceFinish(id: "Beton", name: "Beton", category: .nature, color: [0.32, 0.32, 0.30], roughness: 0.92,
                      pattern: .concrete),
        SurfaceFinish(id: "Sichtbeton hell", name: "Sichtbeton hell", category: .nature, color: [0.50, 0.50, 0.48],
                      roughness: 0.85, pattern: .concrete),
        SurfaceFinish(id: "Granit", name: "Stein poliert (Granit)", category: .nature, color: [0.20, 0.20, 0.21],
                      roughness: 0.2, clearcoat: true, pattern: .concrete),
    ]

    private static let plastics: [SurfaceFinish] = [
        paint("PLA weiß", "PLA weiß", [0.855, 0.855, 0.831], 0.45, category: .plastic),
        paint("PLA schwarz", "PLA schwarz", [0.014, 0.014, 0.016], 0.45, category: .plastic),
        paint("PLA grau", "PLA grau", [0.223, 0.235, 0.254], 0.45, category: .plastic),
        paint("PLA rot", "PLA rot", [0.578, 0.014, 0.019], 0.45, category: .plastic),
        paint("PLA blau", "PLA blau", [0.010, 0.091, 0.485], 0.45, category: .plastic),
        paint("PLA grün", "PLA grün", [0.021, 0.305, 0.061], 0.45, category: .plastic),
        paint("PLA gelb", "PLA gelb", [0.913, 0.578, 0.010], 0.45, category: .plastic),
        paint("PLA orange", "PLA orange", [0.871, 0.171, 0.010], 0.45, category: .plastic),
        metal("PLA Silk gold", "PLA Silk gold", [0.80, 0.56, 0.20], 0.42, category: .plastic),
        metal("PLA Silk silber", "PLA Silk silber", [0.70, 0.71, 0.73], 0.42, category: .plastic),
        SurfaceFinish(id: "PETG klar", name: "PETG transparent", category: .plastic, color: [0.82, 0.90, 0.92],
                      roughness: 0.15, transparent: true),
    ]

    private static let special: [SurfaceFinish] = [
        SurfaceFinish(id: "Glas", name: "Glas", category: .special, color: [0.80, 0.92, 0.95], roughness: 0.02,
                      transparent: true),
        SurfaceFinish(id: "Glas grau", name: "Rauchglas", category: .special, color: [0.30, 0.31, 0.32],
                      roughness: 0.02, transparent: true),
        SurfaceFinish(id: "Acryl klar", name: "Acrylglas klar", category: .special, color: [0.86, 0.92, 0.96],
                      roughness: 0.05, transparent: true),
        SurfaceFinish(id: "Carbon", name: "Carbon (Sichtcarbon)", category: .special, color: [0.035, 0.035, 0.04],
                      roughness: 0.35, clearcoat: true, pattern: .carbon),
        SurfaceFinish(id: "Gummi", name: "Gummi schwarz", category: .special, color: [0.021, 0.021, 0.021],
                      roughness: 0.92),
        SurfaceFinish(id: "Keramik weiß", name: "Keramik weiß glasiert", category: .special,
                      color: [0.88, 0.88, 0.86], roughness: 0.08, clearcoat: true),
    ]

    static let all: [SurfaceFinish] = metals + anodized + paints + nature + plastics + special
}

extension BodyMaterial {
    /// Passende Oberfläche beim Zuweisen des Werkstoffs (nil = Darstellung nach Glanzstufe des Werkstoffs)
    var defaultFinish: String? {
        switch id {
        case "Aluminium": "Aluminium"
        case "Stahl": "Stahl"
        case "Edelstahl": "Edelstahl gebürstet"
        case "Messing": "Messing"
        case "Kupfer": "Kupfer"
        case "Titan": "Titan"
        case "Buche": "Buche"
        case "Kiefer": "Kiefer"
        case "Glas": "Glas"
        case "Beton": "Beton"
        case "PMMA": "Acryl klar"
        default: nil
        }
    }
}

extension SceneBody {
    /// Zugewiesene fertige Oberfläche (nil = keine bzw. eigene Farbe)
    var surfaceFinish: SurfaceFinish? {
        finish.flatMap { SurfaceFinish.named($0) }
    }

    /// Darstellung: fertige Oberfläche, sonst eigene Farbe mit Glanz, sonst Glanzstufe des Werkstoffs.
    var appearance: SurfaceAppearance {
        if let id = finish {
            if let library = SurfaceFinish.named(id) { return library.appearance }
            if let custom = SurfaceFinish.custom(id) {
                return SurfaceFinish.customAppearance(color: color, gloss: custom.gloss, metallic: custom.metallic)
            }
        }
        switch bodyMaterial?.gloss ?? 0 {
        case 1: return SurfaceAppearance(albedo: color, roughness: 0.45)
        case 2: return SurfaceAppearance(albedo: color, roughness: 0.32, metallic: true)
        // Matt wie bisher (Glanzstufe 0 = Rauheit 1)
        default: return SurfaceAppearance(albedo: color, roughness: 1)
        }
    }

    /// Vertexfarbe für den Renderer mit Oberflächenkodierung (siehe SurfaceAppearance.encoded).
    var renderColor: SIMD3<Float> { appearance.encoded }

    /// Sichtbare Grundfarbe (für Export und Vorschau)
    var displayColor: SIMD3<Float> { appearance.albedo }

    /// Name der Oberfläche für Menüs und Eigenschaften
    var finishName: String? {
        guard let id = finish else { return nil }
        if let library = SurfaceFinish.named(id) { return library.name }
        if let custom = SurfaceFinish.custom(id) {
            return "Eigene Farbe, " + custom.gloss.name.lowercased() + (custom.metallic ? ", Metall" : "")
        }
        return nil
    }
}

extension ModelStore {
    /// Fertige Oberfläche zuweisen (nil = entfernen, Darstellung wieder nach Werkstoff). Die Körperfarbe folgt.
    func setFinish(_ id: String?, of indices: [Int]) {
        commitPreview()
        let chosen = indices.filter { bodies.indices.contains($0) }
        guard !chosen.isEmpty else { return }
        let finish = id.flatMap { SurfaceFinish.named($0) }
        var result = bodies
        for index in chosen {
            result[index].finish = finish?.id
            if let finish { result[index].color = finish.color }
        }
        commit(result, name: finish.map { "Oberfläche \($0.name)" } ?? "Oberfläche entfernen")
        selectBodies(chosen)
    }

    /// Eigene Farbe mit Glanzstufe; color nil = Farbe des Körpers behalten.
    func setCustomFinish(color: SIMD3<Float>?, gloss: SurfaceGloss, metallic: Bool, of indices: [Int]) {
        commitPreview()
        let chosen = indices.filter { bodies.indices.contains($0) }
        guard !chosen.isEmpty else { return }
        let id = SurfaceFinish.customID(gloss: gloss, metallic: metallic)
        var result = bodies
        for index in chosen {
            // Von einer fertigen Oberfläche aus deren Farbe übernehmen
            let base: SIMD3<Float> = result[index].displayColor
            result[index].color = color ?? base
            result[index].finish = id
        }
        commit(result, name: "Eigene Oberfläche")
        selectBodies(chosen)
    }
}
