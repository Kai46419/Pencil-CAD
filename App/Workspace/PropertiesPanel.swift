import SwiftUI
import simd

// Fenster „Eigenschaften“ rechts (Kai: Selektierwerkzeug mit hochkantem Infofenster): zeigt zum gewählten
// Körper, zur gewählten Fläche oder Kante die wichtigsten Werte und schätzt für den Körper den 3D-Druck
// wie ein Slicer (Wände, Decken/Böden, Füllung → Gramm, Meter Filament, Kosten).

/// Einstellungen für die Druckschätzung, bleiben gespeichert (UserDefaults).
enum PrintEstimateKeys {
    static let nozzle = "print.nozzle"
    static let walls = "print.walls"
    static let layerHeight = "print.layerHeight"
    static let topBottom = "print.topBottomLayers"
    static let infill = "print.infill"
    static let filament = "print.filament"
    static let material = "print.material"
    static let pricePerKilo = "print.pricePerKilo"
}

/// Geometrie eines Körpers für die Druckschätzung: Volumen und Oberfläche, aufgeteilt nach Lage.
struct PrintGeometry: Equatable {
    /// mm³
    var volume: Double
    /// Waagerechte Flächen (Decken und Böden, Neigung unter ca. 45°), mm²
    var horizontalArea: Double
    /// Übrige Flächen (Wände), mm²
    var otherArea: Double
}

/// Ergebnis der Druckschätzung.
struct PrintEstimate {
    /// Gedrucktes Volumen in mm³ (Hülle + Füllung)
    var printedVolume: Double
    /// Davon Hülle (Wände, Decken, Böden), mm³
    var shellVolume: Double
    var grams: Double
    var meters: Double
    var cost: Double

    /// Schätzung wie ein Slicer: Hülle = waagerechte Fläche × Lagen × Schichthöhe + übrige Fläche × Wände × Düse,
    /// höchstens das ganze Volumen; der Rest wird mit der Füllung gedruckt. Stützmaterial und Brim zählen nicht.
    static func make(_ geometry: PrintGeometry, nozzle: Double, walls: Double, layerHeight: Double,
                     topBottomLayers: Double, infill: Double, filament: Double, density: Double,
                     pricePerKilo: Double) -> PrintEstimate {
        let caps: Double = geometry.horizontalArea * max(0, topBottomLayers) * max(0, layerHeight)
        let sides: Double = geometry.otherArea * max(0, walls) * max(0, nozzle)
        let shell: Double = min(geometry.volume, caps + sides)
        let fill: Double = min(1, max(0, infill / 100))
        let printed: Double = shell + (geometry.volume - shell) * fill
        let grams: Double = printed / 1000 * density
        let radius: Double = max(0.1, filament) / 2
        let meters: Double = printed / (Double.pi * radius * radius) / 1000
        return PrintEstimate(printedVolume: printed, shellVolume: shell, grams: grams, meters: meters,
                             cost: grams / 1000 * max(0, pricePerKilo))
    }
}

extension ModelStore {
    /// Volumen und nach Lage aufgeteilte Oberfläche eines Körpers aus dem Dreiecksnetz (Z ist oben).
    func printGeometry(ofBody body: Int) -> PrintGeometry? {
        guard bodies.indices.contains(body) else { return nil }
        let indices = mesh.triangleIndices(ofBody: body)
        guard indices.count >= 3 else { return nil }
        var horizontal = 0.0, other = 0.0
        var t = 0
        while t + 2 < indices.count {
            let a = SIMD3<Double>(mesh.vertices[Int(indices[t])].position)
            let b = SIMD3<Double>(mesh.vertices[Int(indices[t + 1])].position)
            let c = SIMD3<Double>(mesh.vertices[Int(indices[t + 2])].position)
            t += 3
            let cross = simd_cross(b - a, c - a)
            let doubleArea = simd_length(cross)
            guard doubleArea > 1e-12 else { continue }
            let area = doubleArea / 2
            if abs(cross.z) / doubleArea > 0.7 { horizontal += area } else { other += area }
        }
        return PrintGeometry(volume: volume(ofBody: body), horizontalArea: horizontal, otherArea: other)
    }

    /// Nummern der Flächen und Kanten eines Körpers (aus dem Netz).
    func topologyCounts(ofBody body: Int) -> (faces: Int, edges: Int) {
        let faces = Set(mesh.triangleFaces.filter { $0.body == body }.map(\.face))
        let edges = Set(mesh.edgeRefs.filter { $0.body == body }.map(\.edge))
        return (faces.count, edges.count)
    }

    /// Oberfläche eines Körpers (Summe aller Flächen), mm².
    func surfaceArea(ofBody body: Int) -> Double {
        let faces = Set(mesh.triangleFaces.filter { $0.body == body })
        return faces.reduce(0) { $0 + area(of: $1) }
    }
}

/// Werte zum gerade Gewählten, einmal berechnet, solange sich Modell und Auswahl nicht ändern.
private struct PropertySnapshot {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    var title = ""
    var systemImage = "cube"
    var rows: [Row] = []
    var faceRows: [Row] = []
    var faceTitle = ""
    var edgeRows: [Row] = []
    var edgeTitle = ""
    var body: Int?
    var geometry: PrintGeometry?
}

struct PropertiesPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    let close: () -> Void

    @AppStorage(PrintEstimateKeys.nozzle) private var nozzle = 0.4
    @AppStorage(PrintEstimateKeys.walls) private var walls = 2.0
    @AppStorage(PrintEstimateKeys.layerHeight) private var layerHeight = 0.2
    @AppStorage(PrintEstimateKeys.topBottom) private var topBottomLayers = 4.0
    @AppStorage(PrintEstimateKeys.infill) private var infill = 15.0
    @AppStorage(PrintEstimateKeys.filament) private var filament = 1.75
    /// Leer = Material des Körpers (ohne Kunststoff: PLA)
    @AppStorage(PrintEstimateKeys.material) private var printMaterial = ""
    @AppStorage(PrintEstimateKeys.pricePerKilo) private var pricePerKilo = 20.0

    @State private var snapshot = PropertySnapshot()
    @State private var showsPrint = true

    /// Ändert sich bei jeder Modell- oder Auswahländerung (dann neu rechnen).
    private var key: String {
        let faces = model.selection.map { "f\($0.body).\($0.face)" } ?? ""
        let edges = model.selectedEdges.map { "e\($0.body).\($0.edge)" }.joined(separator: ",")
        let bodies = model.selectedBodies.map(String.init).joined(separator: ",")
        return "\(model.revision)|\(faces)|\(edges)|\(bodies)|\(LengthUnit.current.rawValue)"
    }

    var body: some View {
        SidePanelFrame(title: "Eigenschaften", close: close) {
            bodyPicker
            if snapshot.body == nil {
                Text("Körper, Fläche oder Kante antippen – hier erscheinen Maße, Volumen, Gewicht und die Druckschätzung.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                section(snapshot.title, systemImage: snapshot.systemImage, rows: snapshot.rows)
                if !snapshot.faceRows.isEmpty {
                    section(snapshot.faceTitle, systemImage: "square.on.square", rows: snapshot.faceRows)
                }
                if !snapshot.edgeRows.isEmpty {
                    section(snapshot.edgeTitle, systemImage: "line.diagonal", rows: snapshot.edgeRows)
                }
                if let geometry = snapshot.geometry, geometry.volume > 0 {
                    printSection(geometry)
                }
            }
        }
        .task(id: key) { snapshot = makeSnapshot() }
    }

    // MARK: Körperwahl

    private var bodyPicker: some View {
        Menu {
            ForEach(Array(model.bodies.enumerated()), id: \.offset) { index, item in
                if !item.isHidden {
                    Button(item.name, systemImage: snapshot.body == index ? "checkmark" : "cube") {
                        if workspace.tool != .select { workspace.activate(.select) }
                        model.selectBodies([index])
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "cube")
                    .frame(width: 22)
                Text(snapshot.body.flatMap { model.bodies.indices.contains($0) ? model.bodies[$0].name : nil }
                     ?? "Körper wählen")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Theme.rowHighlight, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.bodies.isEmpty)
        .hoverTip("Körper wählen", "Ganzen Körper auswählen und seine Eigenschaften zeigen.")
    }

    // MARK: Abschnitte

    private func section(_ title: String, systemImage: String, rows: [PropertySnapshot.Row]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 8)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(row.value)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func printSection(_ geometry: PrintGeometry) -> some View {
        let material = chosenMaterial
        let estimate = PrintEstimate.make(geometry, nozzle: nozzle, walls: walls, layerHeight: layerHeight,
                                          topBottomLayers: topBottomLayers, infill: infill, filament: filament,
                                          density: material.density, pricePerKilo: pricePerKilo)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Theme.spring) { showsPrint.toggle() }
            } label: {
                HStack {
                    Label("3D-Druck", systemImage: "printer")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showsPrint ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            if showsPrint {
                resultRow("Filament", grams(estimate.grams), emphasized: true)
                resultRow("Länge", meters(estimate.meters))
                resultRow("Kosten", euros(estimate.cost))
                resultRow("Gedruckt", cubicCentimeters(estimate.printedVolume) + ", Hülle " + cubicCentimeters(estimate.shellVolume))
                Divider().padding(.vertical, 4)
                Picker("Material", selection: $printMaterial) {
                    Text("Wie Körper").tag("")
                    ForEach(BodyMaterial.all.filter(\.isPrintable)) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.footnote)
                inputRow("Düse", value: $nozzle, unit: "mm", digits: 2)
                inputRow("Wandlinien", value: $walls, unit: "", digits: 0)
                inputRow("Schichthöhe", value: $layerHeight, unit: "mm", digits: 2)
                inputRow("Decken/Böden", value: $topBottomLayers, unit: "Lagen", digits: 0)
                inputRow("Füllung", value: $infill, unit: "%", digits: 0)
                inputRow("Filament Ø", value: $filament, unit: "mm", digits: 2)
                inputRow("Preis", value: $pricePerKilo, unit: "€/kg", digits: 2)
                Text("Schätzung wie ein Slicer: \(material.name), \(material.densityText). Stützmaterial und Brim zählen nicht.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chosenMaterial: BodyMaterial {
        if let chosen = BodyMaterial.named(printMaterial) { return chosen }
        let own = model.weighingMaterial(ofBody: snapshot.body)
        return own.isPrintable ? own : BodyMaterial.standard
    }

    private func resultRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .fontWeight(emphasized ? .semibold : .regular)
        }
        .font(emphasized ? .callout : .footnote)
    }

    private func inputRow(_ label: String, value: Binding<Double>, unit: String, digits: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...digits)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
        }
        .font(.footnote)
    }

    private func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0))) + " g"
    }

    private func meters(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " m"
    }

    private func euros(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " €"
    }

    // MARK: Werte berechnen

    private func makeSnapshot() -> PropertySnapshot {
        var result = PropertySnapshot()
        let face = model.selection
        let edge = model.selectedEdges.first
        guard let body = model.selectedBodies.first ?? face?.body ?? edge?.body,
              model.bodies.indices.contains(body) else { return result }
        result.body = body
        result.title = model.bodies[body].name
        result.systemImage = "cube"
        result.rows = bodyRows(body)
        result.geometry = model.printGeometry(ofBody: body)
        if let face, model.bodies.indices.contains(face.body) {
            let info = faceRows(face)
            result.faceTitle = info.title
            result.faceRows = info.rows
        }
        if let edge, model.bodies.indices.contains(edge.body) {
            let info = edgeRows(edge)
            result.edgeTitle = model.selectedEdges.count > 1 ? "\(info.title) (1 von \(model.selectedEdges.count))" : info.title
            result.edgeRows = info.rows
        }
        return result
    }

    private func bodyRows(_ body: Int) -> [PropertySnapshot.Row] {
        let unit = LengthUnit.current
        var rows: [PropertySnapshot.Row] = []
        if let box = model.mesh.bounds(ofBody: body) {
            let size = SIMD3<Double>(box.max - box.min)
            rows.append(.init(label: "L × B × H", value: "\(unit.number(size.x)) × \(unit.number(size.y)) × \(unit.format(size.z))"))
        }
        let volume = model.volume(ofBody: body)
        if volume > 0 {
            rows.append(.init(label: "Volumen", value: cubicCentimeters(volume)))
        }
        rows.append(.init(label: "Oberfläche", value: unit.formatArea(model.surfaceArea(ofBody: body))))
        let material = model.weighingMaterial(ofBody: body)
        if volume > 0 {
            let grams = volume / 1000 * material.density
            let fill = material.isPrintable ? ", voll" : ""
            rows.append(.init(label: "Gewicht", value: self.grams(grams) + " (\(material.name)\(fill))"))
        }
        if let c = model.centerOfMass(ofBody: body) {
            rows.append(.init(label: "Schwerpunkt", value: "\(unit.number(c.x)) / \(unit.number(c.y)) / \(unit.number(c.z))"))
        }
        let counts = model.topologyCounts(ofBody: body)
        rows.append(.init(label: "Flächen · Kanten", value: "\(counts.faces) · \(counts.edges)"))
        return rows
    }

    private func cubicCentimeters(_ cubicMillimeters: Double) -> String {
        (cubicMillimeters / 1000).formatted(.number.precision(.fractionLength(2))) + " cm³"
    }

    private func faceRows(_ face: FaceRef) -> (title: String, rows: [PropertySnapshot.Row]) {
        let unit = LengthUnit.current
        var rows: [PropertySnapshot.Row] = []
        let area = model.area(of: face)
        if let plane = model.plane(of: face) {
            rows.append(.init(label: "Art", value: "Ebene Fläche"))
            rows.append(.init(label: "Fläche", value: unit.formatArea(area)))
            let boundary = model.edgePolylines(ofFace: face).flatMap { $0 }
            let points = boundary.isEmpty ? model.mesh.trianglePoints(of: face).map { SIMD3<Double>($0) } : boundary
            if let rect = FaceExtent.smallestRectangle(points.map { plane.local($0) }) {
                rows.append(.init(label: "L × B", value: "\(unit.number(rect.length)) × \(unit.format(rect.width))"))
            }
            let n = simd_normalize(plane.normal)
            rows.append(.init(label: "Normale", value: direction(n)))
            return ("Fläche", rows)
        }
        if let cylinder = model.cylinder(of: face) {
            rows.append(.init(label: "Art", value: cylinder.convex ? "Zylinder (Zapfen)" : "Zylinder (Bohrung)"))
            rows.append(.init(label: "Fläche", value: unit.formatArea(area)))
            rows.append(.init(label: "Ø", value: unit.format(cylinder.radius * 2)))
            rows.append(.init(label: "Radius", value: unit.format(cylinder.radius)))
            let heights = model.mesh.trianglePoints(of: face).map { simd_dot(SIMD3<Double>($0) - cylinder.origin, cylinder.axis) }
            if let low = heights.min(), let high = heights.max() {
                rows.append(.init(label: "Höhe", value: unit.format(high - low)))
            }
            rows.append(.init(label: "Achse", value: direction(cylinder.axis)))
            return ("Fläche", rows)
        }
        rows.append(.init(label: "Art", value: "Gekrümmte Fläche"))
        rows.append(.init(label: "Fläche", value: unit.formatArea(area)))
        let points = model.mesh.trianglePoints(of: face)
        if let first = points.first {
            let lo = points.reduce(first) { simd_min($0, $1) }, hi = points.reduce(first) { simd_max($0, $1) }
            let size = SIMD3<Double>(hi - lo)
            rows.append(.init(label: "Ausdehnung", value: "\(unit.number(size.x)) × \(unit.number(size.y)) × \(unit.format(size.z))"))
        }
        return ("Fläche", rows)
    }

    private func edgeRows(_ edge: EdgeRef) -> (title: String, rows: [PropertySnapshot.Row]) {
        let unit = LengthUnit.current
        var rows: [PropertySnapshot.Row] = []
        let length = model.length(of: edge)
        let points = model.edgePolylines(edge).max { $0.count < $1.count } ?? []
        rows.append(.init(label: "Länge", value: unit.format(length)))
        guard let start = points.first, let end = points.last else { return ("Kante", rows) }
        let closed = points.count > 2 && simd_distance(start, end) < 1e-3
        if let circle = FaceExtent.circle(through: points) {
            rows.insert(.init(label: "Art", value: closed ? "Kreis" : "Kreisbogen"), at: 0)
            rows.append(.init(label: "Radius", value: unit.format(circle.radius)))
            rows.append(.init(label: "Ø", value: unit.format(circle.radius * 2)))
            rows.append(.init(label: "Mitte", value: point(circle.center)))
        } else if abs(simd_distance(start, end) - length) < max(1e-3, length * 1e-4) {
            rows.insert(.init(label: "Art", value: "Gerade"), at: 0)
        } else {
            rows.insert(.init(label: "Art", value: closed ? "Geschlossene Kurve" : "Kurve"), at: 0)
        }
        if !closed {
            rows.append(.init(label: "Anfang", value: point(start)))
            rows.append(.init(label: "Ende", value: point(end)))
        }
        return ("Kante", rows)
    }

    private func point(_ p: SIMD3<Double>) -> String {
        let unit = LengthUnit.current
        return "\(unit.number(p.x)) / \(unit.number(p.y)) / \(unit.number(p.z))"
    }

    private func direction(_ d: SIMD3<Double>) -> String {
        let format = { (value: Double) in (abs(value) < 5e-4 ? 0 : value).formatted(.number.precision(.fractionLength(0...3))) }
        return "\(format(d.x)) / \(format(d.y)) / \(format(d.z))"
    }
}

/// Hilfsrechnungen für Flächen- und Kantenmaße.
enum FaceExtent {
    /// Kleinstes umschließendes Rechteck (gedreht) einer Punktwolke in der Ebene: Länge ≥ Breite.
    static func smallestRectangle(_ points: [SIMD2<Double>]) -> (length: Double, width: Double)? {
        let hull = convexHull(points)
        guard hull.count >= 2 else { return nil }
        var best: (area: Double, a: Double, b: Double)?
        for i in hull.indices {
            let edge = hull[(i + 1) % hull.count] - hull[i]
            let size = simd_length(edge)
            guard size > 1e-9 else { continue }
            let u = edge / size, v = SIMD2(-u.y, u.x)
            let us = hull.map { simd_dot($0, u) }, vs = hull.map { simd_dot($0, v) }
            guard let uMin = us.min(), let uMax = us.max(), let vMin = vs.min(), let vMax = vs.max() else { continue }
            let a = uMax - uMin, b = vMax - vMin
            if best == nil || a * b < best!.area - 1e-9 { best = (a * b, a, b) }
        }
        guard let best else { return nil }
        return (max(best.a, best.b), min(best.a, best.b))
    }

    /// Konvexe Hülle (Andrew), gegen den Uhrzeigersinn.
    static func convexHull(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let points = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count >= 3 else { return points }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Double>] = []
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Kreis durch einen Linienzug, wenn alle Punkte (eben) auf ihm liegen; sonst nil.
    static func circle(through points: [SIMD3<Double>]) -> (center: SIMD3<Double>, radius: Double)? {
        guard points.count >= 4 else { return nil }
        let a = points[0], b = points[points.count / 3], c = points[(points.count * 2) / 3]
        let ab = b - a, ac = c - a
        let normal = simd_cross(ab, ac)
        let n2 = simd_length_squared(normal)
        guard n2 > 1e-12 else { return nil }
        let term1 = simd_cross(normal, ab) * simd_length_squared(ac)
        let term2 = simd_cross(ac, normal) * simd_length_squared(ab)
        let center = a + (term1 + term2) / (2 * n2)
        let radius = simd_distance(center, a)
        guard radius > 1e-6, radius < 1e6 else { return nil }
        let unitNormal = normal / n2.squareRoot()
        let tolerance = max(1e-3, radius * 2e-3)
        for p in points {
            if abs(simd_distance(p, center) - radius) > tolerance { return nil }
            if abs(simd_dot(p - center, unitNormal)) > tolerance { return nil }
        }
        return (center, radius)
    }
}
