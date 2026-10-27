#!/usr/bin/env python3
"""Rendert die SolidCraft-Werkzeug-Icons (MIT, https://github.com/tangency-labs/solidcraft) als
PNG-Imagesets in den Asset-Katalog App/Assets.xcassets/SolidCraft/.

Die Farbauflösung folgt SolidCraft' eigenem Renderer (crates/ui-egui/src/icon_svg.rs):

* Jede SVG-Farbe ist die `source`-Hexfarbe einer Rolle aus palette.toml und wird zum light- bzw.
  dark-Wert der Rolle; `currentColor` ist die Rolle `line`.
* Akzente (sketch, constraint, construction, surface, form, mesh) ersetzen die Rollen, die sie
  in [accents.<name>] auflisten (normal active-1/2/3). Ein Icon bekommt seinen Akzent aus
  [icon-accents] (nach seiner eigenen id), ein Alias aus aliases.toml seinen expliziten Akzent.
  Die Rolle `guide` bleibt immer die Grundfarbe.
* Gestrichelte, sichtbare Linien, die nicht active-*/gap sind, werden zur Rolle `guide`.
* Die Rolle `gap` (#ffffff) ist keine Farbe, sondern ein Knockout: Sie radiert bereits Gezeichnetes
  transparent (tiny-skia BlendMode::DestinationOut). Innerhalb von <mask> gelten nur die
  Literale `white`/`black` als feste Maskenfarben (Luminanzmaske).
* Fehlt `fill`, ist es `none` (nicht Schwarz wie in SVG). Linien sind immer round/round.
* Gruppen-Opazität multipliziert sich in jedes Element, eine Gruppen-Clip-Fläche ersetzt die
  äußere; eine Elementmaske wird mit der aktuellen Clip-Fläche geschnitten.

Gezeichnet wird Element für Element (erst Füllung, dann Kontur) in einem Chromium-Canvas
(Playwright): jede Maloperation geht in eine Zwischenebene (Clip, Maske via destination-in) und
wird dann mit source-over bzw. – für Knockouts – destination-out auf das Icon gesetzt.

Aufruf:
    python3 scripts/render-solidcraft-icons.py --source <solidcraft-repo> [--ids ids.txt]
        [--out App/Assets.xcassets/SolidCraft] [--preview vorschau.png]

Ohne --ids werden alle Master (model, flat, workspace) und alle Aliase erzeugt. Nicht mehr
benötigte sc.*-Imagesets im Ausgabeordner werden gelöscht.
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import shutil
import sys
import tempfile
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

NS = "{http://www.w3.org/2000/svg}"
BASE_PT = 40
SCALES = (2, 3)
# Reihenfolge wie build.rs: model vor flat vor workspace (bei gleicher id gewinnt model).
# "small" sind Varianten für <= 24 px und werden hier nicht gebraucht.
FAMILIES = ("model", "flat", "workspace")


# ------------------------------------------------------------------------------------------------
# Palette


class Palette:
    def __init__(self, path: Path):
        data = tomllib.loads(path.read_text())
        self.roles: dict[str, dict[str, str]] = {}
        for name, role in data["roles"].items():
            self.roles[name] = {
                "source": (role.get("source") or role["light"]).lower(),
                "light": role["light"].lower(),
                "dark": role["dark"].lower(),
            }
        self.accents: dict[str, dict[str, dict[str, str]]] = {}
        for acc, roles_of in data.get("accents", {}).items():
            items = {}
            for role, v in roles_of.items():
                if role not in self.roles:
                    raise SystemExit(f"palette: Akzent {acc} kennt Rolle {role} nicht")
                if "use" in v:
                    v = roles_of[v["use"]]
                items[role] = {"light": v["light"].lower(), "dark": v["dark"].lower()}
            self.accents[acc] = items
        self.icon_accents: dict[str, str] = {}
        for acc, ids in data.get("icon-accents", {}).items():
            for i in ids:
                self.icon_accents[i] = acc

    def role_of_hex(self, hexv: str) -> str | None:
        # Erste Rolle mit dieser source-Farbe (wie ROLE_SOURCE_HEX.position): #34465b -> ink.
        for name, r in self.roles.items():
            if r["source"] == hexv:
                return name
        return None

    def rgb(self, role: str, accent: str | None, dark: bool) -> list[int]:
        theme = "dark" if dark else "light"
        if role == "guide":
            h = self.roles[role][theme]
        elif accent and role in self.accents.get(accent, {}):
            h = self.accents[accent][role][theme]
        else:
            h = self.roles[role][theme]
        return [int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)]


# ------------------------------------------------------------------------------------------------
# SVG -> Zwischenform (wie Doc::parse in icon_svg.rs)


def url_ref(v: str | None) -> str | None:
    if v and v.startswith("url(#") and v.endswith(")"):
        return v[5:-1]
    return None


def parse_paint(v: str | None, in_mask: bool, pal: Palette):
    """None | ("knockout",) | ("role", name) | ("fixed", [r,g,b])"""
    if v is None or v == "none":
        return None
    if v == "currentColor":
        return ("role", "line")
    if in_mask and v == "white":
        return ("fixed", [255, 255, 255])
    if in_mask and v == "black":
        return ("fixed", [0, 0, 0])
    role = pal.role_of_hex(v.lower())
    if role is None:
        raise ValueError(f"Farbe {v} ist keine Palettenfarbe")
    if role == "gap":
        return ("knockout",)
    return ("role", role)


def parse_dash(v: str | None) -> list[float]:
    if not v:
        return []
    d = []
    for part in v.replace(",", " ").split():
        try:
            d.append(float(part))
        except ValueError:
            pass
    if len(d) % 2 == 1:
        d = d + d
    if d and (any(x < 0 for x in d) or sum(d) <= 0):
        return []
    return d


def fnum(v: str | None, default: float) -> float:
    try:
        return float(v) if v is not None else default
    except ValueError:
        return default


def parse_svg(path: Path, pal: Palette) -> dict:
    root = ET.parse(path).getroot()
    masks: list[list[dict]] = []
    clips: list[list[dict]] = []
    mask_ids: dict[str, int] = {}
    clip_ids: dict[str, int] = {}

    # Zuerst alle mask/clipPath-Definitionen einsammeln (Dokumentreihenfolge wie im Original).
    def node_of(el, in_mask: bool) -> dict:
        tag = el.tag[len(NS):]
        n: dict = {}
        if tag == "path":
            n["d"] = el.get("d")
        else:
            n["cx"], n["cy"], n["r"] = float(el.get("cx")), float(el.get("cy")), float(el.get("r"))
        dash = parse_dash(el.get("stroke-dasharray"))
        stroke = parse_paint(el.get("stroke"), in_mask, pal)
        visible = stroke is not None and stroke[0] == "role" and stroke[1] not in ("gap", "active-1", "active-2", "active-3")
        if dash and visible and not in_mask:
            stroke = ("role", "guide")
        if el.get("fill") is None and in_mask:
            fill = None
        else:
            fill = parse_paint(el.get("fill") or "none", in_mask, pal)
        n["fill"] = fill
        n["stroke"] = stroke
        n["rule"] = "evenodd" if el.get("fill-rule") == "evenodd" else "nonzero"
        n["width"] = fnum(el.get("stroke-width"), 1.0)
        n["dash"] = dash
        n["opacity"] = fnum(el.get("opacity"), 1.0)
        m = url_ref(el.get("mask"))
        n["mask"] = None
        if m is not None:
            if m not in mask_ids:
                raise ValueError(f"unbekannte Maske {m}")
            n["mask"] = mask_ids[m]
        return n

    def walk(el, out: list | None):
        for ch in el:
            tag = ch.tag[len(NS):] if ch.tag.startswith(NS) else ch.tag
            if tag in ("title", "desc"):
                continue
            if tag == "defs":
                walk(ch, None)
            elif tag == "mask":
                masks.append([])
                mask_ids[ch.get("id")] = len(masks) - 1
                idx = len(masks) - 1
                for sub in ch:
                    st = sub.tag[len(NS):]
                    if st in ("path", "circle"):
                        masks[idx].append(node_of(sub, True))
                    else:
                        raise ValueError(f"<{st}> in <mask> nicht unterstützt")
            elif tag == "clipPath":
                clips.append([])
                clip_ids[ch.get("id")] = len(clips) - 1
                idx = len(clips) - 1
                for sub in ch:
                    st = sub.tag[len(NS):]
                    if st in ("path", "circle"):
                        clips[idx].append(node_of(sub, False))
                    else:
                        raise ValueError(f"<{st}> in <clipPath> nicht unterstützt")
            elif tag == "g":
                c = url_ref(ch.get("clip-path"))
                if c is not None and c not in clip_ids:
                    raise ValueError(f"unbekannter Clip {c}")
                g = {"group": True, "clip": clip_ids.get(c) if c else None,
                     "opacity": fnum(ch.get("opacity"), 1.0), "items": []}
                walk(ch, g["items"])
                if out is not None:
                    out.append(g)
            elif tag in ("path", "circle"):
                if out is not None:
                    out.append(node_of(ch, False))
            else:
                raise ValueError(f"Element <{tag}> nicht unterstützt")

    items: list = []
    walk(root, items)
    return {"items": items, "masks": masks, "clips": clips}


def resolve_doc(doc: dict, pal: Palette, accent: str | None, dark: bool) -> dict:
    def paint(p):
        if p is None:
            return None
        if p[0] == "knockout":
            return "knockout"
        if p[0] == "fixed":
            return p[1]
        return pal.rgb(p[1], accent, dark)

    def node(n):
        r = dict(n)
        r["fill"] = paint(n["fill"])
        r["stroke"] = paint(n["stroke"])
        return r

    def items(lst):
        out = []
        for it in lst:
            if it.get("group"):
                out.append({**it, "items": items(it["items"])})
            else:
                out.append(node(it))
        return out

    return {
        "items": items(doc["items"]),
        "masks": [[node(n) for n in m] for m in doc["masks"]],
        "clips": doc["clips"],
    }


# ------------------------------------------------------------------------------------------------
# Rendering im Browser-Canvas

RENDER_JS = r"""
(jobs) => jobs.map((job) => {
  const px = job.px, s = px / 64;
  const mk = () => { const c = document.createElement('canvas'); c.width = c.height = px; return c; };
  const main = mk();
  const layer = mk();
  const lctx = layer.getContext('2d', { willReadFrequently: true });
  const geom = (n) => {
    if (n.d != null) return new Path2D(n.d);
    const p = new Path2D();
    p.moveTo(n.cx + n.r, n.cy);
    p.arc(n.cx, n.cy, n.r, 0, 2 * Math.PI);
    p.closePath();
    return p;
  };
  const clips = job.doc.clips.map((nodes) => nodes.map((n) => ({ p: geom(n), rule: n.rule })));
  const applyClip = (ctx, clip) => {
    if (!clip || clip.length === 0) return;
    if (clip.length === 1) { ctx.clip(clip[0].p, clip[0].rule); return; }
    const u = new Path2D();
    for (const c of clip) u.addPath(c.p);
    ctx.clip(u, 'nonzero');
  };
  // Eine Maloperation: Ebene leeren, (Clip) zeichnen, (Maske) anwenden, auf Ziel setzen.
  const op = (target, n, path, which, paint, alpha, clip, maskCanvas) => {
    lctx.save();
    lctx.setTransform(1, 0, 0, 1, 0, 0);
    lctx.globalCompositeOperation = 'source-over';
    lctx.globalAlpha = 1;
    lctx.clearRect(0, 0, px, px);
    lctx.setTransform(s, 0, 0, s, 0, 0);
    applyClip(lctx, clip);
    lctx.globalAlpha = Math.round(Math.min(1, Math.max(0, alpha)) * 255) / 255;
    const col = paint === 'knockout' ? 'rgb(0,0,0)' : `rgb(${paint[0]},${paint[1]},${paint[2]})`;
    if (which === 'fill') {
      lctx.fillStyle = col;
      lctx.fill(path, n.rule);
    } else {
      lctx.strokeStyle = col;
      lctx.lineWidth = n.width;
      lctx.lineCap = 'round';
      lctx.lineJoin = 'round';
      lctx.setLineDash(n.dash || []);
      lctx.lineDashOffset = 0;
      lctx.stroke(path);
    }
    lctx.restore();
    if (maskCanvas) {
      lctx.save();
      lctx.globalCompositeOperation = 'destination-in';
      lctx.drawImage(maskCanvas, 0, 0);
      lctx.restore();
    }
    const t = target.getContext('2d');
    t.save();
    t.globalCompositeOperation = paint === 'knockout' ? 'destination-out' : 'source-over';
    t.drawImage(layer, 0, 0);
    t.restore();
  };
  const luminanceMask = (nodes) => {
    const sub = mk();
    for (const m of nodes) drawNode(sub, m, null, 1.0);
    const d = sub.getContext('2d', { willReadFrequently: true }).getImageData(0, 0, px, px);
    const out = mk();
    const octx = out.getContext('2d');
    const img = octx.createImageData(px, px);
    for (let i = 0; i < d.data.length; i += 4) {
      const luma = (0.2125 * d.data[i] + 0.7154 * d.data[i + 1] + 0.0721 * d.data[i + 2]) / 255;
      img.data[i + 3] = Math.min(255, Math.ceil(luma * d.data[i + 3]));
    }
    octx.putImageData(img, 0, 0);
    return out;
  };
  const drawNode = (target, n, clip, opacity) => {
    const maskCanvas = n.mask != null ? luminanceMask(job.doc.masks[n.mask]) : null;
    const path = geom(n);
    const alpha = n.opacity * opacity;
    if (n.fill != null) op(target, n, path, 'fill', n.fill, alpha, clip, maskCanvas);
    if (n.stroke != null) op(target, n, path, 'stroke', n.stroke, alpha, clip, maskCanvas);
  };
  const drawItems = (items, clip, opacity) => {
    for (const it of items) {
      if (it.group) {
        const c = it.clip != null ? clips[it.clip] : clip;
        drawItems(it.items, c, opacity * it.opacity);
      } else {
        drawNode(main, it, clip, opacity);
      }
    }
  };
  drawItems(job.doc.items, null, 1.0);
  return main.toDataURL('image/png');
})
"""


def contents_json(obj) -> str:
    return json.dumps(obj, indent=2) + "\n"


def imageset_contents(icon_id: str) -> dict:
    images = []
    for scale in SCALES:
        images.append({"filename": f"{icon_id}@{scale}x.png", "idiom": "universal", "scale": f"{scale}x"})
        images.append({
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": f"{icon_id}-dark@{scale}x.png", "idiom": "universal", "scale": f"{scale}x",
        })
    return {
        "images": images,
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "original"},
    }


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, type=Path, help="SolidCraft-Repository")
    ap.add_argument("--ids", type=Path, help="Datei mit einer Icon-id pro Zeile (# = Kommentar)")
    ap.add_argument("--out", type=Path, default=repo / "App/Assets.xcassets/SolidCraft")
    ap.add_argument("--preview", type=Path, help="Kontaktbogen (PNG) aller erzeugten Icons")
    args = ap.parse_args()

    design = args.source / "assets/icons/ui/design"
    pal = Palette(design / "palette.toml")
    aliases_raw = tomllib.loads((design / "aliases.toml").read_text()).get("alias", {})

    masters: dict[str, Path] = {}
    for fam in FAMILIES:
        for f in sorted((design / "svg" / fam).glob("*.svg")):
            masters.setdefault(f.stem, f)

    aliases: dict[str, tuple[str, str | None]] = {}
    for alias, v in aliases_raw.items():
        if isinstance(v, str):
            master, accent = v, None
        else:
            master, accent = v["master"], v.get("accent") or None
        if accent and accent not in pal.accents:
            raise SystemExit(f"Alias {alias}: unbekannter Akzent {accent}")
        if master not in masters:
            print(f"Warnung: Alias {alias} -> unbekannter Master {master}, übersprungen", file=sys.stderr)
            continue
        aliases[alias] = (master, accent or pal.icon_accents.get(alias))

    # id -> (master, accent); Aliase haben Vorrang (wie resolve_master).
    catalog: dict[str, tuple[str, str | None]] = {}
    for mid in sorted(masters):
        catalog[mid] = (mid, pal.icon_accents.get(mid))
    for aid in sorted(aliases):
        catalog[aid] = aliases[aid]

    if args.ids:
        wanted = []
        for line in args.ids.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line and line not in wanted:
                wanted.append(line)
        missing = [w for w in wanted if w not in catalog]
        if missing:
            print("Warnung: unbekannte ids: " + ", ".join(missing), file=sys.stderr)
        selected = [w for w in wanted if w in catalog]
    else:
        selected = list(catalog)

    parsed: dict[str, dict] = {}
    jobs = []
    meta = []
    for icon_id in selected:
        master, accent = catalog[icon_id]
        if master not in parsed:
            try:
                parsed[master] = parse_svg(masters[master], pal)
            except (ValueError, ET.ParseError) as e:
                print(f"Fehler: {master}: {e} – übersprungen", file=sys.stderr)
                continue
        meta.append((icon_id, master, accent))
        for dark in (False, True):
            doc = resolve_doc(parsed[master], pal, accent, dark)
            for scale in SCALES:
                jobs.append({"id": icon_id, "dark": dark, "scale": scale, "px": BASE_PT * scale, "doc": doc})

    from playwright.sync_api import sync_playwright

    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    (out / "Contents.json").write_text(contents_json({
        "info": {"author": "xcode", "version": 1},
        "properties": {"provides-namespace": False},
    }))
    keep = {f"sc.{m[0]}.imageset" for m in meta}
    removed = 0
    for d in out.glob("sc.*.imageset"):
        if d.name not in keep:
            shutil.rmtree(d)
            removed += 1

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.set_content("<!doctype html><html><body></body></html>")
        batch = 64
        for i in range(0, len(jobs), batch):
            chunk = jobs[i:i + batch]
            urls = page.evaluate(RENDER_JS, chunk)
            for job, url in zip(chunk, urls):
                data = base64.b64decode(url.split(",", 1)[1])
                d = out / f"sc.{job['id']}.imageset"
                d.mkdir(exist_ok=True)
                suffix = "-dark" if job["dark"] else ""
                (d / f"{job['id']}{suffix}@{job['scale']}x.png").write_bytes(data)
        for icon_id, _, _ in meta:
            d = out / f"sc.{icon_id}.imageset"
            wanted_files = {img["filename"] for img in imageset_contents(icon_id)["images"]} | {"Contents.json"}
            for f in d.iterdir():
                if f.name not in wanted_files:
                    f.unlink()
            (d / "Contents.json").write_text(contents_json(imageset_contents(icon_id)))

        if args.preview:
            cells = []
            for icon_id, master, accent in meta:
                d = out / f"sc.{icon_id}.imageset"
                lt = base64.b64encode((d / f"{icon_id}@2x.png").read_bytes()).decode()
                dk = base64.b64encode((d / f"{icon_id}-dark@2x.png").read_bytes()).decode()
                sub = []
                if master != icon_id:
                    sub.append(f"→ {master}")
                if accent:
                    sub.append(accent)
                cells.append(
                    f'<div class="c"><div class="t"><img class="l" src="data:image/png;base64,{lt}">'
                    f'<img class="d" src="data:image/png;base64,{dk}"></div>'
                    f'<div class="n">{html.escape(icon_id)}</div><div class="s">{html.escape(" ".join(sub))}</div></div>'
                )
            page_html = (
                "<!doctype html><html><head><meta charset='utf-8'><style>"
                "body{margin:0;padding:12px;background:#fff;font:11px -apple-system,Helvetica,Arial,sans-serif;color:#222}"
                "h1{font-size:15px;margin:0 0 10px}"
                ".g{display:grid;grid-template-columns:repeat(10,176px);gap:6px}"
                ".c{border:1px solid #ddd;border-radius:6px;padding:4px;text-align:center}"
                ".t{display:flex;gap:4px;justify-content:center}"
                "img{width:80px;height:80px;border-radius:4px;display:block}"
                ".l{background:#f2f4f7}.d{background:#1e2530}"
                ".n{font-weight:600;margin-top:3px;word-break:break-all}.s{color:#777;font-size:10px;min-height:12px}"
                "</style></head><body>"
                f"<h1>SolidCraft-Icons ({len(meta)}) – hell | dunkel, @2x (80 px)</h1>"
                f"<div class='g'>{''.join(cells)}</div></body></html>"
            )
            page.set_viewport_size({"width": 10 * 182 + 24, "height": 800})
            page.set_content(page_html)
            with tempfile.TemporaryDirectory() as tmp:
                shot = Path(tmp) / "vorschau.png"
                page.screenshot(path=str(shot), full_page=True)
                args.preview.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(shot, args.preview)
        browser.close()

    print(f"{len(meta)} Imagesets in {out} geschrieben, {removed} veraltete entfernt.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
