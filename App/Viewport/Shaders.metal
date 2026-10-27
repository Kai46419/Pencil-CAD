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
    /// xyz = Kameraposition, w = Anteil, um den Überlagerungen zur Kamera gezogen werden
    float4 eye;
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
    // Um einen festen Anteil der Entfernung zur Kamera hin verschieben. Ein fester Versatz in der
    // Tiefe wirkte bei größerem Abstand wie mehrere Millimeter: Skizzen und Kanten am Boden
    // schienen dann durch flache Körper hindurch.
    Vertex v = vertices[vid];
    float4 world = uniforms.model * float4(v.position, 1.0);
    world.xyz += (uniforms.eye.xyz - world.xyz) * uniforms.eye.w;
    VertexOut out;
    out.position = uniforms.viewProjection * world;
    out.normal = (uniforms.model * float4(v.normal, 0.0)).xyz;
    out.color = v.color;
    out.world = world.xyz;
    return out;
}

// MARK: Oberflächen (SurfaceFinish.swift)

/// Darstellungswerte eines Körpers, aus der Vertexfarbe gelesen.
struct Surface {
    float3 albedo;
    /// 0 = Spiegel, 1 = ganz matt
    float roughness;
    float metallic;
    float clearcoat;
    float transparent;
    int pattern;
    /// Faserrichtung für gestreckte Glanzlichter (gebürstet, Carbon); Länge = Stärke, 0 = keine
    float3 tangent;
};

/// Kodierung wie SurfaceAppearance.encoded: Farbe im Nachkommateil (0,002…0,995), Ganzzahlteile
/// r = Glanzstufe 0…16 (Rauheit 1 − Stufe/16), g = Bits (1 Metall, 2 Klarlack, 4 transparent), b = Muster.
/// Unkodierte Farben (0…1) ergeben matt ohne Muster wie bisher.
static Surface decodeSurface(float3 c) {
    float3 code = max(floor(c - 0.001f), float3(0.0f));
    Surface s;
    s.albedo = saturate(c - code);
    s.roughness = 1.0f - min(code.x, 16.0f) * (1.0f / 16.0f);
    float bits = code.y;
    s.metallic = fmod(bits, 2.0f) > 0.5f ? 1.0f : 0.0f;
    s.clearcoat = fmod(floor(bits * 0.5f), 2.0f) > 0.5f ? 1.0f : 0.0f;
    s.transparent = bits > 3.5f ? 1.0f : 0.0f;
    s.pattern = int(code.z + 0.5f);
    s.tangent = float3(0.0f);
    return s;
}

/// Einfacher Hash (ohne Sinus), Werte 0…1.
static float hash13(float3 p) {
    p = fract(p * 0.1031f);
    p += dot(p, p.zyx + 31.32f);
    return fract((p.x + p.y) * p.z);
}

/// Wertrauschen 0…1 aus acht Gitterpunkten, weich interpoliert.
static float valueNoise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0f - 2.0f * f);
    float a = hash13(i);
    float b = hash13(i + float3(1.0f, 0.0f, 0.0f));
    float c = hash13(i + float3(0.0f, 1.0f, 0.0f));
    float d = hash13(i + float3(1.0f, 1.0f, 0.0f));
    float e = hash13(i + float3(0.0f, 0.0f, 1.0f));
    float g = hash13(i + float3(1.0f, 0.0f, 1.0f));
    float h = hash13(i + float3(0.0f, 1.0f, 1.0f));
    float k = hash13(i + float3(1.0f, 1.0f, 1.0f));
    float lower = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    float upper = mix(mix(e, g, u.x), mix(h, k, u.x), u.y);
    return mix(lower, upper, u.z);
}

/// Prozedurale Muster in Weltkoordinaten (mm). footprint = Größe eines Bildpunkts in mm: feine Muster
/// verblassen, bevor sie flimmern.
static void applyPattern(thread Surface &s, float3 p, float3 n, float footprint) {
    if (s.pattern == 1) {
        // Holz: Jahresringe um eine Achse entlang X, mit Rauschen verzogen; Fasern längs gestreckt
        float spacing = 2.6f;
        float warp = valueNoise(p * float3(0.04f, 0.35f, 0.35f)) * 1.6f;
        float rings = length(p.yz + float2(41.0f, 13.0f)) / spacing + warp;
        float ring = fract(rings);
        float late = smoothstep(0.55f, 0.9f, ring) * (1.0f - smoothstep(0.9f, 1.0f, ring));
        float fiber = valueNoise(p * float3(0.06f, 2.5f, 2.5f));
        float fade = 1.0f - smoothstep(0.3f * spacing, 0.8f * spacing, footprint);
        float dark = (late * 0.42f + (fiber - 0.5f) * 0.18f) * fade + 0.12f * (1.0f - fade);
        s.albedo *= 1.08f - dark;
        s.roughness = saturate(s.roughness + late * 0.12f * fade);
    } else if (s.pattern == 2) {
        // Beton: wolkige Flecken, feines Korn, kleine dunkle Poren
        float coarse = valueNoise(p * 0.12f);
        float grain = valueNoise(p * 1.7f);
        float pores = smoothstep(0.82f, 0.88f, valueNoise(p * 2.3f + float3(17.0f, 5.0f, 9.0f)));
        float fadeFine = 1.0f - smoothstep(0.15f, 0.5f, footprint);
        float tone = 0.86f + 0.28f * coarse + ((grain - 0.5f) * 0.16f - pores * 0.45f) * fadeFine;
        s.albedo *= tone;
        s.roughness = saturate(s.roughness + pores * 0.1f * fadeFine);
    } else if (s.pattern == 3) {
        // Gebürstet: feine Streifen in Schleifrichtung (an Wänden waagrecht, auf Deckflächen entlang X)
        float3 axis = abs(n.z) < 0.9f ? float3(0.0f, 0.0f, 1.0f) : float3(0.0f, 1.0f, 0.0f);
        float3 along = normalize(cross(axis, n));
        float3 across = cross(n, along);
        float u = dot(p, across);
        float v = dot(p, along);
        float s1 = valueNoise(float3(u * 4.0f, v * 0.03f, 1.7f));
        float s2 = valueNoise(float3(u * 19.0f, v * 0.08f, 5.3f));
        float fade = 1.0f - smoothstep(0.04f, 0.25f, footprint);
        float streak = (s1 * 0.55f + s2 * 0.45f - 0.5f) * fade;
        s.albedo *= 1.0f + streak * 0.3f;
        s.roughness = saturate(s.roughness + streak * 0.12f);
        s.tangent = along;
    } else if (s.pattern == 4) {
        // Carbon: Köperbindung 2/2 mit 2 mm breiten Bündeln, projiziert auf die Hauptebene der Fläche
        float3 an = abs(n);
        float3 axisU = float3(1.0f, 0.0f, 0.0f);
        float3 axisV = float3(0.0f, 1.0f, 0.0f);
        if (an.x > an.z && an.x >= an.y) {
            axisU = float3(0.0f, 1.0f, 0.0f);
            axisV = float3(0.0f, 0.0f, 1.0f);
        } else if (an.y > an.z && an.y > an.x) {
            axisV = float3(0.0f, 0.0f, 1.0f);
        }
        float2 uv = float2(dot(p, axisU), dot(p, axisV)) * 0.5f;
        float2 cell = floor(uv);
        float2 f = fract(uv);
        float diagonal = cell.x + cell.y;
        float twill = diagonal - 4.0f * floor(diagonal * 0.25f);
        bool alongU = twill < 1.5f;
        float acrossFiber = alongU ? f.y : f.x;
        float bundle = sin(acrossFiber * M_PI_F);
        float fade = 1.0f - smoothstep(0.5f, 1.4f, footprint);
        s.albedo *= mix(0.75f, 0.55f + 0.6f * bundle, fade);
        s.tangent = (alongU ? axisU : axisV) * fade;
    }
}

/// Prozedurale Studio-Umgebung für Spiegelungen (Z oben): heller Himmel, Horizont, dunkler Boden,
/// Lichtleiste an der Decke und zwei Softboxen. blur 0…1 (Rauheit) macht Kanten weich und Lichter schwächer.
static float3 environment(float3 d, float blur) {
    float z = d.z;
    float soft = 0.02f + blur * 0.6f;
    float3 sky = mix(float3(0.78f, 0.80f, 0.84f), float3(0.97f, 0.98f, 1.0f), saturate(z * 1.4f));
    float3 ground = mix(float3(0.34f, 0.33f, 0.32f), float3(0.07f, 0.07f, 0.075f), saturate(-z * 2.5f));
    float3 color = mix(ground, sky, smoothstep(-soft, soft, z));
    float glow = 1.0f - blur * 0.75f;
    float width = 0.03f + blur * 0.45f;
    // Lichtleiste an der Decke entlang X
    float ceiling = (1.0f - smoothstep(0.09f, 0.09f + width, abs(d.y))) * smoothstep(0.55f - width, 0.7f, z);
    // Softboxen seitlich (Richtung in der Waagrechten)
    float2 level = d.xy / max(length(d.xy), 1e-4f);
    float key = smoothstep(0.90f - width, 0.95f, dot(level, float2(0.5f, 0.866f)))
        * (1.0f - smoothstep(0.35f, 0.35f + width, abs(z - 0.2f)));
    float rim = smoothstep(0.93f - width, 0.97f, dot(level, float2(-0.94f, -0.34f)))
        * (1.0f - smoothstep(0.2f, 0.2f + width, abs(z - 0.1f)));
    color += float3(1.6f * ceiling + 1.3f * key + 0.8f * rim) * glow;
    return color;
}

/// Glanzlicht der Lampe: Blinn-Phong mit Exponent aus der Rauheit; mit Faserrichtung quer gestreckt (Kajiya-Kay).
static float lampHighlight(float3 n, float3 h, float roughness, float3 tangent) {
    float gloss = 1.0f - roughness;
    float exponent = exp2(2.0f + 9.0f * gloss);
    float strength = mix(0.04f, 1.0f, gloss * gloss);
    float highlight = pow(saturate(abs(dot(n, h))), exponent);
    float t = length(tangent);
    if (t > 0.01f) {
        float th = dot(tangent / t, h);
        float aniso = pow(sqrt(saturate(1.0f - th * th)), exponent * 0.5f);
        highlight = mix(highlight, aniso * 0.6f, min(t, 1.0f));
    }
    return highlight * strength;
}

/// Körper schattieren: matt ohne Muster wie bisher, sonst PBR-ähnlich mit Fresnel (Schlick, rauheitsabhängig),
/// Spiegelung der Studio-Umgebung, Glanzlicht der Lampe und optionaler Klarlackschicht.
static float3 shadeSurface(VertexOut in, constant Uniforms &uniforms, Surface s, float footprint) {
    float3 n = normalize(in.normal);
    float3 l = normalize(uniforms.lightDirection);
    float diffuse = abs(dot(n, l));
    float lambert = 0.35f + 0.65f * diffuse;
    // Die meisten Körper: bisherige matte Darstellung ohne weiteren Aufwand
    if (s.roughness > 0.99f && s.metallic < 0.5f && s.clearcoat < 0.5f && s.pattern == 0) {
        return s.albedo * lambert;
    }
    float3 v = normalize(uniforms.eye.xyz - in.world);
    if (dot(n, v) < 0.0f) n = -n;
    applyPattern(s, in.world, n, footprint);
    float nv = saturate(dot(n, v));
    float3 r = reflect(-v, n);
    float3 h = normalize(l + v);
    float fresnelWeight = pow(1.0f - nv, 5.0f);
    float3 f0 = mix(float3(0.04f), s.albedo, s.metallic);
    float3 f90 = max(float3(1.0f - s.roughness), f0);
    float3 fresnel = f0 + (f90 - f0) * fresnelWeight;
    float3 env = environment(r, s.roughness);
    float highlight = lampHighlight(n, h, s.roughness, s.tangent);
    float3 color;
    if (s.metallic > 0.5f) {
        // Metall: Farbe nur aus der Spiegelung (getönt), etwas Licht für die Form
        color = fresnel * (env * 0.85f + float3(0.2f * diffuse + highlight));
    } else {
        float3 base = s.albedo * lambert * (float3(1.0f) - fresnel);
        color = base + env * fresnel * (1.0f - 0.5f * s.roughness) + float3(highlight * 0.6f);
    }
    if (s.clearcoat > 0.5f) {
        // Klarlack: scharfe, farblose Spiegelung darüber
        float coat = 0.04f + 0.96f * fresnelWeight;
        float3 coatEnv = environment(r, 0.04f);
        float coatHighlight = pow(saturate(abs(dot(n, h))), 600.0f) * 0.9f;
        color = color * (1.0f - coat) + coatEnv * coat + float3(coatHighlight);
    }
    return color;
}

/// Schattierte Körper in Vertexfarbe (mit Oberfläche, siehe decodeSurface).
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]],
                              bool frontFacing [[front_facing]]) {
    // Bildpunktgröße vor allen Verzweigungen (Ableitungen brauchen einheitlichen Kontrollfluss)
    float footprint = length(fwidth(in.world));
    if (clipped(in, uniforms)) discard_fragment();
    Surface s = decodeSurface(in.color);
    // Glas zeichnet fragment_glass in einem zweiten, durchsichtigen Durchgang
    if (s.transparent > 0.5f) discard_fragment();
    // Schnittansicht: Innenseiten wirken als Schnittfläche (flach, abgedunkelt)
    float3 n = uniforms.clipPlane.xyz;
    if (dot(n, n) > 0.0 && !frontFacing) return float4(s.albedo * 0.55 + float3(0.25, 0.12, 0.02), 1.0);
    return float4(shadeSurface(in, uniforms, s, footprint), 1.0);
}

/// Glas und klare Kunststoffe (zweiter Durchgang mit Mischung, ohne Tiefe zu schreiben): getönt durchsichtig,
/// zum Rand hin stärker spiegelnd (Fresnel). Echte Lichtbrechung gibt es nicht.
fragment float4 fragment_glass(VertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(1)]]) {
    if (clipped(in, uniforms)) discard_fragment();
    Surface s = decodeSurface(in.color);
    if (s.transparent < 0.5f) discard_fragment();
    float3 n = normalize(in.normal);
    float3 v = normalize(uniforms.eye.xyz - in.world);
    if (dot(n, v) < 0.0f) n = -n;
    float3 l = normalize(uniforms.lightDirection);
    float3 h = normalize(l + v);
    float nv = saturate(dot(n, v));
    float fresnel = 0.04f + 0.96f * pow(1.0f - nv, 5.0f);
    float3 env = environment(reflect(-v, n), s.roughness);
    float highlight = lampHighlight(n, h, s.roughness, float3(0.0f));
    float alpha = saturate(0.2f + 0.75f * fresnel + highlight * 0.5f);
    float3 color = mix(s.albedo * 0.9f, env, saturate(fresnel * 1.5f + 0.1f)) + float3(highlight);
    return float4(color, alpha);
}

/// Röntgenansicht: halbtransparent.
fragment float4 fragment_xray(VertexOut in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
    float footprint = length(fwidth(in.world));
    if (clipped(in, uniforms)) discard_fragment();
    return float4(shadeSurface(in, uniforms, decodeSurface(in.color), footprint), 0.28);
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

// MARK: Darstellung „Verdeckte Kanten“ und „Zebra“

/// Verdeckte Kanten: blass und gestrichelt. Die Bogenlänge in Bildschirmpunkten steckt in normal.x,
/// so bleiben die Striche beim Zoomen gleich lang.
fragment float4 fragment_dashed_clip(VertexOut in [[stage_in]],
                                     constant Uniforms &uniforms [[buffer(1)]]) {
    if (clipped(in, uniforms)) discard_fragment();
    if (fmod(max(in.normal.x, 0.0f), 8.0f) > 4.5f) discard_fragment();
    return float4(in.color, 0.6f);
}

/// Zebra-Streifen zur Prüfung von Flächenübergängen: Spiegelung einer Wand aus waagerechten Lichtbändern.
/// Laufen die Streifen über eine Kante ohne Knick weiter, ist der Übergang tangential bzw. krümmungsstetig.
/// view.xyz = Blickrichtung, view.w = 1 bei Parallelprojektion.
fragment float4 fragment_zebra(VertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(1)]],
                               constant float4 &view [[buffer(2)]]) {
    if (clipped(in, uniforms)) discard_fragment();
    float3 n = normalize(in.normal);
    float3 d = view.w > 0.5f ? normalize(view.xyz) : normalize(in.world - uniforms.eye.xyz);
    if (dot(n, d) > 0.0f) n = -n;
    float3 r = reflect(d, n);
    // Höhenwinkel der Spiegelrichtung, 16 Streifenpaare je Halbkreis
    float band = asin(clamp(r.z, -1.0f, 1.0f)) * (16.0f / M_PI_F);
    float s = sin(band * 2.0f * M_PI_F);
    float stripe = clamp(s / max(fwidth(s) * 1.5f, 1e-4f) * 0.5f + 0.5f, 0.0f, 1.0f);
    float3 color = mix(float3(0.07, 0.08, 0.10), float3(0.97, 0.97, 0.98), stripe);
    float diffuse = abs(dot(n, normalize(uniforms.lightDirection)));
    return float4(color * (0.8f + 0.2f * diffuse), 1.0f);
}
