# Build 40: U-Schrittweite für freie Skizzenlinien

## Ursache

Die bisherige Rasterung betraf nur die X- und Y-Koordinaten. Die Länge einer schrägen Linie ist die Hypotenuse und kann deshalb zwischen den eingestellten Schritten liegen.

## Änderung

- Freie Linienlängen werden ab ihrem Startpunkt auf die ausdrücklich gewählte U-Schrittweite gerundet. Die Stiftrichtung bleibt erhalten. Das gilt für die Klickfolge und den klassischen Ziehstil.
- Die Vorschau und die gespeicherte Linie verwenden denselben gerundeten Endpunkt.
- Ein eingegebenes Längenmaß, ein Fang auf vorhandene Geometrie oder ein Gleichlängenfang behalten Vorrang. Bei ausgeschaltetem Fang bleibt die Länge frei. Der automatische 1-2-5-Modus ändert seine bisherige Funktion nicht.

## Prüfung

- Drei gezielte Simulator-Tests bestanden. Sie prüfen Vorschau und gespeicherte schräge Linie, die Schritte 1 / 0,5 / 0,2 / 0,1 / 0,01 mm, einen versetzten Startpunkt, ausgeschalteten Fang, vorhandenen Punkt und exakt eingegebene Länge sowie den klassischen Ziehstil.
- Signierter Gerätebuild erfolgreich. Build 40 wurde auf „iPad von Kai“ installiert; `devicectl` bestätigt Version 0.1.0 (40) und einen erfolgreichen App-Start.
- Vor der Installation wurden 166 Dokumentdateien gesichert. Ein Dateivergleich nach Installation und Start zeigt keine Unterschiede.
- `git diff --check` ohne Befund.

## Grenze

Der automatische Gerätetest prüft Installation und Start. Der konkrete Stiftzug auf dem iPad ist noch nicht manuell beobachtet. Die Bewertung „Skizzieren und Fangpunkte“ bleibt daher bei 4/5 Sternen.
