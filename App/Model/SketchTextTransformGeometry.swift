import CoreText
import Foundation
import QuartzCore
import simd

// Verschieben, Skalieren und Drehen eines Skizzentexts über Griffe (Kai: „Wenn ich die erstellte Schrift markiere,
// möchte ich ein Verschiebe- und ein Skalierwerkzeug angezeigt bekommen … Beim Verschieben an Snappunkten
// orientieren, aber nicht aus großer Entfernung einrasten … oder: halte ich den Stift ca. 1 Sekunde auf dem
// Fangpunkt, soll er dort einrasten.“).
//
// Ein gewählter Text zeigt einen Rahmen (Viewport.addTextTransformHandles): Verschiebe-Kreuz in der Mitte (bzw.
// Ziehen irgendwo im Rahmen), Skalier-Pfeil an der Ecke rechts oben (proportional, Gegenecke bleibt stehen) und
// einen Drehgriff oberhalb (Drehpunkt = Rahmenmitte, 15°-Schritte rasten ein). Die Lage steht in
// SketchText.transform und wirkt nach Anker und Drehung des Texts:
//   Glyphen (lokal) → [Verformung, SketchTextDeform, eigener Agent] → Anker/Drehung → transform → Konturen.
// Dadurch fließt sie in Bereiche, Extrudieren und Textkörper wie jede andere Änderung am Text.
//
// Fang beim Verschieben: Bezugspunkte des Texts sind die vier Rahmenecken, die Rahmenmitte und der
// Grundlinienanfang – der dem Fangpunkt nächste zählt. Fangpunkte: Enden, Mitten, Zentren, Schnittpunkte,
// 3D-Leitpunkte, gemerkte Punkte und der Ursprung (die Fangarten der Skizzenpalette gelten).
// - Sofortfang nur sehr nah: 0,3 mm (Skizzenmaß), aber mindestens 2 pt und höchstens 6 pt am Bildschirm. Weit
//   herausgezoomt wären 0,3 mm weniger als ein Bildpunkt (nie zu treffen), stark hineingezoomt viele Punkte
//   (der Text spränge sichtbar heran). 2 pt ≈ 0,4 mm Glas – etwa die Ruhe einer Stiftspitze; 6 pt ≈ 1,1 mm Glas,
//   kein spürbarer Sprung.
// - Verweilfang: bleibt der Bezugspunkt 1 s innerhalb von 10 pt um denselben Fangpunkt, springt der Text dorthin
//   (Haptik wie beim Zeichnen über currentSnap) und bleibt dort, bis der Stift 12 pt weit wegzieht. Bis dahin
//   zeigt ein Ring den Kandidaten. Wie der Winkelfang mit Verweilen (Sketch.swift, angleDwell) prüft ein Zeitgeber
//   selbst, wenn der Stift ganz ruhig steht und keine neuen Punkte kommen.
// Ein Ziehvorgang ist ein Rückgängig-Schritt (setDraggedElement mit begin beim ersten Ändern).

/// Lage eines Texts aus den Griffen: erst skalieren und drehen um den Drehpunkt (Mitte des Schriftsatzes), dann
/// verschieben. Gilt nach Anker und Drehung des Texts (SketchText.transform).
struct SketchTextTransform: Codable, Equatable {
    /// Verschiebung in der Skizze (mm)
    var offset: Point2
    /// Gleichmäßiger Faktor (1 = Originalgröße)
    var scale: Double
    /// Drehung um den Drehpunkt (Bogenmaß, gegen den Uhrzeigersinn)
    var rotation: Double

    init(offset: Point2 = .zero, scale: Double = 1, rotation: Double = 0) {
        self.offset = offset
        self.scale = scale
        self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey {
        case offset, scale, rotation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = (try? container.decodeIfPresent(Point2.self, forKey: .offset)) ?? .zero
        let decodedScale: Double = (try? container.decodeIfPresent(Double.self, forKey: .scale)) ?? 1
        scale = decodedScale > 0 ? decodedScale : 1
        rotation = (try? container.decodeIfPresent(Double.self, forKey: .rotation)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offset, forKey: .offset)
        try container.encode(scale, forKey: .scale)
        try container.encode(rotation, forKey: .rotation)
    }

    static let identity = SketchTextTransform()

    var isIdentity: Bool {
        simd_length(offset) < 1e-12 && abs(scale - 1) < 1e-12 && abs(rotation) < 1e-12
    }

    /// Punkt der Skizze (nach Anker und Drehung) in seine Lage nach den Griffen.
    func apply(_ p: Point2, pivot: Point2) -> Point2 {
        let d: Point2 = (p - pivot) * scale
        let c: Double = cos(rotation), s: Double = sin(rotation)
        return pivot + Point2(c * d.x - s * d.y, s * d.x + c * d.y) + offset
    }

    /// Umkehrung von apply.
    func invert(_ p: Point2, pivot: Point2) -> Point2 {
        let d: Point2 = p - offset - pivot
        let c: Double = cos(rotation), s: Double = sin(rotation)
        let back = Point2(c * d.x + s * d.y, -s * d.x + c * d.y)
        return pivot + back / max(scale, 1e-12)
    }

    /// Zusätzlich um d verschoben.
    func moved(by d: Point2) -> SketchTextTransform {
        SketchTextTransform(offset: offset + d, scale: scale, rotation: rotation)
    }

    /// Danach noch um c mit factor skaliert und um angle gedreht (pivot = Drehpunkt des Texts).
    /// Aus P' = c + R(angle)·factor·(P − c) mit P = pivot + R·scale·(q − pivot) + offset.
    func followed(byScale factor: Double, rotation angle: Double, about c: Point2, pivot: Point2) -> SketchTextTransform {
        let ca: Double = cos(angle), sa: Double = sin(angle)
        let d: Point2 = (pivot + offset - c) * factor
        let turned = Point2(ca * d.x - sa * d.y, sa * d.x + ca * d.y)
        return SketchTextTransform(offset: c + turned - pivot, scale: scale * factor, rotation: rotation + angle)
    }

    /// Skalieren-Werkzeug der Skizze: Anker und Drehpunkt wandern mit, also auch die Verschiebung.
    func scaledOffset(by factor: Double) -> SketchTextTransform {
        SketchTextTransform(offset: offset * factor, scale: scale, rotation: rotation)
    }
}

/// Rahmen eines Texts in der Skizze (gedreht wie der Text).
struct SketchTextFrame {
    /// links unten, rechts unten, rechts oben, links oben
    var corners: [Point2]
    var center: Point2
    /// Einheitsvektoren entlang der Grundlinie bzw. nach oben
    var right: Point2
    var up: Point2
    var width: Double
    var height: Double
    /// Anfang der Grundlinie (links, Höhe 0)
    var baselineStart: Point2

    /// Liegt p im Rahmen (mit Rand margin)?
    func contains(_ p: Point2, margin: Double = 0) -> Bool {
        let d: Point2 = p - corners[0]
        let x: Double = simd_dot(d, right), y: Double = simd_dot(d, up)
        return x >= -margin && x <= width + margin && y >= -margin && y <= height + margin
    }
}

extension SketchText {
    /// Punkt im System des Texts: Anker = Ursprung, Grundlinie = x-Achse (vor Verschieben/Skalieren/Drehen
    /// über die Griffe, siehe SketchTextTransform.swift).
    func local(_ p: Point2) -> Point2 {
        let unplaced: Point2 = transform?.invert(p, pivot: transformPivot) ?? p
        let d = unplaced - anchor
        let c = cos(rotation), s = sin(rotation)
        let x: Double = c * d.x + s * d.y
        let y: Double = c * d.y - s * d.x
        return Point2(x, y)
    }

    /// Umgebendes Rechteck der Buchstaben im System des Texts (nil ohne Umrisse).
    var localBounds: (min: Point2, max: Point2)? {
        let points: [Point2] = loops.flatMap(\.polygon).map { local($0) }
        guard let first = points.first else { return nil }
        let lo = points.reduce(first) { simd_min($0, $1) }
        let hi = points.reduce(first) { simd_max($0, $1) }
        return (lo, hi)
    }
    /// Mitte des Schriftsatzes im System des Texts (Anker = Ursprung, Grundlinie = x-Achse): Mitte der Zeile
    /// je nach Ausrichtung, halbe Großbuchstabenhöhe. Hängt nicht an den Umrissen, bleibt also bei Verformung stehen.
    static func layoutCenter(string: String, height: Double, fontName: String, alignment: TextAlignmentOption) -> Point2 {
        let text = string.replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty, height > 0 else { return Point2(0, height / 2) }
        let font = CTFontCreateWithName(fontName as CFString, 100, nil)
        let capHeight = max(Double(CTFontGetCapHeight(font)), 1)
        let scale: Double = height / capHeight
        let attributed = NSAttributedString(string: text,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil)) * scale
        let x: Double = switch alignment {
        case .left: width / 2
        case .center: 0
        case .right: -width / 2
        }
        return Point2(x, height / 2)
    }

    /// Punkt im System des Texts → Skizze, nur Anker und Drehung.
    static func placedBase(_ q: Point2, anchor: Point2, rotation: Double) -> Point2 {
        let c: Double = cos(rotation), s: Double = sin(rotation)
        return anchor + Point2(c * q.x - s * q.y, s * q.x + c * q.y)
    }

    /// Punkt im System des Texts → Skizze, samt Lage aus den Griffen (Umkehrung von local).
    func placed(_ q: Point2) -> Point2 {
        let base = Self.placedBase(q, anchor: anchor, rotation: rotation)
        return transform?.apply(base, pivot: transformPivot) ?? base
    }

    /// Rahmen um die Buchstaben, padding in Skizzenmaß nach außen (nil ohne Umrisse).
    func frame(padding: Double = 0) -> SketchTextFrame? {
        guard let box = localBounds else { return nil }
        let pad: Double = padding / max(transform?.scale ?? 1, 1e-6)
        let lo = box.min - Point2(pad, pad), hi = box.max + Point2(pad, pad)
        let corners: [Point2] = [placed(lo), placed(Point2(hi.x, lo.y)), placed(hi), placed(Point2(lo.x, hi.y))]
        let along: Point2 = corners[1] - corners[0], rise: Point2 = corners[3] - corners[0]
        let width: Double = simd_length(along), height: Double = simd_length(rise)
        let angle: Double = rotation + (transform?.rotation ?? 0)
        let right: Point2 = width > 1e-12 ? along / width : Point2(cos(angle), sin(angle))
        let up: Point2 = height > 1e-12 ? rise / height : Point2(-right.y, right.x)
        return SketchTextFrame(corners: corners, center: placed((lo + hi) / 2), right: right, up: up,
                               width: width, height: height, baselineStart: placed(Point2(box.min.x, 0)))
    }
}
