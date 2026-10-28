#!/usr/bin/env bash
# Baut das Blechmodul (SheetKit, Rust-Crate pencil-sheet über die SolidCraft-Engine) als
# statische Bibliothek für iPad (Gerät + Simulator, arm64) und packt sie mit Header nach
# Vendor/PencilSheet.xcframework.
#
# Voraussetzungen: Xcode (xcodebuild, Command Line Tools), Internet beim ersten Lauf
# (rustup, Rust-Ziele, Cargo-Abhängigkeiten inkl. SolidCraft von GitHub).
# Fehlt rustup, wird es ohne Rückfrage installiert (nur im Benutzerverzeichnis, ~/.cargo).
# Mehrfach ausführbar: vorhandene Werkzeuge/Ziele werden übersprungen, Cargo baut inkrementell,
# das xcframework wird jedes Mal frisch erzeugt.
set -euo pipefail

DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-17.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/SheetKit"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/build/sheetkit-target}"
OUT="$ROOT/Vendor/PencilSheet.xcframework"
LIB="libpencil_sheet.a"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim)

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Dieses Skript läuft nur auf macOS (Xcode wird gebraucht)."
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild fehlt – Xcode installieren und einmal starten."
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail "iOS-SDK nicht gefunden – in Xcode die iOS-Plattform installieren (xcode-select -p prüfen)."

# --- Rust ----------------------------------------------------------------------------------
# rustup legt cargo/rustc nach ~/.cargo/bin; das gilt auch, wenn die Shell es noch nicht kennt.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
if ! command -v rustup >/dev/null 2>&1; then
  say "rustup fehlt – installiere Rust (rustup.rs) ins Benutzerverzeichnis …"
  curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || fail "cargo nicht gefunden, obwohl rustup installiert ist (PATH: ~/.cargo/bin?)."

# SolidCraft braucht Rust ≥ 1.95 (Edition 2024). Eine ältere stabile Toolchain aktualisieren.
need_minor=95
have_minor="$(rustc --version | sed -E 's/^rustc 1\.([0-9]+).*/\1/')"
if [ "${have_minor:-0}" -lt "$need_minor" ]; then
  say "Rust $(rustc --version | cut -d' ' -f2) ist zu alt (mindestens 1.$need_minor) – aktualisiere stable …"
  rustup update stable
  rustup default stable
fi

installed="$(rustup target list --installed)"
for t in "${TARGETS[@]}"; do
  if ! grep -qx "$t" <<<"$installed"; then
    say "Rust-Ziel $t hinzufügen …"
    rustup target add "$t"
  fi
done

# --- Bauen ---------------------------------------------------------------------------------
export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
for t in "${TARGETS[@]}"; do
  say "Baue pencil-sheet für $t (Release; der erste Lauf dauert einige Minuten) …"
  # `cargo rustc --crate-type staticlib` statt `cargo build`: mit dem rlib-Typ daneben fiele das
  # LTO für die statische Bibliothek weg (Linux-Messung: ~600 MB statt ~76 MB).
  cargo rustc --manifest-path "$CRATE/Cargo.toml" --release --locked --lib --crate-type staticlib \
    --target "$t" --target-dir "$TARGET_DIR"
  [ -f "$TARGET_DIR/$t/release/$LIB" ] || fail "$LIB für $t wurde nicht erzeugt."
done

# --- xcframework ---------------------------------------------------------------------------
say "Packe $OUT …"
HEADERS="$TARGET_DIR/xcframework-headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$CRATE/include/pencil_sheet.h" "$CRATE/include/module.modulemap" "$HEADERS/"

rm -rf "$OUT"
mkdir -p "$ROOT/Vendor"
args=()
for t in "${TARGETS[@]}"; do
  args+=(-library "$TARGET_DIR/$t/release/$LIB" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" >/dev/null

size_dev="$(du -h "$TARGET_DIR/aarch64-apple-ios/release/$LIB" | cut -f1)"
say "Fertig: $OUT (Gerätebibliothek $size_dev, Version $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))."
echo "Als Nächstes: ./scripts/generate-project.sh ausführen, damit das Xcode-Projekt das Blechmodul einbindet."
