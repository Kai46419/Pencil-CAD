# Build 32 – Projekt 21, zweite Abrundung; Skizzentrim

## Ausgangsfall

Projekt 21: 8,5 mm Extrusion, erste Rundung am rechten Steg mit 7,8 mm. Der linke Steg ist im gespeicherten Körper bei 0,5 bis 7,8 mm rundbar; 10 und 27,5 mm liefern mit dem Standardfillet keinen gültigen Körper. Der Nutzer möchte auch größere Rundungen, solange ein sinnvoller Restkörper bleibt. Zusätzlich sollen Ellipsen und Splines an Schnittpunkten abschnittsweise beschnitten werden können.

## Vorgehen und Abnahme

1. Für Projekt 21 den Originalkörper vor der ersten Rundung und den Stand danach getrennt prüfen; feststellen, ob ein gemeinsamer OCCT-Fillet die gewünschten Radien korrekt abbildet oder ob die Geometrie selbst begrenzt.
2. Eine größere Rundung nur dann freigeben, wenn sie die gewählte Kante bearbeitet, einen einzigen gültigen geschlossenen Restkörper erzeugt und keine anderen Konturen unbeabsichtigt beschädigt. Numerische Radien nicht stillschweigend verkleinern.
3. Wenn 27,5 mm in dieser Geometrie nicht gültig konstruierbar sind, die erreichbare Grenze und den konkreten Grund in der Bedienung darstellen. Die Grenzsuche darf keine zusätzlichen instabilen OCCT-Versuche auf dem Main-Thread starten.
4. Ellipsen und Splines an geometrischen Schnittpunkten in verbleibende Abschnitte zerlegen; bestehende Skizzenbedingungen und Auswahlabläufe prüfen.
5. Regressionen an gespeicherter Geometrie, vollständige Simulator- und iPad-Tests, Projektdateien nach Installation vergleichen. Nur verifizierte Ergebnisse in die Sternenwertung übernehmen.
