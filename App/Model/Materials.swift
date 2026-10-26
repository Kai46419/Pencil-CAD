import SwiftUI
import simd

// Materialien für Körper (wie das „Physical Material“ in Fusion 360): Dichte für Masse und Gewicht beim Messen
// und in der Druckprüfung, Farbe und Glanz für die Darstellung. Gespeichert wird nur der Kurzname
// (SceneBody.material in bodies.json); ohne Material gilt beim Wiegen PLA wie bisher.

/// Werkstoff eines Körpers.
struct BodyMaterial: Identifiable, Hashable {
    /// Kurzname, so in bodies.json gespeichert
    let id: String
    let name: String
    /// Dichte in g/cm³
    let density: Double
    /// Darstellungsfarbe (wird beim Zuweisen übernommen, danach frei änderbar)
    let color: SIMD3<Float>
    /// Glanz im Viewport: 0 = matt, 1 = leicht glänzend (Kunststoff), 2 = metallisch
    let gloss: Int
    let category: Category

    enum Category: String, CaseIterable, Identifiable {
        case plastic = "Kunststoff (3D-Druck)"
        case metal = "Metall"
        case other = "Holz und Sonstiges"

        var id: Self { self }
    }

    /// Kunststoffe werden im 3D-Druck selten voll gefüllt: Hinweis zur Füllung beim Gewicht
    var isPrintable: Bool { category == .plastic }

    var symbol: String {
        switch category {
        case .plastic: "printer"
        case .metal: "hammer"
        case .other: "leaf"
        }
    }

    /// Dichte als Text, z. B. „2,70 g/cm³“
    var densityText: String {
        density.formatted(.number.precision(.fractionLength(2))) + " g/cm³"
    }

    static let all: [BodyMaterial] = [
        BodyMaterial(id: "PLA", name: "PLA", density: 1.24, color: [0.93, 0.93, 0.90], gloss: 1, category: .plastic),
        BodyMaterial(id: "PETG", name: "PETG", density: 1.27, color: [0.55, 0.74, 0.86], gloss: 1, category: .plastic),
        BodyMaterial(id: "ABS", name: "ABS", density: 1.04, color: [0.32, 0.33, 0.36], gloss: 0, category: .plastic),
        BodyMaterial(id: "ASA", name: "ASA", density: 1.07, color: [0.84, 0.84, 0.81], gloss: 0, category: .plastic),
        BodyMaterial(id: "TPU", name: "TPU (flexibel)", density: 1.21, color: [0.20, 0.22, 0.25], gloss: 0,
                     category: .plastic),
        BodyMaterial(id: "PA", name: "Nylon (PA12)", density: 1.01, color: [0.90, 0.88, 0.80], gloss: 0, category: .plastic),
        BodyMaterial(id: "PMMA", name: "Acryl (PMMA)", density: 1.19, color: [0.74, 0.87, 0.95], gloss: 1, category: .plastic),
        BodyMaterial(id: "Aluminium", name: "Aluminium", density: 2.70, color: [0.78, 0.80, 0.83], gloss: 2,
                     category: .metal),
        BodyMaterial(id: "Stahl", name: "Stahl", density: 7.85, color: [0.52, 0.54, 0.58], gloss: 2, category: .metal),
        BodyMaterial(id: "Edelstahl", name: "Edelstahl", density: 7.93, color: [0.70, 0.72, 0.74], gloss: 2,
                     category: .metal),
        BodyMaterial(id: "Messing", name: "Messing", density: 8.50, color: [0.82, 0.68, 0.33], gloss: 2, category: .metal),
        BodyMaterial(id: "Kupfer", name: "Kupfer", density: 8.96, color: [0.80, 0.48, 0.32], gloss: 2, category: .metal),
        BodyMaterial(id: "Titan", name: "Titan", density: 4.51, color: [0.60, 0.60, 0.63], gloss: 2, category: .metal),
        BodyMaterial(id: "Buche", name: "Holz (Buche)", density: 0.72, color: [0.80, 0.62, 0.43], gloss: 0, category: .other),
        BodyMaterial(id: "Kiefer", name: "Holz (Kiefer)", density: 0.52, color: [0.87, 0.73, 0.51], gloss: 0, category: .other),
        BodyMaterial(id: "Glas", name: "Glas", density: 2.50, color: [0.70, 0.84, 0.86], gloss: 1, category: .other),
        BodyMaterial(id: "Beton", name: "Beton", density: 2.40, color: [0.62, 0.62, 0.60], gloss: 0, category: .other),
    ]

    /// Ohne zugewiesenes Material: PLA (wie die frühere Gewichtsanzeige)
    static let standard = all[0]

    static func named(_ id: String) -> BodyMaterial? {
        all.first { $0.id == id }
    }
}

extension SceneBody {
    /// Zugewiesenes Material (nil = keins)
    var bodyMaterial: BodyMaterial? {
        material.flatMap { BodyMaterial.named($0) }
    }

    /// Farbe für den Renderer: Glanzstufe als +2 je Stufe kodiert (siehe shade in Shaders.metal).
    var renderColor: SIMD3<Float> {
        guard let gloss = bodyMaterial?.gloss, gloss > 0 else { return color }
        let clamped: SIMD3<Float> = simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        return clamped + SIMD3<Float>(repeating: 2 * Float(gloss))
    }
}

extension ModelStore {
    /// Material der Körper setzen (nil = entfernen). Die Darstellungsfarbe folgt dem Material.
    func setMaterial(_ id: String?, of indices: [Int]) {
        commitPreview()
        let chosen = indices.filter { bodies.indices.contains($0) }
        guard !chosen.isEmpty else { return }
        let material = id.flatMap { BodyMaterial.named($0) }
        var result = bodies
        for index in chosen {
            result[index].material = material?.id
            if let material { result[index].color = material.color }
        }
        commit(result, name: material.map { "Material \($0.name)" } ?? "Material entfernen")
        selectBodies(chosen)
        if let material {
            var grams = 0.0
            for index in chosen {
                let cubicCentimeters: Double = volume(ofBody: index) / 1000
                grams += cubicCentimeters * material.density
            }
            let weight: String
            if grams >= 1000 {
                weight = (grams / 1000).formatted(.number.precision(.fractionLength(0...3))) + " kg"
            } else {
                weight = grams.formatted(.number.precision(.fractionLength(0...1))) + " g"
            }
            message = "\(material.name) (\(material.densityText)): \(weight)"
        }
    }

    /// Material zum Wiegen: das zugewiesene, sonst PLA.
    func weighingMaterial(ofBody index: Int?) -> BodyMaterial {
        guard let index, bodies.indices.contains(index) else { return BodyMaterial.standard }
        return bodies[index].bodyMaterial ?? BodyMaterial.standard
    }
}

/// Kontextmenü eines Körpers im Ebenen-Browser: Material wählen.
struct MaterialMenuItems: View {
    @ObservedObject var model: ModelStore
    let index: Int
    /// Körper, die das Material bekommen (bei Mehrfachauswahl alle gewählten)
    let targets: [Int]

    var body: some View {
        if model.bodies.indices.contains(index) {
            let current: BodyMaterial? = model.bodies[index].bodyMaterial
            Menu {
                ForEach(BodyMaterial.Category.allCases) { category in
                    Section(category.rawValue) {
                        ForEach(BodyMaterial.all.filter { $0.category == category }) { material in
                            Button {
                                model.setMaterial(material.id, of: targets)
                            } label: {
                                Label(material.name + " · " + material.densityText,
                                      systemImage: current?.id == material.id ? "checkmark" : material.symbol)
                            }
                        }
                    }
                }
                if current != nil {
                    Divider()
                    Button("Kein Material", systemImage: "xmark") { model.setMaterial(nil, of: targets) }
                }
            } label: {
                Label(current.map { "Material: \($0.name)" } ?? "Material", systemImage: "cube.transparent")
            }
        }
    }
}
