import Foundation
import simd
import UIKit

// Griffe zum Verformen eines gewählten Texts (Kai: „ringsherum so eine Art Rechteck … an allen vier Ecken …
// in der Mitte von links und rechts einen Punkt, an dem ich das langziehen kann. Oben ebenfalls …“).
// Die Griffe erscheinen nur, wenn in der Leiste ein Verformungsmodus aktiv ist (textDeformMode); sonst zeigt der
// Text seinen Rahmen zum Verschieben, Skalieren und Drehen (SketchTextTransform.swift).
//   Frei transformieren: Seitenmitten ziehen Breite bzw. Höhe, Ecken beides (nicht proportional)
//   Verzerren:           Seitenmitten scheren den Rahmen entlang der Kante
//   Perspektive:         Ecken frei ziehen (Vierpunkt-Hülle, projektive Abbildung)
//   Hülle:               ein Griff oben in der Mitte ändert die Stärke der Vorlage
//   Am Pfad:             Startgriff gleitet auf der Kurve; bei einem Hilfsbogen zieht ein Griff die Krümmung
// Ein Ziehvorgang ist ein Schritt zum Rückgängigmachen. Mathematik: SketchTextDeform.swift.

/// Modus der Verformungsgriffe (Leiste „Verformen“).
enum SketchTextDeformMode: String, CaseIterable, Identifiable {
    case free = "Frei transformieren"
    case shear = "Verzerren"
    case perspective = "Perspektive"
    case envelope = "Hülle"
    case path = "Am Pfad"
    /// Wartet auf das Antippen einer Kurve (Pfad wählen)
    case pickPath = "Pfad wählen"

    var id: Self { self }

    /// Modi mit Griffen, wie sie die Leiste anbietet
    static let handleModes: [SketchTextDeformMode] = [.free, .shear, .perspective, .envelope]

    var systemImage: String {
        switch self {
        case .free: "arrow.up.left.and.arrow.down.right"
        case .shear: "parallelogram"
        case .perspective: "perspective"
        case .envelope: "rainbow"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .pickPath: "hand.point.up.left"
        }
    }

    var hint: String {
        switch self {
        case .free: "Seitenmitten ziehen Breite bzw. Höhe, Ecken beides frei."
        case .shear: "Seitenmitten ziehen den Rahmen schräg (Verzerren)."
        case .perspective: "Ecken einzeln ziehen: perspektivisch verzerren."
        case .envelope: "Vorlage wählen, Griff oben ziehen ändert die Stärke."
        case .path: "Startgriff auf der Kurve ziehen verschiebt den Text entlang des Pfads."
        case .pickPath: "Kurve oder Körperkante antippen, an der der Text entlanglaufen soll."
        }
    }
}

/// Art eines Verformungsgriffs.
enum SketchTextDeformHandleKind: Equatable {
    /// Seitenmitte: 0 links, 1 rechts, 2 unten, 3 oben
    case side(Int)
    /// Ecke: 0 links unten, 1 rechts unten, 2 rechts oben, 3 links oben
    case corner(Int)
    /// Stärke der Hülle
    case bend
    /// Anfang des Texts auf dem Pfad
    case pathStart
    /// Krümmung des Hilfsbogens (Pfad ist ein Bogen der Skizze)
    case pathArc
}

/// Ein Griff in Skizzenkoordinaten.
struct SketchTextDeformHandle {
    var kind: SketchTextDeformHandleKind
    var point: Point2
}

/// Gerechnete Lage eines Texts für die Griffe: Rahmen, Abbildung, Pfad im System des Texts.
struct SketchTextDeformGeometry {
    let text: SketchText
    let deform: SketchTextDeform
    let frame: SketchTextBox
    let deformer: SketchTextDeformMap
    let curve: SketchTextPathCurve?

    init?(_ text: SketchText) {
        let glyphs = SketchTextGlyphCache.glyphs(for: text)
        guard let frame = SketchTextBox(glyphs) else { return nil }
        self.text = text
        let deform = text.deform ?? SketchTextDeform()
        self.deform = deform
        self.frame = frame
        deformer = SketchTextDeformMap(deform: deform, frame: frame, capHeight: text.height)
        if let path = deform.path {
            let step: Double = min(max(text.height / 16, 0.02), 0.5)
            curve = SketchTextPathCurve(path, toLocal: { q in text.unplace(q) }, step: step)
        } else {
            curve = nil
        }
    }

    /// Natürlicher Rahmenpunkt (u, v je 0…1) verformt, in Skizzenkoordinaten.
    func framePoint(_ u: Double, _ v: Double) -> Point2 {
        let natural = frame.lo + frame.size * Point2(u, v)
        return text.place(deformer.point(natural))
    }

    /// Umriss des verformten Rahmens (geschlossen) in Skizzenkoordinaten.
    var outline: [Point2] {
        let steps = 24
        var points: [Point2] = []
        for k in 0..<steps { points.append(framePoint(Double(k) / Double(steps), 0)) }
        for k in 0..<steps { points.append(framePoint(1, Double(k) / Double(steps))) }
        for k in 0..<steps { points.append(framePoint(1 - Double(k) / Double(steps), 1)) }
        for k in 0...steps { points.append(framePoint(0, 1 - Double(k) / Double(steps))) }
        return points
    }

    /// Startpunkt des Texts auf dem Pfad (Skizze).
    var pathStartPoint: Point2? {
        guard let curve, let path = deform.path else { return nil }
        let s = deformer.pathStart(curve: curve, options: path)
        return text.place(curve.sample(s).point)
    }
}

/// Glyphen des zuletzt gefragten Texts (die Griffe werden je Bild gezeichnet; CoreText nicht jedes Mal fragen).
enum SketchTextGlyphCache {
    private static var key = ""
    private static var cached: [SketchTextGlyph] = []

    static func glyphs(for text: SketchText) -> [SketchTextGlyph] {
        let newKey = "\(text.string)|\(text.height)|\(text.fontName)|\(text.alignment.rawValue)"
        if newKey != key {
            cached = SketchText.localGlyphs(string: text.string, height: text.height, fontName: text.fontName,
                                            alignment: text.alignment)
            key = newKey
        }
        return cached
    }
}

extension SketchController {
    /// Laufendes Ziehen eines Verformungsgriffs (gespeichert in textDeformDrag).
    struct TextDeformDrag {
        var entity: Int
        var kind: SketchTextDeformHandleKind
        /// Aufsetzpunkt im System des Texts bzw. (Bogengriff) in der Skizze
        var startLocal: Point2
        var start: Point2
        var original: SketchText
        var hasMoved = false
        /// Gerade an einer Raststelle (Haptik nur beim Erreichen)
        var atDetent = false
        /// Nur Antippen beim Pfad wählen: der Rest der Berührung gehört niemandem (keine Auswahl beim Abheben)
        var pickOnly = false
        /// Der Schritt zum Rückgängigmachen ist angelegt (beim ersten angewandten Zug)
        var remembered = false
    }

    /// Gewählter Text, an dem Verformungsgriffe erscheinen (Pfeil-Werkzeug, Modus aktiv).
    var textDeformTarget: (index: Int, text: SketchText)? {
        guard tool == .select, pendingAction == nil, let mode = textDeformMode, mode != .pickPath,
              let index = selectedTextIndex, let text = sketchText(at: index) else { return nil }
        return (index, text)
    }

    /// Griffe des gewählten Texts im aktiven Modus.
    var textDeformHandles: [SketchTextDeformHandle] {
        guard let target = textDeformTarget, let mode = textDeformMode,
              let geometry = SketchTextDeformGeometry(target.text) else { return [] }
        var result: [SketchTextDeformHandle] = []
        let sides: [(Int, Double, Double)] = [(0, 0, 0.5), (1, 1, 0.5), (2, 0.5, 0), (3, 0.5, 1)]
        let corners: [(Int, Double, Double)] = [(0, 0, 0), (1, 1, 0), (2, 1, 1), (3, 0, 1)]
        let isOnPath = geometry.deform.path != nil
        switch mode {
        case .free where !isOnPath:
            for (k, u, v) in sides { result.append(SketchTextDeformHandle(kind: .side(k), point: geometry.framePoint(u, v))) }
            for (k, u, v) in corners { result.append(SketchTextDeformHandle(kind: .corner(k), point: geometry.framePoint(u, v))) }
        case .shear where !isOnPath:
            for (k, u, v) in sides { result.append(SketchTextDeformHandle(kind: .side(k), point: geometry.framePoint(u, v))) }
        case .perspective where !isOnPath:
            for (k, u, v) in corners { result.append(SketchTextDeformHandle(kind: .corner(k), point: geometry.framePoint(u, v))) }
        case .envelope where !isOnPath:
            result.append(SketchTextDeformHandle(kind: .bend, point: geometry.framePoint(0.5, 1)))
        case .free, .shear, .perspective, .envelope, .path:
            // Am Pfad: Startgriff, bei einem Bogen als Pfad zusätzlich die Krümmung
            if let start = geometry.pathStartPoint { result.append(SketchTextDeformHandle(kind: .pathStart, point: start)) }
            if let apex = pathArcApex(of: target.text) { result.append(SketchTextDeformHandle(kind: .pathArc, point: apex)) }
        case .pickPath:
            break
        }
        return result
    }

    /// Scheitel des Bogens, dem der Text folgt (nil, wenn der Pfad kein Bogen der Skizze ist).
    private func pathArcApex(of text: SketchText) -> Point2? {
        guard let source = text.deform?.path?.source, entities.indices.contains(source),
              case .arc = entities[source] else { return nil }
        return Self.radiusHandle(of: entities[source], index: source)?.point
    }

    /// Rahmen, Pfad und Griffe für den Viewport. unit = Weltmaß eines Bildschirmpunkts.
    func textDeformGeometry(unit: Double) -> (frame: [[Point2]], path: [[Point2]], knobs: [Point2], accents: [Point2]) {
        guard let target = textDeformTarget, let geometry = SketchTextDeformGeometry(target.text) else {
            return ([], [], [], [])
        }
        var frame: [[Point2]] = []
        var path: [[Point2]] = []
        if let curve = target.text.deform?.path {
            var line = curve.points
            if curve.closed, let first = line.first { line.append(first) }
            path.append(line)
        } else {
            frame.append(geometry.outline)
        }
        var knobs: [Point2] = []
        var accents: [Point2] = []
        for handle in textDeformHandles {
            switch handle.kind {
            case .bend, .pathStart, .pathArc:
                accents.append(handle.point)
                // Hüllengriff: kleiner Doppelpfeil nach oben und unten
                if handle.kind == .bend {
                    for sign in [1.0, -1.0] {
                        let tip: Point2 = handle.point + Point2(0, sign * 18 * unit)
                        let base: Point2 = handle.point + Point2(0, sign * 9 * unit)
                        frame.append([base, tip])
                        frame.append([tip + Point2(-4 * unit, -sign * 5 * unit), tip, tip + Point2(4 * unit, -sign * 5 * unit)])
                    }
                }
            default:
                knobs.append(handle.point)
            }
        }
        return (frame, path, knobs, accents)
    }

    // MARK: Ziehen (Haken in began/moved/ended)

    /// true, wenn p einen Verformungsgriff trifft (der Viewport beginnt dort keine Rahmenauswahl), bzw. wenn
    /// gerade ein Pfad gewählt wird (das Antippen gehört dann dem Pfad).
    func hitsTextDeformHandle(at p: Point2, tolerance: Double) -> Bool {
        if textDeformMode == .pickPath, tool == .select, selectedTextIndex != nil { return true }
        return textDeformHit(at: p, tolerance: tolerance) != nil
    }

    /// Nächster Griff unter p. Trefferbereich 14 Bildschirmpunkte um den Griff (28 pt breit, für Finger und Stift).
    private func textDeformHit(at p: Point2, tolerance: Double) -> SketchTextDeformHandle? {
        let reach: Double = tolerance * 0.7
        var best: (distance: Double, handle: SketchTextDeformHandle)?
        for handle in textDeformHandles {
            let distance: Double = simd_distance(handle.point, p)
            guard distance <= reach else { continue }
            if distance < (best?.distance ?? .infinity) { best = (distance, handle) }
        }
        return best?.handle
    }

    /// Stift bzw. Finger setzt auf: Pfad wählen oder Griff greifen. true = übernommen.
    func beginTextDeformDrag(at p: Point2, tolerance: Double) -> Bool {
        textDeformDrag = nil
        if textDeformMode == .pickPath, let index = selectedTextIndex, let text = sketchText(at: index) {
            pickTextPath(at: p, tolerance: tolerance, text: index)
            textDeformDrag = TextDeformDrag(entity: index, kind: .pathStart, startLocal: .zero, start: p, original: text,
                                            pickOnly: true)
            return true
        }
        guard let target = textDeformTarget, let handle = textDeformHit(at: p, tolerance: tolerance) else { return false }
        textDeformDrag = TextDeformDrag(entity: target.index, kind: handle.kind, startLocal: target.text.unplace(p),
                                        start: p, original: target.text)
        return true
    }

    func moveTextDeformDrag(to p: Point2, tolerance: Double) -> Bool {
        guard var drag = textDeformDrag else { return false }
        if drag.pickOnly { return true }
        if !drag.hasMoved {
            // Kleines Zittern beim Tippen ist noch kein Ziehen
            guard simd_distance(p, drag.start) > tolerance * 0.15 else { return true }
        }
        drag.hasMoved = true
        applyTextDeformDrag(&drag, at: p, tolerance: tolerance, final: false)
        textDeformDrag = drag
        return true
    }

    func endTextDeformDrag(at p: Point2, tolerance: Double) -> Bool {
        guard var drag = textDeformDrag else { return false }
        if drag.hasMoved, !drag.pickOnly {
            applyTextDeformDrag(&drag, at: p, tolerance: tolerance, final: true)
        }
        textDeformDrag = nil
        return true
    }

    /// Berührung abgebrochen: bis dahin Gezogenes bleibt (ein Rückgängig-Schritt), Bereiche neu aufbauen.
    func cancelTextDeformDrag() {
        guard let drag = textDeformDrag else { return }
        textDeformDrag = nil
        guard drag.hasMoved, !drag.pickOnly, entities.indices.contains(drag.entity) else { return }
        setDraggedElement(entities[drag.entity], at: drag.entity, begin: false, final: true)
    }

    /// Neue Verformung aus dem Zug berechnen und anwenden.
    private func applyTextDeformDrag(_ drag: inout TextDeformDrag, at p: Point2, tolerance: Double, final: Bool) {
        let original = drag.original
        guard let geometry = SketchTextDeformGeometry(original) else { return }
        let delta: Point2 = original.unplace(p) - drag.startLocal
        var deform = geometry.deform
        var detent = false
        let frame = geometry.frame
        let lo: Point2 = frame.lo + deform.shift
        let size: Point2 = frame.size * deform.stretch
        switch drag.kind {
        case .side(let k) where textDeformMode == .shear:
            switch k {
            case 3: deform.shear.x += delta.x / max(size.y, 1e-6)
            case 2:
                deform.shear.x -= delta.x / max(size.y, 1e-6)
                deform.shift.x += delta.x
            case 1: deform.shear.y += delta.y / max(size.x, 1e-6)
            default:
                deform.shear.y -= delta.y / max(size.x, 1e-6)
                deform.shift.y += delta.y
            }
            // Raste: wieder gerade (2 % Neigung); unten bzw. links gezogen bleibt die Gegenkante stehen
            if k >= 2, abs(deform.shear.x) < 0.02 {
                if k == 2 { deform.shift.x += deform.shear.x * size.y }
                deform.shear.x = 0
                detent = true
            }
            if k < 2, abs(deform.shear.y) < 0.02 {
                if k == 0 { deform.shift.y += deform.shear.y * size.x }
                deform.shear.y = 0
                detent = true
            }
        case .side(let k):
            let edges = Self.stretchedEdges(lo: lo, size: size, delta: delta, left: k == 0, right: k == 1,
                                            bottom: k == 2, top: k == 3, minimum: frame.size * 0.05)
            deform.shift = edges.lo - frame.lo
            deform.stretch = edges.size / frame.size
            detent = Self.snapStretch(&deform, frame: frame, tolerance: tolerance)
        case .corner(let k) where textDeformMode == .perspective:
            var corners = deform.cornerOffsets
            corners[k] += delta
            // Raste: Ecke wieder am Rahmen
            if simd_length(corners[k]) < tolerance * 0.3 {
                corners[k] = .zero
                detent = true
            }
            deform.corners = corners
        case .corner(let k):
            let edges = Self.stretchedEdges(lo: lo, size: size, delta: delta, left: k == 0 || k == 3,
                                            right: k == 1 || k == 2, bottom: k == 0 || k == 1, top: k == 2 || k == 3,
                                            minimum: frame.size * 0.05)
            deform.shift = edges.lo - frame.lo
            deform.stretch = edges.size / frame.size
            detent = Self.snapStretch(&deform, frame: frame, tolerance: tolerance)
        case .bend:
            var warp = deform.warp ?? SketchTextWarp(style: .arc, bend: 0)
            warp.bend = max(-1, min(1, warp.bend + delta.y / max(2 * size.y, 1e-6)))
            if abs(warp.bend) < 0.03 {
                warp.bend = 0
                detent = true
            }
            deform.warp = warp
        case .pathStart:
            guard var path = deform.path, let curve = geometry.curve else { return }
            let from: Double = curve.arcLength(nearest: drag.startLocal)
            let to: Double = curve.arcLength(nearest: original.unplace(p))
            var step: Double = to - from
            if curve.closed, curve.length > 0 { step = remainder(step, curve.length) }
            path.offset += step
            // Raste: zurück auf den ausgerichteten Anfang
            if abs(path.offset) < tolerance * 0.3 {
                path.offset = 0
                detent = true
            }
            deform.path = path
        case .pathArc:
            if dragPathArc(drag, to: p, begin: !drag.remembered, final: final) { drag.remembered = true }
            return
        }
        if detent, !drag.atDetent, snapHaptics { UISelectionFeedbackGenerator().selectionChanged() }
        drag.atDetent = detent
        let changed = original.with(deform: .some(deform))
        guard !changed.loops.isEmpty else { return }
        setDraggedElement(.text(changed), at: drag.entity, begin: !drag.remembered, final: final)
        drag.remembered = true
    }

    /// Rahmenkanten nach dem Ziehen: gezogene Seiten folgen delta, die Gegenseite bleibt stehen.
    private static func stretchedEdges(lo: Point2, size: Point2, delta: Point2, left: Bool, right: Bool, bottom: Bool,
                                       top: Bool, minimum: Point2) -> (lo: Point2, size: Point2) {
        var low = lo
        var high = lo + size
        if left { low.x = min(low.x + delta.x, high.x - minimum.x) }
        if right { high.x = max(high.x + delta.x, low.x + minimum.x) }
        if bottom { low.y = min(low.y + delta.y, high.y - minimum.y) }
        if top { high.y = max(high.y + delta.y, low.y + minimum.y) }
        return (low, high - low)
    }

    /// Raste bei 100 % Breite bzw. Höhe (wenige Bildschirmpunkte).
    private static func snapStretch(_ deform: inout SketchTextDeform, frame: SketchTextBox, tolerance: Double) -> Bool {
        var snapped = false
        let reach: Double = tolerance * 0.25
        for axis in 0..<2 {
            let natural: Double = frame.size[axis]
            guard natural > 1e-9 else { continue }
            if abs(deform.stretch[axis] - 1) * natural < reach, deform.stretch[axis] != 1 {
                deform.stretch[axis] = 1
                snapped = true
            }
        }
        return snapped
    }

    /// Hilfsbogen krümmen: Scheitel folgt dem Stift senkrecht zur Sehne; der Text zieht sofort mit.
    @discardableResult
    private func dragPathArc(_ drag: TextDeformDrag, to p: Point2, begin: Bool, final: Bool) -> Bool {
        guard let source = drag.original.deform?.path?.source, entities.indices.contains(source),
              case .arc(let a, _, let b) = entities[source] else { return false }
        let chord: Point2 = b - a
        let length: Double = simd_length(chord)
        guard length > 1e-9 else { return false }
        let normal = Point2(-chord.y, chord.x) / length
        let middle: Point2 = (a + b) / 2
        var sagitta: Double = simd_dot(p - middle, normal)
        // Nie ganz gerade (sonst kein Bogen) und höchstens ein Halbkreis
        let least: Double = length * 0.01
        if abs(sagitta) < least { sagitta = sagitta < 0 ? -least : least }
        sagitta = max(-length / 2, min(length / 2, sagitta))
        let arc = SketchEntity.arc(start: a, mid: middle + normal * sagitta, end: b)
        // Text folgt dem Bogen schon beim Ziehen (setDraggedElement gleicht Text am Pfad ab)
        setDraggedElement(arc, at: source, begin: begin, final: final)
        return true
    }

    // MARK: Pfad

    /// Kurve unter p als Pfad des Texts übernehmen: Skizzenkurve (folgt ihr bei Änderungen) bzw. projizierte
    /// Körperkante (fester Linienzug).
    private func pickTextPath(at p: Point2, tolerance: Double, text index: Int) {
        if let ref = pick(at: p, tolerance: tolerance), ref.entity != index, entities.indices.contains(ref.entity),
           let curve = SketchTextPath.curve(of: entities[ref.entity]) {
            setTextPath(at: index, points: curve.points, closed: curve.closed, source: ref.entity)
            return
        }
        var best: (distance: Double, curve: [Point2])?
        for guide in modelGuides.curves where guide.count >= 2 {
            let distance: Double = polylineDistance(from: p, to: guide, closed: false).distance
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (distance, guide) }
        }
        if let best, let first = best.curve.first, let last = best.curve.last {
            let closed: Bool = best.curve.count > 2 && simd_distance(first, last) < 1e-6
            let points: [Point2] = closed ? Array(best.curve.dropLast()) : best.curve
            setTextPath(at: index, points: points, closed: closed, source: nil)
            return
        }
        notice = "Keine Kurve getroffen – Linie, Bogen, Kreis, Spline, Linienzug oder Körperkante antippen."
    }

    /// Text an eine Kurve legen (ein Schritt zum Rückgängigmachen). Offene Kurven, die im Text von rechts nach
    /// links laufen, werden umgedreht, damit die Schrift lesbar bleibt.
    func setTextPath(at index: Int, points: [Point2], closed: Bool, source: Int?) {
        guard let text = sketchText(at: index), points.count >= 2 else { return }
        var deform = text.deform ?? SketchTextDeform()
        var path = SketchTextPath(points: points, closed: closed, source: source)
        path.sourceCount = entities.count
        path.alignment = .center
        if !closed, let first = points.first, let last = points.last {
            path.reversed = text.unplace(last).x < text.unplace(first).x
        }
        deform.path = path
        // Hülle und Perspektive gelten am Pfad nicht
        deform.warp = nil
        deform.corners = nil
        let changed = text.with(deform: .some(deform))
        guard !changed.loops.isEmpty else { return }
        replaceText(at: index, with: changed)
        textDeformMode = .path
        notice = source == nil ? "Text folgt der Körperkante." : "Text folgt der Kurve – Startgriff verschiebt ihn."
    }

    /// Bogen-Vorlage: Hilfsbogen (Konstruktion) über dem gewählten Text anlegen und den Text daran ausrichten.
    /// Die Krümmung zieht man am Griff im Scheitel.
    func addTextArcTemplate(at index: Int) {
        guard let text = sketchText(at: index), let geometry = SketchTextDeformGeometry(text) else { return }
        let lo = geometry.deformer.stretched.lo
        let hi = geometry.deformer.stretched.hi
        let base: Double = geometry.deformer.baseline
        let width: Double = hi.x - lo.x
        let start = text.place(Point2(lo.x, base))
        let end = text.place(Point2(hi.x, base))
        let mid = text.place(Point2((lo.x + hi.x) / 2, base + width * 0.25))
        let wasConstruction = constructionMode
        constructionMode = true
        appendEntity(.arc(start: start, mid: mid, end: end))
        constructionMode = wasConstruction
        let arcIndex = entities.count - 1
        guard sketchText(at: index) != nil, let curve = SketchTextPath.curve(of: entities[arcIndex]) else { return }
        selectText(at: index)
        setTextPath(at: index, points: curve.points, closed: curve.closed, source: arcIndex)
        notice = "Hilfsbogen angelegt – Griff im Scheitel zieht die Krümmung."
    }

    /// Pfad ändern (Optionen der Leiste), ein Schritt zum Rückgängigmachen.
    func updateTextPath(at index: Int, _ change: (inout SketchTextPath) -> Void) {
        guard let text = sketchText(at: index), var deform = text.deform, var path = deform.path else { return }
        change(&path)
        deform.path = path
        updateText(at: index) { $0.with(deform: .some(deform)) }
    }

    /// Verformung ändern (Leiste), ein Schritt zum Rückgängigmachen.
    func updateTextDeform(at index: Int, _ change: (inout SketchTextDeform) -> Void) {
        guard let text = sketchText(at: index) else { return }
        var deform = text.deform ?? SketchTextDeform()
        change(&deform)
        updateText(at: index) { $0.with(deform: .some(deform)) }
    }

    /// Texte, deren Pfad einer geänderten Skizzenkurve folgen muss (Haken in entitiesChanged und beim Ziehen).
    /// Der Index der Quelle bleibt beim Löschen und Ersetzen von Elementen gültig (removeEntities schreibt ihn um,
    /// SketchTextPathLink.swift); ist die Kurve weg bzw. keine Kurve mehr, bleibt der Text, wo er ist.
    func textPathUpdates() -> [(index: Int, entity: SketchEntity)] {
        var updates: [(index: Int, entity: SketchEntity)] = []
        for index in entities.indices {
            guard case .text(let text) = entities[index], var deform = text.deform, var path = deform.path,
                  let source = path.source else { continue }
            let curve = entities.indices.contains(source) && source != index
                ? SketchTextPath.curve(of: entities[source]) : nil
            if let curve {
                let moved: Bool = !Self.samePath(curve.points, path.points) || curve.closed != path.closed
                if !moved { continue }
                path.points = curve.points
                path.closed = curve.closed
                path.sourceCount = entities.count
            } else {
                // Kurve weg: Pfad als feste Kurve behalten
                path.source = nil
                path.sourceCount = nil
            }
            deform.path = path
            let changed = text.with(deform: .some(deform))
            if !changed.loops.isEmpty { updates.append((index, .text(changed))) }
        }
        return updates
    }

    private static func samePath(_ a: [Point2], _ b: [Point2]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where simd_distance(a[i], b[i]) > 1e-9 { return false }
        return true
    }
}
