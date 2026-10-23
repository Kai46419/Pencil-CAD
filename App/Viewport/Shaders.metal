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
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float3 color;
};

static VertexOut transformVertex(Vertex v, constant Uniforms &uniforms) {
    VertexOut out;
    out.position = uniforms.viewProjection * uniforms.model * float4(v.position, 1.0);
    out.normal = (uniforms.model * float4(v.normal, 0.0)).xyz;
    out.color = v.color;
    return out;
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
                              constant Uniforms &uniforms [[buffer(1)]]) {
    return float4(shade(in, uniforms), 1.0);
}

/// Röntgenansicht: halbtransparent.
fragment float4 fragment_xray(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
    return float4(shade(in, uniforms), 0.28);
}

fragment float4 fragment_flat(VertexOut in [[stage_in]],
                              constant float4 &color [[buffer(2)]]) {
    return color;
}
