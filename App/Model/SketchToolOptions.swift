import Foundation

/// Eingabestil im Skizzenmodus: SolidCraft (Klickfolge, Fang erzeugt Bedingungen) oder die bisherigen Shapr3D-Gesten
enum SketchInputStyle: String, CaseIterable, Identifiable {
    case solidcraft = "SolidCraft"
    case classic = "Klassisch"
    var id: Self { self }
}

/// Linientyp neuer Skizzenelemente (SolidCraft-Palette „Linientyp“)
enum SketchLineType: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case construction = "Konstruktion"
    case centerline = "Mittellinie"
    case infinite = "Unendlich"
    var id: Self { self }
}

enum OffsetDirectionMode: String, CaseIterable, Identifiable {
    case oneSide = "Eine Seite"
    case twoSides = "Zwei Seiten"
    case symmetric = "Symmetrisch"
    var id: Self { self }
}

enum ChamferType: String, CaseIterable, Identifiable {
    case equalDistance = "Gleicher Abstand"
    case twoDistances = "Zwei Abstände"
    case distanceAngle = "Abstand und Winkel"
    var id: Self { self }
}

/// Gemeinsamer Zustand der Werkzeug-Eigenschaften (rechtes Panel) und der Klickfolge-Werkzeuge.
/// Gehört dem SketchController (`sketch.options`).
final class SketchToolOptions: ObservableObject {
    /// Eingabestil, dauerhaft gespeichert
    @Published var inputStyle: SketchInputStyle {
        didSet { UserDefaults.standard.set(inputStyle.rawValue, forKey: "sketch.inputStyle") }
    }
    @Published var lineType: SketchLineType = .normal
    /// Gesperrte Werte beim Zeichnen (nil = folgt dem Stift), Ausdruckstext wie NumberField.
    /// Schlüssel: "Länge", "Winkel", "Breite", "Höhe", "Radius", "Durchmesser", "Bogenwinkel", "Seiten"
    @Published var locked: [String: String] = [:]
    @Published var roundedRadius: Double?
    @Published var offsetMode: OffsetDirectionMode = .oneSide
    @Published var offsetDistance2: Double = 2
    @Published var offsetFlip = false
    @Published var offsetChain = true
    @Published var chamferType: ChamferType = .equalDistance
    @Published var chamferDistance2: Double = 2
    @Published var chamferAngle: Double = 45
    @Published var chamferFlip = false
    @Published var moveDX: Double = 0
    @Published var moveDY: Double = 0
    @Published var moveAngle: Double = 0
    @Published var moveCopy = false
    /// Raster 1-2-5 automatisch nach Zoom (SolidCraft), sonst feste Rasterweite
    @Published var gridAuto = true
    /// Zuletzt gewählte Variante je Werkzeugfamilie
    @Published var familyChoice: [String: String] = [:]

    init() {
        let stored = UserDefaults.standard.string(forKey: "sketch.inputStyle")
        inputStyle = stored.flatMap(SketchInputStyle.init(rawValue:)) ?? .solidcraft
    }

    var isSolidCraft: Bool { inputStyle == .solidcraft }
}
