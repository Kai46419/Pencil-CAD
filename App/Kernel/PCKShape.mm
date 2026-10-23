#import "PCKShape.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>
#include <vector>

#if __has_include(<BRepPrimAPI_MakeBox.hxx>)
#define PCK_HAS_OCCT 1
#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp_Face.hxx>
#include <BRepLib_ToolTriangulatedShape.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom_BSplineCurve.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <ShapeFix_Face.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <Geom2d_Curve.hxx>
#include <Poly_Triangulation.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax1.hxx>
#include <gp_Circ.hxx>
#include <gp_Ax2.hxx>
#include <gp_Elips.hxx>
#include <gp_Trsf.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt2d.hxx>
#else
#define PCK_HAS_OCCT 0
#endif

#if PCK_HAS_OCCT && __has_include(<STEPControl_Writer.hxx>)
#define PCK_HAS_STEP 1
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Static.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#else
#define PCK_HAS_STEP 0
#endif

namespace {

struct MeshBuffers {
    std::vector<float> vertices; // x y z nx ny nz
    std::vector<uint32_t> indices;
    std::vector<uint32_t> triangleFaces;
    std::vector<float> edges; // Punktpaare
    std::vector<uint32_t> edgeNumbers; // je Punktpaar

    uint32_t addVertex(simd_double3 p, simd_double3 n) {
        const uint32_t index = static_cast<uint32_t>(vertices.size() / 6);
        vertices.insert(vertices.end(), {float(p.x), float(p.y), float(p.z), float(n.x), float(n.y), float(n.z)});
        return index;
    }

    void addTriangle(uint32_t a, uint32_t b, uint32_t c, uint32_t face) {
        indices.insert(indices.end(), {a, b, c});
        triangleFaces.push_back(face);
    }

    void addEdge(simd_double3 a, simd_double3 b, uint32_t number = 0) {
        edges.insert(edges.end(), {float(a.x), float(a.y), float(a.z), float(b.x), float(b.y), float(b.z)});
        edgeNumbers.push_back(number);
    }
};

std::vector<double> toVector(NSArray<NSNumber *> *values) {
    std::vector<double> result;
    result.reserve(values.count);
    for (NSNumber *number in values) {
        result.push_back(number.doubleValue);
    }
    return result;
}

std::vector<simd_double3> toPoints(NSArray<NSNumber *> *xyz) {
    const std::vector<double> v = toVector(xyz);
    std::vector<simd_double3> points;
    for (size_t i = 0; i + 2 < v.size(); i += 3) {
        points.push_back(simd_make_double3(v[i], v[i + 1], v[i + 2]));
    }
    return points;
}

#if !PCK_HAS_OCCT
/// Orthonormale Basis senkrecht zu axis.
std::pair<simd_double3, simd_double3> basisFor(simd_double3 axis) {
    const simd_double3 n = simd_normalize(axis);
    const simd_double3 ref = std::fabs(n.z) < 0.9 ? simd_make_double3(0, 0, 1) : simd_make_double3(1, 0, 0);
    const simd_double3 u = simd_normalize(simd_cross(ref, n));
    return {u, simd_cross(n, u)};
}

// Fallback ohne Kernel: einfache Netze, damit Viewer, Skizze und UI ohne OpenCASCADE testbar sind.
struct FallbackBody {
    MeshBuffers mesh;
    std::vector<std::array<double, 6>> planes; // je Fläche (Index = Nummer - 1)
    std::vector<bool> planar;
};

/// Prisma aus Polygon. smoothSides: Seiten bilden eine gekrümmte Fläche (für Zylinder).
/// Deckel werden als Fächer trianguliert, das ist nur für konvexe Profile korrekt.
FallbackBody fallbackPrism(const std::vector<simd_double3> &points, simd_double3 direction, bool smoothSides) {
    FallbackBody body;
    const size_t n = points.size();
    if (n < 3 || simd_length(direction) == 0) return body;

    // Polygonnormale nach Newell, passt zur Umlaufrichtung
    simd_double3 pn = simd_make_double3(0, 0, 0);
    for (size_t i = 0; i < n; ++i) {
        pn += simd_cross(points[i], points[(i + 1) % n]);
    }
    pn = simd_normalize(pn);
    const simd_double3 dir = simd_normalize(direction);
    const bool flipped = simd_dot(pn, dir) < 0;
    MeshBuffers &m = body.mesh;

    auto addPlane = [&](simd_double3 origin, simd_double3 normal) {
        body.planes.push_back({origin.x, origin.y, origin.z, normal.x, normal.y, normal.z});
        body.planar.push_back(true);
    };

    // Seiten
    if (smoothSides) {
        body.planes.push_back({0, 0, 0, 0, 0, 0});
        body.planar.push_back(false);
    }
    const simd_double3 center = [&] {
        simd_double3 c = simd_make_double3(0, 0, 0);
        for (const auto &p : points) c += p;
        return c / double(n);
    }();
    for (size_t i = 0; i < n; ++i) {
        const simd_double3 a = points[i], b = points[(i + 1) % n];
        simd_double3 outward = simd_normalize(simd_cross(b - a, pn));
        if (flipped) outward = -outward;
        uint32_t face;
        simd_double3 na = outward, nb = outward;
        if (smoothSides) {
            face = 1;
            na = simd_normalize(a - center);
            nb = simd_normalize(b - center);
        } else {
            addPlane(a, outward);
            face = uint32_t(body.planes.size());
        }
        const uint32_t v0 = m.addVertex(a, na), v1 = m.addVertex(b, nb);
        const uint32_t v2 = m.addVertex(b + direction, nb), v3 = m.addVertex(a + direction, na);
        m.addTriangle(v0, v1, v2, face);
        m.addTriangle(v0, v2, v3, face);
        m.addEdge(a, b);
        m.addEdge(a + direction, b + direction);
        if (!smoothSides) m.addEdge(a, a + direction);
    }

    // Deckel
    for (int cap = 0; cap < 2; ++cap) {
        const simd_double3 offset = cap == 0 ? simd_make_double3(0, 0, 0) : direction;
        const simd_double3 normal = cap == 0 ? -dir : dir;
        addPlane(points[0] + offset, normal);
        const uint32_t face = uint32_t(body.planes.size());
        const uint32_t base = static_cast<uint32_t>(m.vertices.size() / 6);
        for (const auto &p : points) m.addVertex(p + offset, normal);
        for (size_t i = 1; i + 1 < n; ++i) {
            m.addTriangle(base, base + uint32_t(i), base + uint32_t(i + 1), face);
        }
    }
    return body;
}

std::vector<simd_double3> circlePoints(simd_double3 base, simd_double3 axis, double radius, int segments) {
    const auto [u, v] = basisFor(axis);
    std::vector<simd_double3> points;
    for (int i = 0; i < segments; ++i) {
        const double a = 2 * M_PI * i / segments;
        points.push_back(base + radius * (std::cos(a) * u + std::sin(a) * v));
    }
    return points;
}
#endif

} // namespace

@implementation PCKMesh

- (instancetype)initWithBuffers:(const MeshBuffers &)buffers {
    if ((self = [super init])) {
        _vertexData = [NSData dataWithBytes:buffers.vertices.data() length:buffers.vertices.size() * sizeof(float)];
        _indexData = [NSData dataWithBytes:buffers.indices.data() length:buffers.indices.size() * sizeof(uint32_t)];
        _faceIndexData = [NSData dataWithBytes:buffers.triangleFaces.data()
                                        length:buffers.triangleFaces.size() * sizeof(uint32_t)];
        _edgeData = [NSData dataWithBytes:buffers.edges.data() length:buffers.edges.size() * sizeof(float)];
        _edgeIndexData = [NSData dataWithBytes:buffers.edgeNumbers.data()
                                        length:buffers.edgeNumbers.size() * sizeof(uint32_t)];
    }
    return self;
}

@end

@implementation PCKShape {
#if PCK_HAS_OCCT
    TopoDS_Shape _shape;
    TopTools_IndexedMapOfShape _faces;
    TopTools_IndexedMapOfShape _edges;
#else
    FallbackBody _fallback;
#endif
}

+ (BOOL)kernelAvailable {
    return PCK_HAS_OCCT;
}

+ (BOOL)stepAvailable {
    return PCK_HAS_STEP;
}

#if PCK_HAS_OCCT

- (instancetype)initWithShape:(const TopoDS_Shape &)shape {
    if ((self = [super init])) {
        _shape = shape;
        TopExp::MapShapes(_shape, TopAbs_FACE, _faces);
        TopExp::MapShapes(_shape, TopAbs_EDGE, _edges);
    }
    return self;
}

+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height {
    BRepPrimAPI_MakeBox maker(gp_Pnt(-width / 2, -depth / 2, 0), width, depth, height);
    return [[PCKShape alloc] initWithShape:maker.Shape()];
}

+ (nullable PCKShape *)cylinderWithBase:(simd_double3)base axis:(simd_double3)axis
                                 radius:(double)radius height:(double)height {
    if (radius <= 0 || height <= 0 || simd_length(axis) == 0) return nil;
    try {
        BRepPrimAPI_MakeCylinder maker(gp_Ax2(gp_Pnt(base.x, base.y, base.z), gp_Dir(axis.x, axis.y, axis.z)),
                                       radius, height);
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

static gp_Pnt toPnt(simd_double3 p) {
    return gp_Pnt(p.x, p.y, p.z);
}

static gp_Dir toDir(simd_double3 d) {
    return gp_Dir(d.x, d.y, d.z);
}

+ (nullable PCKShape *)sphereWithCenter:(simd_double3)center radius:(double)radius {
    if (radius <= 0) return nil;
    try {
        BRepPrimAPI_MakeSphere maker(toPnt(center), radius);
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

+ (nullable PCKShape *)coneWithBase:(simd_double3)base axis:(simd_double3)axis
                       bottomRadius:(double)bottomRadius topRadius:(double)topRadius height:(double)height {
    if (bottomRadius < 0 || topRadius < 0 || bottomRadius + topRadius <= 0 || height <= 0 ||
        simd_length(axis) == 0) return nil;
    try {
        BRepPrimAPI_MakeCone maker(gp_Ax2(toPnt(base), toDir(axis)), bottomRadius, topRadius, height);
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

+ (nullable PCKShape *)ellipsePrismWithCenter:(simd_double3)center normal:(simd_double3)normal
                                        xAxis:(simd_double3)xAxis radiusX:(double)radiusX
                                      radiusY:(double)radiusY direction:(simd_double3)direction {
    if (radiusX <= 0 || radiusY <= 0 || simd_length(direction) == 0 || simd_length(normal) == 0) return nil;
    try {
        // gp_Elips verlangt Hauptradius >= Nebenradius; sonst Hauptachse um 90° drehen.
        simd_double3 major = xAxis;
        double rMajor = radiusX, rMinor = radiusY;
        if (radiusY > radiusX) {
            major = simd_cross(simd_normalize(normal), xAxis);
            std::swap(rMajor, rMinor);
        }
        const gp_Elips ellipse(gp_Ax2(toPnt(center), toDir(normal), toDir(major)), rMajor, rMinor);
        BRepBuilderAPI_MakeEdge edge(ellipse);
        if (!edge.IsDone()) return nil;
        BRepBuilderAPI_MakeWire wire(edge.Edge());
        if (!wire.IsDone()) return nil;
        BRepBuilderAPI_MakeFace face(wire.Wire(), Standard_True);
        if (!face.IsDone()) return nil;
        BRepPrimAPI_MakePrism prism(face.Face(), gp_Vec(direction.x, direction.y, direction.z));
        if (!prism.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:prism.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction {
    const std::vector<simd_double3> points = toPoints(xyz);
    if (points.size() < 3 || simd_length(direction) == 0) return nil;
    try {
        BRepBuilderAPI_MakePolygon polygon;
        for (const auto &p : points) {
            polygon.Add(gp_Pnt(p.x, p.y, p.z));
        }
        polygon.Close();
        if (!polygon.IsDone()) return nil;
        BRepBuilderAPI_MakeFace face(polygon.Wire(), Standard_True);
        if (!face.IsDone()) return nil;
        BRepPrimAPI_MakePrism prism(face.Face(), gp_Vec(direction.x, direction.y, direction.z));
        if (!prism.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:prism.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

/// B-Spline aus Polen. clamped: Enden liegen auf dem ersten und letzten Pol (gleichmäßige innere Knoten),
/// sonst periodisch und kubisch. bezierChain: Pole bilden eine Kette kubischer Bézierkurven (3k + 1 Pole).
static Handle(Geom_BSplineCurve) makeBSpline(const std::vector<gp_Pnt> &poles, bool periodic, bool bezierChain) {
    const int n = int(poles.size());
    TColgp_Array1OfPnt array(1, n);
    for (int i = 0; i < n; ++i) array.SetValue(i + 1, poles[size_t(i)]);
    if (bezierChain) {
        const int segments = (n - 1) / 3;
        if (segments < 1 || segments * 3 + 1 != n) return nullptr;
        TColStd_Array1OfReal knots(1, segments + 1);
        TColStd_Array1OfInteger mults(1, segments + 1);
        for (int i = 0; i <= segments; ++i) {
            knots.SetValue(i + 1, double(i));
            mults.SetValue(i + 1, (i == 0 || i == segments) ? 4 : 3);
        }
        return new Geom_BSplineCurve(array, knots, mults, 3);
    }
    if (periodic) {
        if (n < 3) return nullptr;
        TColStd_Array1OfReal knots(1, n + 1);
        TColStd_Array1OfInteger mults(1, n + 1);
        for (int i = 0; i <= n; ++i) {
            knots.SetValue(i + 1, double(i));
            mults.SetValue(i + 1, 1);
        }
        return new Geom_BSplineCurve(array, knots, mults, std::min(3, n - 1), Standard_True);
    }
    if (n < 2) return nullptr;
    const int degree = std::min(3, n - 1);
    const int count = n - degree + 1;
    TColStd_Array1OfReal knots(1, count);
    TColStd_Array1OfInteger mults(1, count);
    for (int i = 0; i < count; ++i) {
        knots.SetValue(i + 1, double(i));
        mults.SetValue(i + 1, (i == 0 || i == count - 1) ? degree + 1 : 1);
    }
    return new Geom_BSplineCurve(array, knots, mults, degree);
}

/// Baut eine Kontur aus der Segment-Kodierung (siehe PCKShape.h). Liefert einen leeren Draht bei Fehlern.
static TopoDS_Wire wireFromCode(const std::vector<double> &code) {
    BRepBuilderAPI_MakeWire wire;
    size_t i = 0;
    auto point = [&]() {
        const gp_Pnt p(code[i], code[i + 1], code[i + 2]);
        i += 3;
        return p;
    };
    auto has = [&](size_t count) { return i + count <= code.size(); };
    while (i < code.size()) {
        const int type = int(code[i++]);
        TopoDS_Edge edge;
        switch (type) {
        case 0: {
            if (!has(6)) return TopoDS_Wire();
            const gp_Pnt a = point(), b = point();
            if (a.Distance(b) < 1e-7) continue;
            edge = BRepBuilderAPI_MakeEdge(a, b).Edge();
            break;
        }
        case 1: {
            if (!has(9)) return TopoDS_Wire();
            const gp_Pnt a = point(), m = point(), b = point();
            GC_MakeArcOfCircle arc(a, m, b);
            if (!arc.IsDone()) return TopoDS_Wire();
            edge = BRepBuilderAPI_MakeEdge(arc.Value()).Edge();
            break;
        }
        case 2:
        case 5:
        case 6: {
            if (!has(1)) return TopoDS_Wire();
            const size_t n = size_t(code[i++]);
            if (!has(3 * n)) return TopoDS_Wire();
            std::vector<gp_Pnt> poles;
            for (size_t k = 0; k < n; ++k) poles.push_back(point());
            const Handle(Geom_BSplineCurve) curve = makeBSpline(poles, type == 6, type == 2);
            if (curve.IsNull()) return TopoDS_Wire();
            edge = BRepBuilderAPI_MakeEdge(curve).Edge();
            break;
        }
        case 3: {
            if (!has(7)) return TopoDS_Wire();
            const gp_Pnt c = point(), n = point();
            const double r = code[i++];
            edge = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(c, gp_Dir(n.X(), n.Y(), n.Z())), r)).Edge();
            break;
        }
        case 4: {
            if (!has(11)) return TopoDS_Wire();
            const gp_Pnt c = point(), n = point(), x = point();
            double rx = code[i++], ry = code[i++];
            gp_Dir normal(n.X(), n.Y(), n.Z());
            gp_Dir major(x.X(), x.Y(), x.Z());
            if (ry > rx) {
                major = normal.Crossed(major);
                std::swap(rx, ry);
            }
            edge = BRepBuilderAPI_MakeEdge(gp_Elips(gp_Ax2(c, normal, major), rx, ry)).Edge();
            break;
        }
        default:
            return TopoDS_Wire();
        }
        wire.Add(edge);
        if (!wire.IsDone()) return TopoDS_Wire();
    }
    return wire.IsDone() ? wire.Wire() : TopoDS_Wire();
}

/// Ebene Fläche aus Außenkontur und Löchern (Kodierung wie prismWithProfileWires:). Null bei Fehler.
static TopoDS_Face faceFromWires(NSArray<NSArray<NSNumber *> *> *wires) {
    if (wires.count == 0) return TopoDS_Face();
    const TopoDS_Wire outer = wireFromCode(toVector(wires[0]));
    if (outer.IsNull()) return TopoDS_Face();
    BRepBuilderAPI_MakeFace face(outer, Standard_True);
    if (!face.IsDone()) return TopoDS_Face();
    for (NSUInteger k = 1; k < wires.count; ++k) {
        const TopoDS_Wire hole = wireFromCode(toVector(wires[k]));
        if (!hole.IsNull()) face.Add(hole);
    }
    // Umlaufrichtung der Löcher passend zur Außenkontur
    ShapeFix_Face fix(face.Face());
    fix.Perform();
    return fix.Face();
}

+ (nullable PCKShape *)prismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires direction:(simd_double3)direction {
    if (simd_length(direction) == 0) return nil;
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        BRepPrimAPI_MakePrism prism(face, gp_Vec(direction.x, direction.y, direction.z));
        if (!prism.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:prism.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

+ (nullable PCKShape *)faceWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires {
    try {
        const TopoDS_Face face = faceFromWires(wires);
        if (face.IsNull()) return nil;
        return [[PCKShape alloc] initWithShape:face];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

+ (nullable PCKShape *)compoundOfShapes:(NSArray<PCKShape *> *)shapes {
    if (shapes.count == 0) return nil;
    if (shapes.count == 1) return shapes[0];
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    for (PCKShape *shape in shapes) {
        builder.Add(compound, shape->_shape);
    }
    return [[PCKShape alloc] initWithShape:compound];
}

/// Fasst nach booleschen Operationen zerteilte Flächen und Kanten wieder zusammen.
static TopoDS_Shape unified(const TopoDS_Shape &shape) {
    try {
        ShapeUpgrade_UnifySameDomain unify(shape, Standard_True, Standard_True, Standard_False);
        unify.Build();
        const TopoDS_Shape result = unify.Shape();
        return result.IsNull() ? shape : result;
    } catch (const Standard_Failure &) {
        return shape;
    }
}

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    try {
        BRepAlgoAPI_Cut op(_shape, tool->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    try {
        BRepAlgoAPI_Fuse op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)intersecting:(PCKShape *)other {
    try {
        BRepAlgoAPI_Common op(_shape, other->_shape);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)extrudingFace:(NSInteger)index distance:(double)distance {
    if (distance == 0) return nil;
    NSArray<NSNumber *> *plane = [self planeOfFace:index];
    if (plane == nil) return nil;
    const gp_Vec direction(plane[3].doubleValue * distance, plane[4].doubleValue * distance,
                           plane[5].doubleValue * distance);
    try {
        BRepPrimAPI_MakePrism prism(_faces(int(index)), direction);
        if (!prism.IsDone()) return nil;
        if (distance > 0) {
            BRepAlgoAPI_Fuse op(_shape, prism.Shape());
            if (!op.IsDone()) return nil;
            return [[PCKShape alloc] initWithShape:unified(op.Shape())];
        }
        BRepAlgoAPI_Cut op(_shape, prism.Shape());
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:unified(op.Shape())];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)shellingRemovingFace:(NSInteger)face thickness:(double)thickness {
    if (face < 1 || face > _faces.Extent() || thickness <= 0) return nil;
    try {
        TopTools_ListOfShape removed;
        removed.Append(_faces(int(face)));
        BRepOffsetAPI_MakeThickSolid maker;
        maker.MakeThickSolidByJoin(_shape, removed, -thickness, 1e-3);
        maker.Build();
        if (!maker.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:maker.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)transformedBy:(const gp_Trsf &)transform {
    try {
        BRepBuilderAPI_Transform op(_shape, transform, Standard_True);
        if (!op.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:op.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)translatedBy:(simd_double3)offset {
    gp_Trsf transform;
    transform.SetTranslation(gp_Vec(offset.x, offset.y, offset.z));
    return [self transformedBy:transform];
}

- (nullable PCKShape *)rotatedAroundOrigin:(simd_double3)origin axis:(simd_double3)axis angle:(double)radians {
    if (simd_length(axis) == 0) return nil;
    gp_Trsf transform;
    transform.SetRotation(gp_Ax1(toPnt(origin), toDir(axis)), radians);
    return [self transformedBy:transform];
}

- (nullable PCKShape *)mirroredAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    if (simd_length(normal) == 0) return nil;
    gp_Trsf transform;
    transform.SetMirror(gp_Ax2(toPnt(origin), toDir(normal)));
    return [self transformedBy:transform];
}

/// Echte Kanten einer Fläche, ohne Nahtkanten (z. B. bei Zylindern) und entartete Kanten.
static TopTools_IndexedMapOfShape realEdgesOfFace(const TopTools_IndexedMapOfShape &faces, NSInteger index) {
    TopTools_IndexedMapOfShape result;
    if (index < 1 || index > faces.Extent()) return result;
    const TopoDS_Face face = TopoDS::Face(faces(int(index)));
    for (TopExp_Explorer explorer(face, TopAbs_EDGE); explorer.More(); explorer.Next()) {
        const TopoDS_Edge edge = TopoDS::Edge(explorer.Current());
        if (BRep_Tool::Degenerated(edge) || BRep_Tool::IsClosed(edge, face)) continue;
        result.Add(edge);
    }
    return result;
}

- (nullable PCKShape *)filletingEdgesOfFace:(NSInteger)face radius:(double)radius {
    const TopTools_IndexedMapOfShape edges = realEdgesOfFace(_faces, face);
    if (edges.IsEmpty() || radius <= 0) return nil;
    try {
        BRepFilletAPI_MakeFillet fillet(_shape);
        for (int i = 1; i <= edges.Extent(); ++i) {
            fillet.Add(radius, TopoDS::Edge(edges(i)));
        }
        fillet.Build();
        if (!fillet.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:fillet.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)chamferingEdgesOfFace:(NSInteger)face distance:(double)distance {
    const TopTools_IndexedMapOfShape edges = realEdgesOfFace(_faces, face);
    if (edges.IsEmpty() || distance <= 0) return nil;
    try {
        BRepFilletAPI_MakeChamfer chamfer(_shape);
        for (int i = 1; i <= edges.Extent(); ++i) {
            chamfer.Add(distance, TopoDS::Edge(edges(i)));
        }
        chamfer.Build();
        if (!chamfer.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:chamfer.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

/// Kanten aus Nummern (ab 1); ungültige Nummern werden übersprungen.
static std::vector<TopoDS_Edge> edgesFromNumbers(const TopTools_IndexedMapOfShape &edges, NSArray<NSNumber *> *numbers) {
    std::vector<TopoDS_Edge> result;
    for (NSNumber *number in numbers) {
        const NSInteger index = number.integerValue;
        if (index < 1 || index > edges.Extent()) continue;
        result.push_back(TopoDS::Edge(edges(int(index))));
    }
    return result;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)numbers radius:(double)radius {
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    if (edges.empty() || radius <= 0) return nil;
    try {
        BRepFilletAPI_MakeFillet fillet(_shape);
        for (const auto &edge : edges) {
            fillet.Add(radius, edge);
        }
        fillet.Build();
        if (!fillet.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:fillet.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)numbers distance:(double)distance {
    const std::vector<TopoDS_Edge> edges = edgesFromNumbers(_edges, numbers);
    if (edges.empty() || distance <= 0) return nil;
    try {
        BRepFilletAPI_MakeChamfer chamfer(_shape);
        for (const auto &edge : edges) {
            chamfer.Add(distance, edge);
        }
        chamfer.Build();
        if (!chamfer.IsDone()) return nil;
        return [[PCKShape alloc] initWithShape:chamfer.Shape()];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)handleOfEdge:(NSInteger)index {
    if (index < 1 || index > _edges.Extent()) return nil;
    try {
        const TopoDS_Edge edge = TopoDS::Edge(_edges(int(index)));
        if (BRep_Tool::Degenerated(edge)) return nil;
        double first = 0, last = 0;
        BRep_Tool::Range(edge, first, last);
        const double mid = 0.5 * (first + last);
        const gp_Pnt point = BRepAdaptor_Curve(edge).Value(mid);

        // Summe der Flächennormalen an der Kantenmitte; die Gegenrichtung zeigt ins Material.
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
        gp_Vec sum(0, 0, 0);
        const int key = edgeFaces.FindIndex(edge);
        if (key > 0) {
            TopTools_IndexedMapOfShape seen;
            for (TopTools_ListIteratorOfListOfShape it(edgeFaces(key)); it.More(); it.Next()) {
                const TopoDS_Face face = TopoDS::Face(it.Value());
                if (seen.Contains(face)) continue;
                seen.Add(face);
                double f = 0, l = 0;
                Handle(Geom2d_Curve) pcurve = BRep_Tool::CurveOnSurface(edge, face, f, l);
                if (pcurve.IsNull()) continue;
                const gp_Pnt2d uv = pcurve->Value(mid);
                BRepGProp_Face props(face);
                gp_Pnt onFace;
                gp_Vec normal;
                props.Normal(uv.X(), uv.Y(), onFace, normal);
                if (normal.Magnitude() > 1e-12) sum += normal.Normalized();
            }
        }
        gp_Vec direction = -sum;
        if (direction.Magnitude() < 1e-9) direction = gp_Vec(0, 0, -1);
        direction.Normalize();
        return @[@(point.X()), @(point.Y()), @(point.Z()), @(direction.X()), @(direction.Y()), @(direction.Z())];
    } catch (const Standard_Failure &) {
        return nil;
    }
}

- (nullable NSArray<NSNumber *> *)planeOfFace:(NSInteger)index {
    if (index < 1 || index > _faces.Extent()) return nil;
    const TopoDS_Face face = TopoDS::Face(_faces(int(index)));
    BRepAdaptor_Surface surface(face);
    if (surface.GetType() != GeomAbs_Plane) return nil;
    const gp_Pln plane = surface.Plane();
    gp_Dir normal = plane.Axis().Direction();
    if (face.Orientation() == TopAbs_REVERSED) normal.Reverse();
    const gp_Pnt origin = plane.Location();
    return @[@(origin.X()), @(origin.Y()), @(origin.Z()), @(normal.X()), @(normal.Y()), @(normal.Z())];
}

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    MeshBuffers buffers;
    BRepMesh_IncrementalMesh mesher(_shape, deflection, Standard_False, 0.35, Standard_True);

    for (int f = 1; f <= _faces.Extent(); ++f) {
        const TopoDS_Face face = TopoDS::Face(_faces(f));
        TopLoc_Location location;
        Handle(Poly_Triangulation) triangulation = BRep_Tool::Triangulation(face, location);
        if (triangulation.IsNull()) continue;

        BRepLib_ToolTriangulatedShape::ComputeNormals(face, triangulation);
        const gp_Trsf transform = location.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        const uint32_t base = static_cast<uint32_t>(buffers.vertices.size() / 6);

        for (int i = 1; i <= triangulation->NbNodes(); ++i) {
            const gp_Pnt p = triangulation->Node(i).Transformed(transform);
            gp_Dir n = triangulation->Normal(i);
            n.Transform(transform);
            if (reversed) n.Reverse();
            buffers.addVertex(simd_make_double3(p.X(), p.Y(), p.Z()), simd_make_double3(n.X(), n.Y(), n.Z()));
        }
        for (int i = 1; i <= triangulation->NbTriangles(); ++i) {
            int a, b, c;
            triangulation->Triangle(i).Get(a, b, c);
            if (reversed) std::swap(b, c);
            buffers.addTriangle(base + a - 1, base + b - 1, base + c - 1, uint32_t(f));
        }
    }

    // Kanten als Polylinien, Nahtkanten weglassen
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(_shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    for (int i = 1; i <= edgeFaces.Extent(); ++i) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeFaces.FindKey(i));
        if (BRep_Tool::Degenerated(edge)) continue;
        bool seam = false;
        for (TopTools_ListIteratorOfListOfShape it(edgeFaces(i)); it.More(); it.Next()) {
            if (BRep_Tool::IsClosed(edge, TopoDS::Face(it.Value()))) seam = true;
        }
        if (seam) continue;
        try {
            BRepAdaptor_Curve curve(edge);
            GCPnts_TangentialDeflection points(curve, 0.2, deflection);
            const uint32_t number = uint32_t(_edges.FindIndex(edge));
            for (int k = 1; k < points.NbPoints(); ++k) {
                const gp_Pnt a = points.Value(k), b = points.Value(k + 1);
                buffers.addEdge(simd_make_double3(a.X(), a.Y(), a.Z()), simd_make_double3(b.X(), b.Y(), b.Z()),
                                number);
            }
        } catch (const Standard_Failure &) {
            continue;
        }
    }
    return [[PCKMesh alloc] initWithBuffers:buffers];
}

+ (nullable NSArray<PCKShape *> *)shapesFromSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
    try {
        STEPControl_Reader reader;
        if (reader.ReadFile(path.fileSystemRepresentation) != IFSelect_RetDone) return nil;
        reader.TransferRoots();
        const TopoDS_Shape shape = reader.OneShape();
        if (shape.IsNull()) return nil;
        NSMutableArray<PCKShape *> *result = [NSMutableArray array];
        for (TopExp_Explorer explorer(shape, TopAbs_SOLID); explorer.More(); explorer.Next()) {
            [result addObject:[[PCKShape alloc] initWithShape:explorer.Current()]];
        }
        if (result.count == 0) {
            [result addObject:[[PCKShape alloc] initWithShape:shape]];
        }
        return result;
    } catch (const Standard_Failure &) {
        return nil;
    }
#else
    return nil;
#endif
}

+ (BOOL)writeShapes:(NSArray<PCKShape *> *)shapes toSTEPFile:(NSString *)path {
#if PCK_HAS_STEP
    try {
        STEPControl_Writer writer;
        Interface_Static::SetCVal("write.step.unit", "MM");
        for (PCKShape *shape in shapes) {
            if (writer.Transfer(shape->_shape, STEPControl_AsIs) != IFSelect_RetDone) return NO;
        }
        return writer.Write(path.fileSystemRepresentation) == IFSelect_RetDone;
    } catch (const Standard_Failure &) {
        return NO;
    }
#else
    return NO;
#endif
}

#else

- (instancetype)initWithFallback:(FallbackBody)body {
    if ((self = [super init])) {
        _fallback = std::move(body);
    }
    return self;
}

+ (PCKShape *)boxWithWidth:(double)width depth:(double)depth height:(double)height {
    const double x = width / 2, y = depth / 2;
    const std::vector<simd_double3> rect = {
        simd_make_double3(-x, -y, 0), simd_make_double3(x, -y, 0),
        simd_make_double3(x, y, 0), simd_make_double3(-x, y, 0)};
    return [[PCKShape alloc] initWithFallback:fallbackPrism(rect, simd_make_double3(0, 0, height), false)];
}

+ (nullable PCKShape *)cylinderWithBase:(simd_double3)base axis:(simd_double3)axis
                                 radius:(double)radius height:(double)height {
    if (radius <= 0 || height <= 0 || simd_length(axis) == 0) return nil;
    const std::vector<simd_double3> circle = circlePoints(base, axis, radius, 64);
    return [[PCKShape alloc] initWithFallback:fallbackPrism(circle, simd_normalize(axis) * height, true)];
}

+ (nullable PCKShape *)prismWithPointsXYZ:(NSArray<NSNumber *> *)xyz direction:(simd_double3)direction {
    const std::vector<simd_double3> points = toPoints(xyz);
    if (points.size() < 3 || simd_length(direction) == 0) return nil;
    return [[PCKShape alloc] initWithFallback:fallbackPrism(points, direction, false)];
}

+ (nullable PCKShape *)sphereWithCenter:(simd_double3)center radius:(double)radius {
    return nil;
}

+ (nullable PCKShape *)prismWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires direction:(simd_double3)direction {
    return nil;
}

+ (nullable PCKShape *)faceWithProfileWires:(NSArray<NSArray<NSNumber *> *> *)wires {
    return nil;
}

+ (nullable PCKShape *)compoundOfShapes:(NSArray<PCKShape *> *)shapes {
    return shapes.firstObject;
}

+ (nullable PCKShape *)coneWithBase:(simd_double3)base axis:(simd_double3)axis
                       bottomRadius:(double)bottomRadius topRadius:(double)topRadius height:(double)height {
    return nil;
}

+ (nullable PCKShape *)ellipsePrismWithCenter:(simd_double3)center normal:(simd_double3)normal
                                        xAxis:(simd_double3)xAxis radiusX:(double)radiusX
                                      radiusY:(double)radiusY direction:(simd_double3)direction {
    if (radiusX <= 0 || radiusY <= 0 || simd_length(direction) == 0 || simd_length(normal) == 0) return nil;
    const simd_double3 x = simd_normalize(xAxis);
    const simd_double3 y = simd_cross(simd_normalize(normal), x);
    std::vector<simd_double3> points;
    for (int i = 0; i < 72; ++i) {
        const double a = 2 * M_PI * i / 72;
        points.push_back(center + radiusX * std::cos(a) * x + radiusY * std::sin(a) * y);
    }
    return [[PCKShape alloc] initWithFallback:fallbackPrism(points, direction, true)];
}

- (nullable PCKShape *)cutting:(PCKShape *)tool {
    return nil;
}

- (nullable PCKShape *)intersecting:(PCKShape *)other {
    return nil;
}

- (nullable PCKShape *)extrudingFace:(NSInteger)face distance:(double)distance {
    return nil;
}

- (nullable PCKShape *)shellingRemovingFace:(NSInteger)face thickness:(double)thickness {
    return nil;
}

- (nullable PCKShape *)translatedBy:(simd_double3)offset {
    FallbackBody body = _fallback;
    for (size_t i = 0; i + 5 < body.mesh.vertices.size(); i += 6) {
        body.mesh.vertices[i] += float(offset.x);
        body.mesh.vertices[i + 1] += float(offset.y);
        body.mesh.vertices[i + 2] += float(offset.z);
    }
    for (size_t i = 0; i + 5 < body.mesh.edges.size(); i += 3) {
        body.mesh.edges[i] += float(offset.x);
        body.mesh.edges[i + 1] += float(offset.y);
        body.mesh.edges[i + 2] += float(offset.z);
    }
    for (auto &plane : body.planes) {
        plane[0] += offset.x;
        plane[1] += offset.y;
        plane[2] += offset.z;
    }
    return [[PCKShape alloc] initWithFallback:std::move(body)];
}

- (nullable PCKShape *)rotatedAroundOrigin:(simd_double3)origin axis:(simd_double3)axis angle:(double)radians {
    return nil;
}

- (nullable PCKShape *)mirroredAtPlaneOrigin:(simd_double3)origin normal:(simd_double3)normal {
    return nil;
}

- (nullable PCKShape *)fusing:(PCKShape *)other {
    return nil;
}

- (nullable PCKShape *)filletingEdgesOfFace:(NSInteger)face radius:(double)radius {
    return nil;
}

- (nullable PCKShape *)chamferingEdgesOfFace:(NSInteger)face distance:(double)distance {
    return nil;
}

- (nullable PCKShape *)filletingEdges:(NSArray<NSNumber *> *)edges radius:(double)radius {
    return nil;
}

- (nullable PCKShape *)chamferingEdges:(NSArray<NSNumber *> *)edges distance:(double)distance {
    return nil;
}

- (nullable NSArray<NSNumber *> *)handleOfEdge:(NSInteger)edge {
    return nil;
}

- (nullable NSArray<NSNumber *> *)planeOfFace:(NSInteger)face {
    if (face < 1 || size_t(face) > _fallback.planes.size() || !_fallback.planar[face - 1]) return nil;
    const auto &p = _fallback.planes[face - 1];
    return @[@(p[0]), @(p[1]), @(p[2]), @(p[3]), @(p[4]), @(p[5])];
}

- (PCKMesh *)triangulateWithDeflection:(double)deflection {
    return [[PCKMesh alloc] initWithBuffers:_fallback.mesh];
}

+ (nullable NSArray<PCKShape *> *)shapesFromSTEPFile:(NSString *)path {
    return nil;
}

+ (BOOL)writeShapes:(NSArray<PCKShape *> *)shapes toSTEPFile:(NSString *)path {
    return NO;
}

#endif

@end
