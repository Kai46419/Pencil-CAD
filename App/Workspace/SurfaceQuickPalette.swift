import SwiftUI

/// Normteil wird zunächst als Einheit behandelt. Die Oberflächenwahl bleibt ausdrücklich erreichbar.
struct StandardPartPalette: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    let index: Int
    /// Build 83: Fenster auf den Kopf zuklappen
    @AppStorage("standardPart.collapsed") private var collapsed = false

    private var spec: StandardPartSpec? {
        model.bodies.indices.contains(index) ? model.bodies[index].effectiveStandardPart : nil
    }

    var body: some View {
        if let spec {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .frame(width: 25, height: 25)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("NORMTEIL").font(.system(size: 11, weight: .bold)).tracking(0.6)
                            Text(model.bodies[index].name).font(.caption).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        BodyTrashButton(model: model)
                        Button {
                            withAnimation(Theme.snappy) { collapsed.toggle() }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(collapsed ? -90 : 0))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(collapsed ? "Aufklappen" : "Zuklappen")
                    }
                    if !collapsed {
                    Divider()
                    // Build 89 (Kai): Verschieben und Drehen hier statt in der Karte unten
                    if workspace.tool == .move {
                        MovePaletteSection(model: model)
                        Divider()
                    }
                    // Build 83: Normteil setzen und kopieren
                    placementButtons(spec)
                    Divider()
                    if spec.kind == .sleeve {
                        sizeMenu(spec)
                        detail("Innen-Ø", LengthUnit.current.format(spec.sleeveInnerDiameter))
                        detail("Außen-Ø", LengthUnit.current.format(spec.sleeveOuterDiameter))
                        detail("Länge", LengthUnit.current.format(spec.length))
                    } else if spec.kind.isScrew {
                        // Build 88 (Kai): Größe, Länge, Gewindeart und -geometrie direkt hier umstellen
                        sizeMenu(spec)
                        lengthMenu(spec)
                        threadSection(spec)
                        Menu {
                            ForEach(["Nicht festgelegt", "8.8", "10.9", "12.9", "A2-70", "A4-70"], id: \.self) { value in
                                Button(value) { model.setStandardPartClass(value, body: index) }
                            }
                        } label: {
                            detail("Festigkeitsklasse", spec.propertyClass)
                        }
                        Divider()
                        Button(workspace.placesSelectedScrew ? "Zielfläche antippen …" : "An Fläche platzieren") {
                            workspace.centersSelectedPart = false
                            workspace.mountStage = .off
                            workspace.placesSelectedScrew.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        if workspace.placesSelectedScrew {
                            Picker("Bündig", selection: $workspace.screwFaceAnchor) {
                                ForEach(ScrewFaceAnchor.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            NumberField(title: "Versatz", value: workspace.screwFaceOffset, width: 72) { value in
                                if value.isFinite { workspace.screwFaceOffset = value }
                            }
                            Text("Eine ebene Fläche antippen. Die Schraubenachse folgt der Flächennormalen.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if spec.kind == .bearing {
                        detail("Typ", spec.kind.rawValue)
                        detail("Größe", spec.bearingSize.name)
                    } else {
                        detail("Typ", spec.kind.rawValue)
                        sizeMenu(spec)
                        if spec.kind == .nut { threadSection(spec) }
                    }
                    Divider()
                    Button("Oberfläche …", systemImage: "paintpalette") {
                        workspace.showsPartSurface = true
                    }
                    .buttonStyle(.bordered)
                    Button("Als Volumenkörper bearbeiten", systemImage: "cube.transparent") {
                        model.convertStandardPartToBody(index)
                        workspace.activate(.select)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    }
                }
                .padding(PaletteStyle.inset)
            }
            .frame(width: PaletteStyle.width)
            .frame(maxHeight: 560)
            .background(PaletteStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: PaletteStyle.radius).strokeBorder(PaletteStyle.controlBorder) }
            .elevationShadow(.floating)
        }
    }

    /// Build 83: In Loch zentrieren (Schraube, Hülse), Auf Schraube setzen (Mutter, Scheibe), Kopie.
    @ViewBuilder private func placementButtons(_ spec: StandardPartSpec) -> some View {
        if spec.kind.fitsInHole {
            Button(workspace.centersSelectedPart ? "Bohrung antippen …" : "In Loch zentrieren", systemImage: "scope") {
                workspace.mountStage = .off
                workspace.placesSelectedScrew = false
                workspace.centersSelectedPart.toggle()
                if workspace.centersSelectedPart {
                    model.message = "Kreiskante einer Bohrung oder die Bohrungswand antippen."
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .hoverTip("In Loch zentrieren", "Setzt das Teil genau auf die Achse einer Bohrung, Kopf außen auf der Bohrungskante.")
        }
        if spec.kind.mountsOnScrew {
            Button(workspace.mountStage == .off ? "Auf Schraube setzen" : "Schraube, dann Fläche antippen …",
                   systemImage: "arrow.down.to.line") {
                workspace.centersSelectedPart = false
                workspace.placesSelectedScrew = false
                workspace.mountStage = workspace.mountStage == .off ? .pickScrew : .off
                if workspace.mountStage == .pickScrew { model.message = "Erst die Schraube antippen." }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .hoverTip("Auf Schraube setzen", "Erst die Schraube antippen, dann die Fläche, auf der Mutter bzw. Scheibe aufliegt.")
        }
        Button("Kopie", systemImage: "plus.square.on.square") {
            model.duplicateStandardPart(index)
        }
        .buttonStyle(.bordered)
        .hoverTip("Kopie", "Gleiches Teil noch einmal – danach z. B. in die nächste Bohrung setzen.")
    }

    // MARK: Build 88 – Normteil ändern

    private func update(_ step: String, _ change: @escaping (inout StandardPartSpec) -> Void) {
        model.updateStandardPart(index, step: step, change: change)
    }

    /// Zeile mit Wert in Akzentfarbe und ⌃⌄: antippen öffnet die Auswahl
    private func choice(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).foregroundStyle(Color.accentColor)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .font(.caption)
        .contentShape(Rectangle())
    }

    private func sizeMenu(_ spec: StandardPartSpec) -> some View {
        Menu {
            ForEach(Array(MetricSize.all.enumerated()), id: \.offset) { offset, size in
                Button {
                    update("Größe \(size.name)") { part in
                        part.size = offset
                        // Länge passend halten: nächste Normlänge der neuen Größe
                        if part.kind.isScrew, !size.standardLengths.contains(part.length),
                           let next = size.standardLengths.min(by: { abs($0 - part.length) < abs($1 - part.length) }) {
                            part.length = next
                        }
                    }
                } label: {
                    if offset == spec.size {
                        Label("\(size.name)  (Ø \(size.d.formatted()) mm)", systemImage: "checkmark")
                    } else {
                        Text("\(size.name)  (Ø \(size.d.formatted()) mm)")
                    }
                }
            }
        } label: {
            choice("Größe", spec.metric.name)
        }
    }

    private func lengthMenu(_ spec: StandardPartSpec) -> some View {
        let lengths = Set(spec.metric.standardLengths + [spec.length]).sorted()
        return Menu {
            ForEach(lengths, id: \.self) { length in
                Button {
                    update("Länge \(length.formatted()) mm") { $0.length = length }
                } label: {
                    if length == spec.length {
                        Label("\(length.formatted()) mm", systemImage: "checkmark")
                    } else {
                        Text("\(length.formatted()) mm")
                    }
                }
            }
        } label: {
            choice("Länge", LengthUnit.current.format(spec.length))
        }
    }

    /// Gewindeart (Regel-/Feingewinde), Steigung, Kern-Ø, Profil und Darstellung (vereinfacht/modelliert)
    @ViewBuilder private func threadSection(_ spec: StandardPartSpec) -> some View {
        Divider()
        Text("GEWINDE")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
        Menu {
            Button {
                update("Regelgewinde") { $0.finePitch = false }
            } label: {
                Label("Regelgewinde \(spec.metric.name) · P \(spec.metric.pitch.formatted()) mm",
                      systemImage: spec.finePitch ? "circle" : "checkmark.circle.fill")
            }
            Button {
                update("Feingewinde") { $0.finePitch = true }
            } label: {
                Label("Feingewinde \(spec.metric.name)×\(spec.metric.finePitch.formatted()) · P \(spec.metric.finePitch.formatted()) mm",
                      systemImage: spec.finePitch ? "checkmark.circle.fill" : "circle")
            }
        } label: {
            choice("Gewindeart", spec.finePitch ? "Feingewinde" : "Regelgewinde")
        }
        detail("Bezeichnung", "\(spec.threadDesignation) – \(spec.kind == .nut ? "6H" : "6g")")
        detail("Steigung P", LengthUnit.current.format(spec.pitch))
        detail("Profil", "Metrisch ISO, 60°, rechtsgängig")
        detail("Kern-Ø", LengthUnit.current.format(spec.minorDiameter))
        detail("Gewindetiefe", LengthUnit.current.format(spec.threadDepth))
        if spec.kind.isScrew {
            detail("Gewindelänge", LengthUnit.current.format(spec.modeledThreadLength))
        }
        Picker("Gewindegänge", selection: Binding(
            get: { spec.realThread },
            set: { value in update(value ? "Gewinde modellieren" : "Gewinde vereinfachen") { $0.realThread = value } }
        )) {
            Text("Vereinfacht").tag(false)
            Text("Modelliert").tag(true)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        Text(spec.realThread
             ? "Gewindegänge als echte Schraubenlinie – sichtbar, druckbar, etwas langsamer."
             : "Glatter Schaft mit Nenn-Ø. „Modelliert“ schneidet die Gewindegänge ein.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Divider()
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

// Schnellwahl „Oberfläche“ im Modellmodus (Kai: Würfel modelliert, dann Kupfer, Gold, Silber glänzend oder matt,
// Schwarz glänzend oder matt ausprobieren): schlankes 160-pt-Fenster links neben der rechten Leiste, sobald ein
// Körper (bzw. eine Fläche davon) gewählt ist. Kacheln der häufigsten Oberflächen, Schalter Glänzend/Matt,
// „Mehr …“ öffnet die ganze Bibliothek (SurfaceFinishSection). Gespeichert wird je Körper in SceneBody.finish.

struct BodySurfacePalette: View {
    @ObservedObject var model: ModelStore

    /// Zuletzt gewählte Glanzart der Kacheln
    @AppStorage("surfaceQuick.glossy") private var glossy = true
    /// Fenster auf den Kopf zugeklappt
    @AppStorage("surfaceQuick.collapsed") private var collapsed = false
    @State private var showsMore = false

    /// Gewählte Körper; bei gewählter Fläche oder Kante deren Körper
    private var targets: [Int] {
        let chosen: [Int] = model.selectedBodies.filter { model.bodies.indices.contains($0) }
        if !chosen.isEmpty { return chosen }
        if let body = model.selectedBody, model.bodies.indices.contains(body) { return [body] }
        return []
    }

    var body: some View {
        if let first = targets.first {
            let item: SceneBody = model.bodies[first]
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                // Papierkorb neben dem Kopf: gewählte Körper löschen (BodyDelete.swift)
                HStack(spacing: 4) {
                    header(item, count: targets.count)
                    BodyTrashButton(model: model)
                }
                if !collapsed {
                    glossSwitch(item)
                    tiles(current: item.finish)
                    footer(item, index: first)
                    if model.previewFinishAll != nil {
                        previewNote
                    }
                }
            }
            .frame(width: PaletteStyle.contentWidth, alignment: .leading)
            .padding(PaletteStyle.inset)
            .frame(width: PaletteStyle.width)
            .background(PaletteStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous)
                    .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous))
            .elevationShadow(.floating)
            .onAppear { syncGloss(item.finish) }
            .onChange(of: item.finish) { syncGloss(model.bodies.indices.contains(first) ? model.bodies[first].finish : nil) }
        }
    }

    // MARK: Teile

    private func header(_ item: SceneBody, count: Int) -> some View {
        Button {
            withAnimation(Theme.snappy) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("OBERFLÄCHE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(detailText(item, count: count))
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                FinishSwatch(appearance: item.appearance, size: 20)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Oberfläche")
        .accessibilityValue(collapsed ? "Zugeklappt" : "Aufgeklappt")
        .hoverTip("Oberfläche", "Aussehen des gewählten Körpers: Metall, Lack, Holz … Ändert nur die Darstellung, nicht das Gewicht.")
    }

    private func detailText(_ item: SceneBody, count: Int) -> String {
        let name: String = item.finishName ?? "Nach Werkstoff"
        return count > 1 ? "\(count) Körper · \(name)" : name
    }

    /// Glänzend / Matt: wirkt auf die Kacheln und stellt eine gewählte Oberfläche gleich um
    private func glossSwitch(_ item: SceneBody) -> some View {
        HStack(spacing: 3) {
            glossButton("Glänzend", systemImage: "sparkle", value: true, item: item)
            glossButton("Matt", systemImage: "circle.lefthalf.filled", value: false, item: item)
        }
    }

    private func glossButton(_ title: String, systemImage: String, value: Bool, item: SceneBody) -> some View {
        let active = glossy == value
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        return Button {
            setGloss(value, current: item.finish)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(active ? Color.accentColor : PaletteStyle.field, in: shape)
            .overlay { shape.strokeBorder(active ? Color.accentColor : PaletteStyle.controlBorder, lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func tiles(current: String?) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(SurfaceQuickFamily.all) { family in
                tile(family, current: current)
            }
        }
    }

    private func tile(_ family: SurfaceQuickFamily, current: String?) -> some View {
        let finish: SurfaceFinish? = family.finish(glossy: glossy)
        let selected: Bool = family.contains(current)
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        return Button {
            model.setFinish(family.finishID(glossy: glossy), of: targets)
        } label: {
            VStack(spacing: 2) {
                if let finish {
                    FinishSwatch(appearance: finish.appearance, size: 28)
                }
                Text(family.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(selected ? PaletteStyle.activeFill : Color.clear, in: shape)
            .overlay { shape.strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(finish == nil)
        .accessibilityLabel(finish?.name ?? family.name)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .hoverTip(finish?.name ?? family.name, glossy ? "Glänzend" : "Matt")
    }

    private func footer(_ item: SceneBody, index: Int) -> some View {
        HStack(spacing: 3) {
            Button {
                showsMore = true
            } label: {
                Text("Mehr …")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius,
                                                                         style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                            .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alle Oberflächen")
            .hoverTip("Alle Oberflächen", "Bibliothek mit Metall, Eloxal, RAL-Lacken, Holz, Stein, Kunststoff, Glas und eigener Farbe.")
            .popover(isPresented: $showsMore, arrowEdge: .trailing) {
                ScrollView {
                    SurfaceFinishSection(model: model, bodyIndex: index, initiallyExpanded: true)
                        .padding(16)
                }
                .frame(width: 320)
                .frame(maxHeight: 580)
            }
            if item.finish != nil {
                Button {
                    model.setFinish(nil, of: targets)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 36, height: 32)
                        .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius,
                                                                             style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                                .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Oberfläche entfernen")
                .hoverTip("Oberfläche entfernen", "Wieder nach Werkstoff darstellen")
            }
        }
    }

    /// Hinweis, wenn die Vorschau „Oberfläche für alle Körper“ die eigene Oberfläche überdeckt
    private var previewNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Vorschau für alle Körper aktiv")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Vorschau aus") { model.previewFinishAll = nil }
                .font(.caption.weight(.semibold))
        }
    }

    // MARK: Glanz

    /// Schalter an die gewählte Oberfläche anpassen (z. B. „Gold matt“ gewählt → Matt)
    private func syncGloss(_ finish: String?) {
        if let family = SurfaceQuickFamily.family(of: finish) {
            glossy = finish == family.glossy
        } else if let finish, let custom = SurfaceFinish.custom(finish) {
            glossy = custom.gloss == .glossy
        }
    }

    private func setGloss(_ value: Bool, current: String?) {
        glossy = value
        guard let current else { return }
        if let family = SurfaceQuickFamily.family(of: current) {
            let next: String = family.finishID(glossy: value)
            if next != current { model.setFinish(next, of: targets) }
        } else if let custom = SurfaceFinish.custom(current) {
            let gloss: SurfaceGloss = value ? .glossy : .matte
            if gloss != custom.gloss {
                model.setCustomFinish(color: nil, gloss: gloss, metallic: custom.metallic, of: targets)
            }
        }
    }
}

/// „Oberfläche für alle Körper“ im Sichtbarkeitsmenü: Vorschau-Look nur zur Ansicht (ohne die Körper zu
/// ändern), bei Gefallen allen Körpern zuweisen.
struct SurfacePreviewMenu: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        Menu {
            Picker("Oberfläche für alle Körper", selection: Binding(get: { model.previewFinishAll ?? "" },
                                                                    set: { model.previewFinishAll = $0.isEmpty ? nil : $0 })) {
                Text("Aus (eigene Oberflächen)").tag("")
                ForEach(SurfaceQuickFamily.all) { family in
                    Text(SurfaceFinish.named(family.glossy)?.name ?? family.glossy).tag(family.glossy)
                    Text(SurfaceFinish.named(family.matte)?.name ?? family.matte).tag(family.matte)
                }
            }
            if let id = model.previewFinishAll {
                Divider()
                Button("Allen Körpern zuweisen", systemImage: "checkmark.circle") {
                    model.previewFinishAll = nil
                    model.setFinish(id, of: Array(model.bodies.indices))
                }
            }
        } label: {
            Label(model.previewFinishAll.flatMap { SurfaceFinish.named($0)?.name }
                    .map { "Oberfläche für alle: \($0)" } ?? "Oberfläche für alle Körper",
                  systemImage: "paintbrush.pointed")
        }
        .disabled(model.bodies.isEmpty)
    }
}
