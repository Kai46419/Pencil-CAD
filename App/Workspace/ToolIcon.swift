import SwiftUI
import UIKit

/// Werkzeugsymbol: Namen mit „sc.“ sind mehrfarbige SolidCraft-Bilder im Asset-Katalog (Assets.xcassets/SolidCraft,
/// Hell/Dunkel), alle anderen SF Symbols. `Label(_, systemImage:)`, `Button(_, systemImage:)` und
/// `UIImage(systemName:)` kennen nur SF Symbols – Werkzeugsymbole laufen deshalb immer über ToolIcon, ToolLabel
/// bzw. `ToolIcon.uiImage`.
struct ToolIcon: View {
    let name: String
    /// Kantenlänge eigener Bilder; SF Symbols folgen weiter der Schrift des Aufrufers (.font)
    var size: CGFloat

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    /// Eigenes SolidCraft-Bild statt SF Symbol
    static func isCustom(_ name: String) -> Bool { name.hasPrefix("sc.") }

    /// Für UIKit (Menüs, Knöpfe): eigenes Bild aus dem Katalog, sonst SF Symbol.
    static func uiImage(_ name: String) -> UIImage? {
        if isCustom(name) {
            return UIImage(named: name)?.withRenderingMode(.alwaysOriginal)
        }
        return UIImage(systemName: name)
    }

    var body: some View {
        if Self.isCustom(name) {
            Image(name)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
        }
    }
}

/// Ersatz für `Label(title, systemImage:)`, der auch SolidCraft-Bilder zeigt.
struct ToolLabel: View {
    let title: String
    let icon: String
    var size: CGFloat = 20

    init(_ title: String, icon: String, size: CGFloat = 20) {
        self.title = title
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ToolIcon(icon, size: size)
        }
    }
}
