PencilCAD Rundungen Fix – 30.10.2026

Geändert: App/Kernel/PCKShape.mm
- BRepMesh_IncrementalMesh Winkelabweichung: 0.35 -> 0.10 Radiant
- GCPnts_TangentialDeflection Winkelabweichung für sichtbare Kanten: 0.20 -> 0.08 Radiant

Erwartung: feinere Darstellung von Kreis- und Bogenkanten, insbesondere in der Extrusionsvorschau.
Achtung: Die Änderungen betreffen den OCCT-Mesher allgemein; größere Modelle können mehr Rechenzeit benötigen.
Nicht mit Xcode/iPad kompiliert oder getestet. Vor Installation Backup anlegen.
