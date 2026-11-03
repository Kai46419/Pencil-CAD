# PencilCAD Build 28 – Änderungen und Tests

## Änderungen

- Mittelpunktbogen: Ein Fang auf einer vorhandenen Skizzenkurve wird nur übernommen, wenn die Kurve den Radiuskreis tatsächlich am Stift schneidet. Sonst bleibt der Endpunkt frei auf dem Radiuskreis; eine falsche Kurvenabhängigkeit entsteht nicht.
- Tangentialbogen: „Andere Bogenseite“ schaltet Vorschau und Ergebnis um. Ein bereits ausgewählter Bogen lässt sich mit „Bogenseite wechseln“ nachträglich umkehren; der Schritt ist rückgängig zu machen.
- Text am Bogen: Der Pfadwähler und die Bogen-Vorlage sind im Eigenschaftenfenster beschriftet. „Auf“, „Über“ und „Unter“ steuern die Lage; Abstand und Bogenradius sind editierbar. Der gewählte Text bleibt mit dem Skizzenbogen verknüpft.
- Linienzug: Der angezeigte Winkel bezieht sich ab dem zweiten Segment auf den vorherigen Strich. Ein eingetippter Winkel wählt die zum Stift nähere Seite. Ein erkannter paralleler Bezug bleibt als solcher für die grüne Vorschau erhalten.
- Werkzeugrad: Kleine Werkzeugnamen sind sichtbar. Die Auswahlhaptik wird an der SwiftUI-Ansicht des Rades ausgelöst, wenn der schwebende Stift das Werkzeug wechselt.

## Verifikation

- Gezielte Modelltests für Bogenfang, Bogenseite und Undo, Textpfad-Radius, Linienwinkel und Werkzeugrad: bestanden.
- Vollständige Simulator-Suite: 84/84 Tests bestanden.
- iOS-Release-Build für `generic/platform=iOS` ohne Gerätesignierung erfolgreich. Das ist eine Kompilationsprüfung, keine installierbare oder auf dem iPad getestete Version.
- Signierter iPad-Release-Build erstellt, Signatur geprüft, auf Kais iPad installiert und gestartet. Die 125 vor der Installation gesicherten App-Dokumente waren danach bytegleich vorhanden.
- Reale Pencil-Pro-Haptik, Sichtbarkeit der Werkzeugnamen und die fünf neuen Skizzenabläufe sind **noch nicht** durch einen manuellen Praxistest bestätigt. Der Simulator kann keine fühlbare Stifthaptik belegen.

Siehe `Pruefprotokolle/BUILD_28_ABNAHME.md` für Build- und Paketprüfung.
