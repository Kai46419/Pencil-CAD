import SwiftUI

// 2D-Ansicht „Flachmuster“ nach SolidCraft (dialogs_sheet.rs `overlay` von `Sm::FlatPattern`, COMMANDS.md §10):
// Draufsicht ersetzt das Ansichtsfenster, Hintergrund in Panelfarbe; Umriss geschlossen (Strich 1,8, Textfarbe),
// Ausschnitte (1,4), Taschen gestrichelt in Akzentfarbe (3/3) mit Tiefe, Biegelinien gestrichelt (8/5, Strich 1,6) in
// „Biegung oben“- bzw. „Biegung unten“-Farbe; Legende oben links. Ohne Daten „kein Blechkörper“.
// Verschieben mit einem Finger, Zoomen mit zwei Fingern, Doppeltippen passt ein (beim Öffnen eingepasst).
// Zusätzlich (iPad): Abwicklungsgröße und kleine Biegetabelle unten links.

/// Farben wie SolidCraft-Theme (dunkel): bend_up (110, 200, 120), bend_down (240, 150, 80)
enum FlatPatternColors {
    static let up = Color(red: 110 / 255, green: 200 / 255, blue: 120 / 255)
    static let down = Color(red: 240 / 255, green: 150 / 255, blue: 80 / 255)
    static let upLight = Color(red: 30 / 255, green: 140 / 255, blue: 50 / 255)
    static let downLight = Color(red: 200 / 255, green: 90 / 255, blue: 20 / 255)

    static func bend(up: Bool, dark: Bool = true) -> Color {
        if dark { return up ? Self.up : down }
        return up ? upLight : downLight
    }
}

/// Über dem Ansichtsfenster, solange „Flachmuster erstellen“ offen ist (WorkspaceView.swift).
struct SheetFlatOverlay: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let cmd = workspace.command, cmd.id == .sheetFlatPattern, cmd.editing == nil {
            FlatPatternView(state: SheetCommandState.of(cmd))
                .id(ObjectIdentifier(cmd))
                .transition(.opacity)
        }
    }
}

struct FlatPatternView: View {
    @ObservedObject var state: SheetCommandState

    /// Verschiebung und Maßstab (Punkte je mm) der Ansicht
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 0
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    /// Platz der Leisten: links Werkzeugleiste, rechts Panel, oben Kopfzeile, unten Zeitleiste
    private let insets = EdgeInsets(top: 90, leading: 110, bottom: 120, trailing: 210)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                PaletteStyle.background
                if let flat = state.flat {
                    canvas(flat, size: geometry.size)
                        .gesture(pan.simultaneously(with: zoom(geometry.size)))
                        .onTapGesture(count: 2) { fit(flat, geometry.size) }
                        .onAppear { fit(flat, geometry.size) }
                        .onChange(of: state.flatKey) { _, _ in
                            if let flat = state.flat { fit(flat, geometry.size) }
                        }
                    legend(flat)
                        .padding(.top, insets.top)
                        .padding(.leading, insets.leading)
                    table(flat)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.bottom, insets.bottom)
                        .padding(.leading, insets.leading)
                } else {
                    Text(state.flatError ?? "kein Blechkörper")
                        .font(.callout)
                        .foregroundStyle(SketchTheme.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flachmuster")
    }

    // MARK: Zeichnen

    private func canvas(_ flat: FlatPattern, size: CGSize) -> some View {
        let currentScale = scale > 0 ? scale : 1
        let currentOffset = offset
        return Canvas { context, _ in
            func point(_ p: SIMD2<Double>) -> CGPoint {
                // y nach oben wie im CAD
                CGPoint(x: currentOffset.width + CGFloat(p.x) * currentScale,
                        y: currentOffset.height - CGFloat(p.y) * currentScale)
            }
            func loop(_ points: [SIMD2<Double>], closed: Bool = true) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: point(first))
                for p in points.dropFirst() { path.addLine(to: point(p)) }
                if closed { path.closeSubpath() }
                return path
            }
            let ink = SketchTheme.text
            // Material leicht getönt (gerade-ungerade: Ausschnitte bleiben frei)
            var material = Path()
            for outline in flat.outline { material.addPath(loop(outline)) }
            for cutout in flat.cutouts { material.addPath(loop(cutout)) }
            context.fill(material, with: .color(ink.opacity(0.06)), style: FillStyle(eoFill: true))
            for outline in flat.outline {
                context.stroke(loop(outline), with: .color(ink), lineWidth: 1.8)
            }
            for cutout in flat.cutouts {
                context.stroke(loop(cutout), with: .color(ink), lineWidth: 1.4)
            }
            // Perforationslöcher als Kreise (1,4), nur wenn sie mindestens 1 px groß sind (SolidCraft)
            if let first = flat.perforationHoles.first, CGFloat(first.radius) * 2 * currentScale >= 1 {
                var holes = Path()
                for hole in flat.perforationHoles {
                    let center = point(hole.center)
                    let r = CGFloat(hole.radius) * currentScale
                    holes.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                }
                context.stroke(holes, with: .color(ink), lineWidth: 1.4)
            }
            // Taschen: gestrichelt in Akzentfarbe, Tiefe oben mittig
            for pocket in flat.pockets {
                let path = loop(pocket.outline)
                context.stroke(path, with: .color(SketchTheme.accent), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                for cutout in pocket.cutouts {
                    context.stroke(loop(cutout), with: .color(SketchTheme.accent),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
                let box = path.boundingRect
                let text = Text("\(LengthUnit.current.format(pocket.depth)) tief")
                    .font(.caption2)
                    .foregroundColor(SketchTheme.accent)
                context.draw(text, at: CGPoint(x: box.midX, y: box.minY - 8))
            }
            // Biegelinien gestrichelt in Biegefarbe
            for bend in flat.bends {
                var path = Path()
                path.move(to: point(bend.start))
                path.addLine(to: point(bend.end))
                context.stroke(path, with: .color(FlatPatternColors.bend(up: bend.up)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .butt, dash: [8, 5]))
                let mid = CGPoint(x: (point(bend.start).x + point(bend.end).x) / 2,
                                  y: (point(bend.start).y + point(bend.end).y) / 2)
                let label = Text("B\(bend.index)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(FlatPatternColors.bend(up: bend.up))
                context.draw(label, at: CGPoint(x: mid.x + 10, y: mid.y - 10))
            }
        }
        .contentShape(Rectangle())
    }

    /// Legende oben links (SolidCraft: „FLAT PATTERN“, „Bend up“, „Bend down“, Taschen)
    private func legend(_ flat: FlatPattern) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FLACHMUSTER")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(SketchTheme.text)
            legendLine(FlatPatternColors.up, dash: [8, 5], "Biegung oben")
            legendLine(FlatPatternColors.down, dash: [8, 5], "Biegung unten")
            if !flat.pockets.isEmpty {
                legendLine(SketchTheme.accent, dash: [3, 3], "Taschengrenze (Material bleibt)")
            }
        }
        .padding(8)
        .background(PaletteStyle.header.opacity(0.9), in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius))
        .allowsHitTesting(false)
    }

    private func legendLine(_ color: Color, dash: [CGFloat], _ text: String) -> some View {
        HStack(spacing: 6) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, dash: dash))
            }
            .frame(width: 28, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(SketchTheme.text)
        }
    }

    /// Abwicklungsgröße und Biegetabelle (höchstens 12 Zeilen, der Rest im Panel bzw. im CSV)
    private func table(_ flat: FlatPattern) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Abwicklungsgröße  \(FlatPatternFormat.size(flat))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(SketchTheme.text)
            if !flat.bends.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow {
                        header("Biegung")
                        header("Richtung")
                        header("Winkel")
                        header("Radius")
                        header("Länge")
                    }
                    ForEach(flat.bends.prefix(12)) { bend in
                        GridRow {
                            Text("\(bend.index)")
                            Text(bend.up ? "Auf" : "Ab")
                                .foregroundStyle(FlatPatternColors.bend(up: bend.up))
                            Text(SheetFormat.degrees(bend.angle))
                            Text(LengthUnit.current.number(bend.radius))
                            Text(LengthUnit.current.number(bend.length))
                        }
                    }
                    if flat.bends.count > 12 {
                        Text("… \(flat.bends.count - 12) weitere")
                            .foregroundStyle(SketchTheme.textDim)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(SketchTheme.text)
            }
        }
        .padding(8)
        .background(PaletteStyle.header.opacity(0.9), in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius))
        .allowsHitTesting(false)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(SketchTheme.textDim)
    }

    // MARK: Navigation

    private var pan: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func zoom(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? scale
                zoomStart = start
                let next = max(0.005, min(start * value.magnification, 500))
                // Um den Mittelpunkt der Geste zoomen
                let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                let factor = next / max(scale, 1e-6)
                offset = CGSize(width: anchor.x - (anchor.x - offset.width) * factor,
                                height: anchor.y - (anchor.y - offset.height) * factor)
                scale = next
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// Einpassen in den freien Bereich zwischen den Leisten
    private func fit(_ flat: FlatPattern, _ size: CGSize) {
        let bounds = flat.bounds
        let width = max(bounds.max.x - bounds.min.x, 1e-3)
        let height = max(bounds.max.y - bounds.min.y, 1e-3)
        let free = CGRect(x: insets.leading, y: insets.top,
                          width: max(size.width - insets.leading - insets.trailing, 100),
                          height: max(size.height - insets.top - insets.bottom, 100))
        let next = min(free.width / CGFloat(width), free.height / CGFloat(height)) * 0.9
        scale = next
        let centerX = CGFloat(bounds.min.x + bounds.max.x) / 2
        let centerY = CGFloat(bounds.min.y + bounds.max.y) / 2
        offset = CGSize(width: free.midX - centerX * next, height: free.midY + centerY * next)
    }
}
