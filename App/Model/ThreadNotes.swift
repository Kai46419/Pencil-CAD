import Foundation
import simd

// MARK: - Gewinde: Kernlochbohrer, kosmetische Gewinde, Gewinde als Eigenschaft am Körper, Toleranz-Vorlagen
//
// Kernloch nach Bohrertabelle (ISO 2306 für metrische Regelgewinde, übliche Tabellen für UNC/UNF/G/NPT), sonst
// D − P bzw. der Kern-Ø nach Grundprofil. Ein kosmetisches Gewinde erzeugt keine Geometrie: die Bohrung bekommt
// nur das Kernloch, der Bolzen bleibt, wie er ist; das Gewinde steht als ThreadNote am Körper (bodies.json,
// Verlauf) und wird im Viewport als dünne Ringe im Abstand der Steigung gezeigt (ThreadNotesUI.swift).

// MARK: Kernlochbohrer

enum ThreadTapDrills {
    /// Metrische Regelgewinde nach ISO 2306 (Bohrer-Ø in mm), Schlüssel = Größe
    static let metricCoarse: [String: Double] = [
        "M1": 0.75, "M1,2": 0.95, "M1,4": 1.1, "M1,6": 1.25, "M1,8": 1.45, "M2": 1.6, "M2,5": 2.05, "M3": 2.5,
        "M3,5": 2.9, "M4": 3.3, "M5": 4.2, "M6": 5.0, "M7": 6.0, "M8": 6.8, "M10": 8.5, "M12": 10.2, "M14": 12,
        "M16": 14, "M18": 15.5, "M20": 17.5, "M22": 19.5, "M24": 21, "M27": 24, "M30": 26.5, "M33": 29.5,
        "M36": 32, "M39": 35, "M42": 37.5, "M45": 40.5, "M48": 43, "M52": 47, "M56": 50.5, "M60": 54.5, "M64": 58,
    ]

    /// UNC (Nummern- und Buchstabenbohrer bzw. Zollbohrer, in mm umgerechnet)
    static let unc: [String: Double] = [
        "Nr. 4": 2.26, "Nr. 5": 2.58, "Nr. 6": 2.71, "Nr. 8": 3.45, "Nr. 10": 3.80, "Nr. 12": 4.50,
        "1/4\"": 5.11, "5/16\"": 6.53, "3/8\"": 7.94, "7/16\"": 9.35, "1/2\"": 10.72, "9/16\"": 12.30,
        "5/8\"": 13.49, "3/4\"": 16.67, "7/8\"": 19.45, "1\"": 22.23,
    ]

    /// UNF
    static let unf: [String: Double] = [
        "Nr. 4": 2.37, "Nr. 5": 2.64, "Nr. 6": 2.87, "Nr. 8": 3.45, "Nr. 10": 4.04, "Nr. 12": 4.62,
        "1/4\"": 5.41, "5/16\"": 6.91, "3/8\"": 8.43, "7/16\"": 9.92, "1/2\"": 11.51, "9/16\"": 13.10,
        "5/8\"": 14.68, "3/4\"": 17.46, "7/8\"": 20.64, "1\"": 23.42,
    ]

    /// Rohrgewinde G (ISO 228-1)
    static let pipe: [String: Double] = [
        "G1/16": 6.8, "G1/8": 8.8, "G1/4": 11.8, "G3/8": 15.25, "G1/2": 19.0, "G3/4": 24.5, "G1": 30.75,
        "G1 1/4": 39.5, "G1 1/2": 45.25, "G2": 57.0,
    ]

    /// NPT (ohne Reibahle)
    static let npt: [String: Double] = [
        "1/8\" NPT": 8.73, "1/4\" NPT": 11.11, "3/8\" NPT": 14.68, "1/2\" NPT": 18.26, "3/4\" NPT": 23.42,
        "1\" NPT": 29.37, "1 1/4\" NPT": 38.1, "1 1/2\" NPT": 44.05, "2\" NPT": 56.36,
    ]

    /// Auf 0,05 mm gerundet (übliche Bohrerstufen)
    static func rounded(_ value: Double) -> Double {
        (value * 20).rounded() / 20
    }
}

extension ThreadFamily {
    /// Tabelle der Kernlochbohrer dieser Art (nur für die Normsteigung), nil = keine Tabelle
    private var tapDrillTable: [String: Double]? {
        switch self {
        case .metric: return ThreadTapDrills.metricCoarse
        case .unc: return ThreadTapDrills.unc
        case .unf: return ThreadTapDrills.unf
        case .pipe: return ThreadTapDrills.pipe
        case .npt: return ThreadTapDrills.npt
        default: return nil
        }
    }

    /// Kernlochbohrer in mm (ohne Druckspiel): Tabellenwert bei Normsteigung, metrisches Feingewinde D − P,
    /// Zollgewinde D − P (auf 0,05 gerundet), sonst der Kern-Ø nach Grundprofil.
    func tapDrill(_ size: ThreadSize, pitch: Double) -> Double {
        let standardPitch: Bool = abs(pitch - size.pitch) < 1e-6
        if standardPitch, let table = tapDrillTable, let value = table[size.name] {
            return value
        }
        let core: Double = coreDiameter(size, pitch: pitch)
        switch self {
        case .metric:
            return size.diameter - pitch
        case .unc, .unf, .whitworth, .pipe:
            let simple: Double = ThreadTapDrills.rounded(size.diameter - pitch)
            return max(simple, core)
        default:
            return core
        }
    }

    /// Kernloch aus der Bohrertabelle (sonst gerechnet)
    func tapDrillIsTabulated(_ size: ThreadSize, pitch: Double) -> Bool {
        guard abs(pitch - size.pitch) < 1e-6, let table = tapDrillTable else { return false }
        return table[size.name] != nil
    }

    /// Bezeichnung für die Eigenschaft am Körper, z. B. „M6×1 links, 2-gängig“, „Tr 8×8 (P2)“, „1/4"-20 UNC“.
    func noteLabel(_ size: ThreadSize, pitch: Double, starts: Int, leftHanded: Bool) -> String {
        var text: String
        if self == .metric {
            let p: String = pitch.formatted(.number.precision(.fractionLength(0...3)))
            text = "\(size.name)×\(p)"
        } else {
            let shownStarts: Int = isMotionThread ? starts : 1
            text = designation(size, pitch: pitch, starts: shownStarts, leftHanded: false)
        }
        if leftHanded { text += " links" }
        if starts > 1, !isMotionThread { text += ", \(starts)-gängig" }
        return text
    }
}

extension HoleThread {
    /// Kernlochbohrer nach Tabelle (ohne Druckspiel)
    var tapDrill: Double { family.tapDrill(size, pitch: pitch) }

    /// „Kernloch Ø 5,0 (Bohrer)“ bzw. „(gerechnet)“, Druckspiel als Zusatz
    func tapDrillText(clearance: Double) -> String {
        let drill: String = LengthUnit.current.format(tapDrill)
        let source: String = family.tapDrillIsTabulated(size, pitch: pitch) ? "Bohrer" : "gerechnet"
        guard clearance > 1e-9 else { return "Kernloch Ø \(drill) (\(source))" }
        let extra: String = clearance.formatted(.number.precision(.fractionLength(0...2)))
        return "Kernloch Ø \(drill) (\(source)) + \(extra) Spiel"
    }
}

extension ThreadSpec {
    /// Kernlochbohrer der gewählten Größe (ohne Druckspiel)
    var tapDrill: Double { family.tapDrill(size, pitch: pitch) }

    /// Kernradius eines Innengewindes: Kernlochbohrer plus Druckspiel, mindestens der Kern nach Grundprofil
    /// (kegelige Gewinde und Außengewinde: unverändert minor).
    func coreRadius(minor: Double, external: Bool) -> Double {
        guard !external, !family.isTapered else { return minor }
        let drilled: Double = (tapDrill + clearance) / 2
        return max(minor, drilled)
    }

    /// Eigenschaft am Körper für dieses Gewinde an der Fläche (Lage wie in threadedBody); nil, wenn zu kurz.
    func note(for target: ThreadTarget) -> ThreadNote? {
        let fromHigh: Bool = startsAtHigh(target)
        let inward: SIMD3<Double> = fromHigh ? -target.axis : target.axis
        let start: SIMD3<Double> = fromHigh ? target.origin + target.axis * target.length : target.origin
        let zFrom: Double = min(max(0, offset), target.length)
        let wanted: Double = fullLength ? target.length : length
        let zTo: Double = min(target.length, zFrom + wanted)
        guard zTo - zFrom > 0.05 else { return nil }
        let label: String = family.noteLabel(size, pitch: pitch, starts: starts, leftHanded: leftHanded)
        return ThreadNote(designation: label, length: zTo - zFrom, external: target.external, cosmetic: cosmetic,
                          origin: start + inward * zFrom, direction: inward, diameter: size.diameter, pitch: pitch,
                          faceDiameter: 2 * target.radius)
    }
}

extension HoleSpec {
    /// Eigenschaft am Körper für eine Gewindebohrung bei point (outward = Flächennormale, reach = Länge einer
    /// durchgehenden Bohrung aus threadReach); nil ohne Gewinde.
    func threadNote(at point: SIMD3<Double>, outward n: SIMD3<Double>, reach: Double) -> ThreadNote? {
        guard let thread else { return nil }
        let length: Double = through ? max(0.1, reach - 1) : depth
        let label: String = thread.family.noteLabel(thread.size, pitch: thread.pitch, starts: 1,
                                                    leftHanded: thread.leftHanded)
        return ThreadNote(designation: label, length: length, external: false, cosmetic: thread.cosmetic,
                          origin: point, direction: -n, diameter: thread.size.diameter, pitch: thread.pitch,
                          faceDiameter: thread.tapDrill + clearance)
    }
}

// MARK: Gewinde als Eigenschaft am Körper

/// Gewinde an einem Körper (modelliert oder kosmetisch). Gespeichert in bodies.json und im Verlauf.
struct ThreadNote: Codable, Hashable {
    /// z. B. „M6×1 links, 2-gängig“
    var designation: String
    /// Gewindelänge in mm
    var length: Double
    /// Außengewinde (Bolzen) bzw. Innengewinde (Bohrung)
    var external: Bool
    /// Nur als Eigenschaft und Darstellung, ohne Gewindegeometrie
    var cosmetic: Bool
    /// Achse: Gewindeanfang und Richtung ins Gewinde (Welt)
    var origin: SIMD3<Double>
    var direction: SIMD3<Double>
    /// Nenn-Ø und Steigung in mm
    var diameter: Double
    var pitch: Double
    /// Ø der Fläche (Bolzen bzw. Kernloch), an der die Ringe gezeichnet werden
    var faceDiameter: Double? = nil

    /// Text für das Eigenschaften-Fenster: „M6×1 · 12 mm · innen · modelliert“
    var summary: String {
        let lengthText: String = LengthUnit.current.format(length)
        let side: String = external ? "außen" : "innen"
        let kind: String = cosmetic ? "kosmetisch" : "modelliert"
        return "\(designation) · \(lengthText) · \(side) · \(kind)"
    }

    /// Nach einer starren Bewegung des Körpers (Verschieben, Drehen, Muster)
    func moved(by motion: simd_double4x4) -> ThreadNote {
        var note = self
        let point: SIMD4<Double> = motion * SIMD4<Double>(origin.x, origin.y, origin.z, 1)
        let axis: SIMD4<Double> = motion * SIMD4<Double>(direction.x, direction.y, direction.z, 0)
        note.origin = SIMD3<Double>(point.x, point.y, point.z)
        note.direction = SIMD3<Double>(axis.x, axis.y, axis.z)
        return note
    }

    /// Gleiche Achse und gleiche Art (innen/außen): ersetzt ein älteres Gewinde an derselben Fläche
    func sharesAxis(with other: ThreadNote) -> Bool {
        guard external == other.external, simd_length(direction) > 1e-9, simd_length(other.direction) > 1e-9 else {
            return false
        }
        let a: SIMD3<Double> = simd_normalize(direction)
        let b: SIMD3<Double> = simd_normalize(other.direction)
        guard abs(simd_dot(a, b)) > 0.9999 else { return false }
        let offset: SIMD3<Double> = other.origin - origin
        let along: Double = simd_dot(offset, a)
        let radial: SIMD3<Double> = offset - a * along
        return simd_length(radial) < 0.01
    }

    /// Zwei Richtungen senkrecht zur Achse
    private var basis: (u: SIMD3<Double>, v: SIMD3<Double>) {
        let n: SIMD3<Double> = simd_normalize(direction)
        let reference: SIMD3<Double> = abs(n.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
        let u: SIMD3<Double> = simd_normalize(simd_cross(reference, n))
        let v: SIMD3<Double> = simd_cross(n, u)
        return (u, v)
    }

    private var surfaceRadius: Double { (faceDiameter ?? diameter) / 2 }

    /// Passt das Gewinde noch zum Körper (Fläche noch an dieser Stelle)? Prüfpunkte in der Mitte der Länge knapp
    /// im Material bzw. knapp davor.
    func fits(_ shape: PCKShape) -> Bool {
        guard simd_length(direction) > 1e-9, length > 0 else { return false }
        let axis: SIMD3<Double> = simd_normalize(direction)
        let mid: SIMD3<Double> = origin + axis * (length / 2)
        let r: Double = surfaceRadius
        let step: Double = min(max(0.1, 0.3 * pitch), 0.4 * r)
        let solidRadius: Double = external ? r - step : r + step
        let voidRadius: Double = external ? r + step : r - step
        let frame = basis
        var solid = 0
        var empty = 0
        for k in 0..<4 {
            let angle: Double = (Double(k) + 0.25) * .pi / 2
            let radial: SIMD3<Double> = frame.u * cos(angle) + frame.v * sin(angle)
            if shape.contains(point: mid + radial * solidRadius) { solid += 1 }
            if !shape.contains(point: mid + radial * voidRadius) { empty += 1 }
        }
        return solid >= 3 && empty >= 3
    }

    /// Ringe im Abstand der Steigung entlang der Gewindelänge, knapp vor der Fläche (Bolzen außen, Bohrung innen)
    func rings(segments: Int = 32, maximum: Int = 200) -> [[SIMD3<Float>]] {
        guard simd_length(direction) > 1e-9, pitch > 0, length > 0 else { return [] }
        let axis: SIMD3<Double> = simd_normalize(direction)
        let r: Double = surfaceRadius
        let radius: Double = external ? r * 1.01 + 0.02 : r * 0.96 - 0.02
        guard radius > 0.05 else { return [] }
        let count: Int = Int((length / pitch).rounded(.down))
        let every: Int = max(1, (count + maximum - 1) / maximum)
        let step: Double = pitch * Double(every)
        let frame = basis
        var circle: [SIMD3<Double>] = []
        circle.reserveCapacity(segments + 1)
        for k in 0...segments {
            let angle: Double = Double(k) / Double(segments) * 2 * .pi
            let radial: SIMD3<Double> = frame.u * cos(angle) + frame.v * sin(angle)
            circle.append(radial * radius)
        }
        var result: [[SIMD3<Float>]] = []
        var z: Double = 0
        while z <= length + 1e-6 {
            let center: SIMD3<Double> = origin + axis * z
            let ring: [SIMD3<Float>] = circle.map { SIMD3<Float>(center + $0) }
            result.append(ring)
            z += step
        }
        return result
    }
}

extension SceneBody {
    /// Gewinde eintragen; ein älteres Gewinde an derselben Achse wird ersetzt.
    mutating func addThread(_ note: ThreadNote) {
        var list: [ThreadNote] = (threads ?? []).filter { !$0.sharesAxis(with: note) }
        list.append(note)
        threads = list
    }

    /// Zeilen für das Eigenschaften-Fenster
    var threadSummaries: [String] {
        (threads ?? []).map(\.summary)
    }
}

extension ModelStore {
    /// Kosmetisches Gewinde als Vorschau: Körper unverändert, Gewinde nur als Eigenschaft (schnell, ohne Boolean).
    func previewCosmeticThread(_ spec: ThreadSpec, target: ThreadTarget) {
        guard bodies.indices.contains(target.body), let note = spec.note(for: target) else {
            let faceLength: String = target.length.formatted(.number.precision(.fractionLength(0...2)))
            message = "Länge bzw. Versatz prüfen – die Fläche ist \(faceLength) mm lang."
            dropPreview()
            return
        }
        var preview: [SceneBody] = bodies
        preview[target.body].addThread(note)
        let summary: String = threadSummary(spec, target: target)
        message = summary + " · kosmetisch"
        showPreview(preview, name: "Gewinde \(spec.designation) (kosmetisch)")
    }
}

// MARK: Darstellung kosmetischer Gewinde (zwischengespeichert)

/// Ringe aller kosmetischen Gewinde; neu gerechnet nur, wenn sich Körperformen oder Gewinde ändern.
@MainActor
final class CosmeticThreadOverlay {
    static let shared = CosmeticThreadOverlay()

    private var shapes: [PCKShape] = []
    private var notes: [[ThreadNote]] = []
    private var cached: [[SIMD3<Float>]] = []

    func lines(for bodies: [SceneBody]) -> [[SIMD3<Float>]] {
        var newShapes: [PCKShape] = []
        var newNotes: [[ThreadNote]] = []
        for body in bodies where !body.isHidden {
            let cosmetic: [ThreadNote] = (body.threads ?? []).filter(\.cosmetic)
            guard !cosmetic.isEmpty else { continue }
            newShapes.append(body.shape)
            newNotes.append(cosmetic)
        }
        if newNotes == notes, newShapes.count == shapes.count {
            var same = true
            for index in newShapes.indices where newShapes[index] !== shapes[index] {
                same = false
                break
            }
            if same { return cached }
        }
        var lines: [[SIMD3<Float>]] = []
        for index in newShapes.indices {
            for note in newNotes[index] where note.fits(newShapes[index]) {
                lines.append(contentsOf: note.rings())
            }
        }
        shapes = newShapes
        notes = newNotes
        cached = lines
        return lines
    }
}

// MARK: Toleranz-Vorlagen fürs Druckspiel

enum ThreadTolerancePreset: String, CaseIterable, Identifiable {
    case fdm
    case resin
    case machined

    var id: Self { self }

    var title: String {
        switch self {
        case .fdm: "FDM 0,3"
        case .resin: "Harz (SLA) 0,1"
        case .machined: "Fräsen ISO 6H/6g 0"
        }
    }

    /// Druckspiel in mm
    var clearance: Double {
        switch self {
        case .fdm: 0.3
        case .resin: 0.1
        case .machined: 0
        }
    }

    private static let key = "thread.tolerancePreset"

    /// Zuletzt gewählte Vorlage (UserDefaults)
    static var remembered: ThreadTolerancePreset? {
        UserDefaults.standard.string(forKey: key).flatMap { ThreadTolerancePreset(rawValue: $0) }
    }

    static func remember(_ preset: ThreadTolerancePreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: key)
    }

    /// Druckspiel für neue Gewinde: zuletzt gewählte Vorlage, sonst 0,2 mm
    static var defaultClearance: Double { remembered?.clearance ?? 0.2 }
}
