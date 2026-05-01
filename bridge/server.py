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
DEFAULT_MODEL = os.environ.get("FARSHID_MODEL", "minicpm-v:latest")
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
    "date: {date}\n"
    "title: {title}\n"
    "url: {url}\n"
    "summary: {summary}\n"
    "number of images: {image_count}\n"
    "positive or negative: {sentiment}\n"
    "\n"
    "the file name i want to use {filename}\n"
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


def call_ollama(model: str, prompt: str, timeout: int = 180) -> str:
    body = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.2},
    }).encode("utf-8")
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
    """Ask Ollama for a short summary + sentiment, returned as JSON."""
    snippet = (page.get("text") or "")[:6000]
    is_selection = bool(page.get("is_selection"))
    label = "selected snippet from a web page" if is_selection else "web page"
    body_label = "Selected text" if is_selection else "Page text"
    prompt = f"""You are an assistant that summarizes a {label} into structured fields.

Title: {page.get('title','')}
URL: {page.get('url','')}
Meta description: {page.get('description','')}

{body_label} (truncated):
\"\"\"
{snippet}
\"\"\"

Reply with ONLY a single JSON object (no prose, no markdown fences) with these keys:
  "summary":   2-4 sentence neutral summary of the {('selection' if is_selection else 'page')}.
  "sentiment": one of "positive", "negative", or "neutral".

Example: {{"summary": "...", "sentiment": "neutral"}}
"""
    raw = call_ollama(model, prompt)
    parsed = extract_json(raw)
    summary = (parsed.get("summary") or "").strip()
    sentiment = (parsed.get("sentiment") or "").strip().lower()
    if sentiment not in ("positive", "negative", "neutral"):
        sentiment = "neutral"
    if not summary:
        # Fallback: use the meta description or the first lines of text.
        summary = (page.get("description")
                   or (page.get("text") or "")[:400]).strip()
    return {"summary": summary, "sentiment": sentiment, "raw": raw}


def render_template(template: str, fields: dict) -> str:
    """Replace {key} placeholders, leaving unknown ones intact."""
    def repl(match: re.Match) -> str:
        key = match.group(1).strip()
        return str(fields.get(key, match.group(0)))
    return re.sub(r"\{([a-zA-Z0-9_]+)\}", repl, template)


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
        }

        template = read_template()
        rendered = render_template(template, fields)

        # Also append a clear front-matter header so the file is self-describing,
        # even if the user's template is just a list of field names.
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
            f"---\n\n"
            f"## Template (rendered)\n\n{rendered}\n"
        )

        try:
            out_path.write_text(body_md, encoding="utf-8")
        except OSError as e:
            self._json(500, {"error": f"write failed: {e}"})
            return

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
    print(f"[bridge] PKM root:    {PKM_ROOT}")
    print(f"[bridge] Output dir:  {FARSHID_DIR}")
    print(f"[bridge] Template:    {TEMPLATE_PATH}")
    print(f"[bridge] Settings:    {SETTINGS_PATH}")
    print(f"[bridge] Ollama URL:  {OLLAMA_URL}")
    print(f"[bridge] Default model: {current_model()}")
    print(f"[bridge] Listening on http://{HOST}:{PORT}")
    print(f"[bridge]   GET  /health   /models   /settings")
    print(f"[bridge]   POST /clip     /pull     /settings")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] shutting down")
        server.server_close()


if __name__ == "__main__":
    main()
