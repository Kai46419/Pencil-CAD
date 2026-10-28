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

// MARK: Griffe und Ziehen

extension SketchController {
    /// Laufendes Ziehen eines Textgriffs (gespeichert in textTransformDrag, Sketch.swift).
    struct TextTransformDrag {
        enum Kind {
            /// Kreuz in der Mitte bzw. irgendwo im Rahmen
            case move
            /// Pfeil an der Ecke rechts oben (proportional, Ecke links unten bleibt)
            case scale
            /// Griff oberhalb (um die Rahmenmitte)
            case rotate
        }
        var entity: Int
        var kind: Kind
        var start: Point2
        var original: SketchText
        /// Rahmen beim Aufsetzen, ohne Rand (Bezugspunkte des Fangs)
        var frame: SketchTextFrame
        /// Fangweite des Viewports (20 pt in mm)
        var tolerance: Double
        /// Fang ohne den Text selbst
        var snapIndex: SnapIndex
        /// Gemerkte Punkte und Ursprung (zählen als Endpunkte)
        var extra: [Point2]
        /// Antippen ohne Ziehen wählt wie das Pfeil-Werkzeug (auf der Schrift); an Griffen nur ein Hinweis
        var tapSelects: Bool
        var hasMoved = false
        /// Der Schritt zum Rückgängigmachen ist angelegt
        var remembered = false
        /// Eingerasteter Fang (Anzeige und Haptik über currentSnap)
        var snap: SnapResult?
        /// Kandidat für den Verweilfang: Fangpunkt und seit wann der Stift in seiner Nähe ist
        var dwellPoint: Point2?
        var dwellSince: CFTimeInterval = 0
        /// Per Verweilen eingerastet: Fangpunkt, Bezugspunkt (Index in den Bezugspunkten), Fangart
        var lockedPoint: Point2?
        var lockedRef = 0
        var lockedKind: SnapKind = .endpoint
        /// Drehen: letzter Winkel und aufsummierte Drehung (über ±180° hinaus)
        var lastAngle: Double = 0
        var sweep: Double = 0
        var lastPoint: Point2
        var pending: SketchText?
        var lastApply: CFTimeInterval = 0
    }

    /// Sofortfang 0,3 mm (Skizzenmaß); am Bildschirm begrenzt auf 2…6 pt (siehe oben)
    static let textSnapInstant: Double = 0.3
    /// Verweilfang: Radius am Bildschirm (pt) und Wartezeit
    static let textSnapDwellPoints: Double = 10
    static let textSnapDwellTime: CFTimeInterval = 1.0
    /// Mindestabstand zweier Neuberechnungen der Umrisse beim Ziehen (der Stift liefert bis zu 240 Punkte/s)
    private static let textDragInterval: CFTimeInterval = 1.0 / 60
    /// Trefferradius der Griffe (pt): mindestens 22 pt für Stift und Finger
    private static let textHandleHitPoints: Double = 24

    /// Nur ohne aktiven Verformungsmodus (die Verformungsgriffe haben Vorrang, SketchTextDeformHandles.swift).
    var textTransformHandlesVisible: Bool { textDeformMode == nil }

    /// Text, dessen Griffe gezeigt werden: allein gewählt im Pfeil-Werkzeug, ohne Bedingungen am Text (die hängen
    /// am Anker und würden durch die Griffe nicht mitgeführt).
    var transformHandleTextIndex: Int? {
        guard textTransformHandlesVisible, tool == .select, pendingAction == nil, let index = selectedTextIndex,
              !textHasConstraints(index) else { return nil }
        return index
    }

    private func textHasConstraints(_ index: Int) -> Bool {
        constraints.contains { $0.entities.contains(index) }
    }

    /// Lage der Griffe in der Skizze. unit = Skizzenmaß eines Bildschirmpunkts.
    private func textTransformHandlePoints(_ text: SketchText, unit: Double)
        -> (frame: SketchTextFrame, move: Point2, scale: Point2, rotate: Point2, rotateBase: Point2)? {
        guard let frame = text.frame(padding: 6 * unit) else { return nil }
        let top: Point2 = (frame.corners[2] + frame.corners[3]) / 2
        return (frame, frame.center, frame.corners[2], top + frame.up * (30 * unit), top)
    }

    /// Rahmen, Pfeile und Knöpfe für den Viewport (Viewport.addTextTransformHandles). frame wird gestrichelt
    /// gezeichnet, dwell ist der Ring um den Kandidaten des Verweilfangs.
    func textTransformHandleGeometry(unit: Double) -> (frame: [Point2], lines: [[Point2]], knobs: [Point2], dwell: [Point2])? {
        guard let index = transformHandleTextIndex, let text = sketchText(at: index),
              let h = textTransformHandlePoints(text, unit: unit) else { return nil }
        var lines: [[Point2]] = []
        func arrow(from base: Point2, to tip: Point2) {
            let length: Double = simd_distance(base, tip)
            guard length > 1e-12 else { return }
            let axis: Point2 = (tip - base) / length
            let side = Point2(-axis.y, axis.x) * (3.5 * unit)
            let back: Point2 = tip - axis * (4.5 * unit)
            lines.append([base, tip])
            lines.append([back + side, tip, back - side])
        }
        // Verschiebe-Kreuz: vier Pfeile
        for direction in [h.frame.right, -h.frame.right, h.frame.up, -h.frame.up] {
            arrow(from: h.move + direction * (4 * unit), to: h.move + direction * (15 * unit))
        }
        // Skalieren: Doppelpfeil entlang der Diagonale nach außen
        let diagonal: Point2 = h.frame.corners[2] - h.frame.corners[0]
        if simd_length(diagonal) > 1e-12 {
            let d: Point2 = simd_normalize(diagonal)
            arrow(from: h.scale + d * (12 * unit), to: h.scale + d * (22 * unit))
            arrow(from: h.scale + d * (12 * unit), to: h.scale + d * (5 * unit))
        }
        // Drehen: Stiel, Ring und gebogener Pfeil um den Knopf
        lines.append([h.rotateBase, h.rotate - h.frame.up * (7 * unit)])
        var ring: [Point2] = []
        for k in 0...24 {
            let angle: Double = Double(k) / 24 * 2 * .pi
            ring.append(h.rotate + Point2(cos(angle), sin(angle)) * (7 * unit))
        }
        lines.append(ring)
        let baseAngle: Double = atan2(h.frame.up.y, h.frame.up.x)
        var bow: [Point2] = []
        for k in 0...10 {
            let angle: Double = baseAngle + 0.35 + Double(k) / 10 * 1.6
            bow.append(h.rotate + Point2(cos(angle), sin(angle)) * (12 * unit))
        }
        if let tip = bow.last, bow.count >= 2 {
            lines.append(bow)
            let axis: Point2 = simd_normalize(tip - bow[bow.count - 2])
            let side = Point2(-axis.y, axis.x) * (3 * unit)
            let back: Point2 = tip - axis * (4 * unit)
            lines.append([back + side, tip, back - side])
        }
        let corners = h.frame.corners
        let frame: [Point2] = corners + [corners[0]]
        var dwell: [Point2] = []
        if let drag = textTransformDrag, drag.entity == index, let candidate = drag.dwellPoint, drag.lockedPoint == nil {
            for k in 0...24 {
                let angle: Double = Double(k) / 24 * 2 * .pi
                dwell.append(candidate + Point2(cos(angle), sin(angle)) * (Self.textSnapDwellPoints * unit))
            }
        }
        return (frame, lines, [h.move, h.scale, h.rotate], dwell)
    }

    /// Fang der Textgriffe für die Anzeige (currentSnap): Marker am Fangpunkt und Haptik beim Einrasten.
    var textTransformSnap: SnapResult? {
        textTransformDrag?.snap
    }

    /// Welcher Griff bzw. welcher Text liegt unter p? selectedOnly: nur Griffe und Rahmen des gewählten Texts
    /// (Finger und Rahmenauswahl im Viewport), sonst auch die Schrift nicht gewählter Texte.
    private func textTransformHit(at p: Point2, tolerance: Double, selectedOnly: Bool)
        -> (index: Int, kind: TextTransformDrag.Kind, tapSelects: Bool)? {
        let unit: Double = tolerance / 20
        let reach: Double = Self.textHandleHitPoints * unit
        if let index = transformHandleTextIndex, let text = sketchText(at: index),
           let h = textTransformHandlePoints(text, unit: unit) {
            if simd_distance(p, h.rotate) <= reach { return (index, .rotate, false) }
            if simd_distance(p, h.scale) <= reach { return (index, .scale, false) }
            if simd_distance(p, h.move) <= reach { return (index, .move, false) }
            // Im Rahmen: verschieben – außer eine andere Kurve bzw. ein Punkt liegt dort (die geht vor)
            if h.frame.contains(p), pick(at: p, tolerance: tolerance) == nil {
                return (index, .move, text.contains(p, tolerance: tolerance))
            }
        }
        guard !selectedOnly, textTransformHandlesVisible, tool == .select, pendingAction == nil,
              pick(at: p, tolerance: tolerance) == nil, let index = textIndex(at: p, tolerance: tolerance),
              !textHasConstraints(index) else { return nil }
        return (index, .move, true)
    }

    /// true, wenn p einen Griff bzw. den Rahmen des gewählten Texts trifft (der Viewport beginnt dort keine
    /// Rahmenauswahl und nimmt auch den Finger als Ziehen an).
    func hitsTextTransformHandle(at p: Point2, tolerance: Double) -> Bool {
        textTransformHit(at: p, tolerance: tolerance, selectedOnly: true) != nil
    }

    // MARK: Ziehen (Haken in began/moved/ended)

    /// Stift bzw. Finger setzt im Pfeil-Werkzeug auf: Textgriff oder Text getroffen? Dann übernimmt er das Ziehen.
    func beginTextTransformDrag(at p: Point2, tolerance: Double) -> Bool {
        textTransformDrag = nil
        guard let hit = textTransformHit(at: p, tolerance: tolerance, selectedOnly: false),
              let text = sketchText(at: hit.index), let frame = text.frame() else { return false }
        let others: [SketchEntity] = entities.indices.filter { $0 != hit.index }.map { entities[$0] }
        var drag = TextTransformDrag(entity: hit.index, kind: hit.kind, start: p, original: text, frame: frame,
                                     tolerance: tolerance, snapIndex: SnapIndex(entities: others, guides: modelGuides),
                                     extra: marks + [Point2.zero], tapSelects: hit.tapSelects, lastPoint: p)
        drag.lastAngle = atan2(p.y - frame.center.y, p.x - frame.center.x)
        textTransformDrag = drag
        return true
    }

    /// Stift bewegt sich: neue Lage berechnen (mit Fang) und höchstens 60-mal je Sekunde anwenden.
    func moveTextTransformDrag(to p: Point2, tolerance: Double) -> Bool {
        guard var drag = textTransformDrag else { return false }
        drag.lastPoint = p
        if !drag.hasMoved {
            // Kleines Zittern beim Tippen ist noch kein Ziehen
            guard simd_distance(p, drag.start) > tolerance * 0.15 else {
                textTransformDrag = drag
                return true
            }
            drag.hasMoved = true
            // Nicht gewählter Text: beim Ziehen wählen, damit Rahmen und Werte erscheinen
            if selectedTextIndex != drag.entity { selectText(at: drag.entity) }
        }
        let now: CFTimeInterval = CACurrentMediaTime()
        let moved: SketchText = transformedText(&drag, at: p, now: now)
        drag.pending = moved
        if now - drag.lastApply >= Self.textDragInterval {
            drag.lastApply = now
            applyTextTransformDrag(&drag, final: false)
        }
        textTransformDrag = drag
        return true
    }

    /// Stift hebt ab: letzte Lage anwenden (Bereiche und Fang neu aufbauen).
    func endTextTransformDrag(at p: Point2, tolerance: Double) -> Bool {
        guard var drag = textTransformDrag else { return false }
        if drag.hasMoved {
            // Beim Abheben zittert der Stift: kaum bewegt, gilt die zuletzt gezeigte (ggf. eingerastete) Lage
            if simd_distance(p, drag.lastPoint) > tolerance * 0.25 || drag.pending == nil {
                let lifted: SketchText = transformedText(&drag, at: p, now: CACurrentMediaTime())
                drag.pending = lifted
            }
            textTransformDrag = nil
            applyTextTransformDrag(&drag, final: true)
            changed()
            return true
        }
        textTransformDrag = nil
        if drag.tapSelects {
            // Tippen ohne Ziehen: wählen bzw. abwählen wie das Pfeil-Werkzeug
            select(at: drag.start, tolerance: tolerance)
            editableIndex = selection.count == 1 ? selection[0].entity : nil
            changed()
        } else {
            let hint: String
            switch drag.kind {
            case .move: hint = "Kreuz ziehen verschiebt den Text; nahe Fangpunkte rasten nach kurzem Halten ein."
            case .scale: hint = "Pfeil ziehen skaliert den Text, die Ecke links unten bleibt stehen."
            case .rotate: hint = "Griff ziehen dreht den Text um seine Mitte (15°-Schritte rasten ein)."
            }
            notice = hint
            changed()
        }
        return true
    }

    /// Berührung abgebrochen (z. B. zweiter Finger): bis dahin Gezogenes bleibt (ein Rückgängig-Schritt).
    func cancelTextTransformDrag() {
        guard let drag = textTransformDrag else { return }
        textTransformDrag = nil
        if drag.remembered, let text = sketchText(at: drag.entity) {
            setDraggedElement(.text(text), at: drag.entity, begin: false, final: true)
        }
    }

    private func applyTextTransformDrag(_ drag: inout TextTransformDrag, final: Bool) {
        guard let text = drag.pending, !text.loops.isEmpty, sketchText(at: drag.entity) != nil else {
            if final, drag.remembered, let current = sketchText(at: drag.entity) {
                setDraggedElement(.text(current), at: drag.entity, begin: false, final: true)
            }
            return
        }
        setDraggedElement(.text(text), at: drag.entity, begin: !drag.remembered, final: final)
        drag.remembered = true
    }

    /// Text in der Lage für den Stiftpunkt p (aus dem Stand beim Aufsetzen, damit sich nichts aufschaukelt).
    private func transformedText(_ drag: inout TextTransformDrag, at p: Point2, now: CFTimeInterval) -> SketchText {
        let original = drag.original
        let current: SketchTextTransform = original.transform ?? .identity
        let frame = drag.frame
        switch drag.kind {
        case .move:
            var delta: Point2 = p - drag.start
            let refs: [Point2] = (frame.corners + [frame.center, frame.baselineStart]).map { $0 + delta }
            if let hit = textSnapTarget(refs, drag: &drag, now: now) {
                delta += hit.target - refs[hit.ref]
            }
            return original.with(transform: current.moved(by: delta))
        case .scale:
            let fixed: Point2 = frame.corners[0]
            let diagonal: Point2 = frame.corners[2] - fixed
            let length2: Double = simd_dot(diagonal, diagonal)
            guard length2 > 1e-12 else { return original }
            let corner: Point2 = frame.corners[2] + (p - drag.start)
            var factor: Double = simd_dot(corner - fixed, diagonal) / length2
            if let hit = textSnapTarget([fixed + diagonal * factor], drag: &drag, now: now) {
                factor = simd_dot(hit.target - fixed, diagonal) / length2
            }
            // Nicht durch die feste Ecke hindurch und nicht unter 1 % der Originalgröße
            factor = max(factor, 0.01 / max(current.scale, 1e-6), 0.02)
            return original.with(transform: current.followed(byScale: factor, rotation: 0, about: fixed,
                                                              pivot: original.transformPivot))
        case .rotate:
            let center: Point2 = frame.center
            let angle: Double = atan2(p.y - center.y, p.x - center.x)
            drag.sweep += remainder(angle - drag.lastAngle, 2 * .pi)
            drag.lastAngle = angle
            var turn: Double = drag.sweep
            drag.snap = nil
            if snapEnabled, snapKinds.contains(.angle) {
                // Gesamtwinkel des Texts auf 15°-Schritte, wenn er höchstens 2° daneben liegt
                let total: Double = original.rotation + current.rotation + turn
                let step: Double = .pi / 12
                let rounded: Double = (total / step).rounded() * step
                if abs(total - rounded) <= 2 * .pi / 180 { turn += rounded - total }
            }
            return original.with(transform: current.followed(byScale: 1, rotation: turn, about: center,
                                                              pivot: original.transformPivot))
        }
    }

    /// Fangpunkt für einen der Bezugspunkte refs: sofort nur sehr nah, sonst nach 1 s Verweilen (siehe oben).
    /// Ergebnis: Index des Bezugspunkts und Fangpunkt; nil = frei.
    private func textSnapTarget(_ refs: [Point2], drag: inout TextTransformDrag,
                                now: CFTimeInterval) -> (ref: Int, target: Point2)? {
        let unit: Double = drag.tolerance / 20
        let instant: Double = min(max(Self.textSnapInstant, 2 * unit), 6 * unit)
        let dwellRadius: Double = max(Self.textSnapDwellPoints * unit, instant * 1.5)
        let pointKinds: Set<SnapKind> = [.endpoint, .midpoint, .center, .intersection, .modelPoint]
        let kinds: Set<SnapKind> = snapKinds.intersection(pointKinds)
        guard snapEnabled, !kinds.isEmpty, !refs.isEmpty else {
            drag.snap = nil
            drag.dwellPoint = nil
            drag.lockedPoint = nil
            return nil
        }
        // Per Verweilen eingerastet: bleibt, bis der Bezugspunkt deutlich wegzieht
        if let locked = drag.lockedPoint, refs.indices.contains(drag.lockedRef),
           simd_distance(refs[drag.lockedRef], locked) <= dwellRadius * 1.2 {
            drag.snap = SnapResult(point: locked, kind: drag.lockedKind)
            return (drag.lockedRef, locked)
        }
        drag.lockedPoint = nil
        var best: (ref: Int, point: Point2, kind: SnapKind, distance: Double)?
        for (k, ref) in refs.enumerated() {
            let result = drag.snapIndex.snap(ref, tolerance: dwellRadius, kinds: kinds, extra: drag.extra, gridStep: 0)
            guard let kind = result.kind, pointKinds.contains(kind) else { continue }
            let distance: Double = simd_distance(result.point, ref)
            if distance < (best?.distance ?? .infinity) { best = (k, result.point, kind, distance) }
        }
        guard let best else {
            drag.snap = nil
            drag.dwellPoint = nil
            return nil
        }
        if best.distance <= instant {
            drag.dwellPoint = nil
            drag.snap = SnapResult(point: best.point, kind: best.kind)
            return (best.ref, best.point)
        }
        if let candidate = drag.dwellPoint, simd_distance(candidate, best.point) < 1e-9 {
            if now - drag.dwellSince >= Self.textSnapDwellTime {
                drag.lockedPoint = best.point
                drag.lockedRef = best.ref
                drag.lockedKind = best.kind
                drag.dwellPoint = nil
                drag.snap = SnapResult(point: best.point, kind: best.kind)
                return (best.ref, best.point)
            }
        } else {
            drag.dwellPoint = best.point
            drag.dwellSince = now
            scheduleTextDwellCheck(since: now)
        }
        drag.snap = nil
        return nil
    }

    /// Bleibt der Stift ganz ruhig, kommen keine neuen Punkte: nach der Wartezeit selbst prüfen.
    private func scheduleTextDwellCheck(since: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.textSnapDwellTime + 0.03) { [weak self] in
            guard let self, var drag = self.textTransformDrag, drag.hasMoved, drag.dwellPoint != nil,
                  drag.dwellSince == since else { return }
            let last: Point2 = drag.lastPoint
            let held: SketchText = self.transformedText(&drag, at: last, now: CACurrentMediaTime())
            drag.pending = held
            drag.lastApply = CACurrentMediaTime()
            self.applyTextTransformDrag(&drag, final: false)
            self.textTransformDrag = drag
            self.changed()
        }
    }

    // MARK: Werte aus der Leiste (SketchTextTransformPanel.swift), je ein Rückgängig-Schritt

    /// Rahmenmitte des Texts an x bzw. y setzen.
    func setTextCenter(at index: Int, x: Double? = nil, y: Double? = nil) {
        guard let text = sketchText(at: index), let frame = text.frame() else { return }
        let target = Point2(x ?? frame.center.x, y ?? frame.center.y)
        let current: SketchTextTransform = text.transform ?? .identity
        updateText(at: index) { $0.with(transform: current.moved(by: target - frame.center)) }
    }

    /// Skalierung (1 = Originalgröße) um die Rahmenmitte.
    func setTextScale(at index: Int, to scale: Double) {
        guard scale > 1e-4, let text = sketchText(at: index), let frame = text.frame() else { return }
        let current: SketchTextTransform = text.transform ?? .identity
        let factor: Double = scale / max(current.scale, 1e-12)
        updateText(at: index) {
            $0.with(transform: current.followed(byScale: factor, rotation: 0, about: frame.center,
                                                pivot: text.transformPivot))
        }
    }

    /// Drehung aus den Griffen (Bogenmaß) um die Rahmenmitte.
    func setTextTurn(at index: Int, to rotation: Double) {
        guard let text = sketchText(at: index), let frame = text.frame() else { return }
        let current: SketchTextTransform = text.transform ?? .identity
        updateText(at: index) {
            $0.with(transform: current.followed(byScale: 1, rotation: rotation - current.rotation, about: frame.center,
                                                pivot: text.transformPivot))
        }
    }

    /// Lage aus den Griffen verwerfen (Text wie geschrieben).
    func resetTextTransform(at index: Int) {
        guard let text = sketchText(at: index), text.transform != nil else { return }
        updateText(at: index) { $0.with(transform: .identity) }
    }
}
