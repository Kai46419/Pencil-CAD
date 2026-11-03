# PencilCAD Build 23 – 31.10.2026

- Ton und Punkt-Haptik werden erst beim erfolgreichen Merken nach ruhigem Pencil-Hover ausgelöst. Das Vorbeifahren bleibt stumm; ein entmerkter Punkt erzeugt keinen weiteren Fangton. Der gesonderte Klick bei gleicher Länge bleibt bestehen.
- Dreiecksmarken aus gemerkten Punktpaaren werden als Mittelpunkte gefangen, auch wenn Endpunktfang deaktiviert ist.
- Kreuzungen zweier automatisch gezeichneter Mittellinien und Kreuzungen einer solchen Linie mit einer gezeichneten Konstruktionslinie sind Fangpunkte. Das Kreis-Werkzeug kann dort einen Mittelpunkt setzen; auch der klassische Eingabestil nutzt diese Punkte.
- Die Hilfslinien liefern präzise Fangkoordinaten, noch keine dauerhaft verknüpften parametrischen Bedingungen.

## Nachweis

- Gezielte Skizzentests: 30/30 bestanden.
- Vollständige Simulator-Tests nach der letzten Änderung: 67/67 bestanden.
- Signierter Release-Build erfolgreich; Signatur gültig, Bundle-Version 23 und Klickton-Datei im App-Bundle geprüft.
- Verbundenes iPad Air 11-inch (M4): 67/67 Tests bestanden; Release-Build 23 installiert und gestartet.
- Projektbestand vor und nach Test, Installation und Start bytegleich: 13 Projektordner, 94 Dateien. Sicherung unter `work/device-projects-before-build23/Projects`.
- Quell-ZIP und IPA: ZIP-Integrität erfolgreich geprüft; SHA-256-Prüfsummen im Ausgabeverzeichnis.

## Geräteprüfung

Der physische Pencil-Hover und hörbares bzw. fühlbares Feedback sind nicht automatisierbar. Bei aktivem Punktfang im Kreis-Werkzeug den Pencil auf einer Dreiecksmarke und einem Mittellinien-Schnitt ruhig halten; nur nach dem Merken soll der Fangton erscheinen.
