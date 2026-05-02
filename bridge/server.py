"""
Local bridge for the Farshid WebClip AI Chrome extension.

Responsibilities:
  * Receive page payloads from the extension over HTTP (localhost only).
  * Read the user's template file.
  * Ask Ollama (minicpm-v / qwen3:0.6b / ...) to fill in the template fields.
  * Save the resulting markdown into the .farshid folder using the
    `year-mainurl-N.md` filename pattern.

Run:
    python server.py
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ---------------------------------------------------------------------------
# Configuration (override via environment variables if you want).
# ---------------------------------------------------------------------------

# Default save location is ~/.farshid (per-user, cross-platform).
# Override with FARSHID_PKM_ROOT or FARSHID_OUT_DIR environment variables.
PKM_ROOT = Path(os.environ.get(
    "FARSHID_PKM_ROOT",
    str(Path.home() / ".farshid"),
))
FARSHID_DIR = Path(os.environ.get("FARSHID_OUT_DIR", str(PKM_ROOT)))
TEMPLATE_PATH = Path(os.environ.get(
    "FARSHID_TEMPLATE",
    str(FARSHID_DIR / "template-webclip-ai.md"),
))
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434/api/generate")
OLLAMA_BASE = OLLAMA_URL.rsplit("/api/", 1)[0]  # http://127.0.0.1:11434
# Default text model. granite4-fast (3.4B, pinned 8K ctx) is the fastest
# tool/JSON-reliable small model on a 16GB Mac. minicpm-v is a vision
# model and is slow at structured text — don't use it as the default.
# Override with FARSHID_MODEL env var or via the popup model picker.
DEFAULT_MODEL = os.environ.get("FARSHID_MODEL", "granite4-fast:latest")
HOST = os.environ.get("FARSHID_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("FARSHID_BRIDGE_PORT", "8765"))

# Persisted user settings (model choice, etc.) live next to the clips so they
# survive Chrome reinstalls and are easy for the user to inspect/edit.
SETTINGS_PATH = Path(os.environ.get(
    "FARSHID_SETTINGS",
    str(PKM_ROOT / "settings.json"),
))


def read_settings() -> dict:
    try:
        return json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def write_settings(s: dict) -> None:
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(
        json.dumps(s, indent=2, sort_keys=True), encoding="utf-8"
    )


def current_model() -> str:
    return (read_settings().get("model") or DEFAULT_MODEL).strip() or DEFAULT_MODEL

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def main_url_slug(url: str) -> str:
    """Return a short slug for the registrable-ish domain.

    e.g. https://www.github.com/foo  -> github
         https://news.ycombinator.com -> ycombinator
    """
    try:
        host = urlparse(url).hostname or "page"
    except Exception:
        host = "page"
    host = host.lower()
    if host.startswith("www."):
        host = host[4:]
    parts = host.split(".")
    if len(parts) >= 2:
        slug = parts[-2]
    else:
        slug = parts[0]
    slug = re.sub(r"[^a-z0-9]+", "-", slug).strip("-")
    return slug or "page"


def next_filename(out_dir: Path, year: int, slug: str) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    n = 1
    while True:
        candidate = out_dir / f"{year}-{slug}-{n}.md"
        if not candidate.exists():
            return candidate
        n += 1


DEFAULT_TEMPLATE = (
    "---\n"
    "title: {title}\n"
    "url: {url}\n"
    "date: {date}\n"
    "datetime: {datetime}\n"
    "filename: {filename}\n"
    "model: {model}\n"
    "sentiment: {sentiment}\n"
    "image_count: {image_count}\n"
    "is_selection: {is_selection}\n"
    "# --- PKM metadata (LLM-filled) ---\n"
    "para: {Building-a-Second-Brain PARA bucket: one of Project, Area, Resource, Archive}\n"
    "note_type: {Zettelkasten note type: one of fleeting, literature, permanent}\n"
    "domain: {single primary domain or discipline of this content}\n"
    "tags: {5-10 lowercase hashtag-style tags, comma separated, no # symbol}\n"
    "audience: {who is this content written for}\n"
    "reading_time_min: {estimated reading time in whole minutes, integer only}\n"
    "difficulty: {difficulty level: one of beginner, intermediate, advanced}\n"
    "source_credibility: {short note on source authority and bias if any}\n"
    "---\n"
    "\n"
    "# {title}\n"
    "\n"
    "![snapshot]({snapshot})\n"
    "\n"
    "## TL;DR\n"
    "{summary}\n"
    "\n"
    "## Atomic note (Zettelkasten / Evergreen)\n"
    "_One concept, one note. Phrase as a self-contained claim in your own words._\n"
    "\n"
    "{evergreen note: rewrite the single core idea as one declarative sentence in the user's own voice, then 2-3 sentences of explanation. Concept-oriented, atomic, dense.}\n"
    "\n"
    "## Main points (Progressive Summarization layer 2)\n"
    "{at least 3 main points of the page, as a markdown bullet list using - prefix, each point one line}\n"
    "\n"
    "## Key quotes (Progressive Summarization layer 3)\n"
    "{the 1 to 3 most highlight-worthy verbatim quotes from the content, as a markdown bullet list of > blockquote lines}\n"
    "\n"
    "## Why it matters\n"
    "{why is this content important and who would care, 2-3 sentences}\n"
    "\n"
    "## Questions raised (Socratic / Smart Notes)\n"
    "{2-4 open questions this content raises that are worth revisiting later, as a markdown bullet list}\n"
    "\n"
    "## Counterpoints / what's missing\n"
    "{strongest objections, missing context, or biases in this content, 2-3 sentences or bullets}\n"
    "\n"
    "## Connections (Linking Your Thinking / MOC candidates)\n"
    "{3-6 existing concepts, fields, people, or canonical works this note should be linked to in a personal knowledge graph, as a bullet list}\n"
    "\n"
    "## Action items (BASB \"Express\" step)\n"
    "{concrete next steps the reader could take based on this content, as a bullet list, or 'none' if purely informational}\n"
    "\n"
    "## Selected text\n"
    "\n"
    "{selection}\n"
    "\n"
    "## Links\n"
    "\n"
    "{links}\n"
)


def ensure_output_dir_and_template() -> None:
    """Create the output directory and a starter template file if missing."""
    FARSHID_DIR.mkdir(parents=True, exist_ok=True)
    if not TEMPLATE_PATH.exists():
        # Make sure the template's parent directory exists too (in case the
        # user pointed FARSHID_TEMPLATE somewhere outside FARSHID_DIR).
        TEMPLATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        TEMPLATE_PATH.write_text(DEFAULT_TEMPLATE, encoding="utf-8")
        print(f"[bridge] Created starter template at {TEMPLATE_PATH}")


def read_template() -> str:
    # Self-heal on every clip so deleting the file just regenerates it.
    ensure_output_dir_and_template()
    return TEMPLATE_PATH.read_text(encoding="utf-8")


def call_ollama(model: str, prompt: str, timeout: int = 120,
                json_mode: bool = False, num_predict: int = 1024) -> str:
    options = {
        "temperature": 0.2,
        "num_ctx": 8192,
        "num_predict": num_predict,
    }
    body_obj = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": options,
    }
    if json_mode:
        # Ollama-supported: forces the model output to be valid JSON.
        body_obj["format"] = "json"
    body = json.dumps(body_obj).encode("utf-8")
    req = Request(OLLAMA_URL, data=body,
                  headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return (data.get("response") or "").strip()


def extract_json(text: str) -> dict:
    """Pull the first JSON object out of an LLM response."""
    if not text:
        return {}
    # Strip markdown fences.
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S | re.I)
    if fenced:
        text = fenced.group(1)
    # Greedy first {...} block.
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return {}
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return {}


def summarize_page(model: str, page: dict) -> dict:
    """Deprecated. Summary+sentiment are now folded into the single
    combined LLM call done by fill_custom_fields(), so the /clip path
    only does ONE round-trip per clip instead of two.
    """
    return {"summary": "", "sentiment": "neutral", "raw": ""}


# Placeholders may be either a simple identifier ({title}) OR a free-form
# natural-language hint ({at least 3 main points}). The whole content
# inside the braces (after stripping whitespace) is treated as both the
# field key and the hint sent to the LLM. Newlines and nested braces are
# not allowed inside a placeholder.
PLACEHOLDER_RE = re.compile(r"\{([^{}\n]+?)\}")


def render_template(template: str, fields: dict) -> str:
    """Replace {key} placeholders, leaving unknown ones intact."""
    def repl(match: re.Match) -> str:
        key = match.group(1).strip()
        return str(fields.get(key, match.group(0)))
    return PLACEHOLDER_RE.sub(repl, template)


def extract_placeholders(template: str) -> list:
    """Return ordered, de-duplicated list of {name} placeholders in template."""
    seen = []
    for m in PLACEHOLDER_RE.finditer(template):
        name = m.group(1).strip()
        if name and name not in seen:
            seen.append(name)
    return seen


def _normalize_links(raw_links):
    """Normalize links payload (extension may send strings or {href,text})."""
    out = []
    seen = set()
    for item in (raw_links or []):
        if isinstance(item, dict):
            href = (item.get("href") or "").strip()
            text = (item.get("text") or "").strip()
        else:
            href = str(item).strip()
            text = ""
        if not href or href in seen:
            continue
        seen.add(href)
        out.append({"href": href, "text": text or href})
    return out


def fill_custom_fields(model: str, page: dict, names: list) -> dict:
    """Single-call LLM fill for summary, sentiment, and any user fields.

    The list `names` should already include `summary` and `sentiment`
    when the caller wants them. Uses Ollama's `format=json` mode so the
    response is guaranteed-parseable; no per-field retry needed. One
    round-trip per clip.
    """
    if not names:
        return {}
    # Smaller snippet keeps the prompt short -> fast first-token time.
    snippet = (page.get("text") or "")[:3000]
    is_selection = bool(page.get("is_selection"))
    label = "selected snippet" if is_selection else "web page"
    # Map each placeholder to a short numeric key (f1, f2, ...). Small
    # models can reliably reproduce these even when the hint itself is
    # a long natural-language sentence with quotes/colons/brackets.
    id_to_name = {f"f{i+1}": n for i, n in enumerate(names)}
    field_lines = "\n".join(
        f'  "{fid}": {n}' for fid, n in id_to_name.items()
    )
    keys_csv = ", ".join(f'"{fid}"' for fid in id_to_name)
    prompt = f"""You extract structured fields from a {label}.

Title: {page.get('title','')}
URL: {page.get('url','')}
Meta description: {page.get('description','')}

Content (truncated):
\"\"\"
{snippet}
\"\"\"

For EACH field below, the key is a short id and the value should be
inferred from the description after the colon. Always produce a
non-empty value. If the description asks for points/takeaways/
questions/items/list/bullets, return one string with newline-separated
"- " bullet items. If it asks for an integer, return digits only. If
it asks for one of a fixed set, return exactly one of them.

Fields:
{field_lines}

Return a JSON object whose keys are exactly: {keys_csv}
All values must be strings.
"""
    # num_predict is generous: 29 small fields fit comfortably in 1500
    # tokens. Cap timeout so the user gets feedback fast.
    try:
        raw = call_ollama(
            model, prompt,
            timeout=90,
            json_mode=True,
            num_predict=1500,
        )
    except Exception as e:
        print(f"[bridge] LLM call failed: {e}")
        return {n: "" for n in names}
    parsed = extract_json(raw)
    out = {}
    for fid, n in id_to_name.items():
        v = parsed.get(fid, "")
        if isinstance(v, (list, tuple)):
            v = "\n".join(f"- {x}" for x in v)
        elif isinstance(v, dict):
            v = json.dumps(v, ensure_ascii=False)
        out[n] = str(v).strip()
    return out


# ---------------------------------------------------------------------------
# MOC (Map of Content) builder
# ---------------------------------------------------------------------------

MOC_PATH = FARSHID_DIR / "MOC.md"
PARA_BUCKETS = ["Project", "Area", "Resource", "Archive"]


def _parse_front_matter(text: str) -> dict:
    """Parse a leading `---\\n...\\n---` YAML-ish front matter block.

    Tiny custom parser \u2014 we only need flat key:value pairs and we don't
    want a yaml dependency. Lines starting with `#` are skipped.
    """
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 4)
    if end < 0:
        return {}
    block = text[4:end]
    out = {}
    for line in block.splitlines():
        line = line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def _scan_clips(out_dir: Path) -> list:
    """Return list of dicts describing every clipped .md note in out_dir."""
    notes = []
    for p in sorted(out_dir.glob("*.md")):
        if p.name in {"template-webclip-ai.md", "MOC.md"}:
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        fm = _parse_front_matter(text)
        notes.append({
            "filename": p.name,
            "title": fm.get("title", "") or p.stem,
            "url": fm.get("url", ""),
            "date": fm.get("date", ""),
            "para": (fm.get("para", "") or "").strip(),
            "note_type": (fm.get("note_type", "") or "").strip(),
            "domain": (fm.get("domain", "") or "").strip(),
            "tags": [t.strip() for t in (fm.get("tags", "") or "").split(",") if t.strip()],
            "is_selection": fm.get("is_selection", "") == "True",
            "snapshot": p.with_suffix(".png").name if p.with_suffix(".png").exists() else "",
        })
    return notes


def _bucket_para(value: str) -> str:
    """Map an LLM-filled value to one of the four PARA buckets."""
    v = (value or "").strip().lower()
    for b in PARA_BUCKETS:
        if b.lower() in v:
            return b
    return "Unsorted"


def build_moc(out_dir: Path = None) -> Path:
    """Regenerate ~/.farshid/MOC.md from all saved clips.

    Grouped by PARA bucket > domain. Each entry shows the title (linked
    to the file), its tags, and a thumbnail of the snapshot if present.
    """
    out_dir = out_dir or FARSHID_DIR
    notes = _scan_clips(out_dir)
    now = dt.datetime.now()
    lines = []
    lines.append("---")
    lines.append("title: Map of Content - Farshid AI WebClip")
    lines.append(f"generated: {now.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"total_notes: {len(notes)}")
    lines.append("note_kind: MOC")
    lines.append("---")
    lines.append("")
    lines.append("# Map of Content")
    lines.append("")
    lines.append(
        "_Auto-generated index of every clipped note in this folder._  "
        "_Grouped by **PARA** bucket (Building a Second Brain) and **domain**._  "
        "_Sources: Zettelkasten, BASB+PARA, Progressive Summarization, "
        "Linking Your Thinking (MOC), Smart Notes._"
    )
    lines.append("")

    if not notes:
        lines.append("_No clips yet. Use the Chrome extension to save your first note._")
        MOC_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return MOC_PATH

    # Quick stats
    by_para = {b: [] for b in PARA_BUCKETS + ["Unsorted"]}
    for n in notes:
        by_para[_bucket_para(n["para"])].append(n)

    lines.append("## At a glance")
    lines.append("")
    lines.append(f"- **Total notes:** {len(notes)}")
    for b in PARA_BUCKETS + ["Unsorted"]:
        if by_para[b]:
            lines.append(f"- **{b}:** {len(by_para[b])}")
    lines.append("")

    # Tag cloud (most-used 20)
    tag_counts = {}
    for n in notes:
        for t in n["tags"]:
            tag_counts[t] = tag_counts.get(t, 0) + 1
    if tag_counts:
        top = sorted(tag_counts.items(), key=lambda x: (-x[1], x[0]))[:20]
        lines.append("## Top tags")
        lines.append("")
        lines.append(" \u00b7 ".join(f"`#{t}` ({c})" for t, c in top))
        lines.append("")

    # Per-PARA sections, then per-domain inside.
    lines.append("## By PARA bucket")
    lines.append("")
    for b in PARA_BUCKETS + ["Unsorted"]:
        if not by_para[b]:
            continue
        lines.append(f"### {b}")
        lines.append("")
        # Group by domain inside the bucket.
        by_domain = {}
        for n in by_para[b]:
            d = n["domain"] or "(unspecified)"
            by_domain.setdefault(d, []).append(n)
        for d in sorted(by_domain.keys()):
            lines.append(f"#### {d}")
            lines.append("")
            for n in sorted(by_domain[d], key=lambda x: x["date"], reverse=True):
                title = n["title"].replace("|", "\u2502")
                date = n["date"] or "????-??-??"
                tags = " ".join(f"`#{t}`" for t in n["tags"][:5])
                row = f"- {date} \u00b7 [{title}]({n['filename']})"
                if n["note_type"]:
                    row += f" \u00b7 _{n['note_type']}_"
                if tags:
                    row += f" \u00b7 {tags}"
                if n["url"]:
                    row += f" \u00b7 [\u21d7]({n['url']})"
                lines.append(row)
            lines.append("")

    # Reverse-chronological flat index for grep/scrolling.
    lines.append("## All notes (most recent first)")
    lines.append("")
    for n in sorted(notes, key=lambda x: (x["date"], x["filename"]), reverse=True):
        date = n["date"] or "????-??-??"
        title = n["title"].replace("|", "\u2502")
        snippet = ""
        if n["snapshot"]:
            snippet = f" \u00b7 ![]({n['snapshot']}){{ width=80 }}"
        lines.append(f"- {date} \u00b7 [{title}]({n['filename']}){snippet}")

    MOC_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return MOC_PATH


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._json(200, {"ok": True, "model": current_model(),
                             "out_dir": str(FARSHID_DIR),
                             "settings_path": str(SETTINGS_PATH)})
            return
        if self.path == "/models":
            # Proxy Ollama's local model list.
            try:
                with urlopen(f"{OLLAMA_BASE}/api/tags", timeout=5) as resp:
                    tags = json.loads(resp.read().decode("utf-8"))
            except (HTTPError, URLError, TimeoutError) as e:
                self._json(502, {"error": f"ollama unreachable: {e}"})
                return
            models = [m.get("name") for m in (tags.get("models") or []) if m.get("name")]
            self._json(200, {"ok": True, "models": models,
                             "current": current_model()})
            return
        if self.path == "/moc":
            try:
                p = build_moc(FARSHID_DIR)
                notes = _scan_clips(FARSHID_DIR)
                self._json(200, {"ok": True, "path": str(p),
                                 "total": len(notes)})
            except Exception as e:
                self._json(500, {"error": f"moc build failed: {e}"})
            return
        if self.path == "/settings":
            s = read_settings()
            s.setdefault("model", DEFAULT_MODEL)
            self._json(200, {"ok": True, "settings": s,
                             "settings_path": str(SETTINGS_PATH)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/settings":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except Exception as e:
                self._json(400, {"error": f"bad json: {e}"})
                return
            current = read_settings()
            # Whitelist: only known keys make it to disk.
            for key in ("model",):
                if key in payload:
                    current[key] = payload[key]
            try:
                write_settings(current)
            except OSError as e:
                self._json(500, {"error": f"write failed: {e}"})
                return
            self._json(200, {"ok": True, "settings": current,
                             "settings_path": str(SETTINGS_PATH)})
            return

        if self.path == "/pull":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except Exception as e:
                self._json(400, {"error": f"bad json: {e}"})
                return
            name = (payload.get("model") or "").strip()
            if not name:
                self._json(400, {"error": "missing model"})
                return
            # Drain Ollama's streaming pull response. Last status line
            # is usually 'success'.
            body = json.dumps({"name": name, "stream": True}).encode("utf-8")
            req = Request(f"{OLLAMA_BASE}/api/pull", data=body,
                          headers={"Content-Type": "application/json"})
            last = {}
            try:
                with urlopen(req, timeout=3600) as resp:
                    for line in resp:
                        try:
                            last = json.loads(line.decode("utf-8"))
                        except Exception:
                            continue
                        if last.get("error"):
                            self._json(502, {"error": last["error"]})
                            return
            except (HTTPError, URLError, TimeoutError) as e:
                self._json(502, {"error": f"ollama pull failed: {e}"})
                return
            self._json(200, {"ok": True, "model": name,
                             "status": last.get("status", "done")})
            return

        if self.path != "/clip":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as e:
            self._json(400, {"error": f"bad json: {e}"})
            return

        page = payload.get("page") or {}
        url = page.get("url") or ""
        if not url:
            self._json(400, {"error": "missing page.url"})
            return

        model = (payload.get("model") or current_model()).strip() or DEFAULT_MODEL
        try:
            ai = summarize_page(model, page)
        except (HTTPError, URLError, TimeoutError) as e:
            self._json(502, {"error": f"ollama unreachable: {e}"})
            return
        except Exception as e:
            self._json(500, {"error": f"ollama call failed: {e}"})
            return

        now = dt.datetime.now()
        slug = main_url_slug(url)
        out_path = next_filename(FARSHID_DIR, now.year, slug)

        # Save screenshot (if extension sent one) next to the .md file.
        snapshot_rel = ""
        screenshot = payload.get("screenshot") or ""
        if isinstance(screenshot, str) and screenshot.startswith("data:image/"):
            try:
                _, b64 = screenshot.split(",", 1)
                png_bytes = base64.b64decode(b64)
                snap_path = out_path.with_suffix(".png")
                snap_path.write_bytes(png_bytes)
                snapshot_rel = snap_path.name
            except Exception as e:
                print(f"[bridge] screenshot save failed: {e}")

        fields = {
            "date": now.strftime("%Y-%m-%d"),
            "datetime": now.strftime("%Y-%m-%d %H:%M:%S"),
            "title": page.get("title", ""),
            "url": url,
            "summary": ai["summary"],
            "image_count": page.get("image_count", 0),
            "number_of_images": page.get("image_count", 0),
            "sentiment": ai["sentiment"],
            "filename": out_path.name,
            "model": model,
            "is_selection": bool(page.get("is_selection")),
            "selection": (page.get("text") or "") if page.get("is_selection") else "",
            "snapshot": snapshot_rel,
        }
        norm_links = _normalize_links(page.get("links"))
        fields["links"] = "\n".join(
            f"- [{l['text']}]({l['href']})" for l in norm_links[:50]
        )

        template = read_template()
        # Find user-defined placeholders that aren't built-ins. We also
        # ALWAYS request summary + sentiment so the LLM produces them
        # in the same single round-trip (the old code did two calls).
        builtin_keys = set(fields.keys()) - {"summary", "sentiment"}
        custom_keys = [k for k in extract_placeholders(template)
                       if k not in builtin_keys]
        # Make sure summary + sentiment are asked for even if the
        # template doesn't reference them, so the existing built-in
        # `summary` / `sentiment` placeholders behave the same as before.
        for k in ("summary", "sentiment"):
            if k not in custom_keys:
                custom_keys.append(k)
        try:
            llm = fill_custom_fields(model, page, custom_keys)
        except Exception as e:
            print(f"[bridge] custom-field fill failed: {e}")
            llm = {}
        # Sanitize sentiment to the canonical 3-value set.
        sent = (llm.get("sentiment") or "").strip().lower()
        if sent not in ("positive", "negative", "neutral"):
            sent = "neutral"
        llm["sentiment"] = sent
        # Fallback summary if the LLM returned nothing.
        if not (llm.get("summary") or "").strip():
            llm["summary"] = (page.get("description")
                              or (page.get("text") or "")[:400]).strip()
        fields.update(llm)
        rendered = render_template(template, fields)

        # The user's template is the source of truth for the saved file.
        # If it's present and non-empty, write ONLY the rendered template
        # so edits to ~/.farshid/template-webclip-ai.md actually show up
        # in every new clip. We only fall back to the auto-generated
        # boilerplate (front matter + title + summary + selection +
        # images) when the template is missing or empty.
        if rendered.strip():
            body_md = rendered
            # Optionally append images / selection only if the template
            # didn't already include them via {selection} / explicit
            # markdown. We detect this by checking whether the template
            # referenced these fields at all.
            extras = []
            if (page.get("images")
                    and "{image_count}" not in template
                    and "{number_of_images}" not in template
                    and "## Images" not in rendered):
                extras.append(
                    "\n\n## Images\n\n"
                    + "\n".join(f"![]({u})" for u in (page.get("images") or [])[:20])
                )
            if (fields["is_selection"] and fields["selection"]
                    and "{selection}" not in template):
                extras.append(
                    "\n\n## Selected text\n\n> "
                    + fields["selection"].replace("\n", "\n> ")
                )
            if (norm_links
                    and "{links}" not in template
                    and "## Links" not in rendered):
                extras.append(
                    "\n\n## Links\n\n"
                    + "\n".join(
                        f"- [{l['text']}]({l['href']})" for l in norm_links[:50]
                    )
                )
            if extras:
                body_md = body_md.rstrip() + "".join(extras) + "\n"
        else:
            # Template was empty -> use the original self-describing layout.
            header = (
                "---\n"
                f"date: {fields['date']}\n"
                f"title: {json.dumps(fields['title'])}\n"
                f"url: {url}\n"
                f"number_of_images: {fields['image_count']}\n"
                f"sentiment: {fields['sentiment']}\n"
                f"is_selection: {str(fields['is_selection']).lower()}\n"
                f"model: {model}\n"
                f"filename: {fields['filename']}\n"
                "---\n\n"
            )
            selection_block = ""
            if fields["is_selection"] and fields["selection"]:
                selection_block = (
                    "## Selected text\n\n"
                    "> " + fields["selection"].replace("\n", "\n> ") + "\n\n"
                )
            images = page.get("images") or []
            images_block = ""
            if images:
                images_block = "## Images\n\n" + "\n".join(
                    f"![]({u})" for u in images[:20]
                ) + "\n\n"
            body_md = (
                f"{header}"
                f"# {fields['title'] or url}\n\n"
                f"**Summary:** {fields['summary']}\n\n"
                f"{selection_block}"
                f"{images_block}"
            )

        try:
            out_path.write_text(body_md, encoding="utf-8")
        except OSError as e:
            self._json(500, {"error": f"write failed: {e}"})
            return

        # Rebuild the MOC after every save so it stays current.
        try:
            build_moc(FARSHID_DIR)
        except Exception as e:
            print(f"[bridge] MOC rebuild failed: {e}")

        self._json(200, {
            "ok": True,
            "path": str(out_path),
            "filename": out_path.name,
            "fields": {k: v for k, v in fields.items() if k != "model"},
        })

    def log_message(self, fmt, *args):  # quiet default logging
        sys.stderr.write("[bridge] " + (fmt % args) + "\n")


def main() -> None:
    ensure_output_dir_and_template()
    # CLI shortcut: rebuild the MOC and exit. Useful from farshid.sh moc.
    if len(sys.argv) > 1 and sys.argv[1] in ("--moc", "moc"):
        path = build_moc(FARSHID_DIR)
        notes = _scan_clips(FARSHID_DIR)
        print(f"[bridge] Wrote {path} ({len(notes)} notes)")
        return
    print(f"[bridge] PKM root:    {PKM_ROOT}")
    print(f"[bridge] Output dir:  {FARSHID_DIR}")
    print(f"[bridge] Template:    {TEMPLATE_PATH}")
    print(f"[bridge] Settings:    {SETTINGS_PATH}")
    print(f"[bridge] Ollama URL:  {OLLAMA_URL}")
    print(f"[bridge] Default model: {current_model()}")
    print(f"[bridge] Listening on http://{HOST}:{PORT}")
    print(f"[bridge]   GET  /health   /models   /settings   /moc")
    print(f"[bridge]   POST /clip     /pull     /settings")
    # Build an initial MOC so the file exists immediately.
    try:
        build_moc(FARSHID_DIR)
    except Exception as e:
        print(f"[bridge] initial MOC build failed: {e}")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
