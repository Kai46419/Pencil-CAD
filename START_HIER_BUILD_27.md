# PencilCAD Build 27 – Start hier

Dieses Paket enthält das vollständige Xcode-Projekt mit dem OpenCASCADE-Kern und dem Quellcode von Build 27. Öffnen: `PencilCAD.xcodeproj`, Schema `PencilCAD`.

Die separat ausgelieferte IPA ist der signierte iPad-Build. Auf dem angeschlossenen iPad wurde Build 27 bereits installiert und gestartet.

Änderungen: [BUILD_27_AENDERUNGEN_UND_TESTS.md](BUILD_27_AENDERUNGEN_UND_TESTS.md). Testnachweise und Grenzen: [Pruefprotokolle/BUILD_27_ABNAHME.md](Pruefprotokolle/BUILD_27_ABNAHME.md).

Für den Stifttest: Skizze öffnen, Apple Pencil Pro drücken, im geöffneten Werkzeugrad über ein anderes Icon schweben und den Druck lösen. Das Icon soll beim Schweben hervorgehoben werden; beim Wechsel soll der Stift haptisch reagieren; nach dem Loslassen soll das neue Werkzeug aktiv sein. Der eigentliche Pencil-Pro-Druck und die Haptik lassen sich mit XCTest nicht auslösen und sind noch manuell zu prüfen.
