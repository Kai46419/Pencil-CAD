# PencilCAD Build 13 – Abrundung ohne App-Absturz

## Anlass

Build 11 und 12 stürzten bei der interaktiven Abrundung von „Titelloses Projekt 6“ mit `EXC_BAD_ACCESS` in OpenCASCADE ab. Build 12 beseitigte die automatische Radius-Suche, aber der direkte Fillet-Aufruf stürzte weiterhin ab. Der Screenshot `IMG_0125.PNG` zeigt zwei ausgewählte Kanten an einer bereits mehrfach bearbeiteten Form; der beim Absturz gezogene Radius ist nicht gespeichert.

## Erwartetes Verhalten

1. Abrunden und Fasen laufen auf iPadOS 26+ in einem separaten Prozess.
2. Ein nativer Absturz dieses Prozesses beendet PencilCAD nicht. Der aktuelle Versuch liefert kein Ergebnis; der gespeicherte Körper und Verlauf bleiben erhalten. Ein neuer Versuch kann einen neuen Worker starten.
3. Vorschau und Nachbau des gespeicherten Verlaufs verwenden denselben isolierten Pfad. Direkte Kernel-Aufrufe dürfen in diesen beiden Produktpfaden nicht verbleiben.
4. Die Kantenidentität bleibt beim Hin- und Rücktransfer erhalten. Fehlerhafte oder zu große Eingaben werden abgelehnt.
5. Projektdateien bleiben bei Installation und Tests erhalten.

## Grenzen

Die Prozessisolierung behebt einen OpenCASCADE-Geometriefehler nicht automatisch. Eine schwierige Abrundung kann weiterhin scheitern oder nach einem Zeitlimit abbrechen; die App soll dann weiterlaufen. Für iPadOS 17–25 steht in diesem Stand kein sicherer Abrundungs- oder Fasenprozess zur Verfügung. Shapr3D-Funktionsumfang und identische Grenzradien werden nicht behauptet.
