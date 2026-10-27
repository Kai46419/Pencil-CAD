import CoreText
import SwiftUI
import UIKit

// Schriftwahl mit Vorschau (Kai): jeder Schriftname steht in seiner eigenen Schrift, darunter „AaBb 123“.
// Oben „Zuletzt benutzt“ und die bewährten Schriften, darunter alle Schriften des iPads, durchsuchbar.
// Das schmale 160-pt-Fenster zeigt nur einen Knopf (FontPickerButton); die Liste öffnet sich breiter als Popover.

/// Schriften für Skizzentexte: die bewährte Auswahl (SketchText.fonts) und alle installierten Schriften.
enum FontCatalog {
    /// UserDefaults-Schlüssel der zuletzt benutzten Schriften (PostScript-Namen, durch Zeilenumbruch getrennt)
    static let recentKey = "sketchText.recentFonts"
    static let recentLimit = 5

    /// Alle installierten Schriften mit Umrissen, nach Anzeigenamen sortiert, ohne die bewährten (die stehen
    /// oben). Farb-Emoji und versteckte Systemschriften liefern keine Buchstabenumrisse und fehlen deshalb.
    static let installed: [SketchText.Font] = {
        let curated = Set(SketchText.fonts.map(\.name))
        var result: [SketchText.Font] = []
        for family in UIFont.familyNames {
            if family.localizedCaseInsensitiveContains("emoji") { continue }
            for name in UIFont.fontNames(forFamilyName: family) {
                if name.hasPrefix(".") || curated.contains(name) { continue }
                result.append(SketchText.Font(name: name, title: displayName(name)))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    /// Anzeigename: für die bewährten Schriften der deutsche Titel, sonst der Name der Schrift selbst.
    static func title(for name: String) -> String {
        if let font = SketchText.fonts.first(where: { $0.name == name }) { return font.title }
        if let font = installed.first(where: { $0.name == name }) { return font.title }
        return name
    }

    private static func displayName(_ name: String) -> String {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let display = CTFontCopyDisplayName(font) as String
        return display.isEmpty ? name : display
    }

    static func recentNames() -> [String] {
        let stored = UserDefaults.standard.string(forKey: recentKey) ?? ""
        return stored.split(separator: "\n").map(String.init)
    }

    /// Gewählte Schrift vorn in „Zuletzt benutzt“ eintragen.
    static func noteUsed(_ name: String) {
        var names = recentNames().filter { $0 != name }
        names.insert(name, at: 0)
        UserDefaults.standard.set(names.prefix(recentLimit).joined(separator: "\n"), forKey: recentKey)
    }
}

/// Knopf mit der aktuellen Schrift (in ihr selbst geschrieben); antippen öffnet die Liste als Popover.
struct FontPickerButton: View {
    @Binding var selection: String
    /// Volle Breite (schmales Fenster rechts) statt fester Breite (Leiste)
    var fullWidth = true

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 4) {
                Text(FontCatalog.title(for: selection))
                    .font(.custom(selection, fixedSize: 15))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: PaletteStyle.iconButton)
            .frame(width: fullWidth ? nil : 150)
            .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius,
                                                                 style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                    .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Schrift: \(FontCatalog.title(for: selection))")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            FontPickerList(selection: $selection)
                .frame(width: 320)
                .frame(minHeight: 420, maxHeight: 580)
                .appTheme()
        }
    }
}

/// Zeile im Formular (Texteingabe): „Schrift“ links, aktuelle Schrift rechts, öffnet die Liste.
struct FontPickerFormRow: View {
    @Binding var selection: String

    var body: some View {
        NavigationLink {
            FontPickerList(selection: $selection)
                .navigationTitle("Schrift")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack {
                Text("Schrift")
                Spacer()
                Text(FontCatalog.title(for: selection))
                    .font(.custom(selection, size: 17))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Durchsuchbare Liste: Zuletzt benutzt, Bewährt, Alle Schriften. Die aktuelle Schrift ist markiert.
struct FontPickerList: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recent: [String] = FontCatalog.recentNames()

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        sections
                    }
                    .padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Schrift suchen", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius,
                                                             style: .continuous))
    }

    @ViewBuilder private var sections: some View {
        if query.isEmpty {
            let recentFonts = recent.map { SketchText.Font(name: $0, title: FontCatalog.title(for: $0)) }
            if !recentFonts.isEmpty {
                section("Zuletzt benutzt", recentFonts, idPrefix: "recent:")
            }
            section("Bewährt", SketchText.fonts, idPrefix: "")
            section("Alle Schriften", FontCatalog.installed, idPrefix: "")
        } else {
            let hits = matches(SketchText.fonts) + matches(FontCatalog.installed)
            if hits.isEmpty {
                Text("Keine Schrift gefunden")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                section("Treffer", hits, idPrefix: "")
            }
        }
    }

    private func matches(_ fonts: [SketchText.Font]) -> [SketchText.Font] {
        fonts.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Abschnitt; idPrefix trennt die Zeilen von „Zuletzt benutzt“ von denselben Schriften weiter unten
    /// (sonst gäbe es doppelte IDs, und scrollTo fände die falsche Zeile).
    private func section(_ title: String, _ fonts: [SketchText.Font], idPrefix: String) -> some View {
        Section {
            ForEach(fonts) { font in
                FontPickerRow(font: font, isSelected: font.name == selection) { pick(font.name) }
                    .id(idPrefix + font.name)
            }
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.bar)
        }
    }

    private func pick(_ name: String) {
        selection = name
        FontCatalog.noteUsed(name)
        recent = FontCatalog.recentNames()
        dismiss()
    }
}

/// Eine Schrift: Name in der Schrift selbst, darunter die Beispielzeile; Haken bei der aktuellen.
private struct FontPickerRow: View {
    let font: SketchText.Font
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(font.title)
                        .font(.custom(font.name, fixedSize: 18))
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                    Text("AaBb 123")
                        .font(.custom(font.name, fixedSize: 13))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(isSelected ? PaletteStyle.activeFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(font.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
