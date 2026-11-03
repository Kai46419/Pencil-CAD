import XCTest
@testable import PencilCAD

@MainActor
final class SheetKernelIntegrationTests: XCTestCase {
    func testProjectBackupRestoresSeparateCopyAfterOriginalChanges() throws {
        let store = ProjectStore()
        let original = store.create(name: "Sicherungstest \(UUID().uuidString)")
        var backupID: UUID?
        var restoredID: UUID?
        defer {
            if let restoredID { store.delete(restoredID) }
            store.delete(original.id)
            if let backupID { try? store.deleteBackup(backupID) }
        }
        let originalFile = original.folder.appending(path: "model.step")
        try Data("Stand A".utf8).write(to: originalFile)
        let backup = try store.makeBackup(original.id)
        backupID = backup.id
        try Data("Stand B".utf8).write(to: originalFile)

        let restored = try store.restoreBackup(backup.id)
        restoredID = restored.id
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, original.name + " (wiederhergestellt)")
        XCTAssertEqual(try String(contentsOf: restored.folder.appending(path: "model.step"), encoding: .utf8), "Stand A")
        XCTAssertEqual(try String(contentsOf: originalFile, encoding: .utf8), "Stand B")
        XCTAssertTrue(store.backups.contains { $0.id == backup.id })
    }

    func testProjectBackupReopensModelAfterOriginalWasDeleted() throws {
        let store = ProjectStore()
        let original = store.create(name: "Modellsicherung \(UUID().uuidString)")
        var backupID: UUID?
        var restoredID: UUID?
        defer {
            if let restoredID { store.delete(restoredID) }
            store.delete(original.id)
            if let backupID { try? store.deleteBackup(backupID) }
        }
        let workspace = Workspace(project: original)
        workspace.model.previewInsert(.box, size: [20, 30, 10], at: .zero)
        workspace.model.commitPreview()
        XCTAssertEqual(workspace.model.bodies.count, 1)
        let backup = try store.makeBackup(original.id)
        backupID = backup.id
        store.delete(original.id)

        let restored = try store.restoreBackup(backup.id)
        restoredID = restored.id
        let reopened = Workspace(project: restored)
        XCTAssertEqual(reopened.model.bodies.count, 1)
        XCTAssertTrue(try XCTUnwrap(reopened.model.bodies.first?.shape.isClosedSolid))
    }

    private func rectangularSheet() throws -> SheetKernel {
        let kernel = try SheetKernel()
        try kernel.execute(SheetCommand("sketch.create", ["plane": "XY", "name": "Blechtest"]))
        try kernel.execute(SheetCommand("sketch.line", [
            "points": [[0, 0], [80, 0], [80, 60], [0, 60]], "closed": true,
        ]))
        try kernel.execute(SheetCommand("sketch.finish"))
        try kernel.execute(SheetCommand("sheet.flange", ["type": "base", "sketch": "Blechtest"]))
        return kernel
    }

    func testSheetFlangeUnfoldRefoldAndExports() throws {
        let kernel = try rectangularSheet()
        let base = try XCTUnwrap(kernel.bodies().first)
        XCTAssertTrue(base.sheet)
        try kernel.execute(SheetCommand.edgeFlange(edges: [SIMD3(40, 0, 2.5)], height: 15).targeting(base.name))
        let pattern = try kernel.execute(SheetCommand("sheet.flat_pattern").targeting(base.name))
        XCTAssertFalse((pattern["outline"]?.asArray ?? []).isEmpty)
        XCTAssertFalse((pattern["bends"]?.asArray ?? []).isEmpty)
        let dxf = try kernel.execute(SheetCommand("sheet.export_dxf").targeting(base.name))
        XCTAssertTrue((dxf["dxf"]?.asString ?? "").contains("SECTION"))
        let table = try kernel.execute(SheetCommand("sheet.export_bend_table", ["format": "csv"]).targeting(base.name))
        XCTAssertTrue((table["text"]?.asString ?? "").contains("bend,angle_deg"))
        try kernel.execute(SheetCommand.unfold.targeting(base.name))
        XCTAssertTrue(try kernel.bodies().first?.unfolded ?? false)
        try kernel.execute(SheetCommand.refold.targeting(base.name))
        XCTAssertFalse(try kernel.bodies().first?.unfolded ?? true)
    }

    func testSheetHemFoldAndPerforate() throws {
        let hemKernel = try rectangularSheet()
        let hemBody = try XCTUnwrap(hemKernel.bodies().first?.name)
        try hemKernel.execute(SheetCommand.hem(edges: [SIMD3(40, 0, 2.5)], length: 8).targeting(hemBody))
        XCTAssertFalse(try hemKernel.bodies().isEmpty)

        let foldKernel = try rectangularSheet()
        let foldBody = try XCTUnwrap(foldKernel.bodies().first?.name)
        try foldKernel.execute(SheetCommand.fold(from: SIMD3(40, 0, 2.5), to: SIMD3(40, 60, 2.5))
            .targeting(foldBody))
        XCTAssertFalse((try foldKernel.execute(SheetCommand("sheet.flat_pattern").targeting(foldBody))["bends"]?.asArray ?? []).isEmpty)

        let holeKernel = try rectangularSheet()
        let holeBody = try XCTUnwrap(holeKernel.bodies().first?.name)
        try holeKernel.execute(SheetCommand.perforate(diameter: 3, pitch: 8).targeting(holeBody))
        let holes = try holeKernel.execute(SheetCommand("sheet.flat_pattern").targeting(holeBody))
        XCTAssertGreaterThan((holes["perforations"]?.asArray ?? []).count, 0)
    }

    func testSheetBoxDimensionsFlatPatternAndReopen() throws {
        let project = Project(id: UUID(), name: "Blechkasten", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let workspace = Workspace(project: project)
        let spec = SheetBoxSpec(length: 100, width: 80, thickness: 2.5, radius: 2.5,
                                outer: true, heights: [20, 20, 20, 20])
        XCTAssertTrue(workspace.model.createSheetBox(spec))
        let body = try XCTUnwrap(workspace.model.sheetBodies.first)
        let box = try XCTUnwrap(workspace.model.bodies[body].shape.boundingBox?.map(\.doubleValue))
        XCTAssertEqual(box[3] - box[0], 100, accuracy: 0.1)
        XCTAssertEqual(box[4] - box[1], 80, accuracy: 0.1)
        XCTAssertTrue(workspace.model.bodies[body].shape.isClosedSolid)
        let flat = try workspace.model.flatPattern(of: body)
        XCTAssertEqual(flat.bends.count, 4)
        XCTAssertGreaterThan(flat.size.x * flat.size.y, 0)
        let laserDXF = try workspace.model.exportFlatPatternDXF(of: body)
        let drawingDXF = try workspace.model.exportFlatDrawingDXF(of: body)
        let bendCSV = try workspace.model.exportBendTableCSV(of: body)
        for file in [laserDXF, drawingDXF, bendCSV] {
            XCTAssertGreaterThan(try Data(contentsOf: file).count, 100)
            try? FileManager.default.removeItem(at: file)
        }
        let layout = FlatDrawing.sheetLayout(FlatDrawingPlan(flat), views: [:], paper: .a4,
            info: FlatSheetInfo(title: "Blechtest", subtitle: project.name, author: "", material: "",
                                unfolded: false))
        XCTAssertTrue(FlatDrawing.pdfData(layout, title: "Blechtest").starts(with: Data("%PDF".utf8)))
        let reopened = Workspace(project: project)
        XCTAssertEqual(reopened.model.sheetBodies.count, 1)
        XCTAssertEqual(reopened.model.bodies[0].sheetMetal?.steps.count,
                       workspace.model.bodies[body].sheetMetal?.steps.count)
    }

    func testSheetConversionPreviewDoesNotLeaveSourceFiles() throws {
        let project = Project(id: UUID(), name: "Blechumwandlung", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let workspace = Workspace(project: project)
        workspace.model.previewInsert(.box, size: [80, 60, 2.5], at: .zero)
        workspace.model.commitPreview()
        let plan = try XCTUnwrap(workspace.model.suggestSheetConversion(of: 0))
        XCTAssertTrue(plan.plateOnly)
        XCTAssertTrue(workspace.model.convertToSheet(0, baseFace: plan.baseFace, openEdges: [],
                                                      plateOnly: true, preview: true))
        XCTAssertTrue(workspace.model.convertToSheet(0, baseFace: plan.baseFace, openEdges: [],
                                                      plateOnly: true, preview: true))
        let files = try FileManager.default.contentsOfDirectory(at: workspace.model.sheetDocument.storageDirectory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "step" }.count, 1,
                       "Eine wiederholte Vorschau darf keine ungenutzten Quelldateien hinterlassen.")
        workspace.model.cancelPreview()
        let afterCancel = try FileManager.default.contentsOfDirectory(at: workspace.model.sheetDocument.storageDirectory,
                                                                      includingPropertiesForKeys: nil)
        XCTAssertEqual(afterCancel.filter { $0.pathExtension == "step" }.count, 0)
        XCTAssertTrue(workspace.model.convertToSheet(0, baseFace: plan.baseFace, openEdges: [],
                                                      plateOnly: true, preview: true))
        workspace.model.commitPreview()
        XCTAssertEqual(workspace.model.sheetBodies, [0])
        let saved = try FileManager.default.contentsOfDirectory(at: workspace.model.sheetDocument.storageDirectory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(saved.filter { $0.pathExtension == "step" }.count, 1,
                       "Ein übernommener Blechkörper braucht seine Quelldatei für den Verlauf.")
        let reopened = Workspace(project: project)
        XCTAssertEqual(reopened.model.sheetBodies, [0])
        XCTAssertFalse(try reopened.model.flatPattern(of: 0).outline.isEmpty)
    }

    func testSheetContourFlangeAndRuleValues() throws {
        let kernel = try SheetKernel()
        var rule = SheetRule(name: "Testblech", thickness: 1.5, kFactor: 0.4, bendRadius: 2)
        rule.gap = 0.2
        try kernel.execute(rule.command())
        try kernel.execute(SheetCommand("sketch.create", ["plane": "XY", "name": "Profil"]))
        try kernel.execute(SheetCommand("sketch.line", [
            "points": [[0, 0], [30, 0], [30, 20]], "ids": ["c1", "c2"],
        ]))
        try kernel.execute(SheetCommand("sketch.finish"))
        try kernel.execute(SheetCommand("sheet.flange", [
            "type": "contour", "sketch": "Profil", "curves": ["c1", "c2"], "distance": 40,
            "rule": "Testblech",
        ]))
        let body = try XCTUnwrap(kernel.bodies().first)
        XCTAssertTrue(body.sheet)
        let flat = FlatPattern(json: try kernel.execute(SheetCommand("sheet.flat_pattern").targeting(body.name)))
        XCTAssertEqual(flat.thickness, 1.5, accuracy: 0.001)
        XCTAssertEqual(flat.bends.count, 1)
        XCTAssertGreaterThan(flat.size.x * flat.size.y, 0)
    }

    func testSheetPathFlangeFromTransverseSketch() throws {
        let kernel = try rectangularSheet()
        let body = try XCTUnwrap(kernel.bodies().first?.name)
        try kernel.execute(SheetCommand("sketch.create", [
            "name": "Querprofil",
            "plane": ["origin": [40, 0, 2.5], "x_dir": [0, -1, 0], "y_dir": [0, 0, 1]],
        ]))
        try kernel.execute(SheetCommand("sketch.line", [
            "points": [[0, 0], [0, 12], [10, 12]], "ids": ["p1", "p2"],
        ]))
        try kernel.execute(SheetCommand("sketch.finish"))
        try kernel.execute(SheetCommand("sheet.path_flange", [
            "body": .string(body), "edge": [40, 0, 2.5], "sketch": "Querprofil", "curves": ["p1", "p2"],
        ]))
        XCTAssertTrue(try kernel.bodies().first?.sheet ?? false)
        let flat = FlatPattern(json: try kernel.execute(SheetCommand("sheet.flat_pattern").targeting(body)))
        XCTAssertGreaterThanOrEqual(flat.bends.count, 1)
    }

    func testChangingSheetRuleRebuildsMatchingBodyAndSurvivesReopen() throws {
        let project = Project(id: UUID(), name: "Blechregeltest", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let workspace = Workspace(project: project)
        let spec = SheetBoxSpec(length: 100, width: 80, thickness: 2.5, radius: 2.5,
                                outer: true, heights: [20, 20, 20, 20])
        XCTAssertTrue(workspace.model.createSheetBox(spec))
        XCTAssertEqual(try workspace.model.flatPattern(of: 0).thickness, 2.5, accuracy: 0.001)
        var rule = workspace.model.sheetDocument.activeRule
        rule.thickness = 1.5
        rule.bendRadius = 1.5
        workspace.model.setSheetRule(rule)
        XCTAssertEqual(try workspace.model.flatPattern(of: 0).thickness, 1.5, accuracy: 0.001)
        let reopened = Workspace(project: project)
        XCTAssertEqual(try reopened.model.flatPattern(of: 0).thickness, 1.5, accuracy: 0.001)
    }

    func testKantenSelectsOuterEdgeAndKeepsFlatBlankSize() throws {
        let project = Project(id: UUID(), name: "Kantentest", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let workspace = Workspace(project: project)
        let spec = SheetBoxSpec(length: 80, width: 60, thickness: 2.5, radius: 2.5,
                                outer: true, heights: [nil, nil, nil, nil])
        XCTAssertTrue(workspace.model.createSheetBox(spec))
        let before = try workspace.model.flatPattern(of: 0)
        let shape = workspace.model.bodies[0].shape
        let face = try XCTUnwrap((1...shape.faceCount).first { index in
            (workspace.model.plane(of: FaceRef(body: 0, face: index))?.normal.z ?? 0) > 0.9
                && shape.edgeNumbers(ofFace: index).count == 4
        })
        let edge = try XCTUnwrap(shape.edgeNumbers(ofFace: face).first?.intValue)
        workspace.start(.sheetKanten)
        let cmd = try XCTUnwrap(workspace.command)
        cmd.putNumber("height", 15)
        workspace.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: edge))
        XCTAssertNil(cmd.error)
        XCTAssertTrue(workspace.model.hasPreview)
        workspace.model.commitPreview()
        let after = try workspace.model.flatPattern(of: 0)
        XCTAssertEqual(after.bends.count, 1)
        XCTAssertEqual(after.size.x * after.size.y, before.size.x * before.size.y, accuracy: 1)
    }

    func testSheetStepEditDeleteAndReopen() throws {
        let project = Project(id: UUID(), name: "Blechverlauf", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let workspace = Workspace(project: project)
        let spec = SheetBoxSpec(length: 80, width: 60, thickness: 2.5, radius: 2.5,
                                outer: true, heights: [nil, nil, nil, nil])
        XCTAssertTrue(workspace.model.createSheetBox(spec))
        let shape = workspace.model.bodies[0].shape
        let face = try XCTUnwrap((1...shape.faceCount).first { index in
            (workspace.model.plane(of: FaceRef(body: 0, face: index))?.normal.z ?? 0) > 0.9
                && shape.edgeNumbers(ofFace: index).count == 4
        })
        let edge = try XCTUnwrap(shape.edgeNumbers(ofFace: face).first?.intValue)
        let geometry = try XCTUnwrap(shape.geometry(ofEdge: edge)?.map(\.doubleValue))
        let point = SIMD3(geometry[8], geometry[9], geometry[10])
        XCTAssertTrue(workspace.model.appendSheetCommand(.edgeFlange(edges: [point], height: 12), to: 0))
        let step = try XCTUnwrap(workspace.model.sheetInfo(0)?.steps.last)
        var edited = step.command
        edited.params["height"] = .number(18)
        XCTAssertTrue(workspace.model.updateSheetStep(body: 0, step: step.id, command: edited))
        XCTAssertEqual(workspace.model.sheetInfo(0)?.steps.last?.command.params["height"]?.asDouble, 18)
        let reopened = Workspace(project: project)
        XCTAssertEqual(reopened.model.sheetInfo(0)?.steps.last?.command.params["height"]?.asDouble, 18)
        XCTAssertTrue(reopened.model.deleteSheetStep(body: 0, step: step.id))
        XCTAssertTrue(try reopened.model.flatPattern(of: 0).bends.isEmpty)
    }
    func testFilletTapSelectsOneEdgeByDefaultAndContourOnRequest() throws {
        let project = Project(id: UUID(), name: "Konturtest", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let ws = Workspace(project: project)
        ws.model.previewInsert(.box, size: [20, 20, 10], at: .zero)
        ws.model.commitPreview()
        let shape = try XCTUnwrap(ws.model.bodies.first?.shape)
        let face = try XCTUnwrap((1...shape.faceCount).first { number in
            (ws.model.plane(of: FaceRef(body: 0, face: number))?.normal.z ?? 0) > 0.9
        })
        let boundary = shape.edgeNumbers(ofFace: face).map(\.intValue)
        let edge = try XCTUnwrap(boundary.first)
        ws.start(.fillet)
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: edge))
        XCTAssertEqual(ws.model.selectedEdges.map(\.edge), [edge])
        XCTAssertFalse(ws.model.completesEdgeChain)
        let cmd = try XCTUnwrap(ws.command)
        XCTAssertEqual(cmd.choices["selectionScope"], "edge")
        CommandPicks.setItems([], cmd, "edges")
        ws.refreshCommandPreview()
        ws.tapped(face: FaceRef(body: 0, face: face), edge: nil)
        XCTAssertTrue(ws.model.selectedEdges.isEmpty, "Einzelkante darf keine ganze Fläche übernehmen")
        EdgeBlendCommand.setFilletSelectionScope("face", cmd, ws)
        ws.tapped(face: FaceRef(body: 0, face: face), edge: nil)
        XCTAssertEqual(Set(ws.model.selectedEdges.map(\.edge)), Set(boundary))
        EdgeBlendCommand.setFilletSelectionScope("contour", cmd, ws)
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: edge))
        XCTAssertEqual(Set(ws.model.selectedEdges.map(\.edge)), Set(boundary))
        cmd.choices["selectionScope"] = "tangent"
        CommandPicks.setItems([], cmd, "edges")
        ws.refreshCommandPreview()
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: edge))
        XCTAssertEqual(ws.model.selectedEdges.map(\.edge), [edge]) // Quader: 90° an beiden Enden
        cmd.choices["selectionScope"] = "edge"
        CommandPicks.setItems([], cmd, "edges")
        ws.refreshCommandPreview()
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: edge))
        XCTAssertEqual(ws.model.selectedEdges.map(\.edge), [edge])
        ws.cancelCommand()
    }

    func testRepeatedSnappedFilletAndChamferValuesDoNotRestartBlendJobs() throws {
        for operation in [EdgeOperation.fillet, .chamfer] {
            let project = Project(id: UUID(), name: "Ziehpfeiltest", modified: Date())
            defer { try? FileManager.default.removeItem(at: project.folder) }
            let ws = Workspace(project: project)
            ws.model.previewInsert(.box, size: [20, 20, 10], at: .zero)
            ws.model.commitPreview()
            let shape = try XCTUnwrap(ws.model.bodies.first?.shape)
            let edge = try XCTUnwrap(shape.edgeNumbers(ofFace: 1).first)
            ws.model.toggleEdge(EdgeRef(body: 0, edge: edge.intValue))
            let cmd = EdgeBlendCommand.build(operation, id: operation == .fillet ? .fillet : .chamfer, ws)
            let initial = cmd.number(EdgeBlendCommand.valueKey(operation), default: 0)
            let before = ws.model.blendJobs.generation

            EdgeBlendCommand.drag(operation, .edge, initial, cmd, ws)
            XCTAssertEqual(ws.model.blendJobs.generation, before)

            EdgeBlendCommand.drag(operation, .edge, initial + 0.1, cmd, ws)
            let changed = ws.model.blendJobs.generation
            XCTAssertGreaterThan(changed, before)

            EdgeBlendCommand.drag(operation, .edge, initial + 0.1, cmd, ws)
            XCTAssertEqual(ws.model.blendJobs.generation, changed)
            ws.model.cancelBlendJobs()
        }
    }

    func testTangentEdgeChainStopsAtRightAngle() throws {
        // Die untere Kante des Profils hat zwei kollineare BRep-Teilstücke.
        let profile: [Double] = [0, 0, 0, 10, 0, 0, 20, 0, 0, 20, 10, 0, 0, 10, 0]
        let shape = try XCTUnwrap(PCKShape.prism(pointsXYZ: profile.map(NSNumber.init(value:)),
                                                 direction: SIMD3<Double>(0, 0, 5)))
        let face = try XCTUnwrap((1...shape.faceCount).first { number in
            shape.surface(ofFace: number)?.first?.intValue == 0
                && shape.edgeNumbers(ofFace: number).count == 5
        })
        let boundary = shape.edgeNumbers(ofFace: face).map(\.intValue)
        let straight = boundary.filter { number in
            guard let values = shape.geometry(ofEdge: number)?.map(\.doubleValue), values.count >= 8 else { return false }
            return abs(values[3]) < 1e-7 && abs(values[6]) < 1e-7 && abs(values[4] - values[7]) < 1e-7
        }
        XCTAssertEqual(straight.count, 2)
        let chain = shape.tangentEdges(startingAt: try XCTUnwrap(straight.first)).map(\.intValue)
        XCTAssertEqual(Set(chain), Set(straight))
        XCTAssertTrue(shape.tangentEdges(startingAt: 0).isEmpty)
    }

    func testTangentEdgeChainFollowsSemicircularArcs() throws {
        // Kapselprofil: zwei gerade Stücke und zwei tangential anschließende Halbkreise.
        let profile: [Double] = [
            0, -10, 10, 0, 10, 10, 0,
            1, 10, 10, 0, 20, 0, 0, 10, -10, 0,
            0, 10, -10, 0, -10, -10, 0,
            1, -10, -10, 0, -20, 0, 0, -10, 10, 0,
        ]
        let shape = try XCTUnwrap(PCKShape.prism(profileWires: [profile.map(NSNumber.init(value:))],
                                                 direction: SIMD3<Double>(0, 0, 5)))
        let face = try XCTUnwrap((1...shape.faceCount).first { number in
            shape.surface(ofFace: number)?.first?.intValue == 0
                && shape.edgeNumbers(ofFace: number).count == 4
                && shape.edgeNumbers(ofFace: number).allSatisfy { edge in
                    guard let geometry = shape.geometry(ofEdge: edge.intValue)?.map(\.doubleValue),
                          geometry.count >= 8 else { return false }
                    return abs(geometry[4] - 5) < 1e-7 && abs(geometry[7] - 5) < 1e-7
                }
        })
        let boundary = shape.edgeNumbers(ofFace: face).map(\.intValue)
        let chain = shape.tangentEdges(startingAt: try XCTUnwrap(boundary.first)).map(\.intValue)
        XCTAssertEqual(Set(chain), Set(boundary))
    }

    func testChamferSelectionModesKeepOneEdgeOrExplicitContour() throws {
        let project = Project(id: UUID(), name: "Fasenauswahl", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let ws = Workspace(project: project)
        ws.model.previewInsert(.box, size: [20, 20, 10], at: .zero)
        ws.model.commitPreview()
        let shape = try XCTUnwrap(ws.model.bodies.first?.shape)
        let face = try XCTUnwrap((1...shape.faceCount).first { number in
            (ws.model.plane(of: FaceRef(body: 0, face: number))?.normal.z ?? 0) > 0.9
        })
        let boundary = shape.edgeNumbers(ofFace: face).map(\.intValue)
        let seed = try XCTUnwrap(boundary.first)
        ws.start(.chamfer)
        let cmd = try XCTUnwrap(ws.command)
        XCTAssertEqual(cmd.choices["selectionScope"], "edge")
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: seed))
        XCTAssertEqual(ws.model.selectedEdges.map(\.edge), [seed])
        cmd.choices["selectionScope"] = "contour"
        CommandPicks.setItems([], cmd, "edges")
        ws.refreshCommandPreview()
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: seed))
        XCTAssertEqual(Set(ws.model.selectedEdges.map(\.edge)), Set(boundary))
        cmd.choices["selectionScope"] = "tangent"
        CommandPicks.setItems([], cmd, "edges")
        ws.refreshCommandPreview()
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: seed))
        XCTAssertEqual(ws.model.selectedEdges.map(\.edge), [seed])
        ws.tapped(face: FaceRef(body: 0, face: face), edge: EdgeRef(body: 0, edge: seed))
        XCTAssertTrue(ws.model.selectedEdges.isEmpty)
        ws.cancelCommand()
    }

    func testImpossibleBlendDoesNotClampOrRetryAnotherRadius() throws {
        let profile: [Double] = [0, 0, 0, 20, 0, 0, 20, 20, 0, 0, 20, 0]
        let shape = try XCTUnwrap(PCKShape.prism(pointsXYZ: profile.map(NSNumber.init(value:)),
                                                 direction: SIMD3<Double>(0, 0, 10)))
        let edge = try XCTUnwrap(shape.edgeNumbers(ofFace: 1).first)
        for operation in [EdgeOperation.fillet, .chamfer] {
            let input = BlendJobInput(operation: operation, shape: shape, edges: [edge], value: 1_000_000,
                                      second: nil, end: nil, partialRange: nil, mergeShape: nil)
            let result = BlendKernel.run(input)
            XCTAssertNil(result.shape)
            XCTAssertEqual(result.amount, input.value)
        }
    }

    func testNonfiniteBlendValuesAreRejectedBeforeKernelWork() throws {
        let project = Project(id: UUID(), name: "Ungültiger Radius", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let model = Workspace(project: project).model
        model.setEdgeValue(.infinity)
        XCTAssertEqual(model.edgeValue, 0)
        model.setEdgeValue(.nan)
        XCTAssertEqual(model.edgeValue, 0)
        model.setEdgeEndValue(.infinity)
        XCTAssertNil(model.edgeEndValue)
        model.setEdgeSecondValue(.nan)
        XCTAssertNil(model.edgeSecondValue)

        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        XCTAssertNil(box.filleting(edges: [edge], radius: .infinity))
        XCTAssertNil(box.filleting(edges: [edge], radius: 2, endRadius: .infinity))
        XCTAssertNil(box.chamfering(edges: [edge], distance: .infinity))
        XCTAssertNil(box.chamfering(edges: [edge], distance: 2, distance2: .infinity))
    }

    func testBRepTransferPreservesEdgeNumbersAfterFillet() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let first = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        let rounded = try XCTUnwrap(box.filleting(edges: [first], radius: 2))
        let data = try XCTUnwrap(rounded.brepData())
        let restored = try XCTUnwrap(PCKShape.fromBRepData(data))
        XCTAssertEqual(restored.faceCount, rounded.faceCount)
        XCTAssertEqual(restored.volume, rounded.volume, accuracy: 1e-5)
        for face in 1...rounded.faceCount {
            XCTAssertEqual(restored.edgeNumbers(ofFace: face), rounded.edgeNumbers(ofFace: face))
        }
        for edge in 1...30 {
            let original = rounded.geometry(ofEdge: edge)
            let transferred = restored.geometry(ofEdge: edge)
            XCTAssertEqual(original?.count, transferred?.count)
            if let original, let transferred {
                for (a, b) in zip(original, transferred) {
                    XCTAssertEqual(a.doubleValue, b.doubleValue, accuracy: 1e-5)
                }
            }
        }
    }

    func testFilletRunsInSeparateProcess() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        let result = try XCTUnwrap(IsolatedBlend.run(shape: box, edges: [edge], mode: 0, value: 2))
        XCTAssertTrue(result.isClosedSolid)
        XCTAssertTrue(result.isBRepValid)
        XCTAssertTrue(result.isValidBlendPreview(from: box))
        XCTAssertLessThan(result.volume, box.volume)
    }

    func testFilletRejectsCylinderSeamInsteadOfSilentlyRoundingOnlyTop() throws {
        let cylinder = try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
        let top = try XCTUnwrap(IsolatedBlend.run(shape: cylinder, edges: [1], mode: 0, value: 2))
        XCTAssertLessThan(top.volume, cylinder.volume)
        XCTAssertNil(IsolatedBlend.run(shape: cylinder, edges: [2], mode: 0, value: 2))
        XCTAssertNil(IsolatedBlend.run(shape: cylinder, edges: [1, 2], mode: 0, value: 2),
                     "Eine Nahtkante darf nicht stillschweigend aus einer Mehrfachauswahl verschwinden")
    }

    func testChamferRejectsCylinderSeamInsteadOfSilentlyChamferingOnlyTop() throws {
        let cylinder = try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
        let top = try XCTUnwrap(IsolatedBlend.run(shape: cylinder, edges: [1], mode: 1, value: 2))
        XCTAssertLessThan(top.volume, cylinder.volume)
        XCTAssertNil(IsolatedBlend.run(shape: cylinder, edges: [2], mode: 1, value: 2))
        XCTAssertNil(IsolatedBlend.run(shape: cylinder, edges: [1, 2], mode: 1, value: 2),
                     "Eine Nahtkante darf nicht stillschweigend aus einer Mehrfachauswahl verschwinden")
    }

    func testVariableFilletRejectsCylinderSeamInsteadOfSilentlyRoundingOnlyTop() throws {
        let cylinder = try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
        XCTAssertNil(cylinder.filleting(edges: [1, 2], radius: 2, endRadius: 1))
    }

    func testPerEdgeRadiiRejectCylinderSeamInsteadOfSilentlyRoundingOnlyTop() throws {
        let cylinder = try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
        XCTAssertNil(cylinder.filleting(edges: [1, 2], radii: [2, 1]))
    }

    func testAsymmetricChamferRejectsCylinderSeamInsteadOfSilentlyChamferingOnlyTop() throws {
        let cylinder = try XCTUnwrap(PCKShape.cylinder(base: .zero, axis: [0, 0, 1], radius: 10, height: 20))
        XCTAssertNil(cylinder.chamfering(edges: [1, 2], distance: 2, distance2: 1))
    }

    func testProject8MixedEdgeSelectionDoesNotReturnSingleEdgeFillet() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project8_AdjacentFilletInput", withExtension: "step"))
        let shape = try XCTUnwrap(PCKShape.readSTEP(path: url.path)?.first)
        let one = try XCTUnwrap(shape.filleting(edges: [20], radius: 3))
        if let both = shape.filleting(edges: [11, 20], radius: 3) {
            XCTAssertGreaterThan(abs(both.volume - one.volume), 1e-3,
                                 "Die Mehrfachauswahl darf nicht dieselbe Teilrundung wie Kante 20 liefern")
        }
    }

    func testFilletRejectsEntireSelectionWhenOneEdgeNumberIsStale() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        XCTAssertNotNil(box.filleting(edges: [edge], radius: 2))
        XCTAssertNil(box.filleting(edges: [edge, NSNumber(value: Int.max)], radius: 2),
                     "Eine veraltete Kante darf keine scheinbar erfolgreiche Teilrundung ergeben")
    }

    func testChamferRejectsEntireSelectionWhenOneEdgeNumberIsStale() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        XCTAssertNotNil(box.chamfering(edges: [edge], distance: 2))
        XCTAssertNil(box.chamfering(edges: [edge, NSNumber(value: Int.max)], distance: 2),
                     "Eine veraltete Kante darf keine scheinbar erfolgreiche Teilfase ergeben")
    }

    func testBlendWorkerDoesNotPreviewSubsetOfStaleSelection() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        let selection = [edge, NSNumber(value: Int.max)]
        XCTAssertNil(IsolatedBlend.run(shape: box, edges: selection, mode: 0, value: 2))
        XCTAssertNil(IsolatedBlend.run(shape: box, edges: selection, mode: 1, value: 2))
        XCTAssertEqual(box.volume, 4_000, accuracy: 0.01)
    }

    func testSinglePlanarFilletVolumeBoundRejectsExcessMaterialLoss() throws {
        let source = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(source.edgeNumbers(ofFace: 1).first)
        let rounded = try XCTUnwrap(source.filleting(edges: [edge], radius: 2))
        XCTAssertTrue(rounded.hasPlausibleSingleEdgeFilletVolume(from: source, edge: edge.intValue, radius: 2))
        // Ein zusätzliches Loch bleibt ein gültiger BRep, gehört aber nicht zu dieser Abrundung.
        let wrong = try XCTUnwrap(rounded.cutting(PCKShape.box(width: 8, depth: 8, height: 10)))
        XCTAssertTrue(wrong.isValidBlendPreview(from: source))
        XCTAssertFalse(wrong.hasPlausibleSingleEdgeFilletVolume(from: source, edge: edge.intValue, radius: 2))
        XCTAssertGreaterThan(rounded.volume - wrong.volume, 500)
    }

    func testFilletWorkerCrashDoesNotTerminateApp() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        XCTAssertNil(IsolatedBlend.run(shape: box, edges: [edge], mode: 99, value: 2))
        XCTAssertTrue(IsolatedBlend.wasBlocked(shape: box, edges: [edge], mode: 99))
        XCTAssertNil(IsolatedBlend.run(shape: box, edges: [edge], mode: 99, value: 3))
        let recovered = try XCTUnwrap(IsolatedBlend.run(shape: box, edges: [edge], mode: 0, value: 2))
        XCTAssertTrue(recovered.isClosedSolid)
    }

    func testProject6BRepTransferPreservesComplexEdgeNumbers() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project6_FilletInput", withExtension: "step"))
        let shape = try XCTUnwrap(PCKShape.readSTEP(path: url.path)?.first)
        let restored = try XCTUnwrap(PCKShape.fromBRepData(try XCTUnwrap(shape.brepData())))
        XCTAssertEqual(restored.faceCount, shape.faceCount)
        XCTAssertEqual(restored.volume, shape.volume, accuracy: 1e-4)
        for face in 1...shape.faceCount {
            XCTAssertEqual(restored.edgeNumbers(ofFace: face), shape.edgeNumbers(ofFace: face))
        }
    }

    func testProject6InterruptedMergeDoesNotStartFallbackFillet() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project6_FilletInput", withExtension: "step"))
        let complex = try XCTUnwrap(PCKShape.readSTEP(path: url.path)?.first)
        let complexEdge = try XCTUnwrap(complex.edgeNumbers(ofFace: 1).first)
        // Debug-Abbruch nach dem BRep-Transfer; der reale OCCT-Absturz wird hier nicht reproduziert.
        XCTAssertNil(IsolatedBlend.run(shape: complex, edges: [complexEdge], mode: 98, value: 2))
        XCTAssertTrue(IsolatedBlend.wasBlocked(shape: complex, edges: [complexEdge], mode: 0))

        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let boxEdge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        let input = BlendJobInput(operation: .fillet, shape: box, edges: [boxEdge], value: 2,
                                  second: nil, end: nil, partialRange: nil,
                                  mergeShape: complex, mergeEdges: [complexEdge])
        let result = BlendKernel.run(input)
        XCTAssertNil(result.shape, "Ein Worker-Abbruch darf keinen Fillet auf dem Ursprungskörper starten")
        XCTAssertEqual(result.amount, 2)
        XCTAssertTrue(IsolatedBlend.wasBlocked(shape: complex, edges: [complexEdge], mode: 0))
    }

    func testFailedMergeStillFallsBackWhenWorkerReturnsNormally() throws {
        let box = PCKShape.box(width: 20, depth: 20, height: 10)
        let edge = try XCTUnwrap(box.edgeNumbers(ofFace: 1).first)
        let input = BlendJobInput(operation: .fillet, shape: box, edges: [edge], value: 2,
                                  second: nil, end: nil, partialRange: nil,
                                  mergeShape: box, mergeEdges: [NSNumber(value: Int.max)])
        let result = BlendKernel.run(input)
        XCTAssertTrue(try XCTUnwrap(result.shape).isClosedSolid)
        XCTAssertFalse(result.merged)
        XCTAssertFalse(IsolatedBlend.wasBlocked(shape: box, edges: [NSNumber(value: Int.max)], mode: 0))
    }

    private func project8FilletInput() throws -> PCKShape {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project8_FilletInput", withExtension: "step"))
        return try XCTUnwrap(PCKShape.readSTEP(path: url.path)?.first)
    }

    func testProject8AdjacentFilletAcceptsFineRadiusAndReplays() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project8_AdjacentFilletInput", withExtension: "step"))
        let shape = try XCTUnwrap(PCKShape.readSTEP(path: url.path)?.first)
        XCTAssertTrue(shape.isClosedSolid)
        let project = Project(id: UUID(), name: "Project8 Regression", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        for name in ["features", "sketches", "bodies", "project"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project8_Adjacent_\(name)", withExtension: "json"))
            try FileManager.default.copyItem(at: source, to: project.folder.appending(path: "\(name).json"))
        }
        try FileManager.default.copyItem(at: url, to: project.folder.appending(path: "model.step"))
        let model = ModelStore(folder: project.folder)
        XCTAssertEqual(model.features.count, 3)
        XCTAssertNotNil(model.bodies(afterFeatures: 2))
        // Die orange Kante aus IMG_0129 ist in dieser gespeicherten STEP-Geometrie Kante 30.
        model.toggleEdge(EdgeRef(body: 0, edge: 30))
        var volumes: [Double] = []
        var editedVolume: Double?
        for radius in [1.1, 1.5, 4.0] {
            let merge = try XCTUnwrap(model.blendMerge(body: 0, value: radius, end: nil))
            XCTAssertEqual(merge.edges.count, 3)
            if radius == 1.1 { XCTAssertEqual(merge.radii ?? [], [4, 4, 1.1]) }
            let input = BlendJobInput(operation: .fillet, shape: shape, edges: [30], value: radius,
                                      second: nil, end: nil, partialRange: nil,
                                      mergeShape: merge.shape, mergeEdges: merge.edges.map(NSNumber.init(value:)),
                                      mergeRadii: merge.radii)
            let result = try XCTUnwrap(BlendKernel.run(input).shape)
            XCTAssertTrue(result.isBRepValid)
            XCTAssertTrue(result.isClosedSolid)
            XCTAssertTrue(result.isValidBlendPreview(from: merge.shape))
            volumes.append(result.volume)
            if radius == 1.1 {
                var features = model.features
                features[2] = merge.feature
                let replay = try XCTUnwrap(model.runFeatures(&features, from: 2, sketches: model.sketches,
                                                              values: model.variableValues))
                XCTAssertFalse(features[2].failed)
                XCTAssertEqual(try XCTUnwrap(replay.bodies.first).shape.volume, result.volume, accuracy: 0.01)
                let saved = try JSONDecoder().decode(Feature.self, from: JSONEncoder().encode(merge.feature))
                XCTAssertEqual(saved.data.edgeRadiusKeys, ["radius", "radius", "radius2"])
                var edited = model.features
                edited[2] = saved
                let parameter = try XCTUnwrap(edited[2].parameters.firstIndex { $0.key == "radius2" })
                edited[2].parameters[parameter].value = 1.5
                let changed = try XCTUnwrap(model.runFeatures(&edited, from: 2, sketches: model.sketches,
                                                               values: model.variableValues))
                XCTAssertFalse(edited[2].failed)
                editedVolume = changed.bodies.first?.shape.volume
            }
        }
        XCTAssertEqual(try XCTUnwrap(editedVolume), volumes[1], accuracy: 0.01)
        XCTAssertGreaterThan(volumes[0] - volumes[1], 1)
        XCTAssertGreaterThan(volumes[1] - volumes[2], 50)
    }

    func testProject8AdjacentFilletReopensWithoutFirstHistoryReplay() throws {
        let project = Project(id: UUID(), name: "Project8 Vorzustand", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        try FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        for name in ["features", "sketches", "bodies", "project"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project8_Adjacent_\(name)", withExtension: "json"))
            try FileManager.default.copyItem(at: source, to: project.folder.appending(path: "\(name).json"))
        }
        let step = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Project8_AdjacentFilletInput", withExtension: "step"))
        try FileManager.default.copyItem(at: step, to: project.folder.appending(path: "model.step"))
        let original = ModelStore(folder: project.folder)
        XCTAssertNotNil(original.bodies(afterFeatures: 2))
        var renamed = original.bodies
        renamed[0].name = "Geprüfter Körper"
        original.commit(renamed, name: "Körper benennen")

        let reopened = ModelStore(folder: project.folder)
        XCTAssertNotNil(reopened.featureRecorder.preBlendShape)
        XCTAssertNil(reopened.featureRecorder.cache[reopened.features[1].id])
        reopened.toggleEdge(EdgeRef(body: 0, edge: 30))
        let merge = try XCTUnwrap(reopened.blendMerge(body: 0, value: 1.5, end: nil))
        XCTAssertEqual(merge.edges.count, 3)
        XCTAssertNil(reopened.featureRecorder.cache[reopened.features[1].id],
                     "Die erste Nachbarrundung soll den gespeicherten Vorzustand statt eines Verlaufs-Nachbaus nutzen")
    }

    func testProject8SevenMillimeterFaceFilletRejectsInvalidPreview() throws {
        let source = try project8FilletInput()
        XCTAssertTrue(source.isBRepValid)
        XCTAssertTrue(source.isClosedSolid)
        let edges = source.edgeNumbers(ofFace: 8)
        XCTAssertEqual(edges.map(\.intValue).sorted(), [21, 23, 24, 25])
        let input = BlendJobInput(operation: .fillet, shape: source, edges: edges, value: 7,
                                  second: nil, end: nil, partialRange: nil, mergeShape: nil)
        let result = BlendKernel.run(input)
        XCTAssertNil(result.shape)
        XCTAssertEqual(result.amount, 7)
        XCTAssertFalse(IsolatedBlend.wasBlocked(shape: source, edges: edges, mode: 0))
    }

    func testFilletContourIncludesCornersBeyondRightAngle() throws {
        // L-förmiger Querschnitt: ein einspringender Winkel und fünf äußere Ecken.
        let profile: [Double] = [0, 0, 0, 20, 0, 0, 20, 10, 0,
                                 10, 10, 0, 10, 20, 0, 0, 20, 0]
        let shape = try XCTUnwrap(PCKShape.prism(pointsXYZ: profile.map(NSNumber.init(value:)),
                                                 direction: SIMD3<Double>(0, 0, 5)))
        let face = try XCTUnwrap((1...shape.faceCount).first { number in
            shape.surface(ofFace: number)?.first?.intValue == 0
                && shape.edgeNumbers(ofFace: number).count == 6
        })
        let boundary = shape.edgeNumbers(ofFace: face).map(\.intValue)
        let seed = try XCTUnwrap(boundary.first)
        let connected = shape.connectedEdges(ofFace: face, startingAt: seed).map(\.intValue)
        XCTAssertEqual(Set(connected), Set(boundary))
        XCTAssertEqual(connected.count, 6)
        XCTAssertTrue(shape.connectedEdges(ofFace: 0, startingAt: seed).isEmpty)
        let rounded = try XCTUnwrap(shape.filleting(edges: connected.map(NSNumber.init(value:)), radius: 1))
        XCTAssertTrue(rounded.isClosedSolid)
        XCTAssertLessThan(rounded.volume, shape.volume)
    }
    func testBaseFlangeUsesEmbeddedEngine() throws {
        XCTAssertTrue(SheetKernel.isAvailable, "SheetKit must be linked into the iPad test build")
        XCTAssertTrue(SheetKernel.version.contains("SolidCraft"))
        let kernel = try SheetKernel()
        let empty = try kernel.execute(SheetCommand("psk.bodies"))
        XCTAssertEqual(empty["bodies"]?.asArray?.count, 0)

        try kernel.execute(SheetCommand("sketch.create", ["plane": "XY", "name": "Grund"]))
        try kernel.execute(SheetCommand("sketch.line", [
            "points": [[0, 0], [40, 0], [40, 20], [0, 20]],
            "closed": true
        ]))
        try kernel.execute(SheetCommand("sketch.finish"))
        try kernel.execute(SheetCommand("sheet.flange", ["type": "base", "sketch": "Grund"]))
        let result = try kernel.execute(SheetCommand("psk.bodies"))
        let bodies = try XCTUnwrap(result["bodies"]?.asArray)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0]["sheet"]?.asBool, true)
    }
}
