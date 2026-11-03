# PencilCAD Build 16 – Längen-Klick und durchgehende Fangspuren (30.10.2026)

## Änderungen gegenüber Build 14

- Der neue Fang **Gleiche Länge** spielt beim Einrasten einen selbst erstellten, kurzen Doppelklick (ca. 95 ms), ähnlich einem kleinen einrastenden Schloss. Der Klang wird beim Beginn der Skizze vorgeladen. Während derselbe Längenfang beim Ziehen bestehen bleibt, wird er nicht erneut gestartet; nach Verlassen und erneutem Einrasten kann er wieder erklingen.
- Der Schalter **Klick bei gleicher Länge** in „Mehr“ ist standardmäßig aktiv. Er ist unabhängig von den beiden Haptik-Schaltern. Die Audiokategorie `ambient` lässt andere Audioquellen weiterlaufen und respektiert die Stummschaltung des Geräts.
- Aktive grüne Objektfangspuren der Ausrichtung werden bis zu beiden sichtbaren Viewporträndern gezeichnet. Zuvor endete die Spur am aktuellen Fangpunkt.
- Der Suchbereich für automatische waagerechte und senkrechte Ausrichtungspunkte ist an die sichtbare Skizzengröße gekoppelt, mindestens aber so groß wie der bisherige Radius von 300 Bildschirmpunkten. Beim Suchen werden nur Punkte berücksichtigt, die ungefähr auf einer möglichen waagerechten oder senkrechten Spur liegen. Ausdrücklich gemerkte Punkte bleiben erhalten.
- Build 14 brachte den Längenfang, die gelbe Vorschau und die `Gleiche Länge`-Bedingung. Siehe `BUILD_14_AENDERUNGEN_UND_TESTS.md`.

## Verifikation

- Tests prüfen, dass die Ton-Auslösekennung beim Ziehen auf derselben Bezugslinie stabil bleibt und die WAV-Datei im App-Bundle liegt.
- Tests prüfen die sichtbare Verlängerung einer senkrechten und einer waagerechten Spur zu beiden Rändern sowie das Auffinden eines Ausrichtungspunkts jenseits der früheren 300-pt-Grenze.
- Vollständige App-Test-Suite im iPad-Simulator: **40 bestanden, 0 fehlgeschlagen** (`/tmp/PencilCAD-Build16-Sim.xcresult`).
- Vollständige App-Test-Suite auf dem verbundenen iPad: **40 bestanden, 0 fehlgeschlagen** (`/tmp/PencilCAD-Build16-iPad.xcresult`).
- Vor den Gerätetests wurden acht aktuelle Projektordner samt Projektsicherungen separat kopiert.
- Die beiden Test-Zusammenfassungen liegen als JSON in `Pruefprotokolle/`. `BUILD_16_CODE_DIFF_SEIT_BUILD_10.patch` zeigt 22 geänderte Quell- und Projektdateien gegenüber dem archivierten Build 10; die neu erzeugte WAV-Datei ist als Binärdatei separat im Projekt enthalten.
- Signierter Release-Bau 16 erfolgreich erstellt; `codesign --verify --deep --strict` bestanden. Die WAV-Datei und die isolierte BlendWorker-Extension liegen im signierten App-Bundle.
- Release-Bau 16 auf dem iPad installiert und gestartet; die App-Version auf dem Gerät ist 16. Der PencilCAD-Prozess lief bei der Statusprüfung.
- Nach der Installation waren alle acht zuvor vorhandenen Projektordner und 56 Dateien im Projektverzeichnis vorhanden; kein Ordnername fehlte. Ein Bytevergleich wird wegen möglicher paralleler Nutzeränderungen nicht behauptet.

## Grenzen

- Ein automatisierter Test kann die wahrgenommene Lautstärke und Klangfarbe des iPad-Lautsprechers nicht beurteilen. Der Ton muss bei Bedarf am Gerät nach Gehör feinabgestimmt werden.
- Die schwierige, mehrfach verrundete Anwendergeometrie aus Build 13 bleibt ein offener OCCT-Fall. Der isolierte Worker schützt den App-Prozess vor seinem nativen Absturz; er macht diese Rundung nicht erfolgreich. Details und IPS-Bericht: `BUILD_13_AENDERUNGEN_UND_TESTS.md`.
