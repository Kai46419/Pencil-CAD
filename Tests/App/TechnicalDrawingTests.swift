import XCTest
@testable import PencilCAD

@MainActor
final class TechnicalDrawingTests: XCTestCase {
    func testManualLengthUsesModelScaleAndAppearsInPDFAndDXF() throws {
        var layout = DrawingLayout()
        layout.views[.front] = (0.5, [[Point2(40, 70), Point2(50, 70)]])
        layout.elements = [.polyline([Point2(40, 70), Point2(50, 70)], .visible)]
        let first = try XCTUnwrap(TechnicalDrawing.nearestVertex(in: layout, to: Point2(40.2, 70), maxDistance: 1))
        let second = try XCTUnwrap(TechnicalDrawing.nearestVertex(in: layout, to: Point2(49.8, 70), maxDistance: 1))
        let length = try XCTUnwrap(TechnicalDrawing.length(from: first, to: second, kind: .aligned))
        XCTAssertEqual(try XCTUnwrap(TechnicalDrawing.lengthShape(length)).value, 20, accuracy: 1e-9)
        XCTAssertTrue(TechnicalDrawing.containsVertex(first, in: layout))
        let result = TechnicalDrawing.withDimensions(layout, angles: [], lengths: [length])
        let dxf = try XCTUnwrap(String(data: TechnicalDrawing.dxfData(result), encoding: .utf8))
        XCTAssertTrue(dxf.contains("\r\n  1\r\n20\r\n"), "Die Maßzahl muss im DXF stehen.")
        XCTAssertTrue(TechnicalDrawing.pdfData(result, title: "Maßtest").starts(with: Data("%PDF".utf8)))
    }

    func testManualLengthRejectsDifferentViewsAndMeasuresByKind() throws {
        let first = DrawingVertex(point: Point2(20, 30), view: .front, scale: 0.2)
        let second = DrawingVertex(point: Point2(26, 38), view: .front, scale: 0.2)
        XCTAssertNil(TechnicalDrawing.length(from: first,
                                             to: DrawingVertex(point: second.point, view: .top, scale: 0.2),
                                             kind: .aligned))
        XCTAssertNil(TechnicalDrawing.length(from: DrawingVertex(point: first.point, view: .iso, scale: 0.2),
                                             to: DrawingVertex(point: second.point, view: .iso, scale: 0.2),
                                             kind: .aligned))
        let horizontal = try XCTUnwrap(TechnicalDrawing.length(from: first, to: second, kind: .horizontal))
        let vertical = try XCTUnwrap(TechnicalDrawing.length(from: first, to: second, kind: .vertical))
        let aligned = try XCTUnwrap(TechnicalDrawing.length(from: first, to: second, kind: .aligned))
        XCTAssertEqual(try XCTUnwrap(TechnicalDrawing.lengthShape(horizontal)).value, 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TechnicalDrawing.lengthShape(vertical)).value, 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TechnicalDrawing.lengthShape(aligned)).value, 50, accuracy: 1e-9)
    }

    func testBoxViewsKeepCorrectModelDimensionsInBothProjectionMethods() throws {
        let box = PCKShape.box(width: 20, depth: 30, height: 10)
        let views = Dictionary(uniqueKeysWithValues: DrawingView.allCases.map {
            ($0, TechnicalDrawing.project([box], view: $0))
        })
        for method in ProjectionMethod.allCases {
            var options = DrawingOptions()
            options.method = method
            let layout = TechnicalDrawing.layout(views, options: options, title: "Quader", subtitle: nil)
            let front = try XCTUnwrap(layout.views[.front])
            let endpoints = try XCTUnwrap(front.visible.first { $0.count >= 2 })
            XCTAssertTrue(endpoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            let labels = layout.elements.compactMap { element -> String? in
                if case .text(let text, _, _, _, _, _) = element { return text }
                return nil
            }
            XCTAssertTrue(labels.contains("20"), "Die Gesamtbreite muss bemaßt werden.")
            XCTAssertTrue(labels.contains("30"), "Die Tiefe muss bemaßt werden.")
            XCTAssertTrue(labels.contains("10"), "Die Höhe muss bemaßt werden.")
        }
    }
}
