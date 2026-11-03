//! PencilCAD SheetKit: das Blechmodul der SolidCraft-Engine hinter einer schmalen C-ABI.
//!
//! Vertrag: `SheetKit/API.md`, Header: `SheetKit/include/pencil_sheet.h`. Jede Funktion, die
//! JSON liefert, gibt einen mit `psk_string_free` freizugebenden String zurück – auch im
//! Fehlerfall (`{"ok":false,"error":"…"}`). Panics der Engine werden an der Grenze abgefangen
//! und ebenfalls als Fehler-JSON gemeldet, damit die App nie durch einen Rust-Panic abstürzt.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::{Value, json};
use solidcraft_engine::Session;

mod psk;

pub use psk::execute;

/// SolidCraft-Commit, gegen den gebaut wird (muss zu `rev` in Cargo.toml passen).
pub const SOLIDCRAFT_REV: &str = "98b57a3588170ec1a1c7acc91b4bf8a60ea29865";

/// Undurchsichtiger Sitzungs-Griff für C/Swift. Eine Sitzung ist nicht threadsicher: Swift
/// ruft sie immer nur von einer Queue aus auf.
pub struct PskSession {
    session: Session,
}

impl PskSession {
    /// Neue leere SolidCraft-Sitzung (Einheiten mm, Winkel Grad).
    pub fn new() -> Self {
        Self { session: Session::default() }
    }

    /// Ein Befehl (`sheet.*`, `sketch.*`, … oder `psk.*`), Ergebnis im Antwort-Umschlag.
    pub fn execute_json(&mut self, command: &str, params: &Value) -> Value {
        match guarded(|| execute(&mut self.session, command, params)) {
            Ok(v) => json!({"ok": true, "result": v}),
            Err(e) => json!({"ok": false, "error": e}),
        }
    }

    /// Ein Skript `{"commands":[{"command","params"}…]}`. Bricht beim ersten Fehler ab; die
    /// Befehle davor bleiben angewendet (wer das nicht will, sichert vorher mit `checkpoint`).
    pub fn run_script_json(&mut self, script: &Value) -> Value {
        let Some(commands) = script.get("commands").and_then(Value::as_array) else {
            return json!({"ok": false, "error": "Skript braucht {\"commands\":[…]}", "index": 0});
        };
        let mut results = Vec::with_capacity(commands.len());
        for (i, c) in commands.iter().enumerate() {
            let Some(id) = c.get("command").and_then(Value::as_str) else {
                return json!({"ok": false, "error": format!("Befehl {i} hat kein Feld \"command\""), "index": i});
            };
            let params = c.get("params").cloned().unwrap_or_else(|| json!({}));
            match guarded(|| execute(&mut self.session, id, &params)) {
                Ok(v) => results.push(v),
                // SolidCrafts Fehlertexte nennen den Befehl schon; der Index steht in `index`.
                Err(e) => return json!({"ok": false, "error": e, "index": i}),
            }
        }
        json!({"ok": true, "results": results})
    }

    pub fn checkpoint(&mut self) -> u64 {
        self.session.checkpoint()
    }

    pub fn restore(&mut self, id: u64) -> Result<(), String> {
        guarded(|| self.session.restore_checkpoint(id).map_err(|e| e.to_string()))
    }

    /// Direkter Zugriff für Rust-Tests.
    pub fn session(&mut self) -> &mut Session {
        &mut self.session
    }
}

impl Default for PskSession {
    fn default() -> Self {
        Self::new()
    }
}

/// Führt `f` aus und macht aus einem Panic einen Fehlertext.
fn guarded<T>(f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(payload) => {
            let msg = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unbekannter Fehler".into());
            Err(format!("interner Fehler im Blechkern: {msg}"))
        }
    }
}

// ---------------------------------------------------------------------------------------------
// C-ABI
// ---------------------------------------------------------------------------------------------

/// JSON als C-String (Besitz geht an den Aufrufer, freigeben mit `psk_string_free`).
fn to_c(v: &Value) -> *mut c_char {
    // serde_json schreibt nie ein NUL-Byte (Steuerzeichen werden escaped).
    CString::new(v.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn err_c(msg: impl Into<String>) -> *mut c_char {
    to_c(&json!({"ok": false, "error": msg.into()}))
}

/// C-String lesen; `None` bei NULL, Fehlertext bei ungültigem UTF-8.
///
/// # Safety
/// `p` ist NULL oder zeigt auf einen gültigen, NUL-terminierten String.
unsafe fn read_c<'a>(p: *const c_char) -> Result<Option<&'a str>, String> {
    if p.is_null() {
        return Ok(None);
    }
    // SAFETY: vom Aufrufer zugesichert.
    let s = unsafe { CStr::from_ptr(p) };
    s.to_str().map(Some).map_err(|_| "Text ist kein gültiges UTF-8".to_string())
}

/// Leere SolidCraft-Sitzung (Einheiten mm). Nie NULL (außer bei Panic im Aufbau).
#[unsafe(no_mangle)]
pub extern "C" fn psk_session_new() -> *mut PskSession {
    match catch_unwind(PskSession::new) {
        Ok(s) => Box::into_raw(Box::new(s)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Sitzung freigeben (NULL ist erlaubt).
///
/// # Safety
/// `s` stammt aus `psk_session_new` und wird danach nicht mehr benutzt.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn psk_session_free(s: *mut PskSession) {
    if !s.is_null() {
        // SAFETY: vom Aufrufer zugesichert; Panic im Drop wird verschluckt.
        let b = unsafe { Box::from_raw(s) };
        let _ = catch_unwind(AssertUnwindSafe(move || drop(b)));
    }
}

/// Ein Befehl mit JSON-Parametern (NULL = `{}`).
///
/// # Safety
/// `s` aus `psk_session_new`; `command`/`params_json` NULL oder gültige C-Strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn psk_execute(s: *mut PskSession, command: *const c_char, params_json: *const c_char) -> *mut c_char {
    // SAFETY: vom Aufrufer zugesichert.
    let Some(session) = (unsafe { s.as_mut() }) else { return err_c("keine Sitzung") };
    // SAFETY: vom Aufrufer zugesichert.
    let command = match unsafe { read_c(command) } {
        Ok(Some(c)) => c,
        Ok(None) => return err_c("kein Befehl angegeben"),
        Err(e) => return err_c(e),
    };
    // SAFETY: vom Aufrufer zugesichert.
    let params = match unsafe { read_c(params_json) } {
        Ok(None) => json!({}),
        Ok(Some(t)) if t.trim().is_empty() => json!({}),
        Ok(Some(t)) => match serde_json::from_str::<Value>(t) {
            Ok(v) => v,
            Err(e) => return err_c(format!("Parameter sind kein gültiges JSON: {e}")),
        },
        Err(e) => return err_c(e),
    };
    to_c(&session.execute_json(command, &params))
}

/// Mehrere Befehle der Reihe nach (`{"commands":[…]}`).
///
/// # Safety
/// Wie `psk_execute`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn psk_run_script(s: *mut PskSession, script_json: *const c_char) -> *mut c_char {
    // SAFETY: vom Aufrufer zugesichert.
    let Some(session) = (unsafe { s.as_mut() }) else { return err_c("keine Sitzung") };
    // SAFETY: vom Aufrufer zugesichert.
    let script = match unsafe { read_c(script_json) } {
        Ok(Some(t)) => match serde_json::from_str::<Value>(t) {
            Ok(v) => v,
            Err(e) => return to_c(&json!({"ok": false, "error": format!("Skript ist kein gültiges JSON: {e}"), "index": 0})),
        },
        Ok(None) => return to_c(&json!({"ok": false, "error": "kein Skript angegeben", "index": 0})),
        Err(e) => return to_c(&json!({"ok": false, "error": e, "index": 0})),
    };
    to_c(&session.run_script_json(&script))
}

/// Zustand sichern; liefert die Kennung für `psk_restore` (0 bei ungültiger Sitzung).
///
/// # Safety
/// `s` aus `psk_session_new` oder NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn psk_checkpoint(s: *mut PskSession) -> u64 {
    // SAFETY: vom Aufrufer zugesichert.
    match unsafe { s.as_mut() } {
        Some(session) => catch_unwind(AssertUnwindSafe(|| session.checkpoint())).unwrap_or(0),
        None => 0,
    }
}

/// Auf einen Checkpoint zurück: 0 = ok, -1 = keine Sitzung, -2 = unbekannter Checkpoint/Fehler.
/// Der Checkpoint und alle späteren sind danach verbraucht.
///
/// # Safety
/// `s` aus `psk_session_new` oder NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn psk_restore(s: *mut PskSession, id: u64) -> i32 {
    // SAFETY: vom Aufrufer zugesichert.
    match unsafe { s.as_mut() } {
        Some(session) => match session.restore(id) {
            Ok(()) => 0,
            Err(_) => -2,
        },
        None => -1,
    }
}

/// Gibt einen von `psk_execute`/`psk_run_script` gelieferten String frei (NULL ist erlaubt).
///
/// # Safety
/// `str` stammt aus dieser Bibliothek und wird nur einmal freigegeben.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn psk_string_free(str: *mut c_char) {
    if !str.is_null() {
        // SAFETY: vom Aufrufer zugesichert.
        drop(unsafe { CString::from_raw(str) });
    }
}

/// Versionstext, statisch (nicht freigeben).
#[unsafe(no_mangle)]
pub extern "C" fn psk_version() -> *const c_char {
    const V: &str = concat!("pencil-sheet ", env!("CARGO_PKG_VERSION"), " (SolidCraft 98b57a3)\0");
    V.as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panics_become_error_text() {
        let r: Result<(), String> = guarded(|| panic!("Testpanik"));
        assert_eq!(r.unwrap_err(), "interner Fehler im Blechkern: Testpanik");
        let r: Result<(), String> = guarded(|| panic!("{}", String::from("formatiert")));
        assert!(r.unwrap_err().ends_with("formatiert"));
        assert_eq!(guarded(|| Ok::<_, String>(7)).unwrap(), 7);
    }
}
