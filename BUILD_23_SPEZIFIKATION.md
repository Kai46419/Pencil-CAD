# Build 23: Punktfeedback und Fang an Mittellinien

## Anlass

Beim fließenden Vorbeifahren am Fangpunkt soll kein Ton und keine Punkt-Haptik entstehen. Die Rückmeldung gehört erst zum ruhigen Schweben mit erfolgreichem Merken. Automatisch erzeugte Dreiecksmarken und Schnittpunkte gestrichelter Mittellinien sollen beim Setzen eines Kreismittelpunkts fangbar sein.

## Verhalten

- Ein neuer Punkt wird nach 0,5 Sekunden ruhigem Pencil-Hover im SolidCraft-Klickwerkzeug bzw. 1 Sekunde in anderen Werkzeugen gemerkt. Nur bei erfolgreichem neuem Merken werden der konfigurierbare kurze Ton und das unterstützte Pencil-Feedback angefordert. Freies Schweben, bloßes Passieren und Entmerken lösen keinen Punktton aus.
- Der separate Klick bei gleicher Linienlänge bleibt unverändert.
- Dreiecksmarken sind als Mittelpunkt auch bei deaktiviertem Endpunktfang erreichbar.
- Mathematische Schnittpunkte der angezeigten Mittelsenkrechten untereinander und mit gezeichneten Konstruktionssegmenten sind Fangpunkte. Das Kreis-Werkzeug übernimmt diese Koordinate als Mittelpunkt. Die bestehenden Endpunkt- und Schnittpunktfänge bleiben erhalten.
- Hilfslinien und daraus abgeleitete Fangpunkte sind temporäre Skizzenhilfen. Eine dauerhaft parametrische Beziehung zum Kreis entsteht dadurch noch nicht.

## Abnahme

- Gezielte und vollständige Simulator-Tests; iPad-Tests und signierter Release-Build, sofern das Gerät für Tests verfügbar ist.
- Physischer Pencil-Hover, Hörbarkeit und fühlbare Haptik müssen am Gerät manuell geprüft werden.
