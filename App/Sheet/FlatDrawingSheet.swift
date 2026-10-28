import SwiftUI
import UIKit
import simd

// Blatt „Abwicklung“ (Punkt 12): links die Abwicklung mit Bemaßung, darunter die Biegetabelle, rechts die Ansichten
// des gekanteten Teils (Isometrie oben, darunter Vorder-, Seiten- und Draufsicht nach Methode 1 mit L × B × H),
// rechts unten das Schriftfeld wie bei der technischen Zeichnung (TechnicalDrawing.swift) mit Blechdicke, Material
// und Zuschnitt. Gezeichnet mit TechnicalDrawing.draw (A4 oder A3 quer), Export als PDF; dazu das DXF der Abwicklung.

/// Papierformat des Abwicklungsblatts.
enum FlatDrawingPaper: String, CaseIterable, Identifiable {
    case a4 = "A4 quer"
    case a3 = "A3 quer"

    var id: Self { self }

    var size: Point2 { self == .a4 ? Point2(297, 210) : Point2(420, 297) }

    /// Breite der Spalte mit den Ansichten des gekanteten Teils
    var viewColumn: Double { self == .a4 ? 92 : 135 }

    /// Höchstens so viele Zeilen der Biegetabelle auf dem Blatt
    var tableRows: Int { self == .a4 ? 8 : 16 }
}

/// Angaben für das Schriftfeld des Abwicklungsblatts.
struct FlatSheetInfo {
    var title: String
    var subtitle: String
    var author: String
    var material: String
    /// Körper ist entfaltet: die Ansichten zeigen dann den flachen Zustand
    var unfolded: Bool
    var date = Date()
}

/// Fertig angeordnetes Abwicklungsblatt (Blatt-mm, y nach oben, Ursprung links unten).
struct FlatSheetLayout {
    var elements: [DrawingElement] = []
    var paper: FlatDrawingPaper = .a4
    var scaleText = "–"
}

extension FlatDrawing {
    /// Normmaßstäbe (DIN ISO 5455), größter zuerst
    static let sheetScales: [Double] = [10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001]

    static func sheetScale(atMost limit: Double) -> Double {
        sheetScales.first { $0 <= limit * (1 + 1e-9) } ?? max(limit, 1e-6)
    }

    private static func rectangle(_ a: Point2, _ b: Point2, pen: DrawingPen, into elements: inout [DrawingElement]) {
        elements.append(.polyline([a, Point2(b.x, a.y), b, Point2(a.x, b.y), a], pen))
    }

    static func sheetLayout(_ plan: FlatDrawingPlan, views: [DrawingView: DrawingProjection], paper: FlatDrawingPaper,
                            info: FlatSheetInfo) -> FlatSheetLayout {
        var out = FlatSheetLayout(paper: paper)
        let n = TechnicalDrawing.number
        let sheet = paper.size
        let frameMin = Point2(20, 10), frameMax = Point2(sheet.x - 10, sheet.y - 10)
        rectangle(frameMin, frameMax, pen: .frame, into: &out.elements)
        let titleMin = Point2(frameMax.x - 120, frameMin.y), titleMax = Point2(frameMax.x, frameMin.y + 42)
        let columnX = frameMax.x - paper.viewColumn
        out.elements.append(.polyline([Point2(columnX, titleMax.y), Point2(columnX, frameMax.y)], .thin))

        // Biegetabelle links unten
        let rows = plan.tableRows
        let shownRows = min(rows.count, paper.tableRows)
        var tableTop = frameMin.y
        if !rows.isEmpty {
            let height = bendTableHeight(rows: shownRows, truncated: rows.count > shownRows)
            tableTop = frameMin.y + 2 + height
            let marks = bendTable(plan, topLeft: Point2(frameMin.x + 3, tableTop), unit: 1, maxRows: paper.tableRows)
            out.elements += elements(marks, origin: Point2(0, 0), scale: 1)
        }

        // Abwicklung: größter Normmaßstab, bei dem Kontur und Bemaßung in den Bereich passen
        let regionMin = Point2(frameMin.x + 3, max(tableTop + 3, titleMax.y + 3))
        let regionMax = Point2(columnX - 3, frameMax.y - 9)
        let region = regionMax - regionMin
        let length = max(plan.size.x, 1e-6), width = max(plan.size.y, 1e-6)
        let limit = min(region.x / length, region.y / width)
        var chosen: (scale: Double, marks: [FlatMark], box: (min: Point2, max: Point2))?
        for s in sheetScales where s <= limit * (1 + 1e-9) {
            let marks = geometry(plan) + annotations(plan, unit: 1 / s)
            guard let box = bounds(marks) else { continue }
            let need = (box.max - box.min) * s
            chosen = (s, marks, box)
            if need.x <= region.x, need.y <= region.y { break }
        }
        if chosen == nil, limit > 0 {
            let s = limit * 0.5
            let marks = geometry(plan) + annotations(plan, unit: 1 / s)
            if let box = bounds(marks) { chosen = (s, marks, box) }
        }
        if let chosen {
            let s = chosen.scale
            let center = (regionMin + regionMax) / 2
            let origin = center - (chosen.box.min + chosen.box.max) / 2 * s
            out.elements += elements(chosen.marks, origin: origin, scale: s)
            out.scaleText = TechnicalDrawing.scaleText(s)
        }
        out.elements.append(.text("Abwicklung  M \(out.scaleText)  ·  Zuschnitt \(n(plan.size.x)) × \(n(plan.size.y)) mm"
                                  + "  ·  t = \(n(plan.thickness)) mm",
                                  at: Point2(frameMin.x + 3, frameMax.y - 6), height: 3.2, bold: true))

        placeViews(views, columnMin: Point2(columnX + 3, titleMax.y + 3), columnMax: Point2(frameMax.x - 3, frameMax.y - 3),
                   unfolded: info.unfolded, into: &out.elements)
        titleBlock(min: titleMin, max: titleMax, info: info, plan: plan, scale: out.scaleText, paper: paper,
                   into: &out.elements)
        return out
    }

    /// Ansichten des gekanteten Teils: Isometrie oben, darunter Vorderansicht, Seitenansicht von links (rechts
    /// daneben) und Draufsicht (darunter) nach Methode 1, mit Gesamtmaßen L, B, H.
    private static func placeViews(_ views: [DrawingView: DrawingProjection], columnMin: Point2, columnMax: Point2,
                                   unfolded: Bool, into elements: inout [DrawingElement]) {
        let n = TechnicalDrawing.number
        var top = columnMax.y - 3
        guard let front = views[.front]?.bounds, let plan = views[.top]?.bounds, let side = views[.left]?.bounds else {
            elements.append(.text("Ansichten werden berechnet …", at: Point2(columnMin.x, top - 4), height: 2.5))
            return
        }
        let length = front.max.x - front.min.x
        let height = front.max.y - front.min.y
        let depth = plan.max.y - plan.min.y
        elements.append(.text("Fertigteil gekantet", at: Point2(columnMin.x, top - 2.5), height: 2.8, bold: true))
        top -= 7
        elements.append(.text("L × B × H = \(n(length)) × \(n(depth)) × \(n(height)) mm", at: Point2(columnMin.x, top - 2.5),
                              height: 2.5))
        top -= 6
        if unfolded {
            elements.append(.text("Körper ist entfaltet – Ansichten zeigen den flachen Zustand",
                                  at: Point2(columnMin.x, top - 1.8), height: 1.8))
            top -= 4
        }

        func place(_ view: DrawingView, at origin: Point2, scale: Double, bounds: (min: Point2, max: Point2),
                   hidden: Bool) {
            guard let projection = views[view] else { return }
            let map = { (p: Point2) in origin + (p - bounds.min) * scale }
            if hidden {
                for line in projection.hidden { elements.append(.polyline(line.map(map), .hidden)) }
            }
            for line in projection.visible { elements.append(.polyline(line.map(map), .visible)) }
        }

        let totalHeight = top - columnMin.y
        let columnWidth = columnMax.x - columnMin.x
        // Oberes Feld Isometrie, unteres die Normansichten
        let splitY = columnMin.y + totalHeight * 0.6
        var marks: [FlatMark] = []
        let margin = 10.0, gap = 8.0, label = 4.0
        let fit = min((columnWidth - margin - gap - 2) / max(length + depth, 1e-6),
                      (splitY - columnMin.y - margin - gap - 2 * label) / max(height + depth, 1e-6))
        if fit > 0 {
            let s = sheetScale(atMost: fit)
            let col1 = columnMin.x + margin
            let col2 = col1 + s * length + gap
            let lowerRow = columnMin.y + margin
            let upperRow = lowerRow + s * depth + gap + label
            let frontOrigin = Point2(col1, upperRow), planOrigin = Point2(col1, lowerRow)
            let sideOrigin = Point2(col2, upperRow)
            place(.front, at: frontOrigin, scale: s, bounds: front, hidden: true)
            place(.top, at: planOrigin, scale: s, bounds: plan, hidden: true)
            place(.left, at: sideOrigin, scale: s, bounds: side, hidden: true)
            if length > 1e-6 {
                horizontalChain([col1, col1 + s * length], rowY: lowerRow - 6, anchor: { _ in lowerRow }, unit: 1,
                                height: 2.5, valueScale: s, into: &marks)
            }
            if height > 1e-6 {
                verticalChain([upperRow, upperRow + s * height], rowX: col1 - 6, anchor: { _ in col1 }, unit: 1,
                              height: 2.5, valueScale: s, into: &marks)
            }
            if depth > 1e-6 {
                verticalChain([lowerRow, lowerRow + s * depth], rowX: col1 - 6, anchor: { _ in col1 }, unit: 1,
                              height: 2.5, valueScale: s, into: &marks)
            }
            func viewLabel(_ text: String, _ origin: Point2, _ viewHeight: Double) {
                elements.append(.text(text, at: Point2(origin.x, origin.y + viewHeight + 1.5), height: 1.8))
            }
            viewLabel("\(DrawingView.front.rawValue) \(TechnicalDrawing.scaleText(s))", frontOrigin, s * height)
            viewLabel(DrawingView.left.rawValue, sideOrigin, s * height)
            viewLabel(DrawingView.top.rawValue, planOrigin, s * depth)
        }
        elements += self.elements(marks, origin: Point2(0, 0), scale: 1)

        // Isometrie im oberen Feld, eigener Maßstab
        if let iso = views[.iso]?.bounds {
            let isoWidth = iso.max.x - iso.min.x, isoHeight = iso.max.y - iso.min.y
            let boxMin = Point2(columnMin.x + 2, splitY + 2), boxMax = Point2(columnMax.x - 2, top - 4)
            let isoFit = min((boxMax.x - boxMin.x) / max(isoWidth, 1e-6), (boxMax.y - boxMin.y) / max(isoHeight, 1e-6))
            if isoFit > 0 {
                let s = sheetScale(atMost: isoFit)
                let origin = Point2((boxMin.x + boxMax.x - s * isoWidth) / 2, (boxMin.y + boxMax.y - s * isoHeight) / 2)
                place(.iso, at: origin, scale: s, bounds: iso, hidden: false)
                elements.append(.text("\(DrawingView.iso.rawValue) (\(TechnicalDrawing.scaleText(s)))",
                                      at: Point2(columnMin.x, top - 1.8), height: 1.8))
            }
        }
    }

    /// Schriftfeld wie TechnicalDrawing (vereinfacht nach DIN EN ISO 7200) mit einer Zeile Blechdaten.
    private static func titleBlock(min a: Point2, max b: Point2, info: FlatSheetInfo, plan: FlatDrawingPlan,
                                   scale: String, paper: FlatDrawingPaper, into elements: inout [DrawingElement]) {
        let n = TechnicalDrawing.number
        rectangle(a, b, pen: .frame, into: &elements)
        let row1 = a.y + 10, row2 = a.y + 20, row3 = a.y + 30
        for y in [row1, row2, row3] {
            elements.append(.polyline([Point2(a.x, y), Point2(b.x, y)], .thin))
        }
        let column1 = a.x + 35, column2 = a.x + 70
        elements.append(.polyline([Point2(column1, a.y), Point2(column1, row3)], .thin))
        elements.append(.polyline([Point2(column2, a.y), Point2(column2, row3)], .thin))

        func field(_ label: String, _ value: String, x: Double, y: Double, height: Double = 3.5, bold: Bool = false) {
            elements.append(.text(label, at: Point2(x + 1.5, y + 6.8), height: 1.8))
            elements.append(.text(value, at: Point2(x + 1.5, y + 1.8), height: height, bold: bold))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        let name = info.title.count > 34 ? String(info.title.prefix(33)) + "…" : info.title
        elements.append(.text("Benennung", at: Point2(a.x + 1.5, b.y - 3), height: 1.8))
        let creator = info.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if creator.isEmpty {
            elements.append(.text(name, at: Point2(a.x + 1.5, row3 + 2.2), height: 5, bold: true))
        } else {
            elements.append(.text(name, at: Point2(a.x + 1.5, row3 + 4), height: 4.2, bold: true))
            let line = "Created by " + (creator.count > 40 ? String(creator.prefix(39)) + "…" : creator)
            elements.append(.text(line, at: Point2(a.x + 1.5, row3 + 1), height: 2.2))
        }
        if !info.subtitle.isEmpty {
            let text = info.subtitle.count > 40 ? String(info.subtitle.prefix(39)) + "…" : info.subtitle
            elements.append(.text(text, at: Point2(b.x - 1.5 - Double(min(text.count, 40)) * 1.6, b.y - 3), height: 1.8))
        }
        let material = info.material.isEmpty ? "–" : info.material
        field("Maßstab", scale, x: a.x, y: row2, bold: true)
        field("Datum", formatter.string(from: info.date), x: column1, y: row2)
        field("Blatt", "\(paper.rawValue), 1/1", x: column2, y: row2)
        field("Blechdicke", "\(n(plan.thickness)) mm", x: a.x, y: row1, bold: true)
        field("Material", material.count > 16 ? String(material.prefix(15)) + "…" : material, x: column1, y: row1,
              height: 3)
        field("Zuschnitt L × B", "\(n(plan.size.x)) × \(n(plan.size.y)) mm", x: column2, y: row1, height: 3, bold: true)
        field("Projektion", "Methode 1 (E)", x: a.x, y: a.y, height: 3)
        field("Maße", "mm", x: column1, y: a.y, height: 3)
        field("Erstellt mit", "PencilCAD", x: column2, y: a.y, height: 3)
    }

    // MARK: PDF und Vorschau

    /// PDF, eine Seite im Format des Blatts.
    static func pdfData(_ layout: FlatSheetLayout, title: String, author: String = "") -> Data {
        let k = 72 / 25.4
        let size = layout.paper.size
        let bounds = CGRect(x: 0, y: 0, width: size.x * k, height: size.y * k)
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "PencilCAD"]
        if !author.isEmpty { info[kCGPDFContextAuthor as String] = author }
        format.documentInfo = info
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            context.beginPage()
            draw(layout, in: context.cgContext, pointsPerMM: k)
        }
    }

    /// Vorschaubild (weißes Blatt), width in Punkten.
    static func image(_ layout: FlatSheetLayout, width: CGFloat) -> UIImage {
        let paper = layout.paper.size
        let size = CGSize(width: width, height: width * CGFloat(paper.y / paper.x))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(layout, in: context.cgContext, pointsPerMM: Double(width) / paper.x)
        }
    }

    /// TechnicalDrawing.draw spiegelt y an der A4-Höhe; für andere Blatthöhen vorher verschieben.
    private static func draw(_ layout: FlatSheetLayout, in cg: CGContext, pointsPerMM k: Double) {
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat((layout.paper.size.y - TechnicalDrawing.sheetHeight) * k))
        TechnicalDrawing.draw(DrawingLayout(elements: layout.elements), in: cg, pointsPerMM: k)
        cg.restoreGState()
    }
}

// MARK: - Oberfläche

/// Öffnet das Abwicklungsblatt für den gewählten (bzw. letzten) Blechkörper.
@MainActor
enum FlatDrawingPresenter {
    static func present(_ ws: Workspace, body picked: Int? = nil) {
        let model = ws.model
        guard model.sheetAvailable else {
            model.message = model.sheetUnavailableReason ?? SheetUI.notBuiltText
            return
        }
        guard let body = SheetUI.targetSheetBody(model, picked: picked) else {
            model.message = "Kein Blechkörper im Projekt – erst einen Flansch erstellen oder einen Körper in Blech umwandeln."
            return
        }
        guard let root = SheetShare.topController() else { return }
        let box = FlatDrawingControllerBox()
        let view = FlatDrawingSheet(model: model, bodyIndex: body, projectName: ws.project.name) {
            box.controller?.dismiss(animated: true)
        }
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .pageSheet
        box.controller = controller
        root.present(controller, animated: true)
    }
}

/// Schwacher Verweis auf das vorgestellte Blatt (für „Fertig“)
private final class FlatDrawingControllerBox {
    weak var controller: UIViewController?
}

/// „Abwicklungszeichnung“: Vorschau des Blatts, Papierformat, Ersteller; PDF und DXF der Abwicklung teilen.
struct FlatDrawingSheet: View {
    @ObservedObject var model: ModelStore
    let bodyIndex: Int
    let projectName: String
    let onClose: () -> Void

    @State private var paper: FlatDrawingPaper = .a4
    @State private var author = DrawingOptions.savedAuthor
    @State private var plan: FlatDrawingPlan?
    @State private var views: [DrawingView: DrawingProjection] = [:]
    @State private var layout: FlatSheetLayout?
    @State private var preview: UIImage?
    @State private var isWorking = false
    @State private var message: String?

    init(model: ModelStore, bodyIndex: Int, projectName: String, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.bodyIndex = bodyIndex
        self.projectName = projectName
        self.onClose = onClose
    }

    private var bodyName: String {
        model.bodies.indices.contains(bodyIndex) ? model.bodies[bodyIndex].name : "Blech"
    }

    private var fileName: String { ModelStore.sheetFileName(bodyName) + " Abwicklung" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if isWorking {
                        ProgressView("Ansichten werden berechnet …")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .aspectRatio(paper.size.x / paper.size.y, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 16) {
                    Picker("Papier", selection: $paper) {
                        ForEach(FlatDrawingPaper.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    // Ersteller im Schriftfeld, gemeinsam mit der technischen Zeichnung gemerkt
                    TextField("Erstellt von", text: $author)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 190)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Abwicklungszeichnung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { onClose() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("DXF der Abwicklung …", systemImage: "square.and.arrow.up.on.square") { shareDXF() }
                        .disabled(plan == nil)
                    Button("PDF …", systemImage: "doc.richtext") { sharePDF() }
                        .disabled(layout == nil)
                }
            }
        }
        .task { await load() }
        .onChange(of: paper) { _, _ in relayout() }
        .onChange(of: author) { _, name in
            DrawingOptions.savedAuthor = name
            relayout()
        }
    }

    /// Flachmuster sofort, die Ansichten (verdeckte Kanten) danach im Hintergrund.
    @MainActor
    private func load() async {
        guard model.bodies.indices.contains(bodyIndex) else {
            message = "Der Blechkörper ist nicht mehr vorhanden."
            return
        }
        do {
            plan = FlatDrawingPlan(try model.flatPattern(of: bodyIndex))
        } catch {
            message = "Flachmuster: \(error.localizedDescription)"
        }
        relayout()
        isWorking = true
        // Kurz warten, damit die Vorschau steht, bevor der Kernel rechnet
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled, model.bodies.indices.contains(bodyIndex) else { return }
        let shape = model.bodies[bodyIndex].shape
        // Eigene Kopie für den Hintergrund (OpenCASCADE-Formen nicht gleichzeitig benutzen, wie DrawingSheet)
        let copies = [shape].compactMap { $0.translated(by: SIMD3<Double>(0, 0, 0)) }
        let inBackground = copies.count == 1
        for view in [DrawingView.front, .left, .top, .iso] {
            let projection: DrawingProjection
            if inBackground {
                projection = await Task.detached(priority: .userInitiated) {
                    TechnicalDrawing.project(copies, view: view)
                }.value
            } else {
                projection = TechnicalDrawing.project([shape], view: view)
            }
            guard !Task.isCancelled else { return }
            views[view] = projection
        }
        isWorking = false
        relayout()
    }

    @MainActor
    private func relayout() {
        guard let plan else {
            layout = nil
            preview = nil
            return
        }
        let item = model.bodies.indices.contains(bodyIndex) ? model.bodies[bodyIndex] : nil
        let info = FlatSheetInfo(title: "Abwicklung " + bodyName, subtitle: projectName, author: author,
                                 material: item?.bodyMaterial?.name ?? "",
                                 unfolded: model.sheetInfo(bodyIndex)?.isUnfolded ?? false)
        let result = FlatDrawing.sheetLayout(plan, views: views, paper: paper, info: info)
        layout = result
        preview = FlatDrawing.image(result, width: 1400)
    }

    @MainActor
    private func sharePDF() {
        guard let layout else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(fileName).pdf")
        do {
            try? FileManager.default.removeItem(at: url)
            try FlatDrawing.pdfData(layout, title: "Abwicklung " + bodyName, author: author).write(to: url)
            SheetShare.present([url])
        } catch {
            message = "PDF: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func shareDXF() {
        do {
            let url = try model.exportFlatDrawingDXF(of: bodyIndex)
            SheetShare.present([url])
        } catch {
            message = "DXF: \(error.localizedDescription)"
        }
    }
}
