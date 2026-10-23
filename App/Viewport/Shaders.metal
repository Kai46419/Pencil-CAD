#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float3 normal;
    float3 color;
};

struct Uniforms {
    float4x4 viewProjection;
    float4x4 model;
    float3 lightDirection;
    float3 baseColor;
    /// Schnittansicht: xyz = Normale, w = Abstand; Normale 0 = aus
    float4 clipPlane;
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float3 color;
    float3 world;
};

static VertexOut transformVertex(Vertex v, constant Uniforms &uniforms) {
    VertexOut out;
    float4 world = uniforms.model * float4(v.position, 1.0);
    out.position = uniforms.viewProjection * world;
    out.normal = (uniforms.model * float4(v.normal, 0.0)).xyz;
    out.color = v.color;
    out.world = world.xyz;
    return out;
}

/// Schnittansicht: alles auf der Seite der Normale ausblenden.
static bool clipped(VertexOut in, constant Uniforms &uniforms) {
    float3 n = uniforms.clipPlane.xyz;
    return dot(n, n) > 0.0 && dot(n, in.world) > uniforms.clipPlane.w;
}

vertex VertexOut vertex_main(const device Vertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]],
                             uint vid [[vertex_id]]) {
    return transformVertex(vertices[vid], uniforms);
}

/// Wie vertex_main, aber minimal zur Kamera verschoben, damit Kanten und Auswahl
/// nicht mit den Flächen darunter flimmern.
vertex VertexOut vertex_overlay(const device Vertex *vertices [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    VertexOut out = transformVertex(vertices[vid], uniforms);
    out.position.z -= 0.0004 * out.position.w;
    return out;
}

static float3 shade(VertexOut in, constant Uniforms &uniforms) {
    float3 n = normalize(in.normal);
    float diffuse = abs(dot(n, normalize(uniforms.lightDirection)));
    return in.color * (0.35 + 0.65 * diffuse);
}

/// Schattierte Körper in Vertexfarbe.
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]],
                              bool frontFacing [[front_facing]]) {
    if (clipped(in, uniforms)) discard_fragment();
    // Schnittansicht: Innenseiten wirken als Schnittfläche (flach, abgedunkelt)
    float3 n = uniforms.clipPlane.xyz;
    if (dot(n, n) > 0.0 && !frontFacing) return float4(in.color * 0.55 + float3(0.25, 0.12, 0.02), 1.0);
    return float4(shade(in, uniforms), 1.0);
}

/// Röntgenansicht: halbtransparent.
fragment float4 fragment_xray(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
    if (clipped(in, uniforms)) discard_fragment();
    return float4(shade(in, uniforms), 0.28);
}

/// Kanten und Auswahl, mit Schnittansicht.
fragment float4 fragment_flat_clip(VertexOut in [[stage_in]],
                                   constant Uniforms &uniforms [[buffer(1)]],
                                   constant float4 &color [[buffer(2)]]) {
    if (clipped(in, uniforms)) discard_fragment();
    return color;
}

/// Bild (Canvas): uv steckt in der Normale, Deckkraft in color.a.
fragment float4 fragment_texture(VertexOut in [[stage_in]],
                                 texture2d<float> image [[texture(0)]],
                                 constant float4 &color [[buffer(2)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float4 c = image.sample(linearSampler, in.normal.xy);
    return float4(c.rgb, c.a * color.a);
}

fragment float4 fragment_flat(VertexOut in [[stage_in]],
                              constant float4 &color [[buffer(2)]]) {
    return color;
}

/// Einfarbig in Vertexfarbe (breite Linien, Fangsymbole).
fragment float4 fragment_color(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}

/// Körperkanten als breite Linien in Vertexfarbe, mit Schnittansicht.
fragment float4 fragment_color_clip(VertexOut in [[stage_in]],
                                    constant Uniforms &uniforms [[buffer(1)]]) {
    if (clipped(in, uniforms)) discard_fragment();
    return float4(in.color, 1.0);
}
