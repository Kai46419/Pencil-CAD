import Foundation
import simd

// MARK: - Gewinde: Normtabellen, Profile und Einstellungen (Werkzeug „Gewinde“ und Gewindebohrung)
//
// Modelliert wird das Grundprofil der jeweiligen Norm (Außen-Ø, Kern-Ø und Flankenwinkel), mit abgeflachten
// Spitzen und Gründen. Für den 3D-Druck kommt ein Druckspiel dazu: Außengewinde werden um Spiel/2 radial kleiner,
// Innengewinde um Spiel/2 größer. Kegelige Rohrgewinde (R, NPT) haben den Kegel 1:16 auf den Durchmesser.

/// Grundprofil einer Gewindeart, Maße bezogen auf die Steigung P.
struct ThreadForm: Equatable {
    /// Flankenwinkel gegen die Senkrechte zur Achse in Grad: Flanke zum Gewindeanfang bzw. zum Ende hin
    let flankStart: Double
    let flankEnd: Double
    /// Gewindetiefe (Außenradius minus Kernradius) / P
    let depth: Double
    /// Breite der Abflachung an der Spitze des Außengewindes / P
    let crest: Double
    /// Rundung an Spitze und Grund / P (Rundgewinde DIN 405), 0 = abgeflacht
    let round: Double
    /// Profilwinkel zur Anzeige, z. B. „60°“
    let angleText: String

    /// ISO-Grundprofil (DIN 13, ISO 68-1; ebenso UNC/UNF): H = 0,866 P, Tiefe 5H/8, Spitze P/8, Grund P/4
    static let iso = ThreadForm(flankStart: 30, flankEnd: 30, depth: 0.541266, crest: 0.125, round: 0,
                                angleText: "60°")
    /// Whitworth-Profil (BSW, G nach ISO 228, R nach ISO 7): H = 0,960 P, Tiefe 0,640 P, Abflachung H/6
    static let whitworth = ThreadForm(flankStart: 27.5, flankEnd: 27.5, depth: 0.640327, crest: 1.0 / 6.0, round: 0,
                                      angleText: "55°")
    /// NPT (ANSI B1.20.1): Tiefe 0,8 P, schmale Abflachung
    static let npt = ThreadForm(flankStart: 30, flankEnd: 30, depth: 0.8, crest: 0.0381, round: 0, angleText: "60°")
    /// Trapezgewinde DIN 103: Tiefe P/2, Spitze 0,366 P
    static let trapezoidal = ThreadForm(flankStart: 15, flankEnd: 15, depth: 0.5, crest: 0.366025, round: 0,
                                        angleText: "30°")
    /// Rundgewinde DIN 405: Tiefe P/2, Rundung 0,23851 P an Spitze und Grund
    static let rounded = ThreadForm(flankStart: 15, flankEnd: 15, depth: 0.5, crest: 0, round: 0.23851,
                                  angleText: "30° rund")
    /// Sägengewinde DIN 513: tragende Flanke 3° (zum Ende hin), Rückflanke 30°, Tiefe 0,75 P, Abflachung 0,264 P
    static let buttress = ThreadForm(flankStart: 30, flankEnd: 3, depth: 0.75, crest: 0.26384, round: 0,
                                     angleText: "3°/30°")
}

/// Eine Normgröße.
struct ThreadSize: Equatable {
    let name: String
    /// Außen-Ø (Nenn-Ø) in mm; bei kegeligen Gewinden in der Bezugsebene
    let diameter: Double
    /// Regel- bzw. Normsteigung in mm
    let pitch: Double
    /// Weitere gängige Steigungen (Feingewinde, Alternativen)
    var finePitches: [Double] = []
    /// Kegelige Gewinde: Abstand der Bezugsebene vom Anfang des Außengewindes in mm
    var gauge: Double = 0
}

/// Gewindearten.
enum ThreadFamily: String, CaseIterable, Identifiable {
    case metric = "Metrisch ISO"
    case unc = "Zoll UNC"
    case unf = "Zoll UNF"
    case whitworth = "Whitworth BSW"
    case pipe = "Rohrgewinde G"
    case pipeTaper = "Rohrgewinde R (kegelig)"
    case npt = "NPT (kegelig)"
    case trapezoidal = "Trapez Tr"
    case round = "Rundgewinde Rd"
    case buttress = "Sägengewinde S"

    var id: Self { self }

    var standard: String {
        switch self {
        case .metric: "DIN 13 / ISO 261"
        case .unc, .unf: "ASME B1.1"
        case .whitworth: "BS 84"
        case .pipe: "ISO 228-1"
        case .pipeTaper: "ISO 7-1"
        case .npt: "ANSI B1.20.1"
        case .trapezoidal: "DIN 103"
        case .round: "DIN 405"
        case .buttress: "DIN 513"
        }
    }

    var form: ThreadForm {
        switch self {
        case .metric, .unc, .unf: .iso
        case .whitworth, .pipe, .pipeTaper: .whitworth
        case .npt: .npt
        case .trapezoidal: .trapezoidal
        case .round: .rounded
        case .buttress: .buttress
        }
    }

    var sizes: [ThreadSize] {
        switch self {
        case .metric: ThreadTables.metric
        case .unc: ThreadTables.unc
        case .unf: ThreadTables.unf
        case .whitworth: ThreadTables.whitworth
        case .pipe: ThreadTables.pipe
        case .pipeTaper: ThreadTables.pipeTaper
        case .npt: ThreadTables.npt
        case .trapezoidal: ThreadTables.trapezoidal
        case .round: ThreadTables.round
        case .buttress: ThreadTables.buttress
        }
    }

    /// Kegelig 1:16 (auf den Durchmesser)
    var isTapered: Bool { self == .pipeTaper || self == .npt }

    /// Radiusänderung je mm Gewindelänge
    var taper: Double { isTapered ? 1.0 / 32.0 : 0 }

    /// Steigung wird in Gängen je Zoll angegeben
    var usesThreadsPerInch: Bool {
        switch self {
        case .metric, .trapezoidal, .buttress: false
        default: true
        }
    }

    /// Mehrgängige Bezeichnung „Tr 8×8 (P2)“ ist üblich
    var isMotionThread: Bool { self == .trapezoidal || self == .buttress || self == .round }

    /// Größe beim ersten Wählen der Art
    var defaultSizeIndex: Int {
        let list = sizes
        let wanted: String
        switch self {
        case .metric: wanted = "M6"
        case .unc, .unf, .whitworth: wanted = "1/4\""
        case .pipe: wanted = "G1/2"
        case .pipeTaper: wanted = "R1/2"
        case .npt: wanted = "1/2\" NPT"
        case .trapezoidal: wanted = "Tr 8"
        case .round: wanted = "Rd 20"
        case .buttress: wanted = "S 20"
        }
        return list.firstIndex { $0.name == wanted } ?? 0
    }

    /// Kern-Ø des Innengewindes nach Grundprofil (Kernloch ohne Spiel).
    func coreDiameter(_ size: ThreadSize, pitch: Double) -> Double {
        size.diameter - 2 * form.depth * pitch
    }

    /// Nächstliegende Normgröße zum Ø einer Fläche: Bolzen nach dem Außen-Ø, Bohrung nach dem Kern-Ø.
    func suggestedSize(forDiameter diameter: Double, external: Bool) -> Int {
        var best = 0
        var bestError = Double.infinity
        for (index, size) in sizes.enumerated() {
            let reference = external ? size.diameter : coreDiameter(size, pitch: size.pitch)
            let error = abs(reference - diameter)
            if error < bestError {
                best = index
                bestError = error
            }
        }
        return best
    }

    /// Bezeichnung, z. B. „M8×1“, „1/4"-20 UNC“, „Tr 8×8 (P2)“, „G1/2“; „LH“ für Linksgewinde.
    func designation(_ size: ThreadSize, pitch: Double, starts: Int, leftHanded: Bool) -> String {
        let p = pitch.formatted(.number.precision(.fractionLength(0...3)))
        var text: String
        switch self {
        case .metric:
            text = abs(pitch - size.pitch) < 1e-6 ? size.name : "\(size.name)×\(p)"
        case .unc, .unf:
            let tpi = (25.4 / pitch).formatted(.number.precision(.fractionLength(0...1)))
            text = "\(size.name)-\(tpi) \(self == .unc ? "UNC" : "UNF")"
        case .trapezoidal, .buttress, .round:
            let lead = (pitch * Double(starts)).formatted(.number.precision(.fractionLength(0...3)))
            text = starts > 1 ? "\(size.name)×\(lead) (P\(p))" : "\(size.name)×\(p)"
        case .whitworth, .pipe, .pipeTaper, .npt:
            text = size.name
            if abs(pitch - size.pitch) > 1e-6 { text += " P\(p)" }
        }
        if starts > 1, !isMotionThread { text += " \(starts)-gängig" }
        if leftHanded { text += " LH" }
        return text
    }
}

/// Normtabellen (Maße in mm).
enum ThreadTables {
    private static func m(_ name: String, _ d: Double, _ p: Double, _ fine: [Double] = []) -> ThreadSize {
        ThreadSize(name: name, diameter: d, pitch: p, finePitches: fine)
    }

    /// Zollgewinde: Außen-Ø in Zoll, Gänge je Zoll (Alternativen ebenso in Gängen je Zoll)
    private static func inch(_ name: String, _ d: Double, tpi: Double, fine: [Double] = []) -> ThreadSize {
        let pitches: [Double] = fine.map { 25.4 / $0 }
        return ThreadSize(name: name, diameter: d * 25.4, pitch: 25.4 / tpi, finePitches: pitches)
    }

    /// NPT: Flankendurchmesser E0 am kleinen Ende, Einschraublänge von Hand L1 (Zoll); Bezugsebene bei L1
    private static func nptSize(_ name: String, e0: Double, l1: Double, tpi: Double) -> ThreadSize {
        let p = 1.0 / tpi
        let e1 = e0 + l1 / 16
        let major = (e1 + 0.8 * p) * 25.4
        return ThreadSize(name: name, diameter: major, pitch: 25.4 / tpi, gauge: l1 * 25.4)
    }

    /// Rohrgewinde nach ISO 228-1 / ISO 7-1: Außen-Ø in mm, Gänge je Zoll, Bezugsmaß (nur kegelig)
    private static func pipeSize(_ name: String, _ d: Double, tpi: Double, gauge: Double = 0) -> ThreadSize {
        ThreadSize(name: name, diameter: d, pitch: 25.4 / tpi, gauge: gauge)
    }

    /// Metrisches ISO-Gewinde DIN 13-1 (Regelgewinde) mit Feingewinden nach ISO 261
    static let metric: [ThreadSize] = [
        m("M1", 1, 0.25, [0.2]),
        m("M1,2", 1.2, 0.25, [0.2]),
        m("M1,4", 1.4, 0.3, [0.2]),
        m("M1,6", 1.6, 0.35, [0.2]),
        m("M1,8", 1.8, 0.35, [0.2]),
        m("M2", 2, 0.4, [0.25]),
        m("M2,5", 2.5, 0.45, [0.35]),
        m("M3", 3, 0.5, [0.35]),
        m("M3,5", 3.5, 0.6, [0.35]),
        m("M4", 4, 0.7, [0.5]),
        m("M5", 5, 0.8, [0.5]),
        m("M6", 6, 1, [0.75, 0.5]),
        m("M7", 7, 1, [0.75, 0.5]),
        m("M8", 8, 1.25, [1, 0.75, 0.5]),
        m("M10", 10, 1.5, [1.25, 1, 0.75, 0.5]),
        m("M12", 12, 1.75, [1.5, 1.25, 1]),
        m("M14", 14, 2, [1.5, 1.25, 1]),
        m("M16", 16, 2, [1.5, 1]),
        m("M18", 18, 2.5, [2, 1.5, 1]),
        m("M20", 20, 2.5, [2, 1.5, 1]),
        m("M22", 22, 2.5, [2, 1.5, 1]),
        m("M24", 24, 3, [2, 1.5, 1]),
        m("M27", 27, 3, [2, 1.5, 1]),
        m("M30", 30, 3.5, [3, 2, 1.5, 1]),
        m("M33", 33, 3.5, [3, 2, 1.5]),
        m("M36", 36, 4, [3, 2, 1.5]),
        m("M39", 39, 4, [3, 2, 1.5]),
        m("M42", 42, 4.5, [4, 3, 2, 1.5]),
        m("M45", 45, 4.5, [4, 3, 2, 1.5]),
        m("M48", 48, 5, [4, 3, 2, 1.5]),
        m("M52", 52, 5, [4, 3, 2, 1.5]),
        m("M56", 56, 5.5, [4, 3, 2, 1.5]),
        m("M60", 60, 5.5, [4, 3, 2, 1.5]),
        m("M64", 64, 6, [4, 3, 2, 1.5]),
    ]

    /// Unified Coarse (ASME B1.1), Nr. 4 bis 1"
    static let unc: [ThreadSize] = [
        inch("Nr. 4", 0.112, tpi: 40),
        inch("Nr. 5", 0.125, tpi: 40),
        inch("Nr. 6", 0.138, tpi: 32),
        inch("Nr. 8", 0.164, tpi: 32),
        inch("Nr. 10", 0.190, tpi: 24),
        inch("Nr. 12", 0.216, tpi: 24),
        inch("1/4\"", 0.25, tpi: 20),
        inch("5/16\"", 0.3125, tpi: 18),
        inch("3/8\"", 0.375, tpi: 16),
        inch("7/16\"", 0.4375, tpi: 14),
        inch("1/2\"", 0.5, tpi: 13),
        inch("9/16\"", 0.5625, tpi: 12),
        inch("5/8\"", 0.625, tpi: 11),
        inch("3/4\"", 0.75, tpi: 10),
        inch("7/8\"", 0.875, tpi: 9),
        inch("1\"", 1, tpi: 8),
    ]

    /// Unified Fine (ASME B1.1), Nr. 4 bis 1"
    static let unf: [ThreadSize] = [
        inch("Nr. 4", 0.112, tpi: 48),
        inch("Nr. 5", 0.125, tpi: 44),
        inch("Nr. 6", 0.138, tpi: 40),
        inch("Nr. 8", 0.164, tpi: 36),
        inch("Nr. 10", 0.190, tpi: 32),
        inch("Nr. 12", 0.216, tpi: 28),
        inch("1/4\"", 0.25, tpi: 28),
        inch("5/16\"", 0.3125, tpi: 24),
        inch("3/8\"", 0.375, tpi: 24),
        inch("7/16\"", 0.4375, tpi: 20),
        inch("1/2\"", 0.5, tpi: 20),
        inch("9/16\"", 0.5625, tpi: 18),
        inch("5/8\"", 0.625, tpi: 18),
        inch("3/4\"", 0.75, tpi: 16),
        inch("7/8\"", 0.875, tpi: 14),
        inch("1\"", 1, tpi: 12),
    ]

    /// Whitworth BSW (BS 84), Alternative jeweils BSF
    static let whitworth: [ThreadSize] = [
        inch("1/8\"", 0.125, tpi: 40),
        inch("3/16\"", 0.1875, tpi: 24, fine: [32]),
        inch("1/4\"", 0.25, tpi: 20, fine: [26]),
        inch("5/16\"", 0.3125, tpi: 18, fine: [22]),
        inch("3/8\"", 0.375, tpi: 16, fine: [20]),
        inch("7/16\"", 0.4375, tpi: 14, fine: [18]),
        inch("1/2\"", 0.5, tpi: 12, fine: [16]),
        inch("9/16\"", 0.5625, tpi: 12, fine: [16]),
        inch("5/8\"", 0.625, tpi: 11, fine: [14]),
        inch("3/4\"", 0.75, tpi: 10, fine: [12]),
        inch("7/8\"", 0.875, tpi: 9, fine: [11]),
        inch("1\"", 1, tpi: 8, fine: [10]),
        inch("1 1/8\"", 1.125, tpi: 7, fine: [9]),
        inch("1 1/4\"", 1.25, tpi: 7, fine: [9]),
        inch("1 1/2\"", 1.5, tpi: 6, fine: [8]),
        inch("1 3/4\"", 1.75, tpi: 5, fine: [7]),
        inch("2\"", 2, tpi: 4.5, fine: [7]),
    ]

    /// Zylindrisches Rohrgewinde G (ISO 228-1, 55°)
    static let pipe: [ThreadSize] = [
        pipeSize("G1/16", 7.723, tpi: 28),
        pipeSize("G1/8", 9.728, tpi: 28),
        pipeSize("G1/4", 13.157, tpi: 19),
        pipeSize("G3/8", 16.662, tpi: 19),
        pipeSize("G1/2", 20.955, tpi: 14),
        pipeSize("G5/8", 22.911, tpi: 14),
        pipeSize("G3/4", 26.441, tpi: 14),
        pipeSize("G7/8", 30.201, tpi: 14),
        pipeSize("G1", 33.249, tpi: 11),
        pipeSize("G1 1/8", 37.897, tpi: 11),
        pipeSize("G1 1/4", 41.910, tpi: 11),
        pipeSize("G1 1/2", 47.803, tpi: 11),
        pipeSize("G1 3/4", 53.746, tpi: 11),
        pipeSize("G2", 59.614, tpi: 11),
        pipeSize("G2 1/4", 65.710, tpi: 11),
        pipeSize("G2 1/2", 75.184, tpi: 11),
        pipeSize("G2 3/4", 81.534, tpi: 11),
        pipeSize("G3", 87.884, tpi: 11),
        pipeSize("G3 1/2", 100.330, tpi: 11),
        pipeSize("G4", 113.030, tpi: 11),
    ]

    /// Kegeliges Rohrgewinde R (ISO 7-1, Kegel 1:16): Außen-Ø in der Bezugsebene, Bezugsmaß vom Gewindeanfang
    static let pipeTaper: [ThreadSize] = [
        pipeSize("R1/16", 7.723, tpi: 28, gauge: 4.0),
        pipeSize("R1/8", 9.728, tpi: 28, gauge: 4.0),
        pipeSize("R1/4", 13.157, tpi: 19, gauge: 6.0),
        pipeSize("R3/8", 16.662, tpi: 19, gauge: 6.4),
        pipeSize("R1/2", 20.955, tpi: 14, gauge: 8.2),
        pipeSize("R3/4", 26.441, tpi: 14, gauge: 9.5),
        pipeSize("R1", 33.249, tpi: 11, gauge: 10.4),
        pipeSize("R1 1/4", 41.910, tpi: 11, gauge: 12.7),
        pipeSize("R1 1/2", 47.803, tpi: 11, gauge: 12.7),
        pipeSize("R2", 59.614, tpi: 11, gauge: 15.9),
        pipeSize("R2 1/2", 75.184, tpi: 11, gauge: 17.5),
        pipeSize("R3", 87.884, tpi: 11, gauge: 20.6),
        pipeSize("R4", 113.030, tpi: 11, gauge: 25.4),
    ]

    /// NPT (ANSI B1.20.1, Kegel 1:16, 60°)
    static let npt: [ThreadSize] = [
        nptSize("1/16\" NPT", e0: 0.27118, l1: 0.160, tpi: 27),
        nptSize("1/8\" NPT", e0: 0.36351, l1: 0.1615, tpi: 27),
        nptSize("1/4\" NPT", e0: 0.47739, l1: 0.2278, tpi: 18),
        nptSize("3/8\" NPT", e0: 0.61201, l1: 0.240, tpi: 18),
        nptSize("1/2\" NPT", e0: 0.75843, l1: 0.320, tpi: 14),
        nptSize("3/4\" NPT", e0: 0.96768, l1: 0.339, tpi: 14),
        nptSize("1\" NPT", e0: 1.21363, l1: 0.400, tpi: 11.5),
        nptSize("1 1/4\" NPT", e0: 1.55713, l1: 0.420, tpi: 11.5),
        nptSize("1 1/2\" NPT", e0: 1.79609, l1: 0.420, tpi: 11.5),
        nptSize("2\" NPT", e0: 2.26902, l1: 0.436, tpi: 11.5),
    ]

    /// Trapezgewinde DIN 103 (Vorzugsreihe), Alternativen fein/grob; mehrgängig z. B. Tr 8×8 (P2, 4 Gänge)
    static let trapezoidal: [ThreadSize] = [
        m("Tr 8", 8, 1.5, [2]),
        m("Tr 10", 10, 2, [1.5, 3]),
        m("Tr 12", 12, 3, [2]),
        m("Tr 14", 14, 3, [2]),
        m("Tr 16", 16, 4, [2]),
        m("Tr 18", 18, 4, [2]),
        m("Tr 20", 20, 4, [2]),
        m("Tr 22", 22, 5, [3, 8]),
        m("Tr 24", 24, 5, [3, 8]),
        m("Tr 26", 26, 5, [3, 8]),
        m("Tr 28", 28, 5, [3, 8]),
        m("Tr 30", 30, 6, [3, 10]),
        m("Tr 32", 32, 6, [3, 10]),
        m("Tr 36", 36, 6, [3, 10]),
        m("Tr 40", 40, 7, [3, 10]),
        m("Tr 44", 44, 7, [3, 12]),
        m("Tr 48", 48, 8, [3, 12]),
        m("Tr 50", 50, 8, [3, 12]),
        m("Tr 52", 52, 8, [3, 12]),
        m("Tr 60", 60, 9, [3, 14]),
        m("Tr 70", 70, 10, [4, 16]),
        m("Tr 80", 80, 10, [4, 16]),
    ]

    /// Rundgewinde DIN 405: Ø 8–12 mit 10 Gängen je Zoll, 14–38 mit 8, 40–100 mit 6
    static let round: [ThreadSize] = {
        var list: [ThreadSize] = []
        let small: [Double] = [8, 9, 10, 11, 12]
        let middle: [Double] = [14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38]
        let large: [Double] = [40, 42, 44, 46, 48, 50, 52, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100]
        for d in small { list.append(ThreadTables.m("Rd \(Int(d))", d, 25.4 / 10)) }
        for d in middle { list.append(ThreadTables.m("Rd \(Int(d))", d, 25.4 / 8)) }
        for d in large { list.append(ThreadTables.m("Rd \(Int(d))", d, 25.4 / 6)) }
        return list
    }()

    /// Sägengewinde DIN 513 (Vorzugsreihe)
    static let buttress: [ThreadSize] = [
        m("S 10", 10, 2, [3]),
        m("S 12", 12, 3, [2]),
        m("S 14", 14, 3, [2]),
        m("S 16", 16, 4, [2]),
        m("S 18", 18, 4, [2]),
        m("S 20", 20, 4, [2]),
        m("S 22", 22, 5, [3, 8]),
        m("S 24", 24, 5, [3, 8]),
        m("S 26", 26, 5, [3, 8]),
        m("S 28", 28, 5, [3, 8]),
        m("S 30", 30, 6, [3, 10]),
        m("S 32", 32, 6, [3, 10]),
        m("S 36", 36, 6, [3, 10]),
        m("S 40", 40, 7, [3, 10]),
        m("S 44", 44, 7, [3, 12]),
        m("S 48", 48, 8, [3, 12]),
        m("S 52", 52, 8, [3, 12]),
        m("S 60", 60, 9, [3, 14]),
        m("S 70", 70, 10, [4, 16]),
        m("S 80", 80, 10, [4, 16]),
        m("S 90", 90, 12, [4, 18]),
        m("S 100", 100, 12, [4, 20]),
    ]
}

// MARK: - Profil im Achsschnitt

enum ThreadProfile {
    /// Eine Periode der Kontur des Außengewindes im Achsschnitt als (r, z) mit steigendem z, von Grundmitte zu
    /// Grundmitte; die Spitze des Gangs liegt bei z = 0.
    static func contour(_ form: ThreadForm, pitch p: Double, major: Double) -> [SIMD2<Double>] {
        let h = form.depth * p
        let minor = major - h
        if form.round > 0 {
            return roundContour(form, pitch: p, major: major, minor: minor)
        }
        let c = form.crest * p
        let tanStart = tan(form.flankStart * .pi / 180)
        let tanEnd = tan(form.flankEnd * .pi / 180)
        let zLow = -c / 2 - h * tanStart
        let zHigh = c / 2 + h * tanEnd
        let gapCenter = (zHigh + zLow + p) / 2
        return [
            SIMD2<Double>(minor, gapCenter - p),
            SIMD2<Double>(minor, zLow),
            SIMD2<Double>(major, -c / 2),
            SIMD2<Double>(major, c / 2),
            SIMD2<Double>(minor, zHigh),
            SIMD2<Double>(minor, gapCenter),
        ]
    }

    /// Rundgewinde: Bögen an Spitze und Grund, tangential an die geraden Flanken (je Bogen als Polygon).
    private static func roundContour(_ form: ThreadForm, pitch p: Double, major: Double,
                                     minor: Double) -> [SIMD2<Double>] {
        let alpha = form.flankStart * .pi / 180
        let radius = form.round * p
        let crestCenter = major - radius
        let rootCenter = minor + radius
        let sweep = Double.pi / 2 - alpha
        let steps = 5
        var points: [SIMD2<Double>] = []
        // Grund links: von der Grundmitte bis zum Übergang in die Flanke
        for k in 0...steps {
            let psi = sweep * Double(k) / Double(steps)
            let r = rootCenter - radius * cos(psi)
            let z = -p / 2 + radius * sin(psi)
            points.append(SIMD2<Double>(r, z))
        }
        // Spitze
        for k in 0...(2 * steps) {
            let phi = -sweep + sweep * Double(k) / Double(steps)
            let r = crestCenter + radius * cos(phi)
            let z = radius * sin(phi)
            points.append(SIMD2<Double>(r, z))
        }
        // Grund rechts bis zur Grundmitte
        for k in 0...steps {
            let psi = sweep * Double(steps - k) / Double(steps)
            let r = rootCenter - radius * cos(psi)
            let z = p / 2 - radius * sin(psi)
            points.append(SIMD2<Double>(r, z))
        }
        return points
    }

    /// Teil eines Linienzugs oberhalb (keepAbove) bzw. unterhalb einer Radiusgrenze, mit den Schnittpunkten.
    static func clip(_ points: [SIMD2<Double>], level: Double, keepAbove: Bool) -> [SIMD2<Double>] {
        var result: [SIMD2<Double>] = []
        for i in points.indices {
            let a = points[i]
            let inside = keepAbove ? a.x >= level : a.x <= level
            if inside { result.append(a) }
            guard i + 1 < points.count else { continue }
            let b = points[i + 1]
            let da = a.x - level
            let db = b.x - level
            if da * db < 0 {
                let s = da / (da - db)
                result.append(a + (b - a) * s)
            }
        }
        return result
    }

    /// Polygon (Paare r, z, um z = 0 zentriert) für PCKShape.thread. Außengewinde: die Nut zwischen zwei Gängen,
    /// nach außen über den Außen-Ø verlängert (wird abgezogen). Innengewinde: der Gang des Gegenstücks über dem Kern,
    /// nach innen in den Kern verlängert (wird zusammen mit dem Kernzylinder abgezogen). Asymmetrische Profile
    /// (Sägengewinde) werden innen gespiegelt, damit Bolzen und Mutter zusammenpassen. major = Außenradius am Anfang.
    static func kernelProfile(_ form: ThreadForm, pitch p: Double, major: Double, external: Bool) -> [Double]? {
        let h = form.depth * p
        let minor = major - h
        guard p > 0, h > 0, minor > 0 else { return nil }
        // Kleine Stufe an Spitze bzw. Grund, damit keine Fläche genau auf dem Zylinder des Körpers liegt
        let margin = 0.02 * h
        let base = contour(form, pitch: p, major: major)
        let outline: [SIMD2<Double>]
        let cap: Double
        if external {
            // Von der Spitze über den Grund bis zur Spitze des nächsten Gangs
            let second: [SIMD2<Double>] = base.filter { $0.y >= 0 }
            let first: [SIMD2<Double>] = base.filter { $0.y < 0 }.map { SIMD2<Double>($0.x, $0.y + p) }
            outline = clip(second + first, level: major - margin, keepAbove: false)
            cap = major + 0.25 * h + 0.05
        } else {
            let mirrored: [SIMD2<Double>] = base.reversed().map { SIMD2<Double>($0.x, -$0.y) }
            outline = clip(mirrored, level: minor + margin, keepAbove: true)
            cap = max(minor - 0.25 * h, 0.5 * minor)
        }
        // Doppelte Punkte entfernen
        var cleaned: [SIMD2<Double>] = []
        for point in outline {
            if let last = cleaned.last, simd_distance(last, point) < 1e-7 { continue }
            cleaned.append(point)
        }
        guard cleaned.count >= 2, let first = cleaned.first, let last = cleaned.last, last.y - first.y > 1e-4,
              last.y - first.y < p else { return nil }
        let polygon: [SIMD2<Double>] = [SIMD2<Double>(cap, first.y)] + cleaned + [SIMD2<Double>(cap, last.y)]
        let center = (first.y + last.y) / 2
        var result: [Double] = []
        result.reserveCapacity(polygon.count * 2)
        for point in polygon {
            result.append(point.x)
            result.append(point.y - center)
        }
        return result
    }
}

// MARK: - Einstellungen

/// Angetippte Zylinderfläche für das Gewinde-Werkzeug.
struct ThreadTarget: Equatable {
    var body: Int
    /// Achspunkt am unteren Ende der Fläche und Achsrichtung (zum oberen Ende)
    var origin: SIMD3<Double>
    var axis: SIMD3<Double>
    var radius: Double
    var length: Double
    /// Bolzen (Außengewinde) bzw. Bohrung (Innengewinde)
    var external: Bool
    /// Ende frei (kein Material dahinter): dort läuft das Gewinde aus und bekommt den Anschnitt
    var lowOpen: Bool
    var highOpen: Bool
}

/// Einstellungen des Werkzeugs „Gewinde“.
struct ThreadSpec: Equatable {
    var family: ThreadFamily = .metric
    var sizeIndex = ThreadFamily.metric.defaultSizeIndex
    var pitch: Double = 1
    /// Ganze Länge der Fläche; sonst length ab offset
    var fullLength = true
    var length: Double = 10
    /// Abstand vom Gewindeanfang (freies Ende des Bolzens bzw. Eingang der Bohrung)
    var offset: Double = 0
    var leftHanded = false
    /// Gangzahl 1–4 (Steigung je Umdrehung = Gangzahl × P)
    var starts = 1
    /// Druckspiel in mm: Außengewinde radial um die Hälfte kleiner, Innengewinde um die Hälfte größer
    var clearance: Double = 0.2
    /// Fase bzw. Senkung am freien Ende, damit Schraube und Mutter gut ansetzen
    var chamfer = true
    /// Anfang am anderen Ende der Fläche
    var fromOtherEnd = false
    /// Innengewinde im Sackloch: Gewinde endet um den Auslauf e1 nach DIN 76 vor dem Grund
    var runoutDIN76 = false
    var target: ThreadTarget?

    var size: ThreadSize {
        let list = family.sizes
        return list[max(0, min(list.count - 1, sizeIndex))]
    }

    var lead: Double { pitch * Double(starts) }

    /// Steigungen zur Auswahl (Norm zuerst)
    var pitchChoices: [Double] { [size.pitch] + size.finePitches }

    var designation: String {
        family.designation(size, pitch: pitch, starts: starts, leftHanded: leftHanded)
    }

    /// Gewinde beginnt am oberen Ende der Fläche (sonst am unteren): am freien Ende, wenn nur eines frei ist.
    func startsAtHigh(_ target: ThreadTarget) -> Bool {
        let natural = target.highOpen && !target.lowOpen
        return natural != fromOtherEnd
    }
}

/// Radien entlang des Gewindes (z = Abstand vom Gewindeanfang), mit Druckspiel und Kegel.
struct ThreadGeometry {
    let depth: Double
    /// Außenradius ohne Kegel (Nenn-Ø/2 ± Spiel/2)
    let nominalRadius: Double
    /// Radiusänderung je mm in Richtung vom Anfang ins Gewinde: außen wächst der Kegel, innen wird er enger
    let taper: Double
    /// Lage der Bezugsebene (kegelig außen); innen liegt sie am Anfang (Fläche des Innengewindes)
    let gauge: Double

    init(family: ThreadFamily, size: ThreadSize, pitch: Double, clearance: Double, external: Bool) {
        depth = family.form.depth * pitch
        let shift = external ? -clearance / 2 : clearance / 2
        nominalRadius = size.diameter / 2 + shift
        taper = external ? family.taper : -family.taper
        gauge = external ? size.gauge : 0
    }

    func major(at z: Double) -> Double { nominalRadius + taper * (z - gauge) }
    func minor(at z: Double) -> Double { major(at: z) - depth }
}

/// Gewinde einer Bohrung (Bohrungswerkzeug, Option „Gewinde“).
struct HoleThread: Equatable {
    var family: ThreadFamily = .metric
    var sizeIndex = ThreadTables.metric.firstIndex { $0.name == "M3" } ?? 0
    var pitch: Double = 0.5
    var leftHanded = false
    /// Sackloch: Ende des Gewindes – bis zum Grund, Auslauf nach DIN 76 oder eigenes Maß (runoutLength)
    var runout: ThreadRunout = .bottom
    /// Gewindelänge ab der Fläche bei runout = .custom (mm)
    var runoutLength: Double = 8

    var size: ThreadSize {
        let list = family.sizes
        return list[max(0, min(list.count - 1, sizeIndex))]
    }

    var pitchChoices: [Double] { [size.pitch] + size.finePitches }

    /// Kern-Ø nach Norm (Kernloch ohne Druckspiel)
    var coreDiameter: Double { family.coreDiameter(size, pitch: pitch) }

    var designation: String { family.designation(size, pitch: pitch, starts: 1, leftHanded: leftHanded) }

    func summary(clearance: Double, through: Bool, depth: Double) -> String {
        let core = (coreDiameter + clearance).formatted(.number.precision(.fractionLength(0...2)))
        let depthText = through ? "durch" : "\(depth.formatted()) mm tief"
        var text = "Gewinde \(designation), Kernloch Ø \(core) mm, \(depthText)"
        if !through, runout != .bottom {
            let usable: Double = threadLength(depth: depth, through: false)
            let usableText = usable.formatted(.number.precision(.fractionLength(0...2)))
            let note = runout == .din76 ? " (Auslauf DIN 76)" : ""
            text += ", Gewinde \(usableText) mm\(note)"
        }
        return text
    }

    /// Gewindelänge ab der Fläche in einer Bohrung der Tiefe depth (ohne Bohrspitze): durchgehend bzw. „bis Grund“
    /// die ganze Tiefe, mit DIN 76 Bohrtiefe − e1, sonst das eigene Maß; mindestens zwei Steigungen, höchstens depth.
    func threadLength(depth: Double, through: Bool) -> Double {
        guard !through, depth > 0 else { return depth }
        let wanted: Double
        switch runout {
        case .bottom: wanted = depth
        case .din76: wanted = depth - ThreadRunout.din76Length(pitch: pitch)
        case .custom: wanted = runoutLength
        }
        let shortest: Double = min(depth, 2 * pitch)
        return min(depth, max(shortest, wanted))
    }
}

extension HoleSpec {
    /// Werkzeug einer Gewindebohrung als Verbund (wird mit cutting(_:fuzzy:) in einem Schritt abgezogen):
    /// Gänge des Innengewindes (Gang des Gegenstücks über dem Kern), Kernloch über die ganze Tiefe, ggf. Bohrspitze
    /// und 90°-Anschnitt an der Fläche. Im Sackloch endet das Gewinde je nach thread.runout vor dem Grund (DIN 76).
    /// top liegt lift über der Fläche, axis zeigt in den Körper, length = Tiefe + lift. Das Druckspiel ist die Zugabe.
    func threadedTool(_ thread: HoleThread, top: SIMD3<Double>, axis: SIMD3<Double>, length: Double,
                      lift: Double) -> PCKShape? {
        let family = thread.family
        let form = family.form
        let p = thread.pitch
        guard p >= 0.1, length > 0 else { return nil }
        let geometry = ThreadGeometry(family: family, size: thread.size, pitch: p, clearance: clearance, external: false)
        let major = geometry.major(at: 0)
        let minor = geometry.minor(at: 0)
        // Gewindelänge ab top (mit lift); durchgehend die ganze Länge
        let boreDepth: Double = max(0, length - lift)
        let threadLength: Double = thread.threadLength(depth: boreDepth, through: through) + lift
        let bottomMinor = geometry.minor(at: threadLength)
        guard minor > 0.2, bottomMinor > 0.2,
              let profile = ThreadProfile.kernelProfile(form, pitch: p, major: major, external: false) else { return nil }
        let numbers: [NSNumber] = profile.map { NSNumber(value: $0) }
        guard let ridges = PCKShape.thread(base: top, axis: axis, length: threadLength, lead: p, starts: 1,
                                           taper: geometry.taper, leftHanded: thread.leftHanded, profileRZ: numbers,
                                           coreRadius: 0) else { return nil }
        var parts: [PCKShape] = [ridges]
        // Kernloch über die ganze Tiefe (immer zylindrisch, auch bei kegeligen Gewinden)
        let coreRadius: Double = minor
        guard let core = PCKShape.cylinder(base: top, axis: axis, radius: coreRadius, height: length) else { return nil }
        parts.append(core)
        if drillPoint, !through {
            let tipHeight = coreRadius / tan(59 * .pi / 180)
            if let tip = PCKShape.cone(base: top + axis * length, axis: axis, bottomRadius: coreRadius, topRadius: 0,
                                       height: tipHeight) {
                parts.append(tip)
            }
        }
        // Anschnitt: 90°-Senkung vom Außen-Ø auf den Kern-Ø an der Fläche
        let surface = top + axis * lift
        let e = min(0.1, 0.2 * coreRadius)
        let sinkHeight = (major - coreRadius) + 2 * e + 1
        if let sink = PCKShape.cone(base: surface - axis, axis: axis, bottomRadius: major + e + 1,
                                    topRadius: coreRadius - e, height: sinkHeight) {
            parts.append(sink)
        }
        return PCKShape.compound(parts)
    }
}

// MARK: - Gewindeauslauf im Sackloch (DIN 76-1)

/// Ende eines Innengewindes im Sackloch.
enum ThreadRunout: String, CaseIterable, Identifiable {
    /// Gewinde bis zum Grund der Bohrung (für den 3D-Druck)
    case bottom = "bis Grund"
    /// Gewindeauslauf e1 nach DIN 76-1 (Regelfall) vor dem Grund, wie beim Gewindebohren
    case din76 = "DIN 76"
    /// Eigene Gewindelänge
    case custom = "Maß"

    var id: Self { self }

    /// DIN 76-1, Gewindeauslauf für Innengewinde e1 (Regelfall) je Steigung P, in mm
    static let din76Table: [(pitch: Double, e1: Double)] = [
        (0.2, 1.3), (0.25, 1.5), (0.3, 1.8), (0.35, 2.1), (0.4, 2.3), (0.45, 2.6), (0.5, 2.8), (0.6, 3.4),
        (0.7, 3.8), (0.75, 4.0), (0.8, 4.2), (1.0, 5.1), (1.25, 6.2), (1.5, 7.3), (1.75, 8.3), (2.0, 9.3),
        (2.5, 11.2), (3.0, 13.1), (3.5, 15.2), (4.0, 16.8), (4.5, 18.4), (5.0, 20.8), (5.5, 22.4), (6.0, 24.0),
    ]

    /// Auslauf e1 (Abstand Gewindeende bis Bohrungsgrund ohne Spitze): Tabellenwert, sonst etwa 4 · P + 1 mm.
    static func din76Length(pitch: Double) -> Double {
        for entry in din76Table where abs(entry.pitch - pitch) < 0.005 {
            return entry.e1
        }
        return 4 * pitch + 1
    }
}
