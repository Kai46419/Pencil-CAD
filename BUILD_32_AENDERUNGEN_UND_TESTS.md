# PencilCAD Build 32 – Änderungen und Prüfbefund

## Projekt 21: Abrundungen

- Die gespeicherte 8,5-mm-Extrusion mit bereits gerundetem Steg wurde als STEP-Regression übernommen. Die zweite, einzeln gewählte Kante lässt sich bei kleinen Radien runden; 27,5 mm ergibt keinen gültigen Standardfillet. Auch ein gemeinsamer Fillet beider Kanten am Körper vor der ersten Rundung gelingt für 7,8/27,5 mm nicht.
- Am später gespeicherten 5-mm-Körper ist der gültige Radius der geprüften gekrümmten Kante etwa 4,8 mm. Die tangentiale Auswahl dieser und zweier benachbarter Kurvenkanten enthält jeweils nur die gewählte Kante. Eine automatische Übernahme der ganzen Kurvenkette erklärt diesen Fall daher nicht.
- Im Rundungswerkzeug gibt es eine ausdrücklich auszulösende Radiusprüfung. Sie testet die gewählte Einzelkante in einem isolierten Kernelprozess und übernimmt den größten erfolgreich geprüften Wert. Numerische Eingaben werden weiterhin nicht stillschweigend begrenzt. Die Schaltfläche ist bei variabler und teilweiser Rundung sowie bei Mehrfachauswahl deaktiviert.
- Die Suche führt höchstens zwölf Halbierungsschritte nach den Grenzprüfungen aus und bricht ihre Suche nach 15 Sekunden ab. Ihre Aussage bezieht sich auf den geprüften Bereich und den aktuellen Körper; sie ist kein Beweis für einen globalen mathematischen Maximalradius.

## Skizze: Ellipse und Spline beschneiden

- Ellipsen und offene oder geschlossene Fit- und Kontrollpunkt-Splines lassen sich an Schnittpunkten abschnittsweise beschneiden. Das gilt für Antippen und Wischen. Ohne Schnittpunkt gilt weiterhin der bisherige Löschablauf.
- Das Skizzenmodell hat keinen Ellipsenbogen als Entität. Der verbleibende Ellipsenabschnitt wird deshalb als glatte Fit-Spline mit analytischen Endtangenten abgelegt. Ein beschnittener Kontrollpunkt-Spline wird als Fit-Spline angenähert. Die Ursprungskurve bleibt im Rückgängig-Verlauf verfügbar.

## Tests

- Simulator: 111 Tests, 0 Fehler (`Build32_Simulator_XCTest.log`).
- iPad: 111 Tests, 0 Fehler (`Build32_iPad_XCTest.log`).
- Eine zunächst zu enge numerische Testgrenze für den gekrümmten Radius wurde nach einem iPad-Befund von 4,808 mm angepasst. Der Test prüft weiter, dass der zurückgegebene Radius gültig und 10 mm ungültig ist.
- Die Gerätedaten wurden vor den Tests gesichert. Die signierte Release-App (Build 32) wurde auf dem iPad installiert und gestartet. Die Projektdateien sind vor und nach Installation bytegleich; neu hinzugekommen sind lediglich vier automatisch erzeugte Einträge unter `ProjectBackups`.

## Grenze

Ein konstanter, zu beiden ursprünglichen Flächen tangentialer Radius von 27,5 mm an einem nur 8,5 mm hohen Steg kann mit der vorhandenen Standardfillet-Geometrie nicht als gültiger Körper erzeugt werden. Für eine optisch weiterlaufende Materialabnahme wäre ein anderes, ausdrücklich auswählbares Formwerkzeug nötig.
