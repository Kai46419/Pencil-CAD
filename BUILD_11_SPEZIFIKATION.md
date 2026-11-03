# Build 11: Tangentiale Kantenauswahl

## Ziel

Beim Abrunden und Fasen soll der Nutzer zwischen einer einzelnen Kante, einer tangentialen Kantenkette und der gesamten Flächenkontur wählen können. Die Auswahl soll sichtbar nur die tatsächlich gewählten BRep-Kanten umfassen. Eine rechtwinklige Ecke darf durch die tangentiale Option nicht mitgenommen werden.

## Umsetzung

1. Der OCCT-Adapter ermittelt ab einer BRep-Kante die über gemeinsame Eckpunkte verbundenen Kanten, deren Tangenten dort höchstens 3° voneinander abweichen. Die Kanten müssen mindestens eine gemeinsame Fläche haben. Ergebnis und Traversierung sind deterministisch; ungültige Indizes liefern eine leere Liste.
2. Die Panels für Abrunden und Fasen erhalten den Modus „Tangential“. Er bleibt eine bewusste Wahl; Standard ist „Einzelkante“. Ein erneutes Tippen entfernt die gesamte gewählte Gruppe. „Kontur“ behält seine bisherige Bedeutung.
3. Integrationstests prüfen kollineare Teilkanten, tangential anschließende Halbkreise, rechtwinklige Kanten und die Modi in beiden Werkzeugen.

## Abnahme

- Kern- und iPad-Tests bestehen.
- Signierte App baut für das physische iPad; der Projektbestand wird vor/nach Installation geprüft.
- Bericht benennt verbleibende Unterschiede zu Shapr3D ohne Paritätsbehauptung.
