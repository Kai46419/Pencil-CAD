import Foundation

/// Rundungsoptionen nach Shapr3D (Ecken, Stetigkeit, Profil, Overflow), Build 42.
///
/// Wird in App UND BlendWorker übersetzt (project.yml: `Shared` in beiden Targets; beide sehen PCKShape.h über
/// App/Kernel/PencilCAD-Bridging-Header.h). Deshalb nur Foundation + PCKBlendOptions.
///
/// Standard = Rolling Ball, G1, Kreis, Automatisch: dann verhalten sich alle Pfade bitgleich wie bis Build 41
/// (kein neuer Schlüssel im Worker-Protokoll, in features.json oder in den Merk-Schlüsseln).
struct BlendOptions: Codable, Hashable, Sendable {
    enum Corner: String, Codable, Hashable, Sendable, CaseIterable {
        /// Eine Kugel rollt über alle Kanten (Standard)
        case rollingBall
        /// Die Ecke wird weich verblendet, die Rundungen enden im Setback-Abstand vor der Ecke
        case setback
    }

    enum Continuity: String, Codable, Hashable, Sendable, CaseIterable {
        /// Tangential (Standard)
        case g1
        /// Krümmungsstetig
        case g2
    }

    enum Profile: String, Codable, Hashable, Sendable, CaseIterable {
        case circle
        /// Kegelschnitt mit rho (nur G2)
        case conic
    }

    enum Overflow: String, Codable, Hashable, Sendable, CaseIterable {
        case automatic
        case keepEdge
    }

    var corner: Corner = .rollingBall
    /// mm ab Eckpunkt entlang jeder Kante; nur bei corner == .setback (> 0, endlich)
    var setback: Double? = nil
    var continuity: Continuity = .g1
    var profile: Profile = .circle
    /// 0,1 … 0,9; nur bei profile == .conic (und continuity == .g2)
    var rho: Double? = nil
    var overflow: Overflow = .automatic

    init(corner: Corner = .rollingBall, setback: Double? = nil, continuity: Continuity = .g1,
         profile: Profile = .circle, rho: Double? = nil, overflow: Overflow = .automatic) {
        self.corner = corner
        self.setback = setback
        self.continuity = continuity
        self.profile = profile
        self.rho = rho
        self.overflow = overflow
    }

    static let standard = BlendOptions()

    /// Rolling Ball, G1, Kreis, Automatisch. setback/rho zählen hier nicht (gelten nur bei Setback bzw. Kegelschnitt),
    /// wie PCKBlendOptions.isStandard.
    var isStandard: Bool {
        corner == .rollingBall && continuity == .g1 && profile == .circle && overflow == .automatic
    }

    /// Wie PCKBlendOptions.isValid: Setback > 0 und endlich bei Setback-Ecke; Kegelschnitt nur mit G2 und
    /// rho 0,1 … 0,9.
    var isValid: Bool {
        if corner == .setback {
            guard let setback, setback.isFinite, setback > 0 else { return false }
        }
        if profile == .conic {
            guard continuity == .g2, let rho, rho.isFinite, rho >= 0.1 - 1e-12, rho <= 0.9 + 1e-12 else { return false }
        }
        return true
    }

    /// Für Schlüssel, Protokoll und Speichern: nil bei Standard; sonst ohne die nicht geltenden Werte
    /// (setback nur bei Setback, rho nur bei Kegelschnitt). Zwei Optionen mit gleicher Wirkung sind danach gleich.
    var normalized: BlendOptions? {
        guard !isStandard else { return nil }
        var copy = self
        if copy.corner != .setback { copy.setback = nil }
        if copy.profile != .conic { copy.rho = nil }
        return copy
    }

    /// Für den Geometriekernel (PCKShape.filleting(edges:radius:options:) bzw. supports(blendOptions:)).
    var kernel: PCKBlendOptions {
        let options = PCKBlendOptions.standard()
        options.corner = corner == .setback ? .setback : .rollingBall
        options.setback = setback ?? 0
        options.continuity = continuity == .g2 ? .g2 : .g1
        options.profile = profile == .conic ? .conic : .circle
        options.rho = rho ?? 0.5
        options.overflow = overflow == .keepEdge ? .keepEdge : .automatic
        return options
    }

    /// Vorgabe für den Setback-Abstand (folgt dem Radius, bis von Hand eingegeben)
    static func defaultSetback(radius: Double) -> Double {
        1.5 * radius
    }

    /// Kurzbezeichnung für Meldungen und Fehlertexte („Setback“, „G2“, „Setback, G2, Kegelschnitt“); leer bei Standard.
    var shortLabel: String {
        var parts: [String] = []
        if corner == .setback { parts.append("Setback") }
        if continuity == .g2 { parts.append("G2") }
        if profile == .conic { parts.append("Kegelschnitt") }
        if overflow == .keepEdge { parts.append("Kante halten") }
        return parts.joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey {
        case corner, setback, continuity, profile, rho, overflow
    }

    /// Fehlende Schlüssel = Standardwert (Anfragen bzw. Dateien ohne einzelne Felder bleiben lesbar).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        corner = try container.decodeIfPresent(Corner.self, forKey: .corner) ?? .rollingBall
        setback = try container.decodeIfPresent(Double.self, forKey: .setback)
        continuity = try container.decodeIfPresent(Continuity.self, forKey: .continuity) ?? .g1
        profile = try container.decodeIfPresent(Profile.self, forKey: .profile) ?? .circle
        rho = try container.decodeIfPresent(Double.self, forKey: .rho)
        overflow = try container.decodeIfPresent(Overflow.self, forKey: .overflow) ?? .automatic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(corner, forKey: .corner)
        try container.encodeIfPresent(setback, forKey: .setback)
        try container.encode(continuity, forKey: .continuity)
        try container.encode(profile, forKey: .profile)
        try container.encodeIfPresent(rho, forKey: .rho)
        try container.encode(overflow, forKey: .overflow)
    }
}
