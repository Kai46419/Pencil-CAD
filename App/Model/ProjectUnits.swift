import Foundation

// Projekteinheiten (Fusion 360 „Dokumenteinstellungen › Einheiten“): Intern bleibt alles in mm; nur Anzeige
// und Eingabe der Längen werden in die Einheit des Projekts umgerechnet (mm, cm oder Zoll).

enum LengthUnit: String, CaseIterable, Identifiable, Codable {
    case mm
    case cm
    case inch = "in"

    var id: Self { self }

    /// Einheit des geöffneten Projekts (beim Öffnen aus dem Projektordner gelesen).
    static var current: LengthUnit = .mm

    var title: String {
        switch self {
        case .mm: "Millimeter"
        case .cm: "Zentimeter"
        case .inch: "Zoll"
        }
    }

    /// Kürzel hinter Zahlen und in Formeln
    var symbol: String { rawValue }

    /// Länge einer Einheit in mm
    var millimeters: Double {
        switch self {
        case .mm: 1
        case .cm: 10
        case .inch: 25.4
        }
    }

    private var fractionDigits: ClosedRange<Int> {
        switch self {
        case .mm: 0...3
        case .cm, .inch: 0...4
        }
    }

    // MARK: Anzeige

    /// Zahl in dieser Einheit (ohne Kürzel), z. B. für Eingabefelder.
    func number(_ millimeters: Double) -> String {
        (millimeters / self.millimeters).formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never))
    }

    /// Länge mit Kürzel, z. B. „12,5 mm“ bzw. „0,4921 in“.
    func format(_ millimeters: Double) -> String {
        "\(number(millimeters)) \(symbol)"
    }

    /// Fläche (mm² → Einheit²).
    func formatArea(_ squareMillimeters: Double) -> String {
        let value = squareMillimeters / (self.millimeters * self.millimeters)
        return "\(value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never))) \(symbol)²"
    }

    /// Volumen (mm³ → Einheit³).
    func formatVolume(_ cubicMillimeters: Double) -> String {
        let value = cubicMillimeters / (self.millimeters * self.millimeters * self.millimeters)
        return "\(value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never))) \(symbol)³"
    }

    // MARK: Raster

    /// Wählbare Fangraster (mm), passend zur Einheit: metrisch in 1-5-10-Schritten, Zoll in Zweierbrüchen.
    var gridSteps: [Double] {
        // Feste Typen und einzelne Schritte, sonst braucht der Typprüfer zu lange
        switch self {
        case .mm:
            let steps: [Double] = [0.001, 0.01, 0.1, 0.5, 1, 5, 10]
            return steps
        case .cm:
            let steps: [Double] = [0.01, 0.1, 0.5, 1, 5, 10, 50]
            return steps
        case .inch:
            let fractions: [Double] = [64, 32, 16, 8, 4, 2]
            var inches: [Double] = [0.001, 0.01]
            inches += fractions.map { (denominator: Double) -> Double in 1 / denominator }
            inches.append(1)
            return inches.map { (inch: Double) -> Double in inch * 25.4 }
        }
    }

    /// Rasterweite als kurze Beschriftung: Zoll als Bruch („1/16 in“), sonst als Zahl.
    func gridLabel(_ step: Double) -> String {
        if self == .inch {
            let inches = step / 25.4
            for denominator in [2, 4, 8, 16, 32, 64] where abs(inches * Double(denominator) - 1) < 1e-6 {
                return "1/\(denominator) in"
            }
        }
        return format(step)
    }

    /// Zahl der Rasterweite ohne Einheit (zweizeilige Rasteranzeige).
    func gridNumber(_ step: Double) -> String {
        let label = gridLabel(step)
        return label.hasSuffix(" " + symbol) ? String(label.dropLast(symbol.count + 1)) : label
    }

    /// Nächstliegende wählbare Rasterweite (beim Wechsel der Einheit).
    func nearestGridStep(to step: Double) -> Double {
        gridSteps.min { abs(log($0 / max(step, 1e-9))) < abs(log($1 / max(step, 1e-9))) } ?? step
    }

    /// Angezeigte Rasterweiten ohne festes Fangraster (mm), aufsteigend.
    var displayGridSteps: [Float] {
        switch self {
        case .mm, .cm:
            let steps: [Float] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500,
                                  1000, 2000]
            return steps
        case .inch:
            let fractions: [Float] = [64, 32, 16, 8, 4, 2]
            var inches: [Float] = [0.001, 0.01]
            inches += fractions.map { (denominator: Float) -> Float in 1 / denominator }
            let whole: [Float] = [1, 2, 6, 12, 24, 60, 120, 240, 600, 1200]
            inches += whole
            return inches.map { (inch: Float) -> Float in inch * 25.4 }
        }
    }

    /// Jede wievielte Rasterlinie kräftiger ist.
    var majorGridEvery: Int { self == .inch ? 4 : 5 }

    // MARK: Speichern (je Projekt, Datei units.json im Projektordner)

    private struct Stored: Codable {
        var length: LengthUnit
    }

    static func stored(in folder: URL?) -> LengthUnit {
        guard let url = folder?.appending(path: "units.json"), let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .mm }
        return stored.length
    }

    func store(in folder: URL?) {
        guard let url = folder?.appending(path: "units.json"),
              let data = try? JSONEncoder().encode(Stored(length: self)) else { return }
        try? data.write(to: url)
    }
}

extension Formula {
    /// Länge aus einem Zahlenfeld: Zahlen ohne Einheit zählen in der Projekteinheit („2“ im Zollprojekt = 2 in),
    /// Einheiten im Ausdruck gelten wie angegeben („5 mm“). Variablen (in mm gespeichert) werden umgerechnet.
    /// Ergebnis in mm.
    static func evaluateLength(_ text: String, variables: [String: Double] = [:]) throws -> Double {
        let scale = LengthUnit.current.millimeters
        guard scale != 1 else { return try evaluate(text, variables: variables) }
        return try evaluate(text, variables: variables.mapValues { $0 / scale }, lengthScale: scale) * scale
    }
}
