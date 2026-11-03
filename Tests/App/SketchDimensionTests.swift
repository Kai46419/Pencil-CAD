import XCTest
@testable import PencilCAD

@MainActor
final class SketchDimensionTests: XCTestCase {
    func testTextArcRadiusUpdatesLinkedPathAndRejectsImpossibleRadius() throws {
        let text = SketchText(string: "CAD", anchor: [0, 0], height: 2,
                              fontName: "Helvetica", alignment: .left)
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.text(text),
                                              .arc(start: [0, 0], mid: [5, 2], end: [10, 0])])
        let original = try XCTUnwrap(SketchTextPath.curve(of: sketch.entities[1]))
        sketch.setTextPath(at: 0, points: original.points, closed: false, source: 1)
        sketch.setTextPathArcRadius(at: 0, radius: 10)
        guard case .arc(let a, let m, let b) = sketch.entities[1] else { return XCTFail("Bogen fehlt") }
        XCTAssertEqual(try XCTUnwrap(ArcGeometry(a, m, b)).radius, 10, accuracy: 1e-5)
        let updated = try XCTUnwrap(sketch.sketchText(at: 0)?.deform?.path)
        XCTAssertEqual(updated.source, 1)
        XCTAssertNotEqual(updated.points, original.points)
        sketch.setTextPathArcRadius(at: 0, radius: 2)
        guard case .arc(let a2, let m2, let b2) = sketch.entities[1] else { return XCTFail("Bogen fehlt") }
        XCTAssertEqual(try XCTUnwrap(ArcGeometry(a2, m2, b2)).radius, 10, accuracy: 1e-5)
    }

    func testCenterArcSnapsOnlyAtActualRadiusCurveIntersection() throws {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.line([6, 6], [6, 11])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .arc
        sketch.arcMode = .center
        sketch.snapKinds = [.onCurve]
        sketch.click.points = [SketchClickPoint(point: [0, 0], target: nil),
                               SketchClickPoint(point: [10, 0], target: nil)]
        sketch.click.lastAngle = 0
        sketch.clickHover(at: [6.1, 7.9], tolerance: 0.5)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(candidate.point.x, 6, accuracy: 1e-5)
        XCTAssertEqual(candidate.point.y, 8, accuracy: 1e-5)
        guard case .onCurve? = candidate.target else { return XCTFail("Kurve muss exakt gefangen sein") }
        sketch.clickHover(at: [6, 7], tolerance: 0.5)
        if case .onCurve? = sketch.currentCandidate?.target {
            XCTFail("Punkt neben dem Kreis darf keinen Kurvenfang behalten")
        }
    }

    func testTangentArcCanUseOtherSideAndFlipAfterCreation() throws {
        let start = Point2(0, 0), end = Point2(10, 10), direction = Point2(1, 0)
        guard case .arc(let a, let m, let b)? = SketchController.tangentArcShape(start: start,
                   direction: direction, end: end),
              case .arc(_, let otherMid, _)? = SketchController.tangentArcShape(start: start,
                   direction: direction, end: end, opposite: true) else {
            return XCTFail("Beide Bogenseiten müssen möglich sein")
        }
        let first = try XCTUnwrap(ArcGeometry(a, m, b))
        let opposite = try XCTUnwrap(ArcGeometry(a, otherMid, b))
        XCTAssertEqual(first.radius, opposite.radius, accuracy: 1e-7)
        XCTAssertEqual(first.center.x, opposite.center.x, accuracy: 1e-7)
        XCTAssertLessThan(first.sweep * opposite.sweep, 0)

        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.arc(start: a, mid: m, end: b)])
        sketch.addToSelection([.curve(SketchCurveRef(entity: 0, index: 0))])
        sketch.flipSelectedArcSide()
        guard case .arc(_, let flipped, _) = sketch.entities[0] else { return XCTFail("Bogen fehlt") }
        XCTAssertEqual(simd_distance(flipped, otherMid), 0, accuracy: 1e-7)
        sketch.undo()
        guard case .arc(_, let restored, _) = sketch.entities[0] else { return XCTFail("Undo fehlt") }
        XCTAssertEqual(simd_distance(restored, m), 0, accuracy: 1e-7)
    }

    func testSolidCraftLineAngleUsesPreviousSlantedSegment() throws {
        let sketch = SketchController()
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [.line([0, 0], [10, 5])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.snapEnabled = false
        sketch.click.points = [SketchClickPoint(point: [10, 5],
                                                target: .point(SketchPointRef(entity: 0, index: 1)))]
        sketch.clickHover(at: [10, -5], tolerance: 0.5)
        let angle = try XCTUnwrap(sketch.clickLiveValues.first { $0.key == "Winkel" }?.value)
        XCTAssertEqual(angle, 63.4349488, accuracy: 0.01)
        sketch.options.locked["Winkel"] = "90"
        sketch.clickHover(at: [12, -5], tolerance: 0.5)
        let end = try XCTUnwrap(sketch.currentCandidate?.point)
        let back = Point2(-10, -5), next = end - Point2(10, 5)
        XCTAssertEqual(simd_dot(back, next), 0, accuracy: 1e-6)
    }

    func testSketchPencilWheelHoverAndReleaseSelectsToolOnce() {
        let project = Project(id: UUID(), name: "Stiftrad-Test", modified: Date())
        let workspace = Workspace(project: project)
        let sketch = workspace.sketch
        sketch.isActive = true
        sketch.load(plane: .ground, entities: [])
        sketch.tool = .select
        workspace.quickToolsLocation = CGPoint(x: 150, y: 150)
        let palette = QuickToolsPalette(workspace: workspace, sketch: sketch, location: workspace.quickToolsLocation!)
        let size = CGSize(width: 300, height: 300)
        let lineIcon = palette.iconCenter(index: 1, in: size)
        XCTAssertEqual(palette.hoverIndex(at: lineIcon, in: size), 1)
        let firstIcon = palette.iconCenter(index: 0, in: size)
        let nearLine = CGPoint(x: lineIcon.x * 0.9 + firstIcon.x * 0.1,
                               y: lineIcon.y * 0.9 + firstIcon.y * 0.1)
        XCTAssertEqual(palette.hoverIndex(at: nearLine, in: size), 1)
        XCTAssertNil(palette.hoverIndex(at: CGPoint(x: 150, y: 150), in: size))
        workspace.updateQuickToolsHover(1)
        workspace.updateQuickToolsHover(1)
        XCTAssertEqual(workspace.quickToolsHoverIndex, 1)
        XCTAssertTrue(QuickToolsPalette.performSelection(1, workspace: workspace, sketch: sketch))
        XCTAssertEqual(sketch.tool, .polyline)
        XCTAssertNil(workspace.quickToolsLocation)
        XCTAssertNil(workspace.quickToolsHoverIndex)
    }

    func testEqualLengthPreviewHighlightsTransitiveReferenceGroup() throws {
        let first = SketchCurveRef(entity: 0, index: 0)
        let second = SketchCurveRef(entity: 1, index: 0)
        let third = SketchCurveRef(entity: 2, index: 0)
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 0], [10, 0]), .line([20, 0], [30, 0]), .line([40, 0], [50, 0]),
        ], constraints: [SketchConstraint(variant: .equalLength(first, second)),
                         SketchConstraint(variant: .equalLength(second, third))])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.equalLength]
        sketch.click.points = [SketchClickPoint(point: [60, 0], target: nil)]
        sketch.clickHover(at: [70, 0], tolerance: 1)
        guard case .equalLength(let snapped)? = sketch.currentCandidate?.target, snapped == third else {
            return XCTFail("Die nähere dritte Linie muss als Bezug gefangen werden")
        }
        XCTAssertNotNil(sketch.equalLengthPreview)
        let references = sketch.equalLengthReferenceLines
        XCTAssertEqual(references.count, 3)
        XCTAssertTrue(references.contains { $0.count == 2 && $0[0].x == 0 && $0[1].x == 10 })
        XCTAssertTrue(references.contains { $0.count == 2 && $0[0].x == 20 && $0[1].x == 30 })
        XCTAssertTrue(references.contains { $0.count == 2 && $0[0].x == 40 && $0[1].x == 50 })
    }

    func testSolidCraftParallelPreviewMarksCurrentAndReferenceLine() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [10, 5])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.parallel]
        sketch.click.points = [SketchClickPoint(point: [20, 0], target: nil)]
        sketch.clickHover(at: [32, 6], tolerance: 1)
        guard case .parallel(_)? = sketch.currentCandidate?.target else {
            return XCTFail("Der schräge Parallel-Fang muss aktiv sein")
        }
        let reference = try XCTUnwrap(sketch.parallelPreview)
        XCTAssertEqual(reference[0].x, 0, accuracy: 1e-8)
        XCTAssertEqual(reference[1].y, 5, accuracy: 1e-8)
        XCTAssertTrue(sketch.previewPolylines.contains { line in
            line.count == 2 && simd_distance(line[0], [20, 0]) < 1e-8
        })
    }

    func testClosingSolidCraftContourReturnsToSelectionAndShowsEditableLength() {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 0], [10, 0]), .line([10, 0], [10, 10]), .line([10, 10], [0, 10]),
        ])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.click.points = [SketchClickPoint(point: [0, 10], target: nil)]
        sketch.click.chainFirst = [0, 0]
        sketch.clickBegan(at: [0, 0], tolerance: 1)
        sketch.clickEnded(at: [0, 0], tolerance: 1)
        XCTAssertEqual(sketch.entities.count, 4)
        XCTAssertEqual(sketch.tool, .select)
        XCTAssertFalse(sketch.isInProgress)
        sketch.select(at: [5, 0], tolerance: 0.5)
        XCTAssertTrue(sketch.visibleDimensions.contains { $0.kind == .length && $0.isEditable })
    }

    func testClosingClassicContourReturnsToSelection() {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [])
        sketch.options.inputStyle = .classic
        sketch.tool = .polyline
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint]
        let corners: [Point2] = [[0, 0], [20, 0], [20, 20], [0, 20], [0, 0]]
        for index in 0..<4 {
            sketch.began(at: corners[index], tolerance: 0.5)
            sketch.moved(to: corners[index + 1], tolerance: 0.5)
            sketch.ended(at: corners[index + 1], tolerance: 0.5)
        }
        XCTAssertEqual(sketch.entities.count, 4)
        XCTAssertEqual(sketch.tool, .select)
        XCTAssertFalse(sketch.isInProgress)
    }

    func testClassicSnapUsesExactLineCircleIntersections() throws {
        let x = sqrt(91.0)
        let entities: [SketchEntity] = [
            .line([-20, 3], [20, 3]), .circle(center: [0, 0], radius: 10),
        ]
        let index = SnapIndex(entities: entities)
        XCTAssertEqual(index.intersections.count, 2)
        for expectedX in [-x, x] {
            XCTAssertTrue(index.intersections.contains {
                abs($0.x - expectedX) < 1e-6 && abs($0.y - 3) < 1e-6
            }, "Gerade/Kreis muss mathematisch exakt schneiden")
        }

        let sketch = SketchController()
        sketch.load(plane: .ground, entities: entities, construction: [0])
        sketch.options.inputStyle = .classic
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.intersection]
        sketch.tool = .circle
        sketch.hover(at: [x + 0.08, 3.05], tolerance: 1)
        let hovered = try XCTUnwrap(sketch.hoverSnap)
        XCTAssertEqual(hovered.kind, .intersection)
        XCTAssertEqual(hovered.point.x, x, accuracy: 1e-6)
        XCTAssertEqual(hovered.point.y, 3, accuracy: 1e-6)
    }

    func testClassicSnapUsesExactCircleCircleAndArcIntersections() {
        let circles = SnapIndex(entities: [
            .circle(center: [0, 0], radius: 10),
            .circle(center: [12, 1], radius: 10),
        ])
        let exact = SketchTrim.circleCircle([0, 0], 10, [12, 1], 10)
        XCTAssertEqual(circles.intersections.count, 2)
        for expected in exact {
            XCTAssertTrue(circles.intersections.contains { simd_distance($0, expected) < 1e-6 })
        }

        let arc: SketchEntity = .arc(start: [10, 0], mid: [0, 10], end: [-10, 0])
        let upper = SnapIndex(entities: [arc, .line([-20, 3], [20, 3])])
        let lower = SnapIndex(entities: [arc, .line([-20, -3], [20, -3])])
        XCTAssertEqual(upper.intersections.count, 2)
        XCTAssertTrue(lower.intersections.isEmpty, "Schnitt außerhalb des Bogenverlaufs darf nicht fangen")
    }

    func testClassicOnCurveFollowsExactCircleAndArcWithFineGrid() {
        let angle = 0.12345
        let raw = Point2(10.08 * cos(angle), 10.08 * sin(angle))
        let circle = SnapIndex(entities: [.circle(center: [0, 0], radius: 10)])
        let free = circle.snap(raw, tolerance: 1, kinds: [.onCurve], gridStep: 0)
        XCTAssertEqual(free.kind, .onCurve)
        XCTAssertEqual(simd_length(free.point), 10, accuracy: 1e-8)

        let stepped = circle.snap(raw, tolerance: 1, kinds: [.onCurve, .grid], gridStep: 0.001)
        XCTAssertEqual(stepped.kind, .onCurve)
        XCTAssertEqual(simd_length(stepped.point), 10, accuracy: 1e-8)
        let snappedAngle = (10 * angle / 0.001).rounded() * 0.001 / 10
        XCTAssertEqual(atan2(stepped.point.y, stepped.point.x), snappedAngle, accuracy: 1e-8)

        let arc = SnapIndex(entities: [
            .arc(start: [10, 0], mid: [0, 10], end: [-10, 0]),
        ])
        let onArc = arc.snap(raw, tolerance: 1, kinds: [.onCurve], gridStep: 0)
        XCTAssertEqual(onArc.kind, .onCurve)
        XCTAssertEqual(simd_length(onArc.point), 10, accuracy: 1e-8)
    }

    func testSolidCraftHoverKeepsSnapTracesAndCreatesTwoPointMidline() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [20, 0])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline

        XCTAssertTrue(sketch.captureHovered(at: [0, 0], tolerance: 1))
        XCTAssertEqual(sketch.click.pinned.count, 1)
        XCTAssertEqual(sketch.capturedPoints.count, 1)
        XCTAssertTrue(sketch.captureHovered(at: [20, 0], tolerance: 1))
        XCTAssertEqual(sketch.click.pinned.count, 2)
        XCTAssertTrue(sketch.capturedPoints.isEmpty)
        XCTAssertEqual(try XCTUnwrap(sketch.marks.first).x, 10, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(sketch.marks.first).y, 0, accuracy: 1e-8)
        let midline = try XCTUnwrap(sketch.guideLines.first)
        XCTAssertEqual(midline.lines.count, 2)
        XCTAssertEqual(midline.lines[0].count, 2)
        XCTAssertEqual(midline.lines[1].count, 2)

        XCTAssertTrue(sketch.captureHovered(at: [20, 0], tolerance: 1))
        XCTAssertEqual(sketch.click.pinned.count, 1, "Erneutes Schweben muss den Spurpunkt entmerken")
    }

    func testClassicHoverStillCreatesTwoPointMidline() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [20, 0])])
        sketch.options.inputStyle = .classic
        sketch.tool = .polyline
        XCTAssertTrue(sketch.captureHovered(at: [0, 0], tolerance: 1))
        XCTAssertTrue(sketch.captureHovered(at: [20, 0], tolerance: 1))
        XCTAssertEqual(try XCTUnwrap(sketch.marks.first).x, 10, accuracy: 1e-8)
        XCTAssertEqual(sketch.guideLines.first?.lines.count, 2)
        XCTAssertTrue(sketch.click.pinned.isEmpty)
    }

    func testProjectGridStepSurvivesReopen() throws {
        let project = Project(id: UUID(), name: "Rastertest", modified: Date())
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let first = Workspace(project: project)
        first.sketch.gridStep = 0.001
        XCTAssertEqual(GridSettings.stored(in: project.folder), 0.001)
        let reopened = Workspace(project: project)
        XCTAssertEqual(reopened.sketch.gridStep, 0.001)
    }

    func testAlignmentGuideReachesBothViewportEdges() throws {
        let vertical = try XCTUnwrap(SketchGuideGeometry.clipped(
            ([0, 0], [0, 50]), projected: (CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 150)),
            to: CGRect(x: 0, y: 0, width: 200, height: 300)))
        XCTAssertEqual(vertical[0].y, -100, accuracy: 1e-8)
        XCTAssertEqual(vertical[1].y, 200, accuracy: 1e-8)
        let horizontal = try XCTUnwrap(SketchGuideGeometry.clipped(
            ([0, 0], [50, 0]), projected: (CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 100)),
            to: CGRect(x: 0, y: 0, width: 300, height: 200)))
        XCTAssertEqual(horizontal[0].x, -100, accuracy: 1e-8)
        XCTAssertEqual(horizontal[1].x, 200, accuracy: 1e-8)
    }

    func testRememberedPointBisectorSpansViewportWhilePairStaysFinite() throws {
        let pair: [[Point2]] = [[[0, 0], [10, 0]], [[5, -3], [5, 3]]]
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
        let visible = SketchGuideGeometry.visiblePairLines(pair, project: { point in
            CGPoint(x: 100 + point.x * 10, y: 100 + point.y * 10)
        }, to: viewport)
        XCTAssertEqual(visible[0][0].x, pair[0][0].x, accuracy: 1e-8)
        XCTAssertEqual(visible[0][1].x, pair[0][1].x, accuracy: 1e-8)
        XCTAssertEqual(visible[1][0].y, -10, accuracy: 1e-8)
        XCTAssertEqual(visible[1][1].y, 10, accuracy: 1e-8)
    }

    func testAlignmentPointRemainsAvailableBeyondOld300PointLimit() {
        let inference = SketchInference(entities: [.line([0, 0], [10, 0])], construction: [])
        let metrics = SnapMetrics(mmPerPoint: 1, viewHalfHeight: 500)
        XCTAssertGreaterThan(metrics.alignReach, 850)
        let points = inference.alignmentPoints(near: [0, 850], reach: metrics.alignReach,
                                               axisTolerance: metrics.refine, kinds: [.endpoint])
        XCTAssertTrue(points.contains { simd_distance($0, [0, 0]) < 1e-9 })
    }

    func testEqualLengthClickHasOneIdentityDuringDragAndBundledSound() {
        let first = SketchCurveRef(entity: 0, index: 0)
        let second = SketchCurveRef(entity: 1, index: 0)
        let a = SnapFeedbackIdentity.key(target: .equalLength(first), label: "=", point: [10, 0], ticks: true)
        let b = SnapFeedbackIdentity.key(target: .equalLength(first), label: "=", point: [10, 1], ticks: true)
        let c = SnapFeedbackIdentity.key(target: .equalLength(second), label: "=", point: [10, 1], ticks: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotNil(Bundle.main.url(forResource: "EqualLengthClick", withExtension: "wav"))
    }

    func testPassingOverSnapPointsDoesNotPlaySound() {
        let ref = SketchCurveRef(entity: 0, index: 0)
        XCTAssertFalse(SnapFeedbackSound.playsWhileMoving(for: .point(nil), equalLengthClick: true))
        XCTAssertFalse(SnapFeedbackSound.playsWhileMoving(for: .crossing(ref, ref), equalLengthClick: true))
        XCTAssertFalse(SnapFeedbackSound.playsWhileMoving(for: .midpoint(ref), equalLengthClick: true))
        XCTAssertFalse(SnapFeedbackSound.playsWhileMoving(for: .horizontal, equalLengthClick: true))
        XCTAssertTrue(SnapFeedbackSound.playsWhileMoving(for: .equalLength(ref), equalLengthClick: true))
        XCTAssertFalse(SnapFeedbackSound.playsWhileMoving(for: .equalLength(ref), equalLengthClick: false))
        XCTAssertNotNil(Bundle.main.url(forResource: "EqualLengthClick", withExtension: "wav"))
    }

    func testOnlyRememberingARealPointFiresDwellFeedback() {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [20, 0])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        var feedbackCount = 0
        XCTAssertFalse(sketch.captureHovered(at: [50, 50], tolerance: 1, onRemembered: { feedbackCount += 1 }))
        XCTAssertEqual(feedbackCount, 0)
        XCTAssertTrue(sketch.captureHovered(at: [0, 0], tolerance: 1, onRemembered: { feedbackCount += 1 }))
        XCTAssertEqual(feedbackCount, 1)
        XCTAssertTrue(sketch.captureHovered(at: [0, 0], tolerance: 1, onRemembered: { feedbackCount += 1 }))
        XCTAssertEqual(feedbackCount, 1, "Entmerken spielt keinen neuen Fangton")
    }

    func testConstructionCrossingWinsWhenCloserThanNearbyEndpoint() {
        let inference = SketchInference(entities: [
            .line([0, 0], [20, 0]), .line([2, -10], [2, 10]),
        ], construction: [0, 1])
        let metrics = SnapMetrics(mmPerPoint: 0.2)
        let crossing = inference.refine([2, 0], prev: nil, lineTool: false, metrics: metrics,
                                        midOnly: false, kinds: [.endpoint, .intersection], extra: [],
                                        woken: nil, fineStep: 0, gridOn: false)
        XCTAssertEqual(crossing.point.x, 2, accuracy: 1e-8)
        XCTAssertEqual(crossing.point.y, 0, accuracy: 1e-8)
        if case .crossing = crossing.target {} else { XCTFail("Schnittpunkt muss vor dem nahen Ende fangen") }

        let endpoint = inference.refine([0, 0], prev: nil, lineTool: false, metrics: metrics,
                                        midOnly: false, kinds: [.endpoint, .intersection], extra: [],
                                        woken: nil, fineStep: 0, gridOn: false)
        XCTAssertEqual(endpoint.point.x, 0, accuracy: 1e-8)
        if case .point = endpoint.target {} else { XCTFail("Ein genau getroffener Endpunkt bleibt fangbar") }
    }

    func testPencilHoverAndPointMemoryUseConstructionCrossing() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 0], [20, 0]), .line([2, -10], [2, 10]),
        ], construction: [0, 1])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint, .intersection]
        sketch.snapInput = .hover
        sketch.hover(at: [2, 0], tolerance: 4)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(candidate.point.x, 2, accuracy: 1e-8)
        if case .crossing = candidate.target {} else { XCTFail("Hover muss den Schnitt fangen") }
        XCTAssertTrue(sketch.captureHovered(at: [2, 0], tolerance: 4))
        XCTAssertEqual(sketch.click.pinned.first?.x, 2)
    }

    func testRememberedMidpointSnapsAsCircleCenterAfterToolChange() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 0], [20, 0]), .line([0, 20], [20, 20]),
        ], construction: [0, 1])
        sketch.options.inputStyle = .solidcraft
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint, .midpoint, .intersection]
        sketch.tool = .polyline
        XCTAssertTrue(sketch.captureHovered(at: [0, 0], tolerance: 1))
        XCTAssertTrue(sketch.captureHovered(at: [20, 20], tolerance: 1))
        XCTAssertEqual(try XCTUnwrap(sketch.marks.first).x, 10, accuracy: 1e-8)
        sketch.tool = .circle
        sketch.circleMode = .center
        sketch.snapKinds = [.midpoint, .intersection]
        sketch.snapInput = .hover
        sketch.hover(at: [10.2, 10.1], tolerance: 1)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(candidate.point.x, 10, accuracy: 1e-8)
        XCTAssertEqual(candidate.point.y, 10, accuracy: 1e-8)
        XCTAssertTrue(candidate.target?.isPointSnap == true)
    }

    func testCircleCenterSnapsAtIntersectionOfTwoAutomaticMidlines() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 5], [20, 5]), .line([5, 0], [5, 20]),
        ], construction: [0, 1])
        sketch.options.inputStyle = .solidcraft
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint, .midpoint, .intersection]
        sketch.tool = .polyline
        let points: [Point2] = [[0, 5], [20, 5], [5, 0], [5, 20]]
        for point in points {
            XCTAssertTrue(sketch.captureHovered(at: point, tolerance: 1))
        }
        XCTAssertEqual(sketch.guideLines.count, 2)
        sketch.tool = .circle
        sketch.hover(at: [10.2, 10.1], tolerance: 1)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(candidate.point.x, 10, accuracy: 1e-8)
        XCTAssertEqual(candidate.point.y, 10, accuracy: 1e-8)
        XCTAssertEqual(candidate.label, "X")
        sketch.clickBegan(at: [10.2, 10.1], tolerance: 1)
        XCTAssertEqual(sketch.click.points.first?.point.x, 10)
        XCTAssertEqual(sketch.click.points.first?.point.y, 10)
        sketch.clickEnded(at: [10.2, 10.1], tolerance: 1)
        XCTAssertTrue(sketch.captureHovered(at: [10.2, 10.1], tolerance: 1))
    }

    func testCircleCenterSnapsWhereMidlineCrossesConstructionSegment() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 5], [20, 5]), .line([8, 10], [12, 10]),
        ], construction: [0, 1])
        sketch.options.inputStyle = .solidcraft
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint, .midpoint, .intersection]
        sketch.tool = .polyline
        XCTAssertTrue(sketch.captureHovered(at: [0, 5], tolerance: 1))
        XCTAssertTrue(sketch.captureHovered(at: [20, 5], tolerance: 1))
        sketch.tool = .circle
        sketch.hover(at: [10.2, 10.1], tolerance: 1)
        let candidate = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(candidate.point.x, 10, accuracy: 1e-8)
        XCTAssertEqual(candidate.point.y, 10, accuracy: 1e-8)
        XCTAssertEqual(candidate.label, "X")
    }

    func testClassicCircleAlsoSnapsAtAutomaticMidlineCrossing() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [
            .line([0, 5], [20, 5]), .line([8, 10], [12, 10]),
        ], construction: [0, 1])
        sketch.options.inputStyle = .classic
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint, .midpoint, .intersection]
        XCTAssertTrue(sketch.captureHovered(at: [0, 5], tolerance: 1))
        XCTAssertTrue(sketch.captureHovered(at: [20, 5], tolerance: 1))
        sketch.snapKinds = [.midpoint, .intersection]
        sketch.tool = .circle
        sketch.hover(at: [10.2, 10.1], tolerance: 1)
        XCTAssertEqual(sketch.hoverSnap?.point.x, 10)
        XCTAssertEqual(sketch.hoverSnap?.point.y, 10)
        XCTAssertEqual(sketch.hoverSnap?.kind, .intersection)
    }

    func testEqualLengthSnapPreservesVerticalDirectionAndCommitsConstraint() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [10, 0])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.autoConstrain = true
        sketch.snapKinds.formUnion([.equalLength, .alignment])
        sketch.click.points = [SketchClickPoint(point: [20, 0], target: nil)]
        sketch.clickHover(at: [20.2, 10.1], tolerance: 1)
        let preview = try XCTUnwrap(sketch.equalLengthPreview)
        XCTAssertEqual(preview.reference.count, 2)
        let end = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(end.point.x, 20, accuracy: 1e-8)
        XCTAssertEqual(end.point.y, 10, accuracy: 1e-8)
        XCTAssertEqual(end.label, "=")
        XCTAssertNotNil(sketch.commitLine(from: sketch.click.points[0],
                                          to: SketchClickPoint(point: end.point, target: end.target)))
        XCTAssertTrue(sketch.constraints.contains { constraint in
            if case .equalLength = constraint.variant { return true }
            return false
        })
        XCTAssertTrue(ConstraintSolver.satisfies(sketch.constraints, in: sketch.entities))
    }

    func testEqualLengthSnapRespectsTolerancePointSnapAndTypedLength() {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [10, 0])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        let originalSnapKinds = sketch.snapKinds
        defer { sketch.snapKinds = originalSnapKinds }
        sketch.snapKinds = [.endpoint, .equalLength]
        sketch.click.points = [SketchClickPoint(point: [20, 0], target: nil)]
        sketch.clickHover(at: [20, 13], tolerance: 1)
        XCTAssertNil(sketch.equalLengthPreview)
        sketch.clickHover(at: [10.1, 0], tolerance: 1)
        XCTAssertNil(sketch.equalLengthPreview)
        sketch.options.locked["Länge"] = "12"
        sketch.clickHover(at: [20, 10], tolerance: 1)
        XCTAssertNil(sketch.equalLengthPreview)
        XCTAssertEqual(simd_distance(sketch.click.points[0].point, sketch.currentCandidate!.point), 12, accuracy: 1e-8)
    }

    func testEqualLengthSnapWithSlantedDirectionWithoutAutomaticConstraint() throws {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [0, 10])])
        sketch.options.inputStyle = .solidcraft
        sketch.tool = .polyline
        sketch.autoConstrain = false
        sketch.snapKinds.insert(.equalLength)
        sketch.click.points = [SketchClickPoint(point: [20, 20], target: nil)]
        let target = 20 + 10 / sqrt(2.0)
        sketch.clickHover(at: [target + 0.1, target + 0.1], tolerance: 1)
        let end = try XCTUnwrap(sketch.currentCandidate)
        XCTAssertEqual(simd_distance(end.point, [20, 20]), 10, accuracy: 1e-8)
        XCTAssertEqual(end.point.x, end.point.y, accuracy: 1e-8)
        XCTAssertNotNil(sketch.commitLine(from: sketch.click.points[0],
                                          to: SketchClickPoint(point: end.point, target: end.target)))
        XCTAssertTrue(sketch.constraints.isEmpty)
    }

    private func controller(constraints: [SketchConstraint] = []) -> SketchController {
        let sketch = SketchController()
        sketch.load(plane: .ground, entities: [.line([0, 0], [10, 0])], constraints: constraints)
        sketch.addToSelection([.curve(SketchCurveRef(entity: 0, index: 0))])
        return sketch
    }

    private func lengthDimension(_ sketch: SketchController) throws -> SketchDimension {
        try XCTUnwrap(sketch.dimensions.first { $0.kind == .length || $0.kind == .distance })
    }

    func testDimensionUndoRestoresGeometryAndConstraints() throws {
        let sketch = controller()
        let before = sketch.entities[0].parameters
        let dimension = try lengthDimension(sketch)
        sketch.setDimension(id: dimension.id, to: 20, expression: "breite * 2")
        XCTAssertTrue(sketch.canUndo)
        XCTAssertTrue(ConstraintSolver.satisfies(sketch.constraints, in: sketch.entities))
        XCTAssertEqual(sketch.constraints.first?.dimensionValue, 20)
        XCTAssertEqual(sketch.constraints.first?.expression, "breite * 2")
        sketch.undo()
        XCTAssertEqual(sketch.entities[0].parameters, before)
        XCTAssertTrue(sketch.constraints.isEmpty)
    }

    func testConflictingDimensionDoesNotChangeGeometryOrHistory() throws {
        let constraints = [
            SketchConstraint(variant: .lock(SketchPointRef(entity: 0, index: 0), at: [0, 0])),
            SketchConstraint(variant: .lock(SketchPointRef(entity: 0, index: 1), at: [10, 0]))
        ]
        let sketch = controller(constraints: constraints)
        let before = sketch.entities[0].parameters
        sketch.setDimension(id: try lengthDimension(sketch).id, to: 20, expression: "breite")
        XCTAssertEqual(sketch.entities[0].parameters, before)
        XCTAssertEqual(sketch.constraints, constraints)
        XCTAssertFalse(sketch.canUndo)
        XCTAssertNotNil(sketch.notice)
    }

    func testUndoAtCapacityRestoresConstraintBeforeNewEntityDimension() throws {
        let sketch = controller()
        for _ in 0..<100 {
            sketch.toggleDimensionLock(id: try lengthDimension(sketch).id)
            sketch.toggleDimensionLock(id: try lengthDimension(sketch).id)
        }
        sketch.addProjected([[[20, 0], [30, 0]]])
        sketch.clearSelection()
        sketch.addToSelection([.curve(SketchCurveRef(entity: 1, index: 0))])
        let beforeConstraints = sketch.constraints
        let before = sketch.entities.map(\.parameters)
        let dimension = try XCTUnwrap(sketch.dimensions.first {
            if case .entity(1) = $0.target { return $0.kind == .length }
            return false
        })
        sketch.setDimension(id: dimension.id, to: 15)
        sketch.undo()
        XCTAssertEqual(sketch.constraints, beforeConstraints)
        XCTAssertEqual(sketch.entities.map(\.parameters), before)
    }

    func testRejectedDimensionAtCapacityPreservesUndoDepth() throws {
        let locks = [
            SketchConstraint(variant: .lock(SketchPointRef(entity: 0, index: 0), at: [0, 0])),
            SketchConstraint(variant: .lock(SketchPointRef(entity: 0, index: 1), at: [10, 0]))
        ]
        let sketch = controller(constraints: locks)
        for _ in 0..<100 {
            sketch.toggleDimensionLock(id: try lengthDimension(sketch).id)
            sketch.toggleDimensionLock(id: try lengthDimension(sketch).id)
        }
        sketch.setDimension(id: try lengthDimension(sketch).id, to: 25)
        var count = 0
        while sketch.canUndo && count < 205 { sketch.undo(); count += 1 }
        XCTAssertEqual(count, 200)
    }

    func testInvalidExtrusionParametersProduceNoShape() {
        let regions = findRegions(in: [.rectangle(corner: [0, 0], size: [10, 10])]).regions
        XCTAssertNil(extrudeRegions(regions, plane: .ground, distance: 10, mode: .newBody, taper: .nan))
        XCTAssertNil(extrudeRegions(regions, plane: .ground, distance: 10, mode: .newBody,
                                   direction: .twoSides, secondDistance: .infinity))
        XCTAssertNil(extrudeRegions(regions, plane: .ground, distance: .greatestFiniteMagnitude,
                                   mode: .newBody, direction: .symmetric))
    }

    func testRectangleExtrusionCreatesExpectedVolumeWithKernel() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let regions = findRegions(in: [.rectangle(corner: [0, 0], size: [10, 20])]).regions
        let shape = try XCTUnwrap(extrudeRegions(regions, plane: .ground, distance: 5, mode: .newBody))
        XCTAssertTrue(shape.isClosedSolid)
        XCTAssertEqual(shape.volume, 1000, accuracy: 1e-5)
    }

    func testAdjacentSecondFilletAfterLargeFirstFillet() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let base = PCKShape.box(width: 25, depth: 25, height: 12.5)
        let face = try XCTUnwrap((1...base.faceCount).first {
            guard let plane = base.plane(ofFace: $0)?.map(\.doubleValue) else { return false }
            return plane[3] > 0.9 && plane[0] > 12
        })
        let pushed = try XCTUnwrap(base.extruding(face: face, distance: 8.5))
        let first = try XCTUnwrap(pushed.filleting(edges: [8], radius: 9))
        XCTAssertTrue(first.isClosedSolid)
        let second = try XCTUnwrap(first.filleting(edges: [3, 9], radius: 2))
        XCTAssertTrue(second.isClosedSolid)
        XCTAssertGreaterThan(second.volume, 0)
        let mesh = second.triangulate(deflection: 0.05)
        let meshedFaces = mesh.faceIndexData.withUnsafeBytes {
            Set($0.bindMemory(to: UInt32.self))
        }
        for face in 1...second.faceCount where second.area(ofFace: face) > 1e-6 {
            XCTAssertTrue(meshedFaces.contains(UInt32(face)), "Face \(face) lacks display triangles")
        }
    }

    func testSingleBoxEdgeCanRoundPastAdjacentFace() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let box = PCKShape.box(width: 20, depth: 20, height: 20)
        let numbers = Set((1...box.faceCount).flatMap { box.edgeNumbers(ofFace: $0).map(\.intValue) })
        let edge = try XCTUnwrap(numbers.first { number in
            guard let g = box.geometry(ofEdge: number)?.map(\.doubleValue), g.count >= 8 else { return false }
            return g[0] == 0 && abs(g[4] - 20) < 1e-6 && abs(g[7] - 20) < 1e-6
                && abs(g[3] - g[6]) < 1e-6 && abs(g[2] - g[5]) > 19
        })
        let ordinary = try XCTUnwrap(box.filleting(edges: [NSNumber(value: edge)], radius: 9))
        let extended = try XCTUnwrap(box.filleting(edges: [NSNumber(value: edge)], radius: 23.431))
        XCTAssertTrue(extended.isClosedSolid)
        XCTAssertGreaterThan(extended.volume, 0)
        XCTAssertLessThan(extended.volume, ordinary.volume)
        let larger = try XCTUnwrap(box.filleting(edges: [NSNumber(value: edge)], radius: 40))
        XCTAssertTrue(larger.isClosedSolid)
        XCTAssertGreaterThan(larger.volume, 0)
        XCTAssertLessThan(larger.volume, extended.volume)
        let nearEnd = try XCTUnwrap(box.filleting(edges: [NSNumber(value: edge)], radius: 60))
        XCTAssertTrue(nearEnd.isClosedSolid)
        XCTAssertGreaterThan(nearEnd.volume, 0)
        XCTAssertLessThan(nearEnd.volume, larger.volume)
        let mesh = extended.triangulate(deflection: 0.05)
        let meshedFaces = mesh.faceIndexData.withUnsafeBytes { Set($0.bindMemory(to: UInt32.self)) }
        for face in 1...extended.faceCount where extended.area(ofFace: face) > 1e-6 {
            XCTAssertTrue(meshedFaces.contains(UInt32(face)), "Extended fillet face \(face) lacks triangles")
        }
    }

    func testPartialFilletKeepsOneClosedBodyAndLimitsMaterialRemoval() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let box = PCKShape.box(width: 20, depth: 20, height: 20)
        let edges = Set((1...box.faceCount).flatMap { box.edgeNumbers(ofFace: $0).map(\.intValue) })
        let edge = try XCTUnwrap(edges.first { box.geometry(ofEdge: $0)?[0].doubleValue == 0 })
        let full = try XCTUnwrap(box.filleting(edges: [NSNumber(value: edge)], radius: 2))
        let partial = try XCTUnwrap(box.partiallyFilleting(edge: edge, radius: 2, start: 0.2, end: 0.8))
        XCTAssertTrue(partial.isClosedSolid)
        XCTAssertGreaterThan(partial.volume, full.volume)
        XCTAssertLessThan(partial.volume, box.volume)
        let extendedFull = try XCTUnwrap(box.filleting(edges: [NSNumber(value: edge)], radius: 23.431))
        let extendedPart = try XCTUnwrap(box.partiallyFilleting(edge: edge, radius: 23.431, start: 0.2, end: 0.8))
        XCTAssertTrue(extendedPart.isClosedSolid)
        XCTAssertGreaterThan(extendedPart.volume, extendedFull.volume)
        XCTAssertLessThan(extendedPart.volume, box.volume)
        let entire = try XCTUnwrap(box.partiallyFilleting(edge: edge, radius: 2, start: 0, end: 1))
        XCTAssertEqual(entire.volume, full.volume, accuracy: 1e-5)
        let mesh = partial.triangulate(deflection: 0.05)
        let meshed = mesh.faceIndexData.withUnsafeBytes { Set($0.bindMemory(to: UInt32.self)) }
        for face in 1...partial.faceCount where partial.area(ofFace: face) > 1e-6 {
            XCTAssertTrue(meshed.contains(UInt32(face)), "Partial fillet face \(face) lacks triangles")
        }
    }

    func testAllSolidCraftToolIconsExistInAppAssets() {
        XCTAssertEqual(ToolIcon.customNames.count, 107)
        for name in ToolIcon.customNames {
            XCTAssertNotNil(UIImage(named: ToolIcon.assetName(name)), "Missing asset: \(name)")
        }
    }

    func testTimelineCanRebuildEarlierStateAfterReopenClearsCache() throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.previewInsert(.box, size: [10, 10, 10], at: [0, 0, 0])
        model.commitPreview()
        model.previewInsert(.box, size: [5, 5, 5], at: [20, 0, 0])
        model.commitPreview()
        XCTAssertEqual(model.features.count, 2)
        let last = try XCTUnwrap(model.features.last)
        model.featureRecorder.cache = [last.id: model.bodies]
        let earlier = try XCTUnwrap(model.bodies(afterFeatures: 1))
        XCTAssertEqual(earlier.count, 1)
        XCTAssertEqual(earlier[0].shape.volume, 1000, accuracy: 1e-5)
        XCTAssertEqual(model.featureRecorder.cache[model.features[0].id]?.count, 1)
        XCTAssertEqual(model.bodies(afterFeatures: 2)?.count, 2)
        XCTAssertEqual(model.bodies.count, 2)
    }

    func testPartialFilletRebuildsFromRecordedFeature() async throws {
        try XCTSkipUnless(PCKShape.kernelAvailable)
        let model = ModelStore(folder: nil)
        model.previewInsert(.box, size: [20, 20, 20], at: [0, 0, 0])
        model.commitPreview()
        let shape = try XCTUnwrap(model.bodies.first?.shape)
        let edges = Set((1...shape.faceCount).flatMap { shape.edgeNumbers(ofFace: $0).map(\.intValue) })
        let edge = try XCTUnwrap(edges.first { shape.geometry(ofEdge: $0)?[0].doubleValue == 0 })
        model.toggleEdge(EdgeRef(body: 0, edge: edge))
        model.edgeOperation = .fillet
        model.setEdgePartialRange(0.2...0.8, update: false)
        model.setEdgeValue(2)
        for _ in 0..<100 where model.isBlendComputing {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(model.isBlendComputing)
        XCTAssertTrue(model.hasPreview, model.message ?? "No partial fillet preview")
        model.commitPreview()
        XCTAssertEqual(model.features.count, 2)
        let feature = try XCTUnwrap(model.features.last)
        XCTAssertEqual(feature.value("startPercent"), 20)
        XCTAssertEqual(feature.value("stopPercent"), 80)
        let expected = try XCTUnwrap(model.bodies.first?.shape.volume)
        model.featureRecorder.cache = [:]
        let rebuilt = try XCTUnwrap(model.bodies(afterFeatures: 2))
        XCTAssertEqual(rebuilt.count, 1)
        XCTAssertTrue(rebuilt[0].shape.isClosedSolid)
        XCTAssertEqual(rebuilt[0].shape.volume, expected, accuracy: 1e-4)
    }
}
