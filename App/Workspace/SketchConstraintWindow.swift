import SwiftUI

// Build 63 (Kai): „Bedingungen“ als eigenes Fenster rechts unter dem Fenster mit dem Fang „U“ – vorher Abschnitt
// „Bedingen“ in der linken Leiste. Oben Bemaßung und Trennen, darunter alle Bedingungen (passend zur Auswahl farbig,
// wartend blau), dazu die Schalter „Bedingungen“ und „Bemaßungen“ anzeigen. Die Überschrift klappt es zu.

/// AppStorage-Schlüssel: Fenster „Bedingungen“ aufgeklappt
enum SketchConstraintWindowState {
    static let openKey = "sketch.constraintWindowOpen"
}

struct SketchConstraintWindow: View {
    @ObservedObject var sketch: SketchController
    @AppStorage(SketchConstraintWindowState.openKey) private var isOpen = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.snappy) { isOpen.toggle() }
            } label: {
                HStack {
                    Text("BEDINGUNGEN")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bedingungen")
            .accessibilityValue(isOpen ? "Aufgeklappt" : "Zugeklappt")
            .padding(.horizontal, PaletteStyle.inset)
            .background(PaletteStyle.header)
            if isOpen {
                PaletteRule()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        wideButton(title: ConstraintKind.dimension.rawValue, icon: ConstraintKind.dimension.systemImage,
                                   isActive: false) {
                            if sketch.pendingAction != nil { sketch.cancelPending() }
                            sketch.tool = .select
                            sketch.notice = ConstraintKind.dimension.selectionHint
                        }
                        wideButton(title: "Trennen", icon: "link.badge.plus", isActive: sketch.pendingAction == .detach) {
                            sketch.start(.detach)
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(kinds, id: \.self) { kind in
                            cell(kind)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        CheckRow(title: "Bedingungen anzeigen", isOn: $sketch.showsConstraintBadges)
                        CheckRow(title: "Bemaßungen anzeigen", isOn: $sketch.showsDimensions)
                    }
                }
                .padding(PaletteStyle.inset)
                .disabled(sketch.isChoosingPlane)
            }
        }
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
    }

    private var kinds: [ConstraintKind] {
        [ConstraintKind.lock] + ConstraintKind.allCases.filter { $0 != .lock && $0 != .dimension }
    }

    private func wideButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ToolIcon(icon, size: 18)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background(isActive ? PaletteStyle.activeFill : PaletteStyle.field,
                        in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    private func cell(_ kind: ConstraintKind) -> some View {
        let pending = sketch.pendingAction == .constraint(kind)
        let active = sketch.canApply(kind) || pending
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        return Button {
            sketch.start(.constraint(kind))
        } label: {
            VStack(spacing: 2) {
                glyph(kind.systemImage, active: active)
                    .frame(height: 26)
                Text(kind.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(pending ? Color.accentColor.opacity(0.22) : PaletteStyle.field, in: shape)
            .overlay { if pending { shape.strokeBorder(Color.accentColor, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(kind.rawValue)
        .accessibilityAddTraits(pending ? .isSelected : [])
        .hoverTip(kind.rawValue, kind.selectionHint)
    }

    @ViewBuilder private func glyph(_ icon: String, active: Bool) -> some View {
        if ToolIcon.isCustom(icon) {
            ToolIcon(icon, size: 22)
                .saturation(active ? 1 : 0)
                .opacity(active ? 1 : 0.5)
        } else {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.5))
        }
    }
}
