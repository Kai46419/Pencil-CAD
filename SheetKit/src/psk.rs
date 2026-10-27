//! Die `psk.*`-Komfortbefehle (siehe API.md) und die Weiterleitung aller übrigen Befehle an
//! SolidCraft. Die Befehle hier lesen nur den Modellzustand oder rufen SolidCraft-Befehle auf;
//! sie verändern nie SolidCraft-Interna direkt.

use serde_json::{Value, json};
use solidcraft_engine::Session;
use solidcraft_engine::geom::Vec3;

/// Ein Befehl: `psk.*` hier, alles andere unverändert an `Session::execute`.
pub fn execute(s: &mut Session, command: &str, params: &Value) -> Result<Value, String> {
    let params = if params.is_null() { &json!({}) } else { params };
    match command {
        "psk.bodies" => Ok(bodies(s)),
        "psk.export_step" => export_step(s, params),
        "psk.import_step" => import_step(s, params),
        "psk.edges" => edges(s, params),
        "psk.perforation_holes" => perforation_holes(s, params),
        c if c.starts_with("psk.") => {
            Err(format!("unbekannter Befehl `{c}` (psk.bodies, psk.export_step, psk.import_step, psk.edges, psk.perforation_holes)"))
        }
        c => s.execute(c, params).map_err(|e| e.to_string()),
    }
}

fn str_param<'a>(p: &'a Value, key: &str, cmd: &str) -> Result<&'a str, String> {
    p.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()).ok_or_else(|| format!("{cmd}: `{key}` fehlt"))
}

/// `psk.bodies` → `{"bodies":[{"name","sheet","unfolded","component"?}]}` in Modellreihenfolge.
fn bodies(s: &Session) -> Value {
    let model = s.model.state();
    let world = s.world_state();
    let list: Vec<Value> = world
        .bodies
        .iter()
        .map(|b| {
            let sheet = model.sheets.iter().find(|sh| sh.body == b.name);
            json!({
                "name": b.name,
                "sheet": sheet.is_some(),
                "unfolded": sheet.is_some_and(|sh| sh.flat),
                "thickness": sheet.map(|sh| sh.t),
                "rule": sheet.map(|sh| sh.rule.clone()),
            })
        })
        .collect();
    json!({"bodies": list})
}

/// `psk.export_step {body, path}` → `{path, bytes}`: der exakte B-Rep des Körpers (so wie er im
/// Modell liegt, gefaltet oder abgewickelt) über SolidCrafts STEP-Schreiber.
fn export_step(s: &mut Session, p: &Value) -> Result<Value, String> {
    let cmd = "psk.export_step";
    let body = str_param(p, "body", cmd)?;
    let path = str_param(p, "path", cmd)?;
    if s.world_state().body(body).is_none() {
        return Err(format!("{cmd}: kein Körper `{body}`"));
    }
    let out = s
        .execute("file.export", &json!({"path": path, "format": "step", "bodies": [body]}))
        .map_err(|e| format!("{cmd}: {e}"))?;
    Ok(json!({"path": path, "bytes": out["bytes"], "body": body}))
}

/// `psk.import_step {path, name?}` → `{bodies:[…], feature, component}`: STEP-Körper als
/// Import-Feature (SolidCraft `file.insert_step`), etwa um sie danach mit `sheet.convert` in
/// Blech umzuwandeln.
fn import_step(s: &mut Session, p: &Value) -> Result<Value, String> {
    let cmd = "psk.import_step";
    let path = str_param(p, "path", cmd)?;
    let mut q = json!({"path": path});
    if let Some(name) = p.get("name").and_then(Value::as_str).filter(|n| !n.trim().is_empty()) {
        q["name"] = json!(name);
    }
    let out = s.execute("file.insert_step", &q).map_err(|e| format!("{cmd}: {e}"))?;
    Ok(json!({
        "bodies": out["bodies"],
        "feature": out["feature"],
        "component": out["component"],
        "warnings": out["warnings"],
    }))
}

/// Höchstzahl gelieferter Perforationslöcher (wie SolidCrafts Flachansicht), damit ein feines
/// Lochbild über eine große Tafel die App nicht mit Millionen Kreisen flutet.
const MAX_PERFORATION_HOLES: usize = 1_000_000;

/// `psk.perforation_holes {body?}` → `{body, holes:[{center:[x,y], radius, field}], count, truncated}`:
/// die Lochmitten aller Perforationsfelder im Koordinatensystem von `sheet.flat_pattern`
/// (SolidCraft `SheetBody::perforation_holes`, wie die Flachansicht von SolidCraft sie zeichnet).
/// Ohne `body` der zuletzt erzeugte Blechkörper (wie `sheet.flat_pattern`).
fn perforation_holes(s: &mut Session, p: &Value) -> Result<Value, String> {
    let cmd = "psk.perforation_holes";
    let model = s.model.state();
    let sheet = match p.get("body").and_then(Value::as_str).filter(|b| !b.is_empty()) {
        Some(b) => model.sheets.iter().find(|x| x.body == b).ok_or_else(|| format!("{cmd}: `{b}` ist kein Blechkörper"))?,
        None => model.sheets.last().ok_or_else(|| format!("{cmd}: es gibt keinen Blechkörper"))?,
    };
    let mut holes = Vec::new();
    let mut truncated = false;
    for (field, perforation) in sheet.perforations.iter().enumerate() {
        if !perforation.diameter.is_finite() || perforation.diameter <= 0.0 {
            continue;
        }
        let centres = sheet.perforation_holes(perforation).map_err(|e| format!("{cmd}: {e}"))?;
        let radius = perforation.diameter / 2.0;
        for c in centres {
            if holes.len() >= MAX_PERFORATION_HOLES {
                truncated = true;
                break;
            }
            holes.push(json!({"center": [c.x, c.y], "radius": radius, "field": field}));
        }
    }
    Ok(json!({"body": sheet.body, "count": holes.len(), "truncated": truncated, "holes": holes}))
}

// ---------------------------------------------------------------------------------------------
// psk.edges
// ---------------------------------------------------------------------------------------------

type P = [f64; 3];

fn v(p: Vec3) -> P {
    [p.x, p.y, p.z]
}
fn sub(a: P, b: P) -> P {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn add(a: P, b: P) -> P {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn mul(a: P, k: f64) -> P {
    [a[0] * k, a[1] * k, a[2] * k]
}
fn dot(a: P, b: P) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: P, b: P) -> P {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn len(a: P) -> f64 {
    dot(a, a).sqrt()
}
fn unit(a: P) -> Option<P> {
    let l = len(a);
    (l > 1e-300).then(|| mul(a, 1.0 / l))
}
fn round(a: P) -> Value {
    // 1e-9 mm reicht; vermeidet 49.99999999997 in der Oberfläche.
    let r = |x: f64| (x * 1e9).round() / 1e9;
    json!([r(a[0]), r(a[1]), r(a[2])])
}

/// Nächster Punkt auf dem Dreieck abc zu p (Ericson, Real-Time Collision Detection 5.1.5).
fn closest_on_triangle(p: P, a: P, b: P, c: P) -> P {
    let (ab, ac, ap) = (sub(b, a), sub(c, a), sub(p, a));
    let (d1, d2) = (dot(ab, ap), dot(ac, ap));
    if d1 <= 0.0 && d2 <= 0.0 {
        return a;
    }
    let bp = sub(p, b);
    let (d3, d4) = (dot(ab, bp), dot(ac, bp));
    if d3 >= 0.0 && d4 <= d3 {
        return b;
    }
    let vc = d1 * d4 - d3 * d2;
    if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
        return add(a, mul(ab, d1 / (d1 - d3)));
    }
    let cp = sub(p, c);
    let (d5, d6) = (dot(ab, cp), dot(ac, cp));
    if d6 >= 0.0 && d5 <= d6 {
        return c;
    }
    let vb = d5 * d2 - d1 * d6;
    if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
        return add(a, mul(ac, d2 / (d2 - d6)));
    }
    let va = d3 * d6 - d5 * d4;
    if va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0 {
        return add(b, mul(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6))));
    }
    let denom = 1.0 / (va + vb + vc);
    add(a, add(mul(ab, vb * denom), mul(ac, vc * denom)))
}

/// Punkt auf halber Länge der Polylinie und die Richtung dort.
fn polyline_mid(points: &[P]) -> Option<(P, P, f64)> {
    let total: f64 = points.windows(2).map(|w| len(sub(w[1], w[0]))).sum();
    let mut walked = 0.0;
    for w in points.windows(2) {
        let l = len(sub(w[1], w[0]));
        if l > 0.0 && walked + l >= total * 0.5 {
            let t = (total * 0.5 - walked) / l;
            return Some((add(w[0], mul(sub(w[1], w[0]), t)), mul(sub(w[1], w[0]), 1.0 / l), total));
        }
        walked += l;
    }
    points.first().map(|p| (*p, [0.0, 0.0, 0.0], total))
}

/// Ein Flächenstück nahe der Kante: Normale (nach außen) und ein Punkt der Fläche, der von der
/// Kante weg in die Fläche hinein liegt.
struct Side {
    normal: P,
    inward: P,
}

/// Das Dreieck der Fläche `face`, das `m` am nächsten liegt, als Normale + Schwerpunkt.
fn side_of(mesh: &solidcraft_engine::geom::Mesh, face: u32, m: P) -> Option<Side> {
    let mut best: Option<(f64, [P; 3])> = None;
    for (t, f) in mesh.triangles.iter().zip(&mesh.tri_face) {
        if *f != face {
            continue;
        }
        let Some([a, b, c]) = mesh.tri(t) else { continue };
        let (a, b, c) = (v(a), v(b), v(c));
        let d = len(sub(closest_on_triangle(m, a, b, c), m));
        // Entartete Dreiecke (Fläche ~0) taugen nicht für eine Normale.
        if len(cross(sub(b, a), sub(c, a))) < 1e-14 {
            continue;
        }
        if best.is_none_or(|(bd, _)| d < bd) {
            best = Some((d, [a, b, c]));
        }
    }
    let (_, [a, b, c]) = best?;
    let normal = unit(cross(sub(b, a), sub(c, a)))?;
    let centroid = mul(add(add(a, b), c), 1.0 / 3.0);
    Some(Side { normal, inward: sub(centroid, m) })
}

/// `psk.edges {body}` → je B-Rep-Kante: Index, Name, Mittelpunkt, Endpunkte, Länge, die
/// (ein oder zwei) Nachbarflächen und – bei zwei Flächen – konvex/konkav und der Winkel
/// zwischen den Flächennormalen (0° = tangential, 90° = rechtwinklige Körperkante).
fn edges(s: &mut Session, p: &Value) -> Result<Value, String> {
    let cmd = "psk.edges";
    let name = str_param(p, "body", cmd)?;
    let world = s.world_state();
    let b = world.body(name).ok_or_else(|| format!("{cmd}: kein Körper `{name}`"))?;
    // Dieselbe Toleranz wie SolidCrafts `model.edges`, damit die Kantenindizes übereinstimmen.
    let tol = (b.body.size() * 2e-3).max(1e-3);
    let mesh = b.body.tessellate(tol).map_err(|e| format!("{cmd}: {e}"))?;
    let names = solidcraft_engine::doc::naming::edge_names(b);
    let mut out = Vec::with_capacity(mesh.edges.len());
    for (index, poly) in mesh.edges.iter().enumerate() {
        let pts: Vec<P> = poly.iter().copied().map(v).collect();
        let Some((mid, _dir, length)) = polyline_mid(&pts) else { continue };
        let faces: Vec<u32> = mesh.edge_faces.get(index).cloned().unwrap_or_default();
        let mut e = json!({
            "index": index,
            "name": names.get(index),
            "mid": round(mid),
            "a": round(pts[0]),
            "b": round(pts[pts.len() - 1]),
            "length": (length * 1e9).round() / 1e9,
            "closed": pts.len() > 2 && len(sub(pts[0], pts[pts.len() - 1])) < tol * 1e-3,
            "faces": faces,
            "convex": Value::Null,
            "angle_deg": Value::Null,
        });
        if let [f1, f2] = faces[..]
            && f1 != f2
            && let (Some(s1), Some(s2)) = (side_of(&mesh, f1, mid), side_of(&mesh, f2, mid))
        {
            let cos = dot(s1.normal, s2.normal).clamp(-1.0, 1.0);
            let angle = cos.acos().to_degrees();
            // Konvex: jede Fläche liegt hinter der Tangentialebene der anderen (Außennormalen).
            let behind = dot(s2.inward, s1.normal) + dot(s1.inward, s2.normal);
            e["convex"] = json!(behind <= 0.0);
            e["angle_deg"] = json!((angle * 1e6).round() / 1e6);
            e["normals"] = json!([round(s1.normal), round(s2.normal)]);
        }
        out.push(e);
    }
    Ok(json!({"body": b.name, "edges": out}))
}
