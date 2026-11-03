# Build 19: Abrundung beim Ziehen

## Befund

Der iPad-Test meldet Ruckeln beim Abrunden nach Build 18. Der Ziehpfeil rastet in 0,1-mm-Schritten. `touchesMoved` reicht bislang jedes Touch-Ereignis an den Modellbefehl weiter, auch wenn der gerastete Wert unverändert ist. `EdgeBlendCommand.drag` startet dann erneut die Vorschauvorbereitung und invalidiert den laufenden Blend-Job.

## Ziel

- Ein unveränderter gerasteter Wert löst weder Viewport-Aktualisierung noch neue Abrundungsanfrage aus.
- Ein geänderter Wert wird weiterhin sofort als Radius übernommen; 0,1-mm-Schritte bleiben erhalten.
- Die Prüfung gilt für Abrunden und Fasen und verändert die Auswahl- und Kernel-Logik nicht.

## Abnahme

- Regressionstest: Wiederholtes Setzen desselben gerasteten Radius erhöht die Generation des Blend-Jobs nicht; ein neuer Radius schon.
- Vollständige Tests auf Simulator und iPad; Release-Build und Projektsicherung vor Installation.
- Der subjektive Eindruck beim Ziehen wird auf dem iPad gesondert geprüft; automatisierte Tests messen die Bildrate nicht.
