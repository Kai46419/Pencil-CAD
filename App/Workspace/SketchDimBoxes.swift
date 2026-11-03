import Foundation
import simd

// Wertfelder beim Zeichnen nach SolidCraft (MIT OR Apache-2.0, crates/ui-egui/src/sketch_dims.rs): Jede Stufe der
// Klickfolge zeigt ihre Maße direkt an der Vorschau (Länge und Winkel der Linie, Breite und Höhe des Rechtecks,
// Durchmesser, Radius, Bogenwinkel …). Ein getippter Wert sperrt das Maß – der Stift bestimmt dann nur noch den Rest –,
// Enter setzt den Punkt mit den gesperrten Werten. Die Felder sind die vorhandenen Maßfelder des Viewports
// (Kennung „box-<Schlüssel>“, Ziel `.live`), die Schlüssel dieselben wie in `SketchToolOptions.locked`.

extension SketchController {
    /// Maße der Wertfelder an der Vorschau der aktuellen Stufe.
    var liveDimensions: [SketchDimension] {
        guard let kind = clickKind, let a = click.points.last?.point else { return [] }
        let first = click.points.first?.point ?? a
        let h = click.pointer ?? a
        let values = Dictionary(clickLiveValues.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        var result: [SketchDimension] = []
        for key in clickBoxKeys {
            guard let value = values[key],
                  var dimension = liveDimension(key, kind: kind, value: value, first: first, a: a, h: h) else { continue }
            dimension.isEditable = true
            dimension.lockState = lockedValue(key) != nil
            result.append(dimension.tagged("box-\(key)", .live(key)))
        }
        return result
    }

    /// Lage eines Wertfelds (Maßlinie bzw. Winkelbogen wie bei den übrigen Maßen).
    private func liveDimension(_ key: String, kind: SketchClickKind, value: Double, first: Point2, a: Point2,
                               h: Point2) -> SketchDimension? {
        let v = h - a
        switch key {
        case "Länge":
            var from = a
            if kind == .slot, slotMode == .centerPoint { from = a - v }
            return Self.linearBox(.length, value: value, from, h)
        case "Winkel":
            // Winkel zur Waagerechten mit Vorzeichen (−180…180°): eine Linie schräg nach unten zeigt −30° mit kleinem
            // Bogen im Uhrzeigersinn statt 330° mit fast vollem Kreis. Bogen und Feld legt der Viewport in festem
            // Bildschirmabstand an (dimensionGeometry), unabhängig von der Linienlänge.
            guard simd_length(v) > 1e-9 else { return nil }
            let sweep = atan2(v.y, v.x)
            var degrees = value.truncatingRemainder(dividingBy: 360)
            if degrees > 180 { degrees -= 360 }
            if degrees <= -180 { degrees += 360 }
            let bisector = Point2(cos(sweep / 2), sin(sweep / 2))
            var dimension = SketchDimension(kind: .angle, value: degrees, position: a + bisector,
                                            direction: bisector, isEditable: true, span: [a, h])
            dimension.reference = Point2(1, 0)
            dimension.sweep = sweep
            return dimension
        case "Breite" where kind == .slot:
            let along = first - a
            guard simd_length(along) > 1e-9 else { return nil }
            let u = simd_normalize(along)
            let n = Point2(-u.y, u.x)
            let middle = (first + a) / 2
            let half = value / 2
            var dimension = SketchDimension(kind: .width, value: value, position: middle, direction: u,
                                            isEditable: true, span: [middle - n * half, middle + n * half])
            dimension.direction = u
            return dimension
        case "Breite", "Höhe":
            let box = rectangleBox(a, h)
            guard let box else { return nil }
            if key == "Breite" {
                return SketchDimension(kind: .width, value: value, position: Point2((box.lo.x + box.hi.x) / 2, box.lo.y),
                                       direction: Point2(0, -1), isEditable: true,
                                       span: [box.lo, Point2(box.hi.x, box.lo.y)])
            }
            return SketchDimension(kind: .height, value: value, position: Point2(box.hi.x, (box.lo.y + box.hi.y) / 2),
                                   direction: Point2(1, 0), isEditable: true, span: [Point2(box.hi.x, box.lo.y), box.hi])
        case "Durchmesser":
            let center = circleMode == .twoPoint ? (a + h) / 2 : a
            let radius = circleMode == .twoPoint ? simd_length(v) / 2 : simd_length(v)
            guard radius > 1e-9 else { return nil }
            let d = Point2(1, 1) / 2.0.squareRoot()
            return SketchDimension(kind: .diameter, value: value, position: center + d * radius, direction: d,
                                   isEditable: true, span: [center - d * radius, center + d * radius])
        case "Radius" where kind == .rectangle:
            guard let box = rectangleBox(a, h) else { return nil }
            let d = Point2(1, 1) / 2.0.squareRoot()
            return SketchDimension(kind: .radius, value: value, position: box.hi, direction: d, isEditable: true)
        case "Radius":
            guard simd_length(v) > 1e-9 else { return nil }
            return SketchDimension(kind: .radius, value: value, position: h, direction: simd_normalize(v),
                                   isEditable: true, span: [a, h])
        case "Bogenwinkel":
            let radial = a - first
            let r = simd_length(radial)
            guard r > 1e-9 else { return nil }
            let a0 = atan2(radial.y, radial.x)
            let sweep = value * .pi / 180
            let half = a0 + sweep / 2
            let bisector = Point2(cos(half), sin(half))
            var dimension = SketchDimension(kind: .angle, value: value, position: first + bisector,
                                            direction: bisector, isEditable: true, span: [first, a])
            dimension.reference = radial / r
            dimension.sweep = sweep
            return dimension
        default:
            return nil
        }
    }

    /// Längenmaß zwischen zwei Punkten, Maßlinie auf der oberen bzw. rechten Seite.
    private static func linearBox(_ kind: SketchDimension.Kind, value: Double, _ a: Point2, _ b: Point2) -> SketchDimension? {
        guard simd_distance(a, b) > 1e-9 else { return nil }
        var normal = rightNormal(b - a)
        if normal.y < 0 || (normal.y == 0 && normal.x < 0) { normal = -normal }
        return SketchDimension(kind: kind, value: value, position: (a + b) / 2, direction: normal, isEditable: true,
                               span: [a, b])
    }

    /// Ecken des Rechtecks der Vorschau (von der Mitte bzw. diagonal).
    private func rectangleBox(_ a: Point2, _ h: Point2) -> (lo: Point2, hi: Point2)? {
        let p = rectangleMode == .center ? a - (h - a) : a
        let lo = simd_min(p, h), hi = simd_max(p, h)
        guard hi.x - lo.x > 1e-9, hi.y - lo.y > 1e-9 else { return nil }
        return (lo, hi)
    }

    // MARK: Sperren

    /// Getippten Wert eines Felds sperren (leer = wieder frei). Längen in der Projekteinheit bzw. mit Einheit,
    /// Winkel in Grad (Bogenwinkel mit Vorzeichen), Formeln mit Projektvariablen erlaubt.
    func lockLiveValue(_ key: String, text: String, variables: [String: Double]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        variableValues = variables
        guard !trimmed.isEmpty else {
            options.locked[key] = nil
            refreshLockedPreview()
            return
        }
        let value: Double
        do {
            switch key {
            case "Winkel", "Bogenwinkel", "Seiten":
                value = try Formula.evaluate(trimmed, variables: variables)
            default:
                value = try Formula.evaluateLength(trimmed, variables: variables)
            }
        } catch {
            notice = "Formel „\(trimmed)“: \(error.localizedDescription)"
            return
        }
        switch key {
        case "Winkel":
            break
        case "Bogenwinkel":
            guard abs(value) > 1e-6, abs(value) < 360 else {
                notice = "Bogenwinkel zwischen −360° und 360°, nicht 0."
                return
            }
        case "Seiten":
            guard value >= 3, value <= 64 else {
                notice = "Ein Polygon hat 3 bis 64 Seiten."
                return
            }
        default:
            guard value > 0 else {
                notice = "Der Wert muss größer als 0 sein."
                return
            }
        }
        options.locked[key] = trimmed
        notice = nil
        refreshLockedPreview()
    }

    /// Schloss am Wertfeld: gesperrt → frei, frei → aktuellen Wert sperren.
    func toggleLiveLock(_ key: String, current: Double) {
        if options.locked[key] != nil {
            options.locked[key] = nil
        } else {
            options.locked[key] = Self.liveText(current, key: key)
        }
        refreshLockedPreview()
    }

    /// Vorschau sofort mit den gesperrten Werten zeigen, auch wenn der Stift gerade nicht schwebt.
    private func refreshLockedPreview() {
        if let base = click.raw ?? click.pointer, !click.points.isEmpty {
            let p = clickEffective(base, axisLimit: snapMetrics(click.mmPerPoint * 20).axisSnap)
            var hover = click.hover ?? SnapCandidate.free(p)
            hover.point = p
            hover.target = nil
            hover.guide = nil
            hover.label = ""
            click.hover = hover
            click.pointer = p
        }
        changed()
    }
}
