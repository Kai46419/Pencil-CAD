import GameController
import SwiftUI
import UIKit

// MARK: Kompakter Ziffernblock für alle Zahlenfelder

private struct UsesCompactKeypadKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Zahlenfelder (PaletteNumberRow, CountRow) öffnen beim Antippen statt der großen Bildschirmtastatur einen
    /// kleinen Ziffernblock neben dem Feld. Standard an (überall); false nur, wo ausdrücklich die Tastatur gewollt ist.
    var usesCompactKeypad: Bool {
        get { self[UsesCompactKeypadKey.self] }
        set { self[UsesCompactKeypadKey.self] = newValue }
    }
}

/// Ziffernblock im Popover neben dem Feld (das Feld und das Modell bleiben sichtbar): Ziffern, Komma, ±,
/// Rechenzeichen + − × ÷ für Formeln, Löschen, Leeren, Schritte −1/+1, „abc“ (Bildschirmtastatur für Variablen)
/// und OK. Der erste Tastendruck ersetzt den angezeigten Wert (wie ein markierter Wert), danach wird angehängt;
/// ein Rechenzeichen als erster Druck rechnet mit dem angezeigten Wert weiter („45“ → „45 + …“).
/// Eine Hardware-Tastatur tippt direkt in den Block (Ziffern, Rechenzeichen, Buchstaben, ⌫, Return, Esc).
struct CompactKeypad: View {
    let title: String
    @Binding var text: String
    var unitSymbol = ""
    /// Ganzzahl (Anzahl): ohne Komma, Vorzeichen, Rechenzeichen und Bildschirmtastatur
    var isInteger = false
    /// Text nach einem Schritt (+1 / −1), nil = Eingabe nicht lesbar; ohne Funktion keine Schritttasten
    var step: ((Int) -> String?)?
    let onDone: () -> Void
    /// Umschalten auf die Bildschirmtastatur (nil = nicht angeboten)
    var onKeyboard: (() -> Void)?

    @State private var replaces = true
    /// Fokus für Tastendrücke einer Hardware-Tastatur
    @FocusState private var hasKeyFocus: Bool

    fileprivate enum Key: Hashable {
        case digit(String), comma, sign, plus, minus, times, divide, delete, clear, stepDown, stepUp, keyboard, done, blank
    }

    private static let keyWidth: CGFloat = 46
    private static let keyHeight: CGFloat = 40
    private static let gap: CGFloat = 6

    private var columns: Int { isInteger ? 4 : 5 }
    private var totalWidth: CGFloat { Self.keyWidth * CGFloat(columns) + Self.gap * CGFloat(columns - 1) }

    private var rows: [[Key]] {
        let down: Key = step == nil ? .blank : .stepDown
        let up: Key = step == nil ? .blank : .stepUp
        if isInteger {
            return [
                [down, up, .clear, .delete],
                [.digit("7"), .digit("8"), .digit("9"), .blank],
                [.digit("4"), .digit("5"), .digit("6"), .blank],
                [.digit("1"), .digit("2"), .digit("3"), .blank],
                [.digit("0"), .done],
            ]
        }
        return [
            [down, up, .clear, .delete, .divide],
            [.digit("7"), .digit("8"), .digit("9"), .sign, .times],
            [.digit("4"), .digit("5"), .digit("6"), onKeyboard == nil ? .blank : .keyboard, .minus],
            [.digit("1"), .digit("2"), .digit("3"), .comma, .plus],
            [.digit("0"), .done],
        ]
    }

    /// Breite einer Taste in Tastenbreiten (letzte Reihe: 0 und OK füllen die Reihe)
    private func span(_ key: Key) -> Int {
        switch key {
        case .digit("0"): 2
        case .done: columns - 2
        default: 1
        }
    }

    var body: some View {
        VStack(spacing: Self.gap) {
            display
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        keyButton(key)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: totalWidth + 20)
        .background(PaletteStyle.background)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focused($hasKeyFocus)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            hardwareKey(press) ? .handled : .ignored
        }
        .onAppear { hasKeyFocus = true }
        .presentationBackground(PaletteStyle.background)
        .presentationCompactAdaptation(.popover)
    }

    /// Anzeige: Titel, Wert (markiert, solange der erste Tastendruck ihn ersetzt) und Einheit
    private var display: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(text.isEmpty ? " " : text)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 3)
                .background(replaces && !text.isEmpty ? Color.accentColor.opacity(0.35) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            if !unitSymbol.isEmpty {
                Text(unitSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(width: totalWidth, height: 40)
        .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
    }

    @ViewBuilder private func keyButton(_ key: Key) -> some View {
        let keys = CGFloat(span(key))
        let width = Self.keyWidth * keys + Self.gap * (keys - 1)
        if key == .blank {
            Color.clear.frame(width: width, height: Self.keyHeight)
        } else {
            let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                press(key)
            } label: {
                keyLabel(key)
                    .frame(width: width, height: Self.keyHeight)
                    .foregroundStyle(foreground(key))
                    .background(fill(key), in: shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibility(key))
        }
    }

    @ViewBuilder private func keyLabel(_ key: Key) -> some View {
        switch key {
        case .digit(let digit):
            Text(digit).font(.system(size: 20, weight: .semibold).monospacedDigit())
        case .comma:
            Text(",").font(.system(size: 20, weight: .semibold))
        case .sign:
            Text("±").font(.system(size: 19, weight: .semibold))
        case .plus:
            Text("+").font(.system(size: 20, weight: .semibold))
        case .minus:
            Text("−").font(.system(size: 20, weight: .semibold))
        case .times:
            Text("×").font(.system(size: 20, weight: .semibold))
        case .divide:
            Text("÷").font(.system(size: 20, weight: .semibold))
        case .delete:
            Image(systemName: "delete.left").font(.system(size: 16, weight: .semibold))
        case .clear:
            Text("C").font(.system(size: 17, weight: .semibold))
        case .stepDown:
            Text("−1").font(.system(size: 15, weight: .semibold).monospacedDigit())
        case .stepUp:
            Text("+1").font(.system(size: 15, weight: .semibold).monospacedDigit())
        case .keyboard:
            Text("abc").font(.system(size: 15, weight: .semibold))
        case .done:
            Text("OK").font(.system(size: 17, weight: .bold))
        case .blank:
            EmptyView()
        }
    }

    private func foreground(_ key: Key) -> Color {
        switch key {
        case .done: Color.white
        case .plus, .minus, .times, .divide: Color.accentColor
        default: Color.primary
        }
    }

    private func fill(_ key: Key) -> Color {
        switch key {
        case .done: Color.accentColor
        case .digit, .comma: PaletteStyle.header
        default: PaletteStyle.field
        }
    }

    private func accessibility(_ key: Key) -> String {
        switch key {
        case .digit(let digit): digit
        case .comma: "Komma"
        case .sign: "Vorzeichen wechseln"
        case .plus: "Plus"
        case .minus: "Minus"
        case .times: "Mal"
        case .divide: "Geteilt durch"
        case .delete: "Löschen"
        case .clear: "Leeren"
        case .stepDown: "Eins weniger"
        case .stepUp: "Eins mehr"
        case .keyboard: "Bildschirmtastatur"
        case .done: "OK"
        case .blank: ""
        }
    }

    /// Zeichen, nach denen ein „-“ ein Vorzeichen ist (kein Minus-Rechenzeichen)
    private static let operators: Set<Character> = ["+", "-", "−", "*", "×", "/", "÷", "(", "^"]

    /// Hat die Zahl am Ende schon ein Dezimalzeichen („12,5“ bzw. „12.5“ je nach Sprache)? Dann kein zweites Komma.
    private var trailingNumberHasSeparator: Bool {
        let run = text.reversed().prefix(while: { $0.isNumber || $0 == "," || $0 == "." })
        return run.contains(",") || run.contains(".")
    }

    private func press(_ key: Key) {
        switch key {
        case .digit(let digit):
            if replaces || text == "0" { text = digit } else { text += digit }
            replaces = false
        case .comma:
            if replaces || text.isEmpty {
                text = "0,"
            } else if !trailingNumberHasSeparator {
                if !(text.last?.isNumber ?? false) { text += "0" }
                text += ","
            }
            replaces = false
        case .sign:
            toggleSign()
            replaces = false
        case .plus:
            appendOperator("+")
        case .minus:
            appendOperator("-")
        case .times:
            appendOperator("×")
        case .divide:
            appendOperator("÷")
        case .delete:
            if replaces { text = "" } else if !text.isEmpty { text.removeLast() }
            replaces = false
        case .clear:
            text = ""
            replaces = false
        case .stepDown, .stepUp:
            if let stepped = step?(key == .stepUp ? 1 : -1) {
                text = stepped
                replaces = true
            }
        case .keyboard:
            onKeyboard?()
        case .done:
            onDone()
        case .blank:
            break
        }
    }

    /// Rechenzeichen anhängen: rechnet mit dem angezeigten Wert weiter; ein Zeichen direkt nach einem anderen
    /// ersetzt dieses (außer „−“ als Vorzeichen nach × ÷).
    private func appendOperator(_ symbol: Character) {
        replaces = false
        guard let last = text.last else {
            if symbol == "-" { text = "-" }
            return
        }
        if Self.operators.contains(last) {
            if symbol == "-" && (last == "×" || last == "÷" || last == "*" || last == "/" || last == "(") {
                text.append(symbol)
            } else if text.count > 1 {
                text.removeLast()
                text.append(symbol)
            }
            return
        }
        if last == "," || last == "." { text.removeLast() }
        text.append(symbol)
    }

    /// ± wechselt das Vorzeichen der letzten Zahl: „45“ ↔ „-45“, „10+5“ ↔ „10-5“, „2×5“ ↔ „2×-5“.
    private func toggleSign() {
        var chars = Array(text)
        var start = chars.count
        while start > 0, chars[start - 1].isNumber || chars[start - 1] == "," || chars[start - 1] == "." {
            start -= 1
        }
        guard start > 0 else {
            chars.insert("-", at: 0)
            text = String(chars)
            return
        }
        let before = chars[start - 1]
        if before == "-" || before == "−" {
            let isSign = start - 1 == 0 || Self.operators.contains(chars[start - 2])
            if isSign { chars.remove(at: start - 1) } else { chars[start - 1] = "+" }
        } else if before == "+" {
            chars[start - 1] = "-"
        } else {
            chars.insert("-", at: start)
        }
        text = String(chars)
    }

    /// Hardware-Tastatur: Ziffern, Komma/Punkt, Rechenzeichen, Buchstaben (Variablen), ⌫, Return/Esc = OK.
    private func hardwareKey(_ keyPress: KeyPress) -> Bool {
        if keyPress.modifiers.contains(.command) { return false }
        if keyPress.key == .return || keyPress.key == .escape {
            press(.done)
            return true
        }
        if keyPress.key == .delete {
            press(.delete)
            return true
        }
        guard keyPress.characters.count == 1, let character = keyPress.characters.first else { return false }
        if character.isNumber {
            press(.digit(String(character)))
            return true
        }
        if isInteger { return false }
        switch character {
        case ",", ".": press(.comma)
        case "+": press(.plus)
        case "-": press(.minus)
        case "*": press(.times)
        case "/": press(.divide)
        default:
            // Variablen und Formeln („wand“, „sqrt(2)“): Zeichen wie getippt anhängen
            guard character.isLetter || "_()^; ".contains(character) else { return false }
            if replaces { text = "" }
            text.append(character)
            replaces = false
        }
        return true
    }
}

// MARK: Zentrales Zahlenfeld

/// Zahlenfeld für die ganze App: Antippen öffnet den kleinen Ziffernblock im Popover am Feld statt der großen
/// Bildschirmtastatur, die Feld und Modell verdeckt. „abc“ schaltet für Variablen und Formeln auf ein echtes
/// Textfeld um; mit angeschlossener Hardware-Tastatur ist das Feld gleich ein Textfeld (Tippen wie gewohnt).
/// Der Text ändert sich beim Tippen (Bindung); `onCommit` übernimmt bei OK, Return oder Antippen daneben.
struct KeypadField: View {
    let title: String
    @Binding var text: String
    /// Bearbeitung läuft (Ziffernblock offen oder Textfeld aktiv); von außen auf true setzen öffnet das Feld
    @Binding var isEditing: Bool
    var placeholder = ""
    var unitSymbol = ""
    /// Ganzzahl: Block ohne Komma und Rechenzeichen
    var isInteger = false
    var alignment: TextAlignment = .trailing
    var minHeight: CGFloat = PaletteStyle.iconButton - 4
    /// Schritt +1 / −1 vom eingegebenen Text aus (nil = keine Schritttasten)
    var step: ((Int) -> String?)?
    let onCommit: () -> Void

    /// Ziffernblock offen
    @State private var showsPad = false
    /// Echtes Textfeld (nach „abc“ oder mit Hardware-Tastatur)
    @State private var typesWithKeyboard = false
    @FocusState private var isFocused: Bool

    /// Ist eine Hardware-Tastatur angeschlossen? Dann bleibt die Bildschirmtastatur ohnehin zu.
    static var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    var body: some View {
        Group {
            if typesWithKeyboard {
                textField
            } else {
                padButton
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing && !showsPad && !typesWithKeyboard {
                begin()
            } else if !editing && showsPad {
                showsPad = false
            } else if !editing && typesWithKeyboard {
                isFocused = false
            }
        }
        .onAppear {
            if isEditing && !showsPad && !typesWithKeyboard { begin() }
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        default: .trailing
        }
    }

    /// Feld als Knopf: öffnet den Ziffernblock daneben, das Feld zeigt dabei die Eingabe mit
    private var padButton: some View {
        Button(action: begin) {
            Text(text.isEmpty ? (placeholder.isEmpty ? " " : placeholder) : text)
                .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: frameAlignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .popover(isPresented: $showsPad, arrowEdge: .trailing) {
            CompactKeypad(title: title, text: $text, unitSymbol: unitSymbol, isInteger: isInteger, step: step,
                          onDone: { showsPad = false }, onKeyboard: isInteger ? nil : switchToKeyboard)
        }
        .onChange(of: showsPad) { _, shown in
            guard !shown && !typesWithKeyboard else { return }
            // „12,“ (Komma ohne Nachkommastelle) gilt als „12“, sonst meldet der Formelleser ein Zeichen zu viel
            if text.hasSuffix(",") || text.hasSuffix(".") { text.removeLast() }
            isEditing = false
            onCommit()
        }
    }

    private var textField: some View {
        TextField(placeholder.isEmpty ? title : placeholder, text: $text)
            .focused($isFocused)
            .keyboardType(isInteger ? .numberPad : .numbersAndPunctuation)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .multilineTextAlignment(alignment)
            .monospacedDigit()
            .frame(minHeight: minHeight)
            .onSubmit(finishTyping)
            .onChange(of: isFocused) { _, focused in
                if !focused { finishTyping() }
            }
    }

    private func begin() {
        isEditing = true
        if Self.hasHardwareKeyboard {
            typesWithKeyboard = true
            DispatchQueue.main.async { isFocused = true }
        } else {
            showsPad = true
        }
    }

    private func switchToKeyboard() {
        typesWithKeyboard = true
        showsPad = false
        // Erst nach dem Schließen des Popovers fokussieren, sonst bleibt die Tastatur zu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { isFocused = true }
    }

    private func finishTyping() {
        guard typesWithKeyboard else { return }
        typesWithKeyboard = false
        isEditing = false
        onCommit()
    }
}

/// Zahlenfeld für einen Double-Wert (ohne Formel-Speicherung): Ziffernblock, Formeln werden sofort ausgerechnet.
struct KeypadNumberField: View {
    let title: String
    @Binding var value: Double
    /// Nachkommastellen in der Anzeige
    var digits = 2
    var unitSymbol = ""
    var minHeight: CGFloat = 28

    @Environment(\.variableValues) private var variables
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        KeypadField(title: title, text: $text, isEditing: $editing, unitSymbol: unitSymbol, isInteger: digits == 0,
                    minHeight: minHeight, step: stepped, onCommit: commit)
            .onAppear { text = shown(value) }
            .onChange(of: value) { _, newValue in
                if !editing { text = shown(newValue) }
            }
    }

    private func shown(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never))
    }

    private func stepped(_ direction: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let current = trimmed.isEmpty ? value : (try? Formula.evaluate(trimmed, variables: variables))
        guard let current else { return nil }
        return shown(current + Double(direction))
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let result = try? Formula.evaluate(trimmed, variables: variables), result.isFinite {
            value = result
        }
        text = shown(value)
    }
}
