import SwiftUI

// Bausteine der rechten Skizzenpalette nach SolidCraft (crates/ui-egui/src/sketch_palette.rs, ui_kit):
// Abschnitte mit Titel in Großbuchstaben, Bildknöpfe für Varianten, Wertzeilen mit Beschriftung über dem
// Ausdrucksfeld, Schalterzeilen und ein breiter Primärknopf. Kai wollte das rechte Fenster schlank (halb so breit
// wie zuvor 264 pt): Touch-Ziele 36–38 pt, Beschriftungen über den Feldern statt daneben.

/// Maße und Farben der Skizzenpalette (dunkel, Anthrazit wie SolidCraft `Tokens::dark()`).
enum PaletteStyle {
    /// Breite des rechten Fensters (halb so breit wie die frühere Palette mit 264 pt)
    static let width: CGFloat = 160
    /// Innenabstand des Fensters
    static let inset: CGFloat = 8
    /// Nutzbare Breite im Fenster
    static let contentWidth: CGFloat = width - 2 * inset
    /// Mindesthöhe antippbarer Zeilen und Knöpfe
    static let touch: CGFloat = 38
    /// Höhe der Bildknöpfe und Eingabefelder
    static let iconButton: CGFloat = 36
    static let spacing: CGFloat = 6
    static let radius: CGFloat = 12
    static let controlRadius: CGFloat = 8

    /// Panel-Grund `panel` #272B34
    static let background = Color(red: 0x27 / 255, green: 0x2B / 255, blue: 0x34 / 255)
    /// Kopf und Fuß `panel_header` #2F343E
    static let header = Color(red: 0x2F / 255, green: 0x34 / 255, blue: 0x3E / 255)
    /// Eingabefeld `field` #1E2229
    static let field = Color(red: 0x1E / 255, green: 0x22 / 255, blue: 0x29 / 255)
    /// Trennlinie und Rand
    static let rule = Color.primary.opacity(0.10)
    static let controlBorder = Color.primary.opacity(0.18)
    /// Aktiver Bildknopf, gesperrter Wert (`accent_soft`)
    static let activeFill = Color.accentColor.opacity(0.24)
}

// MARK: Fenster

/// Das eine schlanke Fenster rechts (Skizzenmodus und offener Modellbefehl): oben Ansichtswürfel und
/// Ansichtsknöpfe, darunter Kopf, scrollender Mittelteil und fester Fuß. Alles hat feste Breite, damit nichts
/// außerhalb des Fensters Berührungen abfängt (eine zu breite ScrollView hatte das Zeichnen blockiert).
struct PaletteWindow<Top: View, Header: View, Middle: View, Footer: View>: View {
    @ViewBuilder let top: Top
    @ViewBuilder let header: Header
    @ViewBuilder let middle: Middle
    @ViewBuilder let footer: Footer

    /// Höhe des scrollbaren Mittelteils; kurze Inhalte machen das Fenster nicht unnötig hoch
    @State private var contentHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            top
                .frame(width: PaletteStyle.contentWidth)
                .padding(PaletteStyle.inset)
            PaletteRule()
            header
                .frame(width: PaletteStyle.contentWidth, alignment: .leading)
                .padding(PaletteStyle.inset)
                .background(PaletteStyle.header)
            PaletteRule()
            ScrollView(.vertical, showsIndicators: true) {
                middle
                    .frame(width: PaletteStyle.contentWidth, alignment: .leading)
                    .padding(PaletteStyle.inset)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PaletteContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(width: PaletteStyle.width)
            .frame(maxHeight: contentHeight)
            .onPreferenceChange(PaletteContentHeightKey.self) { contentHeight = $0 }
            PaletteRule()
            footer
                .frame(width: PaletteStyle.contentWidth)
                .padding(PaletteStyle.inset)
                .background(PaletteStyle.header)
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
        // Dunkel (Anthrazit): Text, Systemfarben und die „sc.*-dark“-Bilder passend dazu
        .environment(\.colorScheme, .dark)
    }
}

struct PaletteContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Beschriftung über einem Feld (schmales Fenster: kein Platz für eine Spalte daneben).
struct PaletteFieldLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            // Nie mit „…“ kürzen: lange Beschriftungen brechen im schmalen Fenster um
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Beschriftung oben, darunter das Feld in voller Breite.
struct PaletteLabeled<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            PaletteFieldLabel(title: title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Spalten einer Segmentreihe: kurze Wahlen (X/Y/Z, „Neu“) in einer Reihe, längere zu zweit umbrechend.
func paletteSegmentColumns(_ labels: [String]) -> [GridItem] {
    let count: Int
    if labels.count <= 2 || labels.allSatisfy({ $0.count <= 4 }) {
        count = max(1, min(labels.count, 4))
    } else {
        count = 2
    }
    return Array(repeating: GridItem(.flexible(), spacing: 3), count: count)
}

// MARK: Abschnitt

/// Abschnitt mit Titel in Großbuchstaben, optional aufklappbar (SolidCraft `ui_kit::section`).
struct PaletteSection<Content: View>: View {
    let title: String
    var detail: String?
    var collapsible: Bool
    @State private var isExpanded: Bool
    let content: Content

    init(_ title: String, detail: String? = nil, collapsible: Bool = true, expanded: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.collapsible = collapsible
        _isExpanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            if collapsible {
                Button {
                    withAnimation(Theme.snappy) { isExpanded.toggle() }
                } label: {
                    heading
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Aufgeklappt" : "Zugeklappt")
            } else {
                heading
            }
            if isExpanded || !collapsible {
                content
            }
        }
    }

    /// Titel in Großbuchstaben, die Angabe (Werkzeug, Auswahl) darunter – nebeneinander passt beides nicht.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if collapsible {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: collapsible ? PaletteStyle.touch : 22, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Feine Trennlinie zwischen Abschnitten.
struct PaletteRule: View {
    var body: some View {
        Rectangle()
            .fill(PaletteStyle.rule)
            .frame(height: 1)
    }
}

// MARK: Bildknöpfe

/// Eine Wahl in einer Reihe von Bildknöpfen (Variante, Linientyp, Art).
struct IconChoice: Identifiable {
    let id: String
    let title: String
    /// „sc.“-Bild aus dem Katalog oder SF Symbol
    let icon: String
    var isEnabled = true
}

/// Bildknöpfe 36 pt hoch, standardmäßig drei je Reihe (umbrechend); aktiv mit getöntem Grund und Rand
/// (SolidCraft `palettes.rs:94-98`).
struct IconSegment: View {
    let choices: [IconChoice]
    /// Gewählte Einträge (mehrere bei gemischter Auswahl, z. B. Linientypen)
    let selected: Set<String>
    /// Knöpfe je Reihe (Linientyp: 2 × 2)
    var columnCount = 3
    let pick: (String) -> Void

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: max(1, columnCount))
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(choices) { choice in
                IconChoiceButton(choice: choice, isSelected: selected.contains(choice.id)) {
                    pick(choice.id)
                }
            }
        }
    }
}

private struct IconChoiceButton: View {
    let choice: IconChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        Button(action: action) {
            glyph
                .frame(maxWidth: .infinity)
                .frame(height: PaletteStyle.iconButton)
                .background(isSelected ? PaletteStyle.activeFill : Color.primary.opacity(0.05), in: shape)
                .overlay {
                    shape.strokeBorder(isSelected ? Color.accentColor : PaletteStyle.controlBorder,
                                       lineWidth: isSelected ? 1.5 : 1)
                }
                .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .disabled(!choice.isEnabled)
        .opacity(choice.isEnabled ? 1 : 0.35)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .hoverTip(choice.title)
    }

    @ViewBuilder private var glyph: some View {
        if ToolIcon.isCustom(choice.icon) {
            ToolIcon(choice.icon, size: 24)
        } else {
            Image(systemName: choice.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
    }
}

// MARK: Wertzeilen

/// Liest einen Ausdruck wie NumberField: Länge in der Projekteinheit („mm“), sonst als Zahl (Grad, Faktor).
enum PaletteExpression {
    static func evaluate(_ text: String, unit: String, variables: [String: Double]) throws -> Double {
        unit == "mm" ? try Formula.evaluateLength(text, variables: variables)
            : try Formula.evaluate(text, variables: variables)
    }

    static func shown(_ value: Double, unit: String) -> String {
        unit == "mm" ? LengthUnit.current.number(value) : NumberField.format(value)
    }

    static func unitSymbol(_ unit: String) -> String {
        unit == "mm" ? LengthUnit.current.symbol : unit
    }
}

/// Zahlenzeile: Beschriftung, Ausdrucksfeld mit Einheit. Übernimmt beim Bestätigen (wie NumberField).
struct PaletteNumberRow: View {
    let title: String
    let value: Double
    var unit = "mm"
    let set: (Double) -> Void

    @Environment(\.variableValues) private var variables
    @State private var text = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        PaletteLabeled(title: title) {
            PaletteFieldBox(isLocked: false, hasError: error != nil) {
                TextField(title, text: $text)
                    .focused($isFocused)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onChange(of: value) { _, newValue in
                        if !isFocused { text = PaletteExpression.shown(newValue, unit: unit) }
                    }
                    .onAppear { text = PaletteExpression.shown(value, unit: unit) }
                if !unit.isEmpty {
                    Text(PaletteExpression.unitSymbol(unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .help(error ?? "")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            text = PaletteExpression.shown(value, unit: unit)
            error = nil
            return
        }
        do {
            let result = try PaletteExpression.evaluate(trimmed, unit: unit, variables: variables)
            error = nil
            set(result)
            text = PaletteExpression.shown(result, unit: unit)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Sperrbarer Wert beim Zeichnen (SolidCraft `sketch_dims`): ohne Sperre zeigt das Feld den Live-Wert am Stift,
/// eine Eingabe sperrt ihn (`options.locked[key]` = Ausdruck), das Schloss löst ihn bzw. hält den Live-Wert fest.
struct PaletteLockRow: View {
    let title: String
    /// Schlüssel in `SketchToolOptions.locked` („Länge“, „Winkel“ …)
    let key: String
    var unit = "mm"
    /// Live-Wert der aktuellen Stufe (nil = noch nichts gezeichnet)
    let live: Double?
    @ObservedObject var options: SketchToolOptions

    @Environment(\.variableValues) private var variables
    @State private var text = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    private var lockedText: String? { options.locked[key] }

    var body: some View {
        PaletteLabeled(title: title) {
            HStack(spacing: 2) {
                lockField
                lockButton
            }
        }
        .help(error ?? "")
    }

    private var lockField: some View {
        PaletteFieldBox(isLocked: lockedText != nil, hasError: error != nil) {
            TextField(live.map { PaletteExpression.shown($0, unit: unit) } ?? "–", text: $text)
                .focused($isFocused)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onChange(of: lockedText) { _, newValue in
                    if !isFocused { text = newValue ?? "" }
                }
                .onAppear { text = lockedText ?? "" }
            if !unit.isEmpty {
                Text(PaletteExpression.unitSymbol(unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private var lockButton: some View {
        Button(action: toggleLock) {
            Image(systemName: lockedText != nil ? "lock.fill" : "lock.open")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lockedText != nil ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: PaletteStyle.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lockedText == nil && live == nil)
        .accessibilityLabel(lockedText != nil ? "\(title) lösen" : "\(title) sperren")
        .hoverTip(lockedText != nil ? "Wert lösen" : "Wert sperren",
                  lockedText != nil ? "Der Wert folgt wieder dem Stift."
                                    : "Hält den aktuellen Wert fest; er wird beim Setzen als Bemaßung angelegt.")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Feld geleert: Sperre aufheben
            error = nil
            if lockedText != nil { options.locked[key] = nil }
            return
        }
        guard trimmed != lockedText else { return }
        do {
            _ = try PaletteExpression.evaluate(trimmed, unit: unit, variables: variables)
            error = nil
            options.locked[key] = trimmed
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleLock() {
        if lockedText != nil {
            options.locked[key] = nil
            text = ""
        } else if let live {
            let shown = PaletteExpression.shown(live, unit: unit)
            options.locked[key] = shown
            text = shown
        }
    }
}

/// Feldrahmen: Grund `field`, Rand `controlBorder`, gesperrt mit getöntem Grund und kleinem Schloss.
struct PaletteFieldBox<Content: View>: View {
    var isLocked: Bool
    var hasError: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        HStack(spacing: 4) {
            content
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton)
        .background(isLocked ? PaletteStyle.activeFill : PaletteStyle.field, in: shape)
        .overlay {
            shape.strokeBorder(hasError ? Color.red : (isLocked ? Color.accentColor.opacity(0.7) : PaletteStyle.controlBorder),
                               lineWidth: hasError ? 1.5 : 1)
        }
    }
}

// MARK: Schalter, Anzahl, Knöpfe

/// Schalterzeile (SolidCraft-Checkbox) mit Symbol.
struct CheckRow: View {
    let title: String
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                if let icon {
                    ToolIcon(icon, size: 16)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: PaletteStyle.iconButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "Ein" : "Aus")
    }
}

/// Anzahl mit Minus/Plus (SolidCraft „Anzahl (±)“).
struct CountRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        PaletteLabeled(title: title) {
            HStack(spacing: PaletteStyle.spacing) {
                stepButton("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - 1) }
                Text("\(value)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                stepButton("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + 1) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 1)
            case .decrement: value = max(range.lowerBound, value - 1)
            @unknown default: break
            }
        }
    }

    private func stepButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .frame(width: PaletteStyle.touch, height: PaletteStyle.iconButton)
                .background(PaletteStyle.field,
                            in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                        .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Breiter Knopf: Primär (Akzentfarbe, z. B. „Skizze beenden“) oder sekundär (Rahmen).
struct PrimaryWideButton: View {
    let title: String
    var systemImage: String?
    var isPrimary = true
    var isActive = false
    /// false: nur das Symbol (schmales Fenster; der Name steht im Hinweis und in der Bedienungshilfe)
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                if showsTitle || systemImage == nil {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(.horizontal, 4)
            .foregroundStyle(isPrimary ? Color.white : (isActive ? Color.accentColor : Color.primary))
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch)
            .background(isPrimary ? Color.accentColor : (isActive ? PaletteStyle.activeFill : PaletteStyle.field), in: shape)
            .overlay {
                if !isPrimary {
                    shape.strokeBorder(isActive ? Color.accentColor : PaletteStyle.controlBorder, lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
    }
}

/// Hinweistext des Werkzeugs (SolidCraft `sketch_tools` hint).
struct PaletteHint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "hand.point.up.left")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Auswahl als Segmente, senkrecht gut lesbar (Schrift, Ausrichtung, Eingabestil).
struct PalettePickerRow<Value: Hashable, Options: RandomAccessCollection>: View where Options.Element == Value {
    let title: String
    @Binding var selection: Value
    let options: Options
    let label: (Value) -> String

    var body: some View {
        PaletteLabeled(title: title) {
            Picker(title, selection: $selection) {
                ForEach(Array(options), id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.iconButton, alignment: .leading)
        }
    }
}
