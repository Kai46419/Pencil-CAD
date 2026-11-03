# PencilCAD Build 17 – Änderungen und Prüfstand

Stand: 31.10.2026. App-ID `de.kai46419.pencilcad`, Version `0.1.0`, Build `17`.

## Umgesetzt

- **Abrundung:** Der Blend-Worker prüft die resultierende BRep-Form, ein vollständiges Dreiecksnetz und dessen räumliche Ausdehnung vor Vorschau und Übernahme. Eine unplausible Form wird abgewiesen. Für einzelne planare Kanten prüft er zusätzlich, ob der Volumenverlust zum gewählten Radius passt. Der native Rundungskernel bleibt in einem isolierten Worker; dessen Absturz soll die App nicht beenden.
- **Kantenauswahl:** „Einzelkante“ reagiert auf eine einzelne Kante. Ein Antippen einer Fläche nimmt in diesem Modus nicht mehr stillschweigend alle Flächenkanten. Die explizite Flächenauswahl bleibt möglich.
- **Projektdateien:** Speichern verwendet einen Transaktionsstand; nach einer Unterbrechung wird der letzte vollständig gespeicherte Stand wiederhergestellt. Duplizieren und Wiederherstellen veröffentlichen erst vollständig kopierte Projekte. Projektmetadaten und Rasterweite werden atomar gespeichert.
- **Verlauf:** Ein Regressionstest prüft, dass der Verlauf nach erneutem Öffnen anwählbar bleibt und einen früheren Modellstand aufbaut.
- **Raster:** Die im Projekt gewählte Rasterweite bleibt nach erneutem Öffnen erhalten.

## Verifikation

| Prüfung | Ergebnis |
| --- | --- |
| Xcode Debug, iPad-Pro-Simulator, Build für Tests | bestanden |
| Vollständige Simulator-Suite (`/tmp/PencilCAD_B17_Final_Full.xcresult`) | **49/49 bestanden**, 0 übersprungen |
| Xcode Release für iOS | bestanden |
| Signatur der Release-App (`codesign --verify --deep --strict`) | gültig |
| Installation auf „iPad von Kai“ | bestanden; Gerät meldet Build 17 |
| Vollständige Tests auf „iPad von Kai“ (`/tmp/PencilCAD_B17_Device_Full.xcresult`) | **49/49 bestanden**, 0 übersprungen |
| Release-App auf dem iPad gestartet | bestanden; Startbildschirm zeigt Build 17 und acht Projekte |
| Manuelle Bearbeitung komplexer Biege- und Rundungsfälle auf dem iPad | nicht durchgeführt; daraus folgt keine Freigabe für jeden Geometriefall |

Die Tests enthalten das gespeicherte STEP-Modell aus „Titelloses Projekt 8“. Für eine getestete 7-mm-Flächenauswahl wird ein ungültiges Ergebnis abgewiesen. Die Auswahl entspricht nicht nachweislich exakt der auf dem Bildschirmfoto angetippten Kante.

## Bekannte Grenze

Der OCCT-Kernel berechnet weiterhin nicht jede große oder eng benachbarte Abrundung. Build 17 soll ungültige Ergebnisse zuverlässig zurückweisen und Worker-Abstürze von der App isolieren; er stellt keine allgemeine Lösung für alle vom Nutzer gemeldeten Rundungsfälle dar. Ein bestandener Simulatorlauf beweist keine Stabilität bei beliebiger Anwendergeometrie auf dem iPad.

## Externe Einordnung

Die Fusion-API-Dokumentation zeigt die Bedienung einer geschlossenen CAD-Engine, keinen frei nutzbaren Rundungskernel. SolidCraft ist quelloffen, begrenzt problematische Radien aber ebenfalls. Die übernommenen Prüfungen sind eigene PencilCAD-Implementierungen. Details stehen in `ABRUNDUNG_FUSION_SOLIDCRAFT_PENCILCAD.md`.

## Dateien

- `PencilCAD_iPad_Test_Build_17_2026-10-31.ipa`: signierte iPad-App.
- `PencilCAD_Vollstaendiges_Projekt_Build_17_2026-10-31.zip`: vollständiger Quellstand mit Tests und Vendor-Frameworks.
- `BUILD_17_CODE_DIFF_SEIT_BUILD_16.patch`: textueller Vergleich des Quellstands mit Build 16.
- `SHA256SUMS_BUILD_17.txt`: Prüfsummen der Lieferdateien.
- `BUILD_17_iPad_TESTERGEBNIS.json`: maschinenlesbare Zusammenfassung des Gerätetests.
- `BUILD_17_iPad_Release_Start.png`: Startbildschirm des installierten Release-Builds.

Die Projektdateien des iPads wurden vor der Installation gesichert unter `work/device-projects-before-build17-install`.
