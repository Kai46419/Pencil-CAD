//! Blech-Gesamtumfang über die C-ABI (`psk_execute`, `psk_run_script`, …), so wie die
//! Swift-Brücke sie aufruft. Jeder Test arbeitet in eigenen Sitzungen und eigenen Temp-Dateien.

use std::ffi::{CStr, CString};
use std::path::PathBuf;

use pencil_sheet::*;
use serde_json::{Value, json};

/// Kleine Hülle um eine C-Sitzung, wie sie SheetKernel.swift nachbaut.
struct Psk(*mut PskSession);

impl Psk {
    fn new() -> Self {
        let s = psk_session_new();
        assert!(!s.is_null());
        Self(s)
    }

    fn take(raw: *mut std::ffi::c_char) -> Value {
        assert!(!raw.is_null());
        // SAFETY: String aus der Bibliothek, genau einmal freigegeben.
        let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        unsafe { psk_string_free(raw) };
        serde_json::from_str(&text).unwrap()
    }

    /// Roher Umschlag `{"ok":…}`.
    fn call(&self, cmd: &str, params: Value) -> Value {
        let c = CString::new(cmd).unwrap();
        let p = CString::new(params.to_string()).unwrap();
        // SAFETY: gültige Sitzung und Strings.
        Self::take(unsafe { psk_execute(self.0, c.as_ptr(), p.as_ptr()) })
    }

    /// Ergebnis eines Befehls, der gelingen muss.
    fn ok(&self, cmd: &str, params: Value) -> Value {
        let r = self.call(cmd, params.clone());
        assert_eq!(r["ok"], true, "{cmd} {params}: {r}");
        r["result"].clone()
    }

    fn script(&self, script: Value) -> Value {
        let c = CString::new(script.to_string()).unwrap();
        // SAFETY: gültige Sitzung und String.
        Self::take(unsafe { psk_run_script(self.0, c.as_ptr()) })
    }

    fn volume(&self) -> f64 {
        self.ok("inspect.measure", json!({}))["total"]["volume_mm3"].as_f64().unwrap()
    }

    fn bodies(&self) -> Vec<Value> {
        self.ok("psk.bodies", json!({}))["bodies"].as_array().unwrap().clone()
    }

    fn flat(&self) -> Value {
        self.ok("sheet.flat_pattern", json!({}))
    }
}

impl Drop for Psk {
    fn drop(&mut self) {
        // SAFETY: aus psk_session_new, nur hier freigegeben.
        unsafe { psk_session_free(self.0) };
    }
}

fn tmp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("pencil-sheet-tests-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn close(a: f64, b: f64, tol: f64) -> bool {
    (a - b).abs() <= tol * b.abs().max(1.0)
}

/// Blechregel „Stahl 2“: 2 mm, Biegeradius 2 mm, K 0,4, Spalt 0,5 mm.
fn rule(s: &Psk) {
    s.ok(
        "sheet.manage_rules",
        json!({"name": "Stahl 2", "thickness": "2 mm", "bend_radius": "2 mm", "k_factor": 0.4, "gap": "0.5 mm", "active": true}),
    );
}

/// Grundflansch 150 × 100 aus einer geschlossenen Linienkette (wie PencilCAD Skizzen übergibt).
fn base_from_lines(s: &Psk) {
    s.ok("sketch.create", json!({"plane": "XY", "name": "Grund"}));
    s.ok("sketch.line", json!({"points": [[0, 0], [150, 0], [150, 100], [0, 100]], "closed": true}));
    s.ok("sketch.finish", json!({}));
    s.ok("sheet.flange", json!({"type": "base", "sketch": "Grund"}));
}

#[test]
fn version_and_error_envelopes() {
    // SAFETY: statischer String.
    let v = unsafe { CStr::from_ptr(psk_version()) }.to_str().unwrap();
    assert!(v.starts_with("pencil-sheet ") && v.contains("SolidCraft"), "{v}");

    let s = Psk::new();
    let r = s.call("gibt.es.nicht", json!({}));
    assert_eq!(r["ok"], false);
    assert!(r["error"].as_str().unwrap().contains("gibt.es.nicht"), "{r}");
    let r = s.call("psk.nichts", json!({}));
    assert_eq!(r["ok"], false, "{r}");

    // Ungültiges JSON, NULL-Parameter und NULL-Sitzung.
    let c = CString::new("psk.bodies").unwrap();
    let bad = CString::new("{kaputt").unwrap();
    let r = Psk::take(unsafe { psk_execute(s.0, c.as_ptr(), bad.as_ptr()) });
    assert_eq!(r["ok"], false);
    let r = Psk::take(unsafe { psk_execute(s.0, c.as_ptr(), std::ptr::null()) });
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["result"]["bodies"], json!([]));
    let r = Psk::take(unsafe { psk_execute(std::ptr::null_mut(), c.as_ptr(), std::ptr::null()) });
    assert_eq!(r["ok"], false);
    unsafe {
        psk_string_free(std::ptr::null_mut());
        psk_session_free(std::ptr::null_mut());
    }
    assert_eq!(unsafe { psk_restore(std::ptr::null_mut(), 1) }, -1);
    assert_eq!(unsafe { psk_restore(s.0, 9999) }, -2);

    // Blechbefehl ohne Blechkörper: sauberer Fehler, kein Absturz.
    let r = s.call("sheet.flat_pattern", json!({}));
    assert_eq!(r["ok"], false);
    assert!(r["error"].as_str().unwrap().contains("sheet metal"), "{r}");
}

#[test]
fn rules_base_flange_from_lines_and_bodies() {
    let s = Psk::new();
    rule(&s);
    let rules = s.ok("sheet.rules", json!({}));
    assert_eq!(rules["active"], "Stahl 2", "{rules}");
    base_from_lines(&s);
    assert!(close(s.volume(), 150.0 * 100.0 * 2.0, 1e-9), "{}", s.volume());
    let bodies = s.bodies();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["sheet"], true);
    assert_eq!(bodies[0]["unfolded"], false);
    assert_eq!(bodies[0]["thickness"], 2.0);

    // `flip` im Grundflansch: Dicke gegen die Ebenennormale (z = -2 … 0).
    let f = Psk::new();
    rule(&f);
    f.ok("sketch.create", json!({"plane": "XY", "name": "Grund"}));
    f.ok("sketch.rectangle.two_point", json!({"p0": [0, 0], "p1": [50, 30]}));
    f.ok("sketch.finish", json!({}));
    f.ok("sheet.flange", json!({"sketch": "Grund", "flip": true}));
    let bb = &f.ok("inspect.measure", json!({}))["bodies"][0]["bbox"];
    assert!((bb["min"][2].as_f64().unwrap() + 2.0).abs() < 1e-9 && bb["max"][2].as_f64().unwrap().abs() < 1e-9, "{bb}");
}

#[test]
fn edge_flange_hem_unfold_refold_flat_pattern_dxf_csv() {
    let s = Psk::new();
    rule(&s);
    base_from_lines(&s);
    let plate = s.volume();

    // Kantenflansch an der vorderen Oberkante (y = 0, z = Dicke).
    s.ok("sheet.flange", json!({"edges": [[75, 0, 2]], "height": 30, "angle": "90 deg"}));
    let flanged = s.volume();
    assert!(flanged > plate * 1.1, "{flanged}");

    // Umkantung an der Oberkante des Flansches.
    let edges = s.ok("psk.edges", json!({"body": s.bodies()[0]["name"]}));
    let top = edges["edges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["a"][2].as_f64().unwrap() > 29.0 && e["b"][2].as_f64().unwrap() > 29.0 && e["length"].as_f64().unwrap() > 100.0)
        .map(|e| e["mid"].clone())
        .next()
        .expect("Oberkante des Flansches");
    s.ok("sheet.hem", json!({"edges": [top], "length": 8}));
    let hemmed = s.volume();
    assert!(hemmed > flanged, "{hemmed} > {flanged}");

    // Flachmuster: zwei Biegungen (90° und 180°).
    let f = s.flat();
    let bends = f["bends"].as_array().unwrap();
    assert_eq!(bends.len(), 2, "{f}");
    assert!(bends.iter().any(|b| close(b["angle_deg"].as_f64().unwrap(), 180.0, 1e-9)), "{f}");
    let size = f["flat_size_mm"].as_array().unwrap();
    assert!(size[1].as_f64().unwrap() > 100.0 + 30.0, "{f}");

    // Entfalten und wieder falten. Abgewickelt ist die Biegezone so lang wie die neutrale Faser
    // beim K-Faktor (0,4 statt 0,5), daher weicht das Volumen leicht ab (< 1 %).
    s.ok("sheet.unfold", json!({}));
    assert_eq!(s.bodies()[0]["unfolded"], true);
    assert!(close(s.volume(), hemmed, 1e-2), "{} vs {hemmed}", s.volume());
    s.ok("sheet.refold", json!({}));
    assert_eq!(s.bodies()[0]["unfolded"], false);
    assert!(close(s.volume(), hemmed, 1e-6), "{} vs {hemmed}", s.volume());

    // DXF als Text und als Datei.
    let dxf = s.ok("sheet.export_dxf", json!({"bend_notes": true}));
    let text = dxf["dxf"].as_str().unwrap();
    assert!(text.contains("OUTLINE") && text.contains("BEND_"), "DXF ohne Ebenen");
    let path = tmp("abwicklung.dxf");
    s.ok("sheet.export_dxf", json!({"path": path.to_string_lossy()}));
    let on_disk = std::fs::read_to_string(&path).unwrap();
    assert!(on_disk.contains("OUTLINE") && on_disk.trim_end().ends_with("EOF"));

    // Biegetabelle als CSV.
    let csv = s.ok("sheet.export_bend_table", json!({"format": "csv"}));
    assert_eq!(csv["bends"], 2, "{csv}");
    let csv_text = csv["text"].as_str().unwrap();
    assert!(csv_text.starts_with("body,rule,thickness_mm,k_factor,bend,angle_deg"), "{csv}");
    assert_eq!(csv_text.lines().count(), 3, "Kopf + 2 Biegungen: {csv}");
    let csv_path = tmp("biegungen.csv");
    s.ok("sheet.export_bend_table", json!({"format": "csv", "path": csv_path.to_string_lossy()}));
    assert!(std::fs::read_to_string(&csv_path).unwrap().lines().count() >= 3);
}

#[test]
fn contour_flange_from_open_chain() {
    let s = Psk::new();
    rule(&s);
    // Skizze auf der XZ-Ebene (y nach unten = -Z wie in SolidCrafts Orakel 72).
    s.ok("sketch.create", json!({"plane": {"origin": [0, 0, 0], "x_dir": [1, 0, 0], "y_dir": [0, 0, -1]}, "name": "Kontur"}));
    s.ok("sketch.line", json!({"points": [[0, 0], [40, 0], [40, -30], [70, -30]], "ids": ["l1", "l2", "l3"]}));
    s.ok("sketch.finish", json!({}));
    s.ok("sheet.flange", json!({"type": "contour", "sketch": "Kontur", "curves": ["l1", "l2", "l3"], "distance": 50}));
    let b = s.bodies();
    assert_eq!(b.len(), 1);
    assert_eq!(b[0]["sheet"], true);
    let f = s.flat();
    assert_eq!(f["bends"].as_array().unwrap().len(), 2, "{f}");
    // Gestreckte Länge ≈ 40 + 30 + 30 abzüglich Rückschnitt + Biegezugaben: zwischen 90 und 100.
    let flat_len = f["flat_size_mm"][0].as_f64().unwrap();
    assert!(flat_len > 90.0 && flat_len < 100.0, "{f}");
}

#[test]
fn path_flange_and_fold() {
    // Pfadflansch: Wandhalter (Grundflansch + Wand), Pfad quer über die Wandoberkante.
    let s = Psk::new();
    rule(&s);
    base_from_lines(&s);
    s.ok("sheet.flange", json!({"edges": [[0, 50, 2]], "height": 40}));
    let a = 40.0 / 2f64.sqrt();
    s.ok("sketch.create", json!({"plane": {"origin": [0, 0, 20], "x_dir": [1, 0, 0], "y_dir": [0, 1, 0]}, "name": "Pfad"}));
    s.ok("sketch.line", json!({"points": [[0, 0], [a, -a], [a + 80.0, -a]], "ids": ["p1", "p2"]}));
    s.ok("sketch.finish", json!({}));
    let before = s.volume();
    s.ok("sheet.path_flange", json!({"edge": [1, 0, 20], "sketch": "Pfad", "curves": ["p1", "p2"]}));
    assert_eq!(s.bodies().len(), 1, "der Pfadflansch gehört zum Blech");
    assert!(s.volume() > before);
    assert_eq!(s.flat()["bends"].as_array().unwrap().len(), 3);

    // Falten entlang einer Linie quer über eine ebene Platte.
    let f = Psk::new();
    rule(&f);
    base_from_lines(&f);
    let plate = f.volume();
    f.ok("sheet.fold", json!({"points": [[100, 0, 2], [100, 100, 2]], "angle": "90 deg"}));
    let fp = f.flat();
    assert_eq!(fp["bends"].as_array().unwrap().len(), 1, "{fp}");
    // Falten verbraucht kein Material: Flachmaß bleibt 150 × 100.
    assert!(close(fp["flat_size_mm"][0].as_f64().unwrap(), 150.0, 1e-6), "{fp}");
    // Gefaltet: Biegezone mit neutraler Faser in der Mitte statt beim K-Faktor (< 1 % mehr).
    assert!(close(f.volume(), plate, 1e-2), "{} vs {plate}", f.volume());
}

#[test]
fn perforate_shows_in_flat_pattern_and_dxf() {
    let s = Psk::new();
    rule(&s);
    base_from_lines(&s);
    s.ok("sheet.perforate", json!({"diameter": "3", "pitch": "6", "margin": "5", "pattern": "square"}));
    let f = s.flat();
    let count = f["perforations"][0]["count"].as_u64().unwrap();
    assert!(count > 100, "{}", f["perforations"]);
    let dxf = s.ok("sheet.export_dxf", json!({}))["dxf"].as_str().unwrap().to_owned();
    assert!(dxf.contains("PERFORATION"));

    // Lochmitten im Flachmuster-Koordinatensystem: so viele wie `count`, alle mit Rand auf der Tafel.
    let body = s.bodies()[0]["name"].as_str().unwrap().to_owned();
    let h = s.ok("psk.perforation_holes", json!({"body": body}));
    assert_eq!(h["count"].as_u64(), Some(count), "{}", h["count"]);
    assert_eq!(h["truncated"], false);
    let holes = h["holes"].as_array().unwrap();
    assert_eq!(holes.len() as u64, count);
    for hole in holes {
        let (x, y) = (hole["center"][0].as_f64().unwrap(), hole["center"][1].as_f64().unwrap());
        assert_eq!(hole["radius"], 1.5);
        assert!(x >= 5.0 + 1.5 - 1e-9 && x <= 150.0 - 6.5 + 1e-9 && y >= 6.5 - 1e-9 && y <= 100.0 - 6.5 + 1e-9, "{hole}");
    }
    // Quadratisches Raster mit Teilung 6.
    let (a, b) = (&holes[0]["center"], &holes[1]["center"]);
    let d = (a[0].as_f64().unwrap() - b[0].as_f64().unwrap()).hypot(a[1].as_f64().unwrap() - b[1].as_f64().unwrap());
    assert!((d - 6.0).abs() < 1e-9, "{a} {b}");
    // Ohne `body`: letzter Blechkörper; Nicht-Blech: Fehler; ohne Perforation: leer.
    assert_eq!(s.ok("psk.perforation_holes", json!({}))["count"].as_u64(), Some(count));
    assert_eq!(s.call("psk.perforation_holes", json!({"body": "gibtsnicht"}))["ok"], false);
    let plain = Psk::new();
    rule(&plain);
    base_from_lines(&plain);
    assert_eq!(plain.ok("psk.perforation_holes", json!({}))["holes"], json!([]));
    assert!(s.volume() < 150.0 * 100.0 * 2.0);
}

/// „In Blech umwandeln“: ein geschalter Kasten (oben offen) aus einer Sitzung als STEP
/// hinaus, in eine frische Sitzung hinein, Bodenkanten über psk.edges wählen, umwandeln.
#[test]
fn convert_imported_box_to_sheet_metal() {
    let src = Psk::new();
    src.ok("solid.box", json!({"length": 100, "width": 60, "height": 30, "body_name": "Kasten"}));
    src.ok("solid.shell", json!({"faces": [[50, 30, 30]], "thickness": 2}));
    let step = tmp("kasten.step");
    let out = src.ok("psk.export_step", json!({"body": "Kasten", "path": step.to_string_lossy()}));
    assert!(out["bytes"].as_u64().unwrap() > 1000, "{out}");
    let shell_volume = src.volume();

    let s = Psk::new();
    rule(&s);
    let imported = s.ok("psk.import_step", json!({"path": step.to_string_lossy(), "name": "Kasten"}));
    let names = imported["bodies"].as_array().unwrap().clone();
    assert_eq!(names.len(), 1, "{imported}");
    let body = names[0].as_str().unwrap().to_owned();
    assert!(close(s.volume(), shell_volume, 1e-6), "STEP-Rundlauf exakt: {} vs {shell_volume}", s.volume());

    // Außen-Bodenkanten: konvex, 90°, auf z = 0, am Rand.
    let edges = s.ok("psk.edges", json!({"body": body}));
    let all = edges["edges"].as_array().unwrap();
    assert!(all.iter().all(|e| e["faces"].as_array().unwrap().len() == 2), "geschlossener Körper");
    let bottom: Vec<Value> = all
        .iter()
        .filter(|e| {
            let m = &e["mid"];
            let (x, y, z) = (m[0].as_f64().unwrap(), m[1].as_f64().unwrap(), m[2].as_f64().unwrap());
            z.abs() < 1e-6 && (x.abs() < 1e-6 || (x - 100.0).abs() < 1e-6 || y.abs() < 1e-6 || (y - 60.0).abs() < 1e-6)
        })
        .cloned()
        .collect();
    assert_eq!(bottom.len(), 4, "{bottom:?}");
    for e in &bottom {
        assert_eq!(e["convex"], true, "{e}");
        assert!(close(e["angle_deg"].as_f64().unwrap(), 90.0, 1e-6), "{e}");
    }
    // Innenkanten oben am Boden (z = 2) sind konkav.
    assert!(
        all.iter().any(|e| (e["mid"][2].as_f64().unwrap() - 2.0).abs() < 1e-6 && e["convex"] == false),
        "konkave Innenkante fehlt"
    );
    let bends: Vec<Value> = bottom.iter().map(|e| e["mid"].clone()).collect();
    let r = s.ok("sheet.convert", json!({"body": body, "face": [50, 30, 0], "bends": bends}));
    assert!(r.get("warning").is_none_or(Value::is_null), "{r}");
    let b = s.bodies();
    assert!(b.iter().any(|x| x["sheet"] == true), "{b:?}");
    let f = s.flat();
    assert_eq!(f["bends"].as_array().unwrap().len(), 4, "{f}");
    assert!(close(f["thickness"].as_f64().unwrap(), 2.0, 1e-9));
    // Die Wände öffnen sich an den Ecken (Spalt der Regel): Abwicklung ist ein Kreuz.
    let size = f["flat_size_mm"].as_array().unwrap();
    assert!(size[0].as_f64().unwrap() > 140.0 && size[1].as_f64().unwrap() > 100.0, "{f}");
    let dxf = s.ok("sheet.export_dxf", json!({}))["dxf"].as_str().unwrap().to_owned();
    assert!(dxf.contains("BEND_UP"));
}

/// Exakter STEP-Rundlauf eines Blechkörpers: Volumen, Flächen und Kanten bleiben gleich.
#[test]
fn export_step_round_trip_of_a_sheet_body() {
    let s = Psk::new();
    rule(&s);
    base_from_lines(&s);
    s.ok("sheet.flange", json!({"edges": [[75, 0, 2], [75, 100, 2]], "height": 25}));
    let name = s.bodies()[0]["name"].as_str().unwrap().to_owned();
    let volume = s.volume();
    let measure = s.ok("inspect.measure", json!({}))["total"].clone();
    let path = tmp("blech.step");
    s.ok("psk.export_step", json!({"body": name, "path": path.to_string_lossy()}));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.starts_with("ISO-10303-21;"));
    assert!(text.contains("CYLINDRICAL_SURFACE"), "Biegungen exakt als Zylinder");

    let t = Psk::new();
    let names = t.ok("psk.import_step", json!({"path": path.to_string_lossy()}))["bodies"].clone();
    let back = names[0].as_str().unwrap();
    assert!(close(t.volume(), volume, 1e-6), "{} vs {volume}", t.volume());
    let back_measure = t.ok("inspect.measure", json!({}))["total"].clone();
    assert!(close(back_measure["area_mm2"].as_f64().unwrap(), measure["area_mm2"].as_f64().unwrap(), 1e-6), "{back_measure} vs {measure}");
    // SolidCraft teilt Blechflächen intern an den Panelgrenzen; der STEP-Schreiber fasst
    // koplanare Stücke zusammen. Gleiche Geometrie, also höchstens so viele Flächen.
    assert!(back_measure["faces"].as_u64().unwrap() <= measure["faces"].as_u64().unwrap(), "{back_measure} vs {measure}");
    assert!(!t.ok("psk.edges", json!({"body": back}))["edges"].as_array().unwrap().is_empty());
    assert_eq!(t.bodies()[0]["sheet"], false, "importiert ist es ein normaler Körper");
    // Fehlerfälle.
    assert_eq!(s.call("psk.export_step", json!({"body": "gibtsnicht", "path": path.to_string_lossy()}))["ok"], false);
    assert_eq!(s.call("psk.import_step", json!({"path": "/gibt/es/nicht.step"}))["ok"], false);
}

/// Skizze auf einer freien Ebene (Ursprung + Normale + x-Achse aus PencilCAD): y = n × x.
#[test]
fn sketch_on_free_plane() {
    let s = Psk::new();
    rule(&s);
    // Ebene 30° um die x-Achse gekippt, Ursprung (10, 20, 5).
    let (sin, cos) = (30f64.to_radians().sin(), 30f64.to_radians().cos());
    let origin = [10.0, 20.0, 5.0];
    let normal = [0.0, -sin, cos];
    let x = [1.0, 0.0, 0.0];
    let y = [normal[1] * x[2] - normal[2] * x[1], normal[2] * x[0] - normal[0] * x[2], normal[0] * x[1] - normal[1] * x[0]];
    let r = s.ok("sketch.create", json!({"plane": {"origin": origin, "x_dir": x, "y_dir": y}, "name": "Schräg"}));
    assert!(r.is_object());
    s.ok("sketch.line", json!({"points": [[0, 0], [80, 0], [80, 40], [0, 40]], "closed": true}));
    s.ok("sketch.finish", json!({}));
    s.ok("sheet.flange", json!({"sketch": "Schräg"}));
    assert!(close(s.volume(), 80.0 * 40.0 * 2.0, 1e-9));
    // Die Platte liegt auf der Ebene und wächst entlang der Normale.
    let m = s.ok("inspect.measure", json!({}));
    let c = &m["bodies"][0]["center_of_mass"];
    let c = [c[0].as_f64().unwrap(), c[1].as_f64().unwrap(), c[2].as_f64().unwrap()];
    let want = [0, 1, 2].map(|i| origin[i] + 40.0 * x[i] + 20.0 * y[i] + 1.0 * normal[i]);
    for i in 0..3 {
        assert!((c[i] - want[i]).abs() < 1e-6, "Schwerpunkt {c:?} statt {want:?}");
    }
    // Ein Kantenflansch auf dieser schrägen Platte geht ebenso.
    let edge = [0, 1, 2].map(|i| origin[i] + 40.0 * x[i] + 2.0 * normal[i]);
    s.ok("sheet.flange", json!({"edges": [edge], "height": 20}));
    assert_eq!(s.flat()["bends"].as_array().unwrap().len(), 1);
}

#[test]
fn script_checkpoint_and_restore() {
    let s = Psk::new();
    let r = s.script(json!({"commands": [
        {"command": "sheet.manage_rules", "params": {"name": "Alu 1.5", "thickness": "1.5 mm", "bend_radius": "1.5 mm", "k_factor": 0.44, "active": true}},
        {"command": "sketch.create", "params": {"plane": "XY", "name": "Base"}},
        {"command": "sketch.rectangle.two_point", "params": {"p0": [0, 0], "p1": [80, 50]}},
        {"command": "sketch.finish", "params": {}},
        {"command": "sheet.flange", "params": {"type": "base"}},
        {"command": "psk.bodies"}
    ]}));
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["results"].as_array().unwrap().len(), 6);
    assert_eq!(r["results"][5]["bodies"][0]["sheet"], true);
    let plate = s.volume();

    // Vorschau: sichern, Flansch probieren, zurück.
    let cp = unsafe { psk_checkpoint(s.0) };
    s.ok("sheet.flange", json!({"edges": [[40, 0, 1.5]], "height": 20}));
    assert!(s.volume() > plate);
    assert_eq!(unsafe { psk_restore(s.0, cp) }, 0);
    assert!(close(s.volume(), plate, 1e-12));
    assert_eq!(unsafe { psk_restore(s.0, cp) }, -2, "verbraucht");

    // Fehler im Skript: Index des fehlerhaften Befehls.
    let r = s.script(json!({"commands": [
        {"command": "psk.bodies", "params": {}},
        {"command": "sheet.flange", "params": {"edges": [[40, 0, 1.5]], "height": "20 deg"}}
    ]}));
    assert_eq!(r["ok"], false, "{r}");
    assert_eq!(r["index"], 1);
    let r = s.script(json!({"kein": "skript"}));
    assert_eq!(r["ok"], false);
}

/// Profil wie aus einer PencilCAD-Skizze: Linien + Bogen (Kontur) und ein Kreis (Loch), auf
/// der YZ-Ebene als freie Ebene übergeben. Das Loch wird Ausschnitt im Flachmuster und Kreis im DXF.
#[test]
fn base_flange_with_arc_and_hole_on_free_plane() {
    let s = Psk::new();
    rule(&s);
    // Ursprung (5,0,0), Normale +X, x-Achse +Y → y-Achse = n × x = +Z.
    s.ok("sketch.create", json!({"plane": {"origin": [5, 0, 0], "x_dir": [0, 1, 0], "y_dir": [0, 0, 1]}, "name": "Lasche"}));
    s.ok("sketch.line", json!({"points": [[60, 0], [0, 0], [0, 40], [60, 40]], "ids": ["u", "l", "o"]}));
    // Halbkreis rechts von (60,40) über (80,20) nach (60,0), Mittelpunkt (60,20).
    s.ok("sketch.arc.center_point", json!({"center": [60, 20], "start": [60, 0], "end": [60, 40]}));
    s.ok("sketch.circle.center", json!({"center": [60, 20], "radius": 6}));
    s.ok("sketch.finish", json!({}));
    s.ok("sheet.flange", json!({"sketch": "Lasche", "profiles": [{"point": [10, 10]}]}));
    let area = 60.0 * 40.0 + std::f64::consts::PI * 20.0 * 20.0 / 2.0 - std::f64::consts::PI * 36.0;
    assert!(close(s.volume(), area * 2.0, 1e-3), "{} vs {}", s.volume(), area * 2.0);
    let f = s.flat();
    let circles: Vec<&Value> = f["cutout_shapes"].as_array().unwrap().iter().filter_map(|c| c.get("circle")).collect();
    assert_eq!(circles.len(), 1, "{f}");
    assert!(close(circles[0]["radius"].as_f64().unwrap(), 6.0, 1e-9));
    let dxf = s.ok("sheet.export_dxf", json!({}))["dxf"].as_str().unwrap().to_owned();
    assert!(dxf.contains("CIRCLE") && dxf.contains("ARC"), "Kreis und Bogen exakt im DXF");
    // Die Platte liegt bei x = 5 … 7 (Dicke entlang der Normale +X).
    let bb = &s.ok("inspect.measure", json!({}))["bodies"][0]["bbox"];
    assert!((bb["min"][0].as_f64().unwrap() - 5.0).abs() < 1e-9 && (bb["max"][0].as_f64().unwrap() - 7.0).abs() < 1e-9, "{bb}");
}
