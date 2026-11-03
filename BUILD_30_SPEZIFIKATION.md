# Build 30 – Abrunden/Fasen: vollständige Kantenauswahl

## Fehlerbild und Ursache

`edgesFromNumbers` überspringt ungültige Kantennummern. Die aufrufenden Abrundungs- und Fasenfunktionen können dadurch mit einer unvollständigen Auswahl weiterrechnen. Eine durch eine vorherige Modelländerung veraltete Kante darf nicht zu einer scheinbar erfolgreichen Teilrundung führen.

## Abnahme

1. Ein Referenzquader mit zwei gültigen Kanten und einer zusätzlichen ungültigen Kantennummer muss die Abrundung und Fase vollständig ablehnen. Ein einzelner gültiger Kantenwert bleibt erfolgreich.
2. Der Fehler wird im isolierten Worker als fehlgeschlagene Vorschau gemeldet; der ursprüngliche Körper bleibt unverändert.
3. Bisherige Projekt-6-/Projekt-8-Regressionen, kompletter Simulator- und iPad-Testlauf bleiben grün.
4. Signierten Build 30 auf dem iPad installieren; vorhandene Projektdaten vorher sichern und danach byteweise vergleichen.

## Bewertung

Die Abrundung steigt nur auf 3/5, wenn die geprüften Auswahl- und Absturzpfade auf dem Gerät bestehen. Komplexe Mehrfachrundungen beliebiger Anwenderkörper und große Radien sind damit nicht allgemein gelöst.
