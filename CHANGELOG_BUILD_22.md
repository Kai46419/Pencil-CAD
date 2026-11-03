# PencilCAD Build 22 – 31.10.2026

## Schwebepunkte in Skizzen

- Ursache: Der voreingestellte SolidCraft-Eingabestil leitete gemerkte Schwebepunkte ausschließlich zu den Fangspuren. Die bestehende Paarfunktion für Abstand, Mittelpunkt und gestrichelte Mittellinien wurde im Zeichenwerkzeug übersprungen.
- Jetzt wird ein neu gemerkter Punkt in beiden Funktionen verwendet. Erneutes Schweben über denselben Punkt entmerkt ihn aus der Fangspur und aus einem noch offenen Punktpaar.
- Der klassische Eingabestil bleibt bei seiner bisherigen Paarfunktion.
- Die iPad-Einstellungen wurden gelesen: SolidCraft und „Waagerecht/Senkrecht“ waren aktiv. Der Fehler lag nicht an einem ausgeschalteten Fangschalter.
- Der Screenshot aus Projekt 11 zeigte eine zweite Ursache: Die Mittelsenkrechte war nur `1,2 × Punktabstand` lang. Sie wird jetzt als gestrichelte Anzeige bis zu beiden sichtbaren Viewporträndern verlängert; die Verbindung und gespeicherte Geometrie bleiben unverändert.
- Der Klickton war ausschließlich mit „Gleiche Länge“ verbunden. End-, Mittel-, Zentrum-, Schnitt- und Körperpunkte spielen jetzt denselben kurzen Ton einmal beim neu erreichten Fang. „Klick bei Fangpunkten“ ist separat einstellbar und standardmäßig aktiv.
- Fanghaptik wird am Punkt angefordert; beim Merken eines Punkts wird ein gesondertes Abschlussfeedback über den vorhandenen Canvas-Generator ausgelöst, sofern „Haptik Fang“ aktiv ist.
- Ein nahegelegener Endpunkt verdrängte wegen seines größeren Fangradius einen näheren Schnittpunkt zweier Konstruktionslinien. Die Auswahl vergleicht jetzt die tatsächlichen Abstände zum Stift.

## Nachweis

- Regressionstests prüfen zwei Schwebepunkte im SolidCraft-Zeichenwerkzeug, Mittelpunkt, Verbindungs- und Mittellinie, Fangspur und Entmerken sowie den klassischen Modus.
- Zusätzliche Tests prüfen die Tonentscheidung für Punktfänge und getrennte Schalter sowie den Schnitt zweier Konstruktionslinien nahe einem Endpunkt bis zum Hover- und Merkpfad.
- Ein Geometrietest prüft, dass eine kurze Mittelsenkrechte über die gesamte Viewporthöhe sichtbar wird, die Punktverbindung aber endlich bleibt.
- Vollständige Simulator- und iPad-Tests nach allen Änderungen: jeweils 62/62 bestanden. Die strukturierten Testprotokolle liegen unter `Pruefprotokolle/`.
- Signierter Release-Build 22 nach allen Änderungen erfolgreich, Signatur geprüft, iPad-App installiert und gestartet. Die Audiodatei liegt im signierten App-Bundle.
- Vor und nach der letzten Installation: jeweils 11 Projektordner und 90 Dateien. Ausschließlich `modified` in der Projekt-11-Metadatei änderte sich beim App-Start; die übrigen Projektdaten waren dateigleich. Eine Sicherung vor der Installation liegt im Arbeitsordner.

## Grenze

Ein automatisierter Test kann weder den physischen Apple-Pencil-Hover noch einen hör- oder fühlbaren Ton bestätigen. Die Fanglogik und die Audio-/Haptikaufrufe sind im Code geprüft; die tatsächliche Wahrnehmung muss mit dem verwendeten Apple Pencil direkt geprüft werden. Die App respektiert die Stummschaltung des iPads.
