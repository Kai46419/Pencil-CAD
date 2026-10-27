import SwiftUI

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
                header(item, count: targets.count)
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
            .environment(\.colorScheme, .dark)
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
