# PencilCAD Build 13 – isolierte Abrundung und Fase (30.10.2026)

## Befund

Build 12 stürzte auf dem iPad am 30.10.2026 um 23:07:14 Uhr in `BRepFilletAPI_MakeFillet::Build` ab. Der `PencilCAD.blend`-Thread zeigte einen direkten Aufruf der angeforderten Rundung; die zuvor entfernte Maximalradius-Suche war nicht beteiligt. Der vollständige Bericht liegt als `PencilCAD_Absturz_Build_12_2026-10-30_230714.ips` bei.

## Änderungen

- Abrunden und Fasen werden ab iPadOS 26 über eine `ExtensionFoundation`-Extension und XPC in einem anderen Prozess berechnet. Der Worker nutzt denselben OpenCASCADE-Kernel.
- `PCKShape` überträgt den nativen BRep. Der Host prüft den Eingang, wartet höchstens acht Sekunden und übernimmt nur ein zurückgegebenes Ergebnis. Ein Worker-Absturz liefert kein Vorschauergebnis.
- Sowohl interaktive Vorschau (`BlendJobs.swift`) als auch Verlaufsnachbau (`FeatureHistory.swift`) verwenden den isolierten Rechenweg. Dazu gehören konstante und variable Radien, Teilabrundung und ein- bzw. zweidistanzige Fasen.
- Auf iPadOS unter 26 meldet die Werkzeugvorschau die Mindestversion, statt den instabilen In-Process-Aufruf auszuführen.
- Die Version 12 bleibt zurückgezogen; ihre Dokumentation nennt nun auch den zweiten Absturz.

## Nachweise

- Mac-Kerntests: 84 bestanden, 0 fehlgeschlagen.
- iPad-Simulator: 34 App-Tests bestanden, 0 fehlgeschlagen.
- Physisches iPad: 34 App-Tests bestanden, 0 fehlgeschlagen.
- Der Test `testFilletWorkerCrashDoesNotTerminateApp` löst nur im Debug-Build absichtlich einen Worker-Absturz aus, prüft das `nil`-Ergebnis und berechnet anschließend eine neue gültige Abrundung. Ein Worker-IPS-Bericht und ein weiter laufender PencilCAD-Prozess wurden beobachtet.
- Der BRep-Transfer erhält Flächen- und Kantennummern bei einem verrundeten Testkörper und beim gespeicherten Körper aus „Titelloses Projekt 6“; die Volumina stimmen innerhalb der Testtoleranz überein.
- Vor dem physischen Test wurden sechs Projektordner gesichert. Nach dem Test waren alle 47 Dateien bytegleich; kein Projektordner fehlte.
- Nach der zusätzlichen Sperre für eine im Worker abgestürzte Kantenauswahl: 34 von 34 Simulatortests und der gezielte iPad-Absturztest bestanden. Dieselbe Auswahl wird für die laufende App-Sitzung gesperrt, bis Körper oder Auswahl wechseln; dadurch startet das Ziehen des Pfeils nicht sofort weitere Worker-Prozesse für dieselbe riskante Auswahl.
- Signierter Release-Bau 13 erstellt, `codesign --verify --deep --strict` bestanden, auf dem iPad installiert und ohne Testmodul gestartet. Der PencilCAD-Prozess lief bei der anschließenden Statusprüfung.
- Nach der Installation waren die sechs vorherigen Projektordner vorhanden, zusätzlich ein neuer. In „Titelloses Projekt 6“ wurden zwischen Sicherung und Nachprüfung zwei weitere Features gespeichert; deshalb ist dieser spätere Dateistand bewusst **nicht** als bytegleich bezeichnet. Die Sicherung vor dem Test bleibt erhalten.

## Grenzen und offener Geometriefall

Auf dem iPad trat nach dem Test bei der schwierigen Anwendergeometrie erneut ein `EXC_BAD_ACCESS` im **PencilCADBlendWorker** auf (`PencilCADBlendWorker-2026-10-30-232847.ips`); der PencilCAD-App-Prozess lief weiter. Das bestätigt die Trennung, aber auch den weiterhin offenen OpenCASCADE-Fehler. Der Screenshot enthält den zuletzt gezogenen Radius nicht; genau diese Rundung wurde nicht als erfolgreich berechnet nachgewiesen. Die Prozessisolierung erweitert die geometrisch möglichen Radien nicht. Nach diesem Befund wurde die Sperre für dieselbe Kantenauswahl ergänzt und gezielt getestet. Der finale Build 13 enthält diese Sperre; ein erneuter manueller Test exakt dieser Auswahl im signierten Release wurde noch nicht dokumentiert.

Ein Downloadpaket wird zusammen mit dem nächsten Skizzenstand erstellt.
