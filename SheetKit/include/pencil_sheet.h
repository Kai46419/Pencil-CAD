/*
 * pencil_sheet.h – C-Schnittstelle des PencilCAD-Blechmoduls (Rust-Crate `pencil-sheet`,
 * SolidCraft-Engine). Vertrag und Befehle: SheetKit/API.md. Handgeschrieben; bei Änderungen
 * an SheetKit/src/lib.rs mitpflegen.
 *
 * Alle Texte sind UTF-8. Jeder zurückgegebene `char *` gehört dem Aufrufer und wird mit
 * psk_string_free freigegeben. Eine Sitzung ist nicht threadsicher (nur von einer Queue aus
 * benutzen); verschiedene Sitzungen dürfen parallel laufen.
 */
#ifndef PENCIL_SHEET_H
#define PENCIL_SHEET_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PskSession PskSession;

/* Leere SolidCraft-Sitzung (Einheiten mm, Winkel Grad). */
PskSession *psk_session_new(void);
/* Sitzung freigeben; NULL ist erlaubt. */
void psk_session_free(PskSession *s);

/* Ein Befehl: command z. B. "sheet.flange" oder "psk.edges", params_json ein JSON-Objekt
 * (NULL = {}). Rückgabe (immer, freigeben mit psk_string_free):
 *   {"ok":true,"result":<JSON des Befehls>}  oder  {"ok":false,"error":"<Text>"} */
char *psk_execute(PskSession *s, const char *command, const char *params_json);

/* Mehrere Befehle der Reihe nach:
 *   script_json = {"commands":[{"command":"…","params":{…}}, …]}
 * Rückgabe {"ok":true,"results":[…]} oder {"ok":false,"error":"…","index":<n>}.
 * Bei einem Fehler bleiben die Befehle vor <n> angewendet. */
char *psk_run_script(PskSession *s, const char *script_json);

/* Zustand sichern / zurücksetzen (Vorschau, solange ein Panel offen ist).
 * psk_restore: 0 = ok, -1 = keine Sitzung, -2 = unbekannter Checkpoint. Der Checkpoint und alle
 * späteren sind nach psk_restore verbraucht. */
uint64_t psk_checkpoint(PskSession *s);
int32_t psk_restore(PskSession *s, uint64_t id);

/* Gibt einen von dieser Bibliothek gelieferten String frei; NULL ist erlaubt. */
void psk_string_free(char *str);
/* Versionstext, statisch (nicht freigeben). */
const char *psk_version(void);

#ifdef __cplusplus
}
#endif

#endif /* PENCIL_SHEET_H */
