# PencilCAD Build 18 – Abrundung mit feinen Nachbarradien

Stand: 31.10.2026. Grundlage ist der iPad-Quellstand Build 17. Die Änderung bezieht sich auf die gespeicherte Geometrie von „Titelloses Projekt 8“ und die Bilder IMG_0129/IMG_0130.

## Ursache

Der vorherige Schritt rundet zwei benachbarte Kanten mit 4 mm ab. Eine neue Rundung auf dem daraus entstandenen Körper schlägt an der gewählten Kante selbst mit 0,3, 0,5, 1,1 und 1,5 mm fehl. Build 17 berechnete beide Kanten nur bei exakt gleichem Radius gemeinsam neu. Deshalb blieb der Körper bei 3 mm unverändert und änderte sich bei 4 mm sprunghaft.

## Änderungen

- OCCT kann mehrere Kanten mit unterschiedlichen Radien in einem gemeinsamen Rundungsschritt berechnen. Dieser Pfad läuft wie die anderen Abrundungen im isolierten BlendWorker.
- Bei einer neuen Kante neben der letzten Rundung werden beide Schritte auch bei unterschiedlichen Radien gemeinsam auf dem Körper vor der letzten Rundung berechnet.
- Die Radiuszuordnung je Kante wird im Feature gespeichert. Die Parameter „Radius“ und „Zusatzradius“ sind im Verlauf getrennt bearbeitbar und werden beim Nachbau wieder angewendet.
- Der Rundungspfeil lässt mindestens 0,1-mm-Schritte zu; ein feineres Raster aus dem U-Menü bleibt erhalten. Zahlenfelder erlauben weiterhin direkte Eingaben wie 1,1 oder 1,5 mm.
- OCCT-Ergebnisse werden vor der Weitergabe auf gültige Solids geprüft. NaN/Unendlich erreichen den BlendWorker nicht. Eine fehlgeschlagene unabhängige Körperkopie blockiert den Hauptthread nicht.

## Nachweise

- Projekt-8-Regression: Die im gespeicherten Modell identifizierte Kante 30 wird mit 1,1, 1,5 und 4 mm berechnet. Alle Ergebnisse sind gültige, geschlossene und triangulierbare Körper. Die Volumenwerte unterscheiden sich stufenweise. JSON-Speicherung, Nachbau und das Ändern des Zusatzradius von 1,1 auf 1,5 mm sind geprüft.
- Vollständige Simulator-Suite: **51/51 bestanden** (`/tmp/PencilCAD_B18_FineFillet_Sim_Full.xcresult`).
- Vollständige Suite auf dem angeschlossenen iPad: **51/51 bestanden** (`/tmp/PencilCAD_B18_FineFillet_Device_Full.xcresult`).
- Signierter Release-Build erfolgreich (`/tmp/PencilCAD_B18_FineFillet_Release.log`). Build 18 auf iPad `00008132-001C65AC0160C01C` installiert und gestartet; `devicectl` meldet `bundleVersion: 18`.
- Projekterhalt nach Installation: 9 Projektordner vorher und nachher; die gespeicherte `model.step` von Projekt 8 hat dieselbe SHA-256-Prüfsumme.

## Grenze

Der automatisierte Test bildet die gespeicherte Projekt-8-Geometrie ab. Ein manueller Stifttest der konkreten Ansicht aus den Bildern wurde nicht durchgeführt. OCCT kann andere, geometrisch unmögliche Kombinationen weiterhin ablehnen; ein nativer Fehler während `Build()` bleibt durch den separaten Worker von der App isoliert. Die erreichte CAD-Funktion ist kein Nachweis für Funktionsgleichheit mit Shapr3D oder Fusion.
