import Foundation
import simd
import UIKit

// Technische Zeichnung (Fahrplan Nr. 24): Standardansichten der Körper mit verdeckten Kanten (gestrichelt),
// Gesamtmaßen und Schriftfeld auf A4 quer, als PDF und DXF. Alle Blattkoordinaten in mm, y nach oben,
// Ursprung links unten.

/// Ansichtsrichtung einer Normansicht.
enum DrawingView: String, CaseIterable, Identifiable {
    case front = "Vorderansicht"
    case top = "Draufsicht"
    case left = "Seitenansicht von links"
    case right = "Seitenansicht von rechts"
    case iso = "Isometrie"

    var id: Self { self }

    /// Richtung vom Modell zum Betrachter (Z oben, Vorderseite zeigt nach −Y)
    var toEye: SIMD3<Double> {
        switch self {
        case .front: [0, -1, 0]
        case .top: [0, 0, 1]
        case .left: [-1, 0, 0]
        case .right: [1, 0, 0]
        case .iso: simd_normalize(SIMD3<Double>(1, -1, 1))
        }
    }

    /// Rechtsrichtung der Ansicht; oben ist toEye × xAxis.
    var xAxis: SIMD3<Double> {
        switch self {
        case .front, .top: [1, 0, 0]
        case .left: [0, -1, 0]
        case .right: [0, 1, 0]
        case .iso: simd_normalize(SIMD3<Double>(1, 1, 0))
        }
    }

    var yAxis: SIMD3<Double> { simd_cross(toEye, xAxis) }
}

/// Anordnung der Ansichten nach DIN ISO 128 bzw. ISO 5456-2.
enum ProjectionMethod: String, CaseIterable, Identifiable {
    /// Europa: Draufsicht unter, Seitenansicht von links rechts neben der Vorderansicht
    case first = "Methode 1 (Europa)"
    /// Amerika: Draufsicht über, Seitenansicht von rechts rechts neben der Vorderansicht
    case third = "Methode 3 (Amerika)"

    var id: Self { self }

    var sideView: DrawingView { self == .first ? .left : .right }
}

/// Eine Ansicht als 2D-Linienzüge in Modell-mm (Ansichtsebene).
struct DrawingProjection {
    var visible: [[Point2]] = []
    var hidden: [[Point2]] = []
    /// true = exakt mit OpenCASCADE (HLR), false = angenähert aus dem Anzeige-Netz
    var exact = false
    /// false = Verdeckung nicht geprüft (zu viele Dreiecke), alles durchgezogen
    var occlusionChecked = true

    var bounds: (min: Point2, max: Point2)? {
        let points = Array(visible.joined()) + Array(hidden.joined())
        guard let first = points.first else { return nil }
        return points.reduce((min: first, max: first)) { (min: simd_min($0.min, $1), max: simd_max($0.max, $1)) }
    }
}

/// Linienart auf dem Blatt.
enum DrawingPen {
    case visible, hidden, dimension, frame, thin

    /// Strichstärke in mm (DIN ISO 128: breit 0,5, schmal 0,25)
    var width: Double {
        switch self {
        case .visible: 0.5
        case .frame: 0.7
        case .hidden, .dimension, .thin: 0.25
        }
    }

    var dxfLayer: String {
        switch self {
        case .visible: "SICHTBAR"
        case .hidden: "VERDECKT"
        case .dimension: "BEMASSUNG"
        case .frame, .thin: "RAHMEN"
        }
    }
}

/// Grundelement des Blatts.
enum DrawingElement {
    case polyline([Point2], DrawingPen)
    /// Gefüllte Maßpfeilspitze: Spitze und Richtung, in die sie zeigt
    case arrow(tip: Point2, direction: Point2)
    /// Text: Grundlinie links (bzw. Mitte bei centered), Schrifthöhe in mm, Drehung in Grad
    case text(String, at: Point2, height: Double, rotation: Double = 0, centered: Bool = false, bold: Bool = false)
}

/// Einstellungen der Zeichnung.
struct DrawingOptions: Equatable {
    var method: ProjectionMethod = .first
    var showsIso = true
    var showsHidden = true
    /// Nur die gewählten Körper (sonst alle sichtbaren)
    var onlySelection = true
}

/// Fertig angeordnetes Blatt.
struct DrawingLayout {
    var elements: [DrawingElement] = []
    var scaleText = "1:1"
    var approximate = false
}

enum TechnicalDrawing {
    static let sheetWidth = 297.0
    static let sheetHeight = 210.0
    /// Zeichenrahmen (links 20 mm Heftrand)
    static let frameMin = Point2(20, 10)
    static let frameMax = Point2(287, 200)
    /// Schriftfeld rechts unten
    static let titleMin = Point2(167, 10)
    static let titleMax = Point2(287, 42)

    // MARK: Ansichten berechnen

    /// Ansicht der Körper: exakt per OpenCASCADE (verdeckte Kanten), sonst angenähert aus dem Netz.
    static func project(_ shapes: [PCKShape], view: DrawingView) -> DrawingProjection {
        if let data = PCKShape.hiddenLineView(shapes, toEye: view.toEye, xAxis: view.xAxis, deflection: 0.02),
           data.count == 2 {
            var projection = DrawingProjection(visible: chain(doubles(data[0])), hidden: chain(doubles(data[1])))
            projection.exact = true
            if projection.bounds != nil { return projection }
        }
        return meshProjection(shapes, view: view)
    }

    private static func doubles(_ data: Data) -> [Double] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }

    /// Punktpaare (x1, y1, x2, y2 …) zu Linienzügen verketten, damit Strichlinien durchlaufen.
    private static func chain(_ values: [Double]) -> [[Point2]] {
        var result: [[Point2]] = []
        var i = 0
        while i + 3 < values.count {
            let a = Point2(values[i], values[i + 1]), b = Point2(values[i + 2], values[i + 3])
            i += 4
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { continue }
            if let last = result.last?.last, simd_distance(last, a) < 1e-9 {
                result[result.count - 1].append(b)
            } else {
                result.append([a, b])
            }
        }
        return result
    }

    /// Ersatz ohne HLR: Netzkanten projizieren; verdeckt ist ein Stück, wenn der Strahl zum Betrachter
    /// einen Körper trifft (Prüfung je Teilstück, daher nur angenähert).
    private static func meshProjection(_ shapes: [PCKShape], view: DrawingView) -> DrawingProjection {
        var mesh = Mesh()
        for (index, shape) in shapes.enumerated() {
            mesh.append(Mesh(shape.triangulate(deflection: 0.05), body: index))
        }
        var projection = DrawingProjection()
        guard let box = mesh.bounds else { return projection }
        let size = Double(simd_length(box.max - box.min))
        let x = view.xAxis, y = view.yAxis
        func flat(_ p: SIMD3<Float>) -> Point2 {
            let d = SIMD3<Double>(p)
            return Point2(simd_dot(d, x), simd_dot(d, y))
        }
        let toEye = SIMD3<Float>(view.toEye)
        let offset = Float(max(size * 1e-4, 1e-4))
        let pieceLength = max(size / 60, 1e-3)
        var pieces = 0
        for i in stride(from: 0, to: mesh.edges.count - 1, by: 2) {
            let length = Double(simd_distance(mesh.edges[i], mesh.edges[i + 1]))
            pieces += min(8, max(1, Int((length / pieceLength).rounded(.up))))
        }
        // Aufwand begrenzen: Strahltest prüft alle Dreiecke
        let checks = pieces * mesh.triangleCount <= 40_000_000
        projection.occlusionChecked = checks
        func isHidden(_ p: SIMD3<Float>) -> Bool {
            checks && mesh.pick(origin: p + toEye * offset, direction: toEye) != nil
        }
        for i in stride(from: 0, to: mesh.edges.count - 1, by: 2) {
            let a = mesh.edges[i], b = mesh.edges[i + 1]
            let length = Double(simd_distance(a, b))
            let count = min(8, max(1, Int((length / pieceLength).rounded(.up))))
            for k in 0..<count {
                let p = a + (b - a) * (Float(k) / Float(count))
                let q = a + (b - a) * (Float(k + 1) / Float(count))
                let segment = [flat(p), flat(q)]
                if isHidden((p + q) / 2) {
                    projection.hidden.append(segment)
                } else {
                    projection.visible.append(segment)
                }
            }
        }
        projection.visible = merged(projection.visible)
        projection.hidden = merged(projection.hidden)
        return projection
    }

    /// Aneinanderstoßende Stücke wieder zu Linienzügen verbinden.
    private static func merged(_ segments: [[Point2]]) -> [[Point2]] {
        var result: [[Point2]] = []
        for segment in segments {
            if let last = result.last?.last, let first = segment.first, simd_distance(last, first) < 1e-9 {
                result[result.count - 1] += segment.dropFirst()
            } else {
                result.append(segment)
            }
        }
        return result
    }

    // MARK: Blatt anordnen

    /// Normmaßstäbe (DIN ISO 5455), größter zuerst.
    private static let scales: [Double] = [10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001]

    private static func standardScale(atMost limit: Double) -> Double {
        scales.first { $0 <= limit * (1 + 1e-9) } ?? limit
    }

    static func scaleText(_ s: Double) -> String {
        s >= 1 ? "\(Int(s.rounded())):1" : "1:\(Int((1 / s).rounded()))"
    }

    /// Maßzahl mit Komma, ohne überflüssige Nullen.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }

    static func layout(_ projections: [DrawingView: DrawingProjection], options: DrawingOptions,
                       title: String, subtitle: String?, date: Date = Date()) -> DrawingLayout {
        var out = DrawingLayout()
        let sideView = options.method.sideView
        out.approximate = [DrawingView.front, .top, sideView].contains { projections[$0]?.exact == false }

        // Rahmen und Schriftfeld
        rectangle(frameMin, frameMax, pen: .frame, into: &out.elements)

        guard let front = projections[.front]?.bounds, let top = projections[.top]?.bounds,
              let side = projections[sideView]?.bounds else {
            titleBlock(title: title, subtitle: subtitle, scale: "–", method: options.method, date: date,
                       into: &out.elements)
            out.elements.append(.text("Keine Körper für die Zeichnung", at: Point2(153.5, 120), height: 5, centered: true))
            return out
        }
        let width = front.max.x - front.min.x
        let height = front.max.y - front.min.y
        let depth = top.max.y - top.min.y

        // Maßstab: drei Ansichten mit Platz für Maße in den Bereich über dem Schriftfeld
        let areaMin = Point2(frameMin.x, titleMax.y), areaMax = frameMax
        let areaWidth = areaMax.x - areaMin.x, areaHeight = areaMax.y - areaMin.y
        let margin = 18.0
        let limit = min((areaWidth - 3 * margin) / max(width + depth, 1e-6),
                        (areaHeight - 3 * margin) / max(height + depth, 1e-6))
        let s = standardScale(atMost: max(limit, 1e-6))
        out.scaleText = scaleText(s)

        // Gleichmäßige Abstände; Spalten und Zeilen sorgen für die Projektionsbeziehung
        let gapX = (areaWidth - s * (width + depth)) / 3
        let gapY = (areaHeight - s * (height + depth)) / 3
        let column1 = areaMin.x + gapX
        let column2 = column1 + s * width + gapX
        let lowerHeight = options.method == .first ? depth : height
        let lowerRow = areaMin.y + gapY
        let upperRow = lowerRow + s * lowerHeight + gapY

        let frontOrigin = Point2(column1, options.method == .first ? upperRow : lowerRow)
        let topOrigin = Point2(column1, options.method == .first ? lowerRow : upperRow)
        let sideOrigin = Point2(column2, frontOrigin.y)

        func place(_ view: DrawingView, at origin: Point2, scale: Double, bounds: (min: Point2, max: Point2)) {
            guard let projection = projections[view] else { return }
            let map = { (p: Point2) in origin + (p - bounds.min) * scale }
            if options.showsHidden {
                for line in projection.hidden { out.elements.append(.polyline(line.map(map), .hidden)) }
            }
            for line in projection.visible { out.elements.append(.polyline(line.map(map), .visible)) }
        }
        place(.front, at: frontOrigin, scale: s, bounds: front)
        place(.top, at: topOrigin, scale: s, bounds: top)
        place(sideView, at: sideOrigin, scale: s, bounds: side)

        // Gesamtmaße außen: Höhe links der Vorderansicht, Tiefe links der Draufsicht, Breite unter der unteren Ansicht
        let lowerOrigin = options.method == .first ? topOrigin : frontOrigin
        if width > 1e-6 {
            horizontalDimension(from: lowerOrigin.x, to: lowerOrigin.x + s * width, edge: lowerOrigin.y,
                                at: lowerOrigin.y - 9, value: width, into: &out.elements)
        }
        if height > 1e-6 {
            verticalDimension(from: frontOrigin.y, to: frontOrigin.y + s * height, edge: frontOrigin.x,
                              at: frontOrigin.x - 9, value: height, into: &out.elements)
        }
        if depth > 1e-6 {
            verticalDimension(from: topOrigin.y, to: topOrigin.y + s * depth, edge: topOrigin.x,
                              at: topOrigin.x - 9, value: depth, into: &out.elements)
        }

        // Ansichtsnamen klein über den Ansichten
        func label(_ text: String, origin: Point2, viewHeight: Double) {
            out.elements.append(.text(text, at: Point2(origin.x, origin.y + viewHeight + 3), height: 2.5))
        }
        label(DrawingView.front.rawValue, origin: frontOrigin, viewHeight: s * height)
        label(DrawingView.top.rawValue, origin: topOrigin, viewHeight: s * depth)
        label(sideView.rawValue, origin: sideOrigin, viewHeight: s * height)

        // Isometrie im freien Feld, eigener Maßstab
        if options.showsIso, let iso = projections[.iso]?.bounds {
            let isoWidth = iso.max.x - iso.min.x, isoHeight = iso.max.y - iso.min.y
            let boxMin: Point2, boxMax: Point2
            if options.method == .first {
                boxMin = Point2(column2 - gapX / 2, areaMin.y + 4)
                boxMax = Point2(areaMax.x - 4, upperRow - gapY / 2)
            } else {
                boxMin = Point2(column2 - gapX / 2, upperRow - gapY / 2)
                boxMax = Point2(areaMax.x - 4, areaMax.y - 4)
            }
            let fit = min((boxMax.x - boxMin.x - 4) / max(isoWidth, 1e-6), (boxMax.y - boxMin.y - 10) / max(isoHeight, 1e-6))
            if fit > 0 {
                let isoScale = standardScale(atMost: fit)
                let origin = Point2((boxMin.x + boxMax.x - isoScale * isoWidth) / 2,
                                    (boxMin.y + boxMax.y - 6 - isoScale * isoHeight) / 2)
                place(.iso, at: origin, scale: isoScale, bounds: iso)
                label("\(DrawingView.iso.rawValue) (\(scaleText(isoScale)))", origin: origin, viewHeight: isoScale * isoHeight)
            }
        }

        titleBlock(title: title, subtitle: subtitle, scale: out.scaleText, method: options.method, date: date,
                   into: &out.elements)
        return out
    }

    private static func rectangle(_ a: Point2, _ b: Point2, pen: DrawingPen, into elements: inout [DrawingElement]) {
        elements.append(.polyline([a, Point2(b.x, a.y), b, Point2(a.x, b.y), a], pen))
    }

    /// Waagerechtes Maß: Hilfslinien von der Ansichtskante (edge) bis knapp über die Maßlinie bei y = at.
    private static func horizontalDimension(from x0: Double, to x1: Double, edge: Double, at y: Double, value: Double,
                                            into elements: inout [DrawingElement]) {
        let down: Double = y < edge ? -1 : 1
        for x in [x0, x1] {
            elements.append(.polyline([Point2(x, edge + down * 1.5), Point2(x, y + down * 2)], .dimension))
        }
        appendDimensionLine(Point2(x0, y), Point2(x1, y), into: &elements)
        elements.append(.text(number(value), at: Point2((x0 + x1) / 2, y + 1), height: 3.5, centered: true))
    }

    /// Senkrechtes Maß links bzw. rechts der Ansicht; Maßzahl von rechts lesbar (um 90° gedreht).
    private static func verticalDimension(from y0: Double, to y1: Double, edge: Double, at x: Double, value: Double,
                                          into elements: inout [DrawingElement]) {
        let left: Double = x < edge ? -1 : 1
        for y in [y0, y1] {
            elements.append(.polyline([Point2(edge + left * 1.5, y), Point2(x + left * 2, y)], .dimension))
        }
        appendDimensionLine(Point2(x, y0), Point2(x, y1), into: &elements)
        elements.append(.text(number(value), at: Point2(x - 1, (y0 + y1) / 2), height: 3.5, rotation: 90, centered: true))
    }

    /// Maßlinie mit Pfeilen; bei kurzen Maßen stehen die Pfeile außen.
    private static func appendDimensionLine(_ a: Point2, _ b: Point2, into elements: inout [DrawingElement]) {
        let length = simd_distance(a, b)
        guard length > 1e-9 else { return }
        let d = (b - a) / length
        if length >= 8 {
            elements.append(.polyline([a, b], .dimension))
            elements.append(.arrow(tip: a, direction: -d))
            elements.append(.arrow(tip: b, direction: d))
        } else {
            elements.append(.polyline([a - d * 6, b + d * 6], .dimension))
            elements.append(.arrow(tip: a, direction: d))
            elements.append(.arrow(tip: b, direction: -d))
        }
    }

    /// Schriftfeld (vereinfacht nach DIN EN ISO 7200): Benennung, Maßstab, Datum, Blatt, Projektionsmethode.
    private static func titleBlock(title: String, subtitle: String?, scale: String, method: ProjectionMethod,
                                   date: Date, into elements: inout [DrawingElement]) {
        let a = titleMin, b = titleMax
        rectangle(a, b, pen: .frame, into: &elements)
        let row1 = a.y + 10, row2 = a.y + 20
        elements.append(.polyline([Point2(a.x, row2), Point2(b.x, row2)], .thin))
        elements.append(.polyline([Point2(a.x, row1), Point2(b.x, row1)], .thin))
        let column1 = a.x + 40, column2 = a.x + 80
        elements.append(.polyline([Point2(column1, a.y), Point2(column1, row2)], .thin))
        elements.append(.polyline([Point2(column2, a.y), Point2(column2, row2)], .thin))

        func field(_ label: String, _ value: String, x: Double, y: Double, height: Double = 3.5, bold: Bool = false) {
            elements.append(.text(label, at: Point2(x + 1.5, y + 6.8), height: 1.8))
            elements.append(.text(value, at: Point2(x + 1.5, y + 1.8), height: height, bold: bold))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        // Benennung über die ganze Breite (lange Namen kürzen)
        let name = title.count > 34 ? String(title.prefix(33)) + "…" : title
        elements.append(.text("Benennung", at: Point2(a.x + 1.5, b.y - 3), height: 1.8))
        elements.append(.text(name, at: Point2(a.x + 1.5, row2 + 2.2), height: 5, bold: true))
        if let subtitle, !subtitle.isEmpty {
            let text = subtitle.count > 40 ? String(subtitle.prefix(39)) + "…" : subtitle
            elements.append(.text(text, at: Point2(b.x - 1.5 - Double(min(text.count, 40)) * 1.6, b.y - 3), height: 1.8))
        }
        field("Maßstab", scale, x: a.x, y: row1, bold: true)
        field("Datum", formatter.string(from: date), x: column1, y: row1)
        field("Blatt", "A4 quer, 1/1", x: column2, y: row1)
        field("Projektion", method == .first ? "Methode 1 (E)" : "Methode 3 (A)", x: a.x, y: a.y, height: 3)
        field("Maße", "mm", x: column1, y: a.y, height: 3)
        field("Erstellt mit", "PencilCAD", x: column2, y: a.y, height: 3)
    }

    // MARK: PDF und Vorschau

    /// PDF, eine Seite A4 quer.
    static func pdfData(_ layout: DrawingLayout, title: String) -> Data {
        let k = 72 / 25.4
        let bounds = CGRect(x: 0, y: 0, width: sheetWidth * k, height: sheetHeight * k)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "PencilCAD"]
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            context.beginPage()
            draw(layout, in: context.cgContext, pointsPerMM: k)
        }
    }

    /// Vorschaubild (weißes Blatt), width in Punkten.
    static func image(_ layout: DrawingLayout, width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: width * sheetHeight / sheetWidth)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(layout, in: context.cgContext, pointsPerMM: Double(width) / sheetWidth)
        }
    }

    /// Zeichnet das Blatt in einen Kontext (UIKit-Koordinaten, y nach unten).
    static func draw(_ layout: DrawingLayout, in cg: CGContext, pointsPerMM k: Double) {
        func map(_ p: Point2) -> CGPoint { CGPoint(x: p.x * k, y: (sheetHeight - p.y) * k) }
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        let ink = UIColor.black.cgColor
        let hiddenInk = UIColor(white: 0.25, alpha: 1).cgColor
        // Linien gesammelt je Linienart (schneller, Strichmuster laufen über Linienzüge durch)
        for pen in [DrawingPen.hidden, .thin, .dimension, .frame, .visible] {
            let path = CGMutablePath()
            for case .polyline(let points, let linePen) in layout.elements where linePen == pen && points.count >= 2 {
                path.addLines(between: points.map(map))
            }
            guard !path.isEmpty else { continue }
            cg.saveGState()
            cg.setStrokeColor(pen == .hidden ? hiddenInk : ink)
            cg.setLineWidth(pen.width * k)
            if pen == .hidden { cg.setLineDash(phase: 0, lengths: [CGFloat(3 * k), CGFloat(1.5 * k)]) }
            cg.addPath(path)
            cg.strokePath()
            cg.restoreGState()
        }
        cg.setFillColor(ink)
        for case .arrow(let tip, let direction) in layout.elements {
            let length = simd_length(direction)
            guard length > 1e-12 else { continue }
            let d = direction / length, n = Point2(-d.y, d.x)
            let base = tip - d * 3
            cg.move(to: map(tip))
            cg.addLine(to: map(base + n * 0.5))
            cg.addLine(to: map(base - n * 0.5))
            cg.closePath()
            cg.fillPath()
        }
        for case .text(let string, let at, let height, let rotation, let centered, let bold) in layout.elements {
            // Versalhöhe der Systemschrift etwa 0,7 × Schriftgröße
            let font = UIFont.systemFont(ofSize: CGFloat(height * k / 0.7), weight: bold ? .semibold : .regular)
            let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: UIColor.black])
            let size = text.size()
            cg.saveGState()
            let p = map(at)
            cg.translateBy(x: p.x, y: p.y)
            cg.rotate(by: -CGFloat(rotation) * .pi / 180)
            text.draw(at: CGPoint(x: centered ? -size.width / 2 : 0, y: -font.ascender))
            cg.restoreGState()
        }
    }

    // MARK: DXF

    /// DXF R12 in Blattkoordinaten (mm), Ebenen SICHTBAR, VERDECKT (gestrichelt), BEMASSUNG, RAHMEN, TEXT.
    static func dxfData(_ layout: DrawingLayout) -> Data {
        var out = VectorFiles.DXFWriter()
        out.pair(0, "SECTION")
        out.pair(2, "HEADER")
        out.pair(9, "$ACADVER")
        out.pair(1, "AC1009")
        out.pair(9, "$INSUNITS")
        out.pair(70, "4")
        out.pair(9, "$MEASUREMENT")
        out.pair(70, "1")
        out.pair(9, "$EXTMIN")
        out.point(10, Point2(0, 0))
        out.pair(9, "$EXTMAX")
        out.point(10, Point2(sheetWidth, sheetHeight))
        out.pair(9, "$LTSCALE")
        out.number(40, 1)
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "TABLES")
        out.pair(0, "TABLE")
        out.pair(2, "LTYPE")
        out.pair(70, "2")
        out.pair(0, "LTYPE")
        out.pair(2, "CONTINUOUS")
        out.pair(70, "0")
        out.pair(3, "Solid line")
        out.pair(72, "65")
        out.pair(73, "0")
        out.number(40, 0)
        out.pair(0, "LTYPE")
        out.pair(2, "DASHED")
        out.pair(70, "0")
        out.pair(3, "__ __ __ __")
        out.pair(72, "65")
        out.pair(73, "2")
        out.number(40, 4.5)
        out.number(49, 3)
        out.number(49, -1.5)
        out.pair(0, "ENDTAB")
        let layers: [(name: String, color: String, type: String)] = [
            ("0", "7", "CONTINUOUS"), ("SICHTBAR", "7", "CONTINUOUS"), ("VERDECKT", "8", "DASHED"),
            ("BEMASSUNG", "3", "CONTINUOUS"), ("RAHMEN", "7", "CONTINUOUS"), ("TEXT", "7", "CONTINUOUS"),
        ]
        out.pair(0, "TABLE")
        out.pair(2, "LAYER")
        out.pair(70, String(layers.count))
        for layer in layers {
            out.pair(0, "LAYER")
            out.pair(2, layer.name)
            out.pair(70, "0")
            out.pair(62, layer.color)
            out.pair(6, layer.type)
        }
        out.pair(0, "ENDTAB")
        out.pair(0, "TABLE")
        out.pair(2, "STYLE")
        out.pair(70, "1")
        out.pair(0, "STYLE")
        out.pair(2, "STANDARD")
        out.pair(70, "0")
        out.number(40, 0)
        out.number(41, 1)
        out.number(50, 0)
        out.pair(71, "0")
        out.number(42, 2.5)
        out.pair(3, "txt")
        out.pair(4, "")
        out.pair(0, "ENDTAB")
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "ENTITIES")
        for element in layout.elements {
            switch element {
            case .polyline(let points, let pen):
                guard points.count >= 2 else { continue }
                let closed = points.count > 3 && simd_distance(points[0], points[points.count - 1]) < 1e-9
                let vertices = closed ? Array(points.dropLast()) : points
                out.pair(0, "POLYLINE")
                out.pair(8, pen.dxfLayer)
                out.pair(66, "1")
                out.point(10, .zero)
                // 128: Strichmuster läuft über die Stützpunkte durch
                out.pair(70, String((closed ? 1 : 0) + 128))
                for p in vertices {
                    out.pair(0, "VERTEX")
                    out.pair(8, pen.dxfLayer)
                    out.point(10, p)
                }
                out.pair(0, "SEQEND")
                out.pair(8, pen.dxfLayer)
            case .arrow(let tip, let direction):
                let length = simd_length(direction)
                guard length > 1e-12 else { continue }
                let d = direction / length, n = Point2(-d.y, d.x)
                let base = tip - d * 3
                out.pair(0, "SOLID")
                out.pair(8, DrawingPen.dimension.dxfLayer)
                out.point(10, tip)
                out.point(11, base + n * 0.5)
                out.point(12, base - n * 0.5)
                out.point(13, base - n * 0.5)
            case .text(let string, let at, let height, let rotation, let centered, _):
                out.pair(0, "TEXT")
                out.pair(8, "TEXT")
                out.point(10, at)
                out.number(40, height)
                out.pair(1, dxfText(string))
                if rotation != 0 { out.number(50, rotation) }
                if centered {
                    out.pair(72, "1")
                    out.point(11, at)
                }
            }
        }
        out.pair(0, "ENDSEC")
        out.pair(0, "EOF")
        return out.data
    }

    /// Umlaute und andere Zeichen außerhalb von ASCII als \U+XXXX (versteht AutoCAD auch in R12-Dateien).
    private static func dxfText(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(format: "\\U+%04X", scalar.value)
            }
        }
        return result
    }
}
