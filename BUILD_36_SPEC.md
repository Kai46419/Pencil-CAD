# Build 36: Blechabwicklung prüfen

## Ziel

Vor dem DXF Export eine ungültige Abwicklung erkennen. Benachbarte Laschen und ihre Eckfreischnitte bleiben exportierbar, solange der Zuschnitt geometrisch gültig ist.

## Akzeptanz

- Ein Kasten mit vier benachbarten Laschen erzeugt einen geschlossenen Körper und eine überlappungsfreie Abwicklung.
- Eine Kontur mit kreuzenden oder überdeckten, nicht benachbarten Segmenten wird als ungültig erkannt.
- Bei ungültiger Abwicklung wird keine DXF Datei ausgegeben; die Fehlermeldung beschreibt die Ursache.
- Der vollständige Simulator Testlauf und ein Gerätetest auf dem iPad bestehen.
