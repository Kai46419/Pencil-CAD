# PencilCAD Build 6 – Änderungen und Prüfstand (30.10.2026)

## Änderungen

- Im 3D-Modus stehen die Werkzeuge jetzt wie in der Skizze in zwei Spalten. Jede Gruppe zeigt zunächst bis zu vier Reihen; durch Antippen der Gruppenüberschrift erscheinen die übrigen Befehle. Zuletzt und häufig verwendete Befehle werden innerhalb der Gruppe vorgezogen. Befehle lassen sich per langem Drücken anheften.
- Eine einzelne durchgehende rechtwinklige Quaderkante kann über die Breite ihrer Nachbarfläche hinaus verrundet werden. Diese begrenzte geometrische Fortsetzung entfernt weiterhin Material, solange ein gültiger geschlossener Restkörper entsteht. Andere Körper und mehrere ausgewählte Kanten werden weiterhin vom üblichen OpenCASCADE-Abrunder verarbeitet.
- Das Blechmodul ist für iPad und Apple-Silicon-Simulator gebaut und im Xcode-Projekt eingebunden. Der Quelltext und `SheetKit/Cargo.lock` liegen bei; das Paket enthält `Vendor/PencilSheet.xcframework` für beide Ziele.
- Die Zeitleiste wurde mit der privat gesicherten Geometrie von Projekt 27 im Simulator nach dem erneuten Öffnen geprüft: frühere Schritte ließen sich anwählen. Diese privaten Projektdaten sind nicht im Quellpaket.

## Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Eigenständige Kerntests auf dem Mac | 84 bestanden, 0 fehlgeschlagen |
| App-Tests im Simulator einschließlich Quaderabrundung und Blech-Grundflansch | 11 bestanden, 0 fehlgeschlagen |
| Signierter iPad-Build, iPad-Tests und Installation | erfolgreich; 11 App-Tests bestanden |
| Start auf dem iPad | erfolgreich; Version 0.1.0, Build 6 auf dem Gerät bestätigt |
| Dokumente vor/nach Installation und Tests | 9/9 Dateien, keine fehlenden oder geänderten SHA-256-Prüfsummen |

Der Quader-Test prüft eine 20 × 20 × 20 mm Form mit 9, 23,431 und 40 mm Radius an derselben Kante, geschlossenen Restkörper, sinkendes Volumen und vorhandene Dreiecke auf allen Flächen.

## Bekannte Grenzen

- Der neue große Radius ist derzeit nur für eine einzelne volle rechtwinklige Kante eines einfachen Quaders belegt. Ein durchgehendes Auflösen beliebiger bereits gerundeter Körper ist damit nicht gelöst.
- Die Bedienoberfläche zeigt im aktuellen Screenshot „1 Kante“. Die gespeicherte aktuelle Form enthält mehrere ungeteilte Kreisbogenkanten von rund 31,4 mm Länge. OpenCASCADE baut beim Abrunden außerdem automatisch eine Kontur aus tangential anschließenden Kanten auf. Der Screenshot legt die genaue betroffene Kantennummer nicht fest, aber das Umschalten einer Auswahlverkettung allein würde eine lange Einzelkante nicht auf einen Abschnitt begrenzen. Eine lokale Teilabrundung mit frei wählbarem Start- und Endpunkt ist noch keine PencilCAD-Funktion.
- Der kleine helle Keil aus Projekt 27 ist nicht nachweislich behoben. Zwei sehr kleine Körperüberschneidungen waren schon im Ausgangskörper vor den Abrundungen vorhanden (0,0064 und 0,0135 mm³). Ihre Rolle beim sichtbaren Artefakt ist nicht belegt; die Projektgeometrie wurde nicht automatisch verändert.
- Die Werkzeugleiste wurde durch Build und App-Tests geprüft; eine vollständige visuelle und gestische Abnahme aller Gruppen auf dem iPad steht aus.

## Daten und Paket

Die älteren iPad-Projekte wurden laut Nutzer bewusst entfernt. Die bestehende Sicherung vor Build 5 bleibt getrennt erhalten. Der aktuelle iPad-Projektstand wurde vor Build 6 erneut gesichert. Die signierte IPA ist für das registrierte Test-iPad bestimmt; andere Geräte benötigen eine eigene Signierung.

## Vergleich zum Abrunden in anderen CAD-Programmen

[Fusion 360](https://help.autodesk.com/view/fusion360/ENU/?contextId=SLD-REF-TANGENT-CHAIN) lässt die automatische Auswahl tangential verbundener Kanten abschalten. [Onshape](https://cad.onshape.com/help/Content/PartStudio/fillet.htm) bietet ebenfalls einen Schalter für die tangentiale Fortsetzung und außerdem eine Teilabrundung mit einstellbarer Start- und Endposition auf einer Kante. Diese beiden Einstellungen sind verschiedene Funktionen: Nur die zweite begrenzt eine Abrundung innerhalb einer einzigen langen Kante.

Eine private Diagnose des aktuellen `model.step` ergab einen Körper mit 10 Flächen und mehreren ungeteilten Kreisbogenkanten von rund 31,4 mm. Die Diagnose liegt nicht im Paket. Damit ist die technische Grenze eingegrenzt, aber eine Teilabrundung ist nicht implementiert. Ebenso ist die Fortsetzung großer Radien für beliebige schon bearbeitete Körper nicht belegt. Diese beiden Punkte gelten bei der Abnahme von Build 6 nicht als abgeschlossen.
