# PencilCAD Build 17 – Abrundung und Projektintegrität

## Fehlerbild

- In „Titelloses Projekt 8“ zeigt die laufende 7-mm-Abrundung herausragende Dreiecke/Flächen. Die gespeicherte Grundgeometrie liegt unter `work/device-projects-before-build17/Projects/B056BBE2-3D77-4A2F-95C2-76AA3AC72059`.
- Im Modus „Einzelkante“ akzeptiert das Kantenfeld aktuell auch eine Flächenauswahl. Diese wählt intern sämtliche Kanten der Fläche und widerspricht der angezeigten Auswahlart.
- Der Rasterwert muss nach dem Schließen und Öffnen eines Projekts erhalten bleiben.

## Abnahmekriterien

1. Aus dem Projekt-8-Modell entsteht bei 7 mm entweder eine geometrisch gültige Abrundung ohne Fremdflächen oder eine klare Fehlermeldung. Eine ungültige Vorschau darf sich nicht übernehmen lassen.
2. „Einzelkante“ wählt bei einem Kantenantipp genau eine Kante; ein Flächenantipp wählt in diesem Modus keine versteckte Kantenmenge. Eine ausdrücklich gewählte Flächenoption darf ihre Kanten auswählen.
3. Crashs des nativen Rundungskernels beenden nicht die App; Vorschau und Commit nutzen denselben abgesicherten Weg.
4. Der Rasterwert übersteht Projekt-Neuöffnung. Verlauf und gespeicherte Geometrie werden nach Neuöffnung mit Tests geprüft.
5. Simulator- und iPad-Build sowie Tests werden protokolliert. Nicht bestandene Fälle werden benannt und nicht als abgeschlossen erklärt.
6. Nach einem unterbrochenen Speichervorgang öffnet das Projekt wieder mit dem letzten vollständigen Dateistand; eine kopierte Projektdatei wird erst nach vollständig geschriebener Kopie sichtbar.

## Implementierung

- Ein disjunkter Kernel/Blend-Worker-Arbeitsstrang prüft BRep-Ergebnis und Vorschau. Ein zweiter prüft Verlauf und Persistenz. Die Befehlsauswahl und der Rasterwert werden separat korrigiert.
- Die Fusion-Dokumentation dient als Funktionsreferenz. Ein öffentliches API-Beispiel ruft Fusion auf und enthält keinen eigenständig nutzbaren Fusion-Geometriekernel.
