import Foundation

/// Treiber ÄNDERN/ANORDNEN/KONSTRUIEREN/PRÜFEN (Paket M2)
extension ModelCommands {
    static func registerModify() {
        let list: [ModelCommandDriver.Type] = [
            // ÄNDERN (EdgeCommands.swift, FaceCommands.swift, BodyCommands.swift)
            FilletDriver.self, ChamferDriver.self, PressPullDriver.self,
            ShellDriver.self, DraftDriver.self, OffsetFaceDriver.self, ReplaceFaceDriver.self,
            WrapDriver.self, ImprintDriver.self,
            CombineDriver.self, SplitBodyDriver.self, ScaleDriver.self, MoldDriver.self,
            // ANORDNEN (ArrangeCommands.swift)
            MoveDriver.self, CopyDriver.self, TranslateDriver.self, AlignDriver.self, MirrorDriver.self,
            PatternRectDriver.self, PatternCircularDriver.self,
            // KONSTRUIEREN / PRÜFEN (ConstructInspectCommands.swift)
            ConstructPlaneDriver.self, ConstructAxisDriver.self, ConstructPointDriver.self,
            MeasureDriver.self, SectionDriver.self, PrintCheckDriver.self, MeshSculptDriver.self,
        ]
        for driver in list { register(driver) }
        // Antippen über den bisherigen Weg (eigene Regeln je Werkzeug)
        legacyTapIDs.formUnion([.wrap, .imprint, .mold, .translate, .constructPlane, .constructAxis, .constructPoint,
                                .measure, .printCheck, .meshSculpt])
    }
}
