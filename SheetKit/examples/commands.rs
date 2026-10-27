//! Rohliste der SolidCraft-Befehlsdokumentation (genau der eingebundene Commit), zum Abgleich mit
//! der kuratierten Referenz COMMANDS.md. Aufruf: `cargo run --example commands > COMMANDS-RAW.md`
//! NICHT nach COMMANDS.md umleiten – die ist von Hand gepflegt.

use solidcraft_engine::command_specs;

/// Befehlsgruppen, die PencilCAD für das Blechmodul nutzt.
const PREFIXES: &[&str] = &["sheet.", "sketch.", "file.insert_step", "file.export", "model.", "inspect.measure", "solid.box", "solid.shell", "body.rename"];

fn main() {
    println!("# SolidCraft-Befehle für das Blechmodul (Rohliste)\n");
    println!("Automatisch erzeugt aus `solidcraft-engine` (Commit {}) mit", pencil_sheet::SOLIDCRAFT_REV);
    println!("`cargo run --example commands > COMMANDS-RAW.md` – nicht von Hand ändern. Kuratierte Referenz: COMMANDS.md.\n");
    println!("Längen in mm, Winkel in Grad; Ausdrücke wie `\"20 mm\"`, `\"45 deg\"` oder `\"W / 2\"` sind erlaubt,");
    println!("wo die Beschreibung `expr` nennt. Punkte `[x,y,z]` sind Weltkoordinaten. Zusätzlich gibt es die");
    println!("`psk.*`-Befehle aus API.md.\n");
    let mut specs: Vec<_> = command_specs().into_iter().filter(|s| PREFIXES.iter().any(|p| s.id.starts_with(p))).collect();
    specs.sort_by_key(|s| s.id);
    specs.dedup_by_key(|s| s.id);
    for s in specs {
        println!("## `{}` – {}\n", s.id, s.label);
        if s.params.is_empty() {
            println!("(keine Parameter)\n");
        } else {
            println!("{}\n", s.params.replace('\n', " "));
        }
    }
}
