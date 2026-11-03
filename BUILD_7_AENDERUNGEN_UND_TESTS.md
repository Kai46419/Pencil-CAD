# PencilCAD Build 7 – Abschlussstand der Abrundungsrunde (30.10.2026)

## Änderungen seit Build 6

- **Teilweise abrunden:** Bei einer einzelnen geraden oder kreisbogenförmigen Kante kann in der Abrundung „Teilweise“ gewählt werden. Start und Ende werden als Prozentposition entlang der Kante eingegeben (Vorgabe 20–80 %). Das Werkzeug begrenzt die Materialabnahme mit zwei Schnittebenen; an beiden Grenzen entstehen ebene Abschlussflächen. Eine Auswahl mehrerer Kanten und Abschnitte unter 5 % werden abgelehnt.
- Die Teilabrundung steht sowohl in der bisherigen unteren Abrundungsleiste als auch im neuen Werkzeugpanel bereit. Die beiden Positionen werden als bearbeitbare Werte im Verlauf gespeichert und beim erneuten Aufbau verwendet.
- Die große Quaderabrundung aus Build 6 arbeitet auch zusammen mit der Teilabrundung. Der Quader-Regressionsfall wurde bis 60 mm Radius an einer 20 × 20 mm Ecke geprüft. Die Berechnung wird nur übernommen, wenn ein gültiger geschlossener Restkörper entsteht.
- Scheitert eine Teilabrundung, bleibt der Körper unverändert und die App meldet, dass Radius oder Abschnitt geändert werden müssen.

## Prüfungen

| Prüfung | Ergebnis |
| --- | --- |
| Kerntests auf dem Mac | 84 bestanden, 0 fehlgeschlagen |
| App-Tests im Simulator | 13 bestanden, 0 fehlgeschlagen |
| Private Nachstellung am zuletzt gespeicherten gerundeten Körper | Zwei Bogenkanten: gültige geschlossene Teilabrundung bei 4 mm, mit geringerer Materialabnahme als bei voller Abrundung |
| Verlauf nach gelöschtem Zwischenspeicher | Teilabrundung aus Radius, Start, Ende und Kantensignatur erneut aufgebaut |
| Signierter Build und App-Tests auf dem iPad | 13 bestanden, 0 fehlgeschlagen |
| Installation und Start auf dem iPad Air M4 | erfolgreich; Version 0.1.0, Build 7 am Gerät bestätigt |
| Projektdaten vor/nach Tests und sauberer Installation | 9/9 Dateien, keine fehlenden oder geänderten SHA-256-Prüfsummen |

Die privaten Projektdaten und Diagnosetests sind nicht im Quellpaket.

## Geometrische Grenzen

- Die Teilabrundung setzt voraus, dass die vollständige Abrundung dieser Kante zunächst berechenbar ist. Das funktioniert an den zwei geprüften Bogenkanten des aktuellen Testkörpers, aber nicht an jeder Kante desselben Körpers. Sie unterstützt gerade Kanten und Kreisbögen bis 180°. Die Abschlussflächen sind eben; der Übergang hat dort keine weiche Auslaufzone.
- Große Radien lassen sich am geprüften einfachen Quader weit über die Nachbarfläche hinaus ziehen. Bei bereits mehrfach gerundeten Körpern kann der Geometriekern weiterhin an Selbstüberschneidungen oder verschwindenden Flächen scheitern. Am privaten aktuellen Testkörper waren an zwei geprüften Kanten 8 und 12 mm gültig, 20 mm und mehr nicht. Zwei alternative Fillet-Berechnungsarten ergaben dort ebenfalls keinen gültigen Körper. Ein allgemeines „bis zum vollständigen Verschwinden“ für jede beliebige Form wäre deshalb eine unbewiesene Behauptung.
- Das kleine Artefakt aus Projekt 27 wird auf Wunsch des Nutzers in dieser Runde nicht weiter bearbeitet.

## Paket und Daten

Das Quellpaket enthält Xcode-Projekt, OCCT und PencilSheet für iPad und Apple-Silicon-Simulator, Tests, Cargo-Sperrdatei und die 107 SolidCraft-Symbole. Der aktuelle PencilCAD-Datenordner wurde vor der Geräteinstallation gesichert und danach unverändert wiedergefunden. Die installierte App wurde ohne Testzusatz neu gebaut. Eine IPA für andere iPads muss mit einem eigenen Team signiert werden.
