import SwiftUI
import UIKit

// MARK: Kompakter Ziffernblock für Zahlenfelder im rechten Fenster

private struct UsesCompactKeypadKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Zahlenfelder (PaletteNumberRow, CountRow) öffnen beim Antippen statt der großen Bildschirmtastatur einen
    /// kleinen Ziffernblock neben dem Feld. Standard aus; die Muster-Panels schalten ihn ein.
    var usesCompactKeypad: Bool {
        get { self[UsesCompactKeypadKey.self] }
        set { self[UsesCompactKeypadKey.self] = newValue }
    }
}

/// Ziffernblock im Popover neben dem Feld (das Feld bleibt sichtbar): Ziffern, Komma, Minus, Löschen, Leeren,
/// Schritte −1/+1, „abc“ (Bildschirmtastatur für Formeln und Variablen) und OK.
/// Der erste Tastendruck ersetzt den angezeigten Wert (wie ein markierter Wert), danach wird angehängt.
struct CompactKeypad: View {
    let title: String
    @Binding var text: String
    var unitSymbol = ""
    /// Ganzzahl (Anzahl): ohne Komma, Minus und Bildschirmtastatur
    var isInteger = false
    /// Text nach einem Schritt (+1 / −1), nil = Eingabe nicht lesbar
    let step: (Int) -> String?
    let onDone: () -> Void
    /// Umschalten auf die Bildschirmtastatur (nil = nicht angeboten)
    var onKeyboard: (() -> Void)?

    @State private var replaces = true

    fileprivate enum Key: Hashable {
        case digit(String), comma, minus, delete, clear, stepDown, stepUp, keyboard, done, blank
    }

    private static let keyWidth: CGFloat = 46
    private static let keyHeight: CGFloat = 40
    private static let gap: CGFloat = 6
    private static var wideWidth: CGFloat { keyWidth * 2 + gap }
    private static var totalWidth: CGFloat { keyWidth * 4 + gap * 3 }

    private var rows: [[Key]] {
        [
            [.stepDown, .stepUp, .clear, .delete],
            [.digit("7"), .digit("8"), .digit("9"), isInteger ? .blank : .minus],
            [.digit("4"), .digit("5"), .digit("6"), onKeyboard == nil || isInteger ? .blank : .keyboard],
            [.digit("1"), .digit("2"), .digit("3"), isInteger ? .blank : .comma],
            [.digit("0"), .done],
        ]
    }

    var body: some View {
        VStack(spacing: Self.gap) {
            display
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.gap) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: Self.totalWidth + 20)
        .background(PaletteStyle.background)
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
        .frame(width: Self.totalWidth, height: 40)
        .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
    }

    @ViewBuilder private func keyButton(_ key: Key) -> some View {
        let width = key == .done || key == .digit("0") ? Self.wideWidth : Self.keyWidth
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
                    .foregroundStyle(key == .done ? Color.white : Color.primary)
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
        case .minus:
            Text("−").font(.system(size: 20, weight: .semibold))
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
        case .minus: "Minus"
        case .delete: "Löschen"
        case .clear: "Leeren"
        case .stepDown: "Eins weniger"
        case .stepUp: "Eins mehr"
        case .keyboard: "Bildschirmtastatur"
        case .done: "OK"
        case .blank: ""
        }
    }

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
        case .minus:
            if replaces || text.isEmpty { text = "-" } else if text.last != "-" { text += "-" }
            replaces = false
        case .delete:
            if replaces { text = "" } else if !text.isEmpty { text.removeLast() }
            replaces = false
        case .clear:
            text = ""
            replaces = false
        case .stepDown, .stepUp:
            if let stepped = step(key == .stepUp ? 1 : -1) {
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
}
