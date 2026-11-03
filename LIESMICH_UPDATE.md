# PencilCAD – Sammelupdate vom 30.10.2026

Dieses Paket enthält das vollständige überarbeitete Projekt einschließlich des mitgelieferten
OpenCASCADE-Geometriekerns für iPad und Apple-Silicon-Simulator. Es ist ein Quellprojekt, keine fertig
installierbare iPad-App. Das ursprüngliche ZIP und das vorhandene iCloud-Projekt wurden nicht verändert.

## Öffnen

1. Das ZIP in einen neuen Ordner entpacken.
2. Darin `PencilCAD_Integration_Work/PencilCAD.xcodeproj` öffnen.
3. In Xcode das Schema **PencilCAD** und das eigene iPad wählen. Die vorhandene Team-ID und Bundle-ID
   sind übernommen; die lokale Anmeldung und Berechtigung für dieses Team müssen weiterhin gültig sein.

Das Xcode-Projekt ist bereits neu erzeugt. Einzelne Swift-Dateien müssen nicht manuell ersetzt oder
hinzugefügt werden. Ein Neubau von OCCT ist für die mitgelieferten arm64-Ziele nicht erforderlich.

## Was verbessert wurde

- Lokale Maßänderungen prüfen auch Bedingungen außerhalb der gerade bearbeiteten Form.
- Fehlgeschlagene Maßänderungen übernehmen weder eine neue Formel noch einen unvollständigen Zustand.
  Das Rückgängigmachen wurde auch an der Grenze von 200 gespeicherten Schritten korrigiert.
- Formeln unterstützen `1e-3`, `2.5E+2`, führendes Dezimalkomma und Multiplikation vor Klammern.
- Extrusionsbereiche werden vor Kernel-Aufrufen auf ungültige Zahlen und Überläufe geprüft.
- STL-/3MF-Import erkennt mehr beschädigte Daten, einschließlich ungültiger Koordinaten,
  fehlender Komponenten, ungültiger Transformationen und ZIP-Prüfsummenfehler.
- Automatisierte Kerntests und sechs bestandene iOS-App-Tests sind im Paket enthalten.
- Die Startseite hält Titel, Versionszeile und Aktionsknöpfe auch im iPad-Pro-Simulator lesbar.

## Belegter Stand

**84 Kerntests bestanden, 0 fehlgeschlagen.** Diese Tests führen die tatsächlichen Swift-Implementierungen
von Geometrie, Löser, Formeln, Extrusionsbereich und Datei-Lesern auf dem Mac aus.

Nach Installation der Metal-Toolchain wurde die vollständige App für den iOS-Simulator erfolgreich gebaut.
**6 App-Tests bestanden, 0 fehlgeschlagen**, einschließlich einer tatsächlichen OCCT-Rechteckextrusion
mit geprüftem Volumen. Die App wurde im iPad-Pro-Simulator gestartet; die Startseite wurde nach einer
Layoutkorrektur visuell geprüft. Es gab keinen Test auf einem echten iPad und keine vollständige
Abnahme aller CAD-Werkzeuge. Das Paket ist deshalb keine vollständig abgenommene Release-Version.

## Tests bei Bedarf wiederholen

Im entpackten Projektordner:

```bash
bash scripts/test-core.sh
bash scripts/check-source.sh
```

Die Kerntests benötigen Swift und die macOS-Systembibliotheken, aber keine zusätzlichen Pakete,
kein iPad und keinen Simulator. Die vollständige App erfordert Xcode mit passender iOS- und
Metal-Toolchain. Die sechs Integrationstests laufen über **Product → Test**.

Falls Xcode ebenfalls eine fehlende Metal-Toolchain meldet, diese über die Komponentenverwaltung von Xcode
installieren. Die Fehlermeldung nennt alternativ `xcodebuild -downloadComponent MetalToolchain`.

## Details

- `AENDERUNGEN_2026-10-30.md`: Änderungen und Kompatibilitätshinweise.
- `PRUEFBERICHT_2026-10-30.md`: tatsächlich ausgeführte Prüfungen und Grenzen.
- `ANALYSE_2026-10-30.md`: Architektur, Priorisierung und weitere offene Arbeit.
- `Pruefprotokolle/`: tatsächliche Ausgaben der Prüfungen.
- `AENDERUNGEN.patch`: Quelltextdifferenz gegenüber dem hochgeladenen ZIP, ohne Bibliotheksdateien.

Das Blechmodul liegt als Rust-Quelltext bei. Ein gebautes `PencilSheet.xcframework` war nicht im Upload
enthalten und wurde hier nicht hinzugefügt. Die vorhandene OCCT-Konfiguration bleibt deshalb ohne dieses Modul.
