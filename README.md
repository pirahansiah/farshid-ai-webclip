



# Farshid AI WebClip

<p align="center">
  <img src="farshid.png" alt="Farshid AI WebClip" width="160" />
</p>

## Updates

**Last update: 2026-05-02**

- Added **YouTube support**: clipping a `youtube.com/watch?v=...` page
  now extracts the title, channel, view count, and full description
  text, and uses the `maxresdefault` thumbnail as the snapshot. No API
  keys, no third-party libraries, no transcript scraping.
- Added **MOC (Map of Content)**: `~/.farshid/MOC.md` is now
  auto-generated and rebuilt after every clip. Notes are grouped by
  PARA bucket and domain, with a top-tags cloud and a
  reverse-chronological flat index. Trigger a manual rebuild with
  `bash scripts/farshid.sh moc` (or `farshid.bat moc`), or `GET /moc`.

A small **Chrome extension + local Python bridge** that:






1. Clips the **current tab** OR your **highlighted selection** (text, links,
   images in that area) when you click the toolbar icon, hit a popup
   button, or right-click.
2. Captures a **PNG snapshot** of the visible page next to the saved note.
3. Sends the page text/title/url (or just the selection) to **Ollama**
   (default `granite4-fast:latest`, or any model you set in `FARSHID_MODEL` /
   `scripts/local.env.sh`).
4. Asks the model to fill in your **PKM template** — not just summary +
   sentiment, but any field you invent. Placeholders take **free-form
   natural-language hints** (e.g. `{at least 3 main points as bullets}`),
   so adding new sections doesn't require any code changes.
5. Saves the result as Markdown into your PKM folder using the filename
   pattern `<year>-<mainurl>-<N>.md`, with the snapshot saved as a
   sibling `.png`.

The default template is grounded in major PKM methods — **Zettelkasten**,
**Building a Second Brain (PARA + Progressive Summarization)**,
**Evergreen notes**, **Linking Your Thinking (MOC)**, and **Smart Notes**
— so every clip becomes a structured, linkable note. See section 6.

> Project naming follows the pattern **`farshid-<action>-<what>`**, e.g.
> `farshid-ai-webclip` → action = `ai`, what = `webclip`.

Chrome extensions cannot write to the local filesystem or talk to your local
Ollama directly, so we ship a tiny **localhost-only** Python bridge
(`bridge/server.py`) that does both jobs.

---

## TL;DR

```bash
# macOS / Linux
ollama pull granite4:latest
bash scripts/farshid.sh install
```

```bat
:: Windows  (no admin needed)
ollama pull granite4:latest
:: Either run from a terminal:
scripts\farshid.bat
:: ...or just double-click scripts\farshid.bat in Explorer.
:: Zero-arg = full setup, then starts the bridge HIDDEN in the
:: background (no terminal window). Final step is one click in Chrome.
```

That single command:

- packs the extension,
- copies a self-contained runtime into `~/.farshid/runtime/` (so it works
  even if this project lives in Dropbox / iCloud / a path with spaces),
- registers the bridge to auto-start at every login,
- on Windows, starts the bridge **hidden in the background** (no
  console window) and copies the staged extension folder path to
  your clipboard,
- opens `chrome://extensions` for you with one-time instructions.

After it finishes, on **all three OSes** you do one 30-second
click-through in Chrome (`chrome://extensions` → Developer mode →
Load unpacked → paste the path). On **Linux** the extension is
auto-installed via Chrome's enterprise policy and you just open Chrome.

---

## 1. Prerequisites

- [Ollama](https://ollama.com/) installed and running locally.
- A small text model pulled. The default is `granite4-fast:latest`
  (3.4B params, ~2 GB, ~5–20 s per clip on M-series). Reliable for the
  structured-JSON template fill on a 16 GB Mac.
  ```bash
  ollama pull granite4:latest          # then `farshid` will Modelfile-pin
  # alternatives that also work well:
  ollama pull qwen2.5:3b
  ollama pull minicpm-v:latest         # vision; slower at structured text
  ```
- Python 3.9+ (standard library only — no `pip install` required).
- Google Chrome (or any Chromium-based browser that supports MV3 — Brave
  works too).

---

## 2. One-time setup

### macOS / Linux

```bash
cd farshid-ai-webclip
bash scripts/farshid.sh install
```

The installer prints a final block telling you exactly what to do next.

### Windows

No admin password. No UAC prompt. No visible terminal window.

```bat
cd farshid-ai-webclip
scripts\farshid.bat
```

Or just **double-click `scripts\farshid.bat`** in Explorer — with no
argument it runs the full one-click setup, then exits. The bridge
keeps running **hidden in the background** (a `wscript.exe` launching
`bridge-hidden.vbs` — no console, no taskbar icon). Auto-start
handles every subsequent login the same way (still hidden).

What the script does, in order:

1. **Packs** the extension into `dist\farshid-ai-webclip.crx`.
2. **Stages** a self-contained copy of the bridge, the unpacked
   extension, the `.crx`, and a hidden VBScript launcher into
   `%USERPROFILE%\.farshid\runtime\` — a stable path that survives
   project moves and OneDrive/Dropbox sandboxing.
3. **Removes** any leftover dead `HKCU\Software\Google\Chrome\Extensions\<id>`
   sideload key. (Modern Chrome silently disables HKCU-sideloaded
   `.crx` files — the key just clutters `chrome://extensions` with a
   greyed-out card and no Enable button.)
4. **Installs** a hidden Startup-folder shortcut
   `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Farshid AI WebClip.lnk`
   that runs `wscript.exe bridge-hidden.vbs` at login (no window).
5. **Starts** the bridge + Ollama hidden in the background right now.
6. **Copies** `%USERPROFILE%\.farshid\runtime\extension` to your
   clipboard and **opens** `chrome://extensions/`, ready for the
   one-time Load-unpacked click below.

Finish in Chrome (one time, ~20 seconds):

1. Top-right of `chrome://extensions`: turn **Developer mode** ON.
2. Top-left: click **Load unpacked**.
3. In the file picker click the address bar at the top, press
   **Ctrl+V** (the path is already on your clipboard), Enter, then
   **Select Folder**.
4. The card shows **Farshid AI WebClip 0.5.0** — pin it via the
   puzzle-piece icon in the toolbar. Done forever.

Because the staged path never changes, you only do step 1–4 **once**.
Later, after editing `extension\` or `bridge\`, just double-click
`farshid.bat` again and click **Update** on `chrome://extensions/` —
the loaded extension reloads in place.

> **Why no admin?** Earlier versions of this script wrote a
> machine-wide HKLM `ExtensionInstallForcelist` policy, which needed
> UAC. We dropped that — Google deliberately makes any silent extension
> install on consumer Chrome require either admin (HKLM policy) or
> publishing to the Web Store ($5 + review). Load-unpacked is the
> only no-admin path that works, and the path is permanent so it's
> still a one-click experience.
>
> If you ran an older version that wrote the HKLM policy and want it
> cleaned up, run `scripts\farshid.bat cleanup-admin` once (single
> UAC prompt → done forever).

### What `setup` actually does

| Step | All OSes                                                                       |
| ---- | ------------------------------------------------------------------------------ |
| 1    | Packs the extension into `dist/farshid-ai-webclip.crx` (+ `.pem`, `updates.xml`). The signing key is reused on every run so the extension ID is stable. |
| 2    | Stages a self-contained copy of bridge code, the unpacked extension, the `.crx`, and a copy of the launcher into `~/.farshid/runtime/` (macOS/Linux) or `%USERPROFILE%\.farshid\runtime\` (Windows). On Windows it also writes a `bridge-hidden.vbs` so login auto-start runs with no console window. The project folder is no longer required at runtime, and OneDrive / Dropbox / iCloud sandboxing cannot break startup. |
| 3    | Registers the bridge + Ollama to start at login (LaunchAgent on macOS, systemd `--user` unit on Linux, Startup-folder shortcut pointing at the **hidden** VBScript launcher on Windows). |
| 4    | **Linux only:** writes Chrome's `ExtensionInstallForcelist` policy (pointing at the staged `updates.xml`) so the extension installs (and re-installs) automatically with no user action. **Windows & macOS:** opens `chrome://extensions` for the one-time **Load unpacked** click (no admin needed). |

### macOS-specific finish step

On a personal Mac, Chrome refuses sideloaded `.crx` files ("not from the
Chrome Web Store") and Apple silently refuses to install unsigned
configuration profiles, so the only mechanism that always works is
**Load unpacked**. The `install` command does it almost all for you and
opens `chrome://extensions` with these final clicks:

1. Top-right of `chrome://extensions`: turn **Developer mode** ON.
2. Top-left: click **Load unpacked**.
3. In the file picker press `Cmd+Shift+G` and paste:
   ```
   ~/.farshid/runtime/extension
   ```
4. Click **Select**. Done — fully enabled, no warnings.
5. Pin the puzzle-piece toolbar icon for quick access.

The folder lives outside Dropbox/iCloud, so the extension survives
reboots and Chrome updates without ever needing to "re-add" it.

---

## 3. Use it

1. Open any normal `http://` or `https://` page.
2. **Whole page:** click the toolbar icon → **Whole page** (or
   **Clip (selection if any, else page)**).
3. **One snippet:** highlight the text you care about, then either
   right-click → **Clip selection with Farshid AI**, or open the toolbar
   popup and hit **Selection only**. Anchored images inside the
   selection — or sitting in the same enclosing card if your selection
   is text-only — are captured automatically.
4. The popup or an in-page toast shows the saved path, e.g.
   ```
   Saved [selection]: /Users/you/.farshid/2026-linkedin-1.md
   ```

Clips made from a selection get `is_selection: true` in the front matter
and a `## Selected text` block in the Markdown body. The summary prompt
also tells Ollama it's looking at a snippet, not the whole page.

### YouTube videos

If you clip a `youtube.com/watch?v=...` page (whole-page mode), the
extension extracts the metadata YouTube already renders into the DOM:

- video **title**, **channel**, **view count**
- the full **description** text — this is what the LLM uses as the
  source for the summary, evergreen note, main points, etc.
- the high-resolution **thumbnail** (`maxresdefault.jpg`) is set as the
  snapshot image so it shows up inline in your note

This is intentionally lightweight: no YouTube API keys, no third-party
libraries, no captions/transcript scraping. The video description (the
text the channel author wrote) is almost always enough for a useful
PKM note. If you want a deeper note, paste a key sentence into the page
first and use **Clip selection** instead.

---

## 4. Where things live

| Path                                          | What                                                            |
| --------------------------------------------- | --------------------------------------------------------------- |
| `~/.farshid/`                                 | Output folder. All clipped `.md` files land here.               |
| `~/.farshid/template-webclip-ai.md`           | Your editable template (auto-created on first run).             |
| `~/.farshid/MOC.md`                           | **Map of Content** — auto-generated index of every clipped note, grouped by PARA bucket and domain, with tag cloud. Rebuilt on every save. |
| `~/.farshid/settings.json`                    | Bridge runtime info (model name, paths) — auto-managed.         |
| `~/.farshid/runtime/` *(or `%USERPROFILE%\.farshid\runtime\` on Windows)* | Self-contained staged runtime — extension, bridge, `.crx`, logs. |
| `~/.farshid/runtime/extension/`               | The unpacked extension you point Chrome at on macOS.            |
| `~/.farshid/runtime/logs/`                    | Bridge + LaunchAgent logs (`launchagent.out.log`, `.err.log`).  |
| `~/Library/LaunchAgents/com.farshid.aiwebclip.plist` (macOS) | Auto-start LaunchAgent.                          |
| `~/.config/systemd/user/farshid-ai-webclip.service` (Linux)  | Auto-start systemd unit.                         |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Farshid AI WebClip.lnk` (Windows) | Startup shortcut. Targets `wscript.exe bridge-hidden.vbs` so the bridge runs hidden at every login (no console window). |

---

## 5. Environment overrides

You almost never need these — the defaults work — but if you do, create
either of these gitignored files:

`scripts/local.env.sh` (macOS / Linux):
```bash
export PYTHON=/opt/homebrew/bin/python3
export OLLAMA=/opt/homebrew/bin/ollama
export MODEL=qwen3:0.6b
# export CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# export CHROME_PROFILE="$HOME/chrome-farshid"
# export STAGE_DIR="$HOME/.farshid/runtime"
```

`scripts/local.env.bat` (Windows):
```bat
set PYTHON=C:\Users\me\miniconda3\envs\py312\python.exe
set OLLAMA=C:\Users\me\AppData\Local\Programs\Ollama\ollama.exe
set MODEL=qwen3:0.6b
```

Bridge-side env vars (set in `local.env.sh` or your shell):

| Variable               | Default                                                              |
| ---------------------- | -------------------------------------------------------------------- |
| `FARSHID_PKM_ROOT`     | `~/.farshid`                                                         |
| `FARSHID_OUT_DIR`      | same as `FARSHID_PKM_ROOT`                                           |
| `FARSHID_TEMPLATE`     | `<OUT_DIR>/template-webclip-ai.md`                                   |
| `OLLAMA_URL`           | `http://127.0.0.1:11434/api/generate`                                |
| `FARSHID_MODEL`        | `granite4-fast:latest`                                               |
| `FARSHID_BRIDGE_HOST`  | `127.0.0.1`                                                          |
| `FARSHID_BRIDGE_PORT`  | `8765`                                                               |

---

## 6. Template

The bridge auto-creates the output folder and template **on first launch**
(and again any time the template file is missing):

- Folder: `<FARSHID_OUT_DIR>` (default `~/.farshid/`)
- File:   `<FARSHID_TEMPLATE>` (default `~/.farshid/template-webclip-ai.md`)

Edit it freely — the bridge only re-creates it if you delete it.

### How placeholders work

Anything inside `{...}` (one line, no nested braces) is a placeholder.
There are **two kinds**, and the bridge decides automatically:

1. **Built-in placeholders** — filled mechanically from the page or
   metadata. They are NOT sent to the LLM.
2. **Custom placeholders** — anything else. The text inside the braces
   is sent to the LLM as your instruction for that field. Use plain
   English: `{author}`, `{at least 3 main points as bullets}`,
   `{strongest objection in 2 sentences}`.

### Built-in placeholders

| Placeholder | Value |
| --- | --- |
| `{date}` | `YYYY-MM-DD` |
| `{datetime}` | `YYYY-MM-DD HH:MM:SS` |
| `{title}` | Page `<title>` |
| `{url}` | Page URL |
| `{summary}` | LLM-generated short summary |
| `{sentiment}` | `positive` / `negative` / `neutral` |
| `{image_count}` / `{number_of_images}` | Number of `<img>` tags captured |
| `{is_selection}` | `True` if the clip came from a highlighted selection |
| `{selection}` | The highlighted text (empty when whole-page clipping) |
| `{links}` | Markdown bullet list `- [text](url)` for every link in the selection (or whole page) |
| `{snapshot}` | Filename of the saved PNG (sibling of the `.md`); use as `![]({snapshot})` |
| `{filename}` | The output filename, e.g. `2026-github-1.md` |
| `{model}` | Model name used for the clip |

Unknown placeholders are **left as-is** if the LLM call fails, so your
file never ends up half-broken.

### Auto-appended sections

If your template doesn't reference some data, the bridge appends it at
the bottom so nothing is lost:

- `## Selected text` — appended if `{selection}` isn't in your template
  and the clip came from a highlight.
- `## Images` — appended if neither `{image_count}` nor
  `{number_of_images}` is referenced and images were captured.
- `## Links` — appended if `{links}` isn't referenced and the page /
  selection has links.

If you reference these placeholders explicitly, the bridge trusts your
layout and doesn't append anything extra.

### Default PKM template

The default template installed at `~/.farshid/template-webclip-ai.md` is
built from the most-used personal-knowledge-management frameworks:

| Framework | Field(s) it contributes |
| --- | --- |
| **Zettelkasten** (Luhmann / Ahrens) | `note_type` (fleeting / literature / permanent), "Atomic note" section, ID-based filename |
| **Evergreen notes** (Andy Matuschak) | "Atomic note (Zettelkasten / Evergreen)" — one self-contained claim in your voice |
| **Building a Second Brain + PARA** (Tiago Forte) | `para` bucket (Project / Area / Resource / Archive), "Action items" (Express step) |
| **Progressive Summarization** (Forte) | TL;DR (layer 1) → Main points (layer 2) → Key quotes (layer 3) |
| **Linking Your Thinking** (Nick Milo) | "Connections / MOC candidates" |
| **Smart Notes** (Sönke Ahrens) | "Questions raised", "Counterpoints / what's missing" |
| **Faceted search / discovery** | `domain`, `tags`, `difficulty`, `audience`, `reading_time_min`, `source_credibility` |

Delete `~/.farshid/template-webclip-ai.md` to regenerate it from the
latest version after a project update.

### Adding your own field

Just add a line. The placeholder name **is** your prompt:

```markdown
backlinks: {3 wikilink-style [[concept]] references this note should connect to}
steelman: {strongest steelman of the opposite view in 2 sentences}
applies_to_my_work: {how this connects to my work in <your domain>}
moc: {single most likely Map-of-Content this note belongs under}
citeable_claim: {one quotable claim from this content with the page URL}
```

No code changes, no restart — the bridge reads the template on every
clip, gathers all unknown `{...}` placeholders, and asks the LLM for
them in a single batched JSON call.

### Multi-line / bullet-list fields

The LLM is told that fields whose hints mention "points", "takeaways",
"questions", "items", "list", etc. should return newline-separated
`-` bullets. Single-fact fields return a short string.

---

## 7. Filename rule

`<year>-<mainurl>-<N>.md` where:

- `year` = current year, e.g. `2026`
- `mainurl` = the registrable label of the host
  (`https://www.github.com/x` → `github`,
  `https://news.ycombinator.com` → `ycombinator`)
- `N` = next free integer starting from `1` so existing files are never
  overwritten.

The **page snapshot** is saved as `<year>-<mainurl>-<N>.png` next to the
`.md` file, so any markdown viewer renders `![]({snapshot})` inline.
Snapshot capture is best-effort: it silently skips on `chrome://`,
`file://`, the Web Store, and the PDF viewer.

---

## 8. Project layout

```
farshid-ai-webclip/
├── README.md
├── LICENSE
├── farshid.png             # logo / source for extension icons
├── bridge/
│   ├── server.py           # localhost HTTP bridge -> Ollama -> .farshid file
│   ├── run.bat             # double-clickable launcher (Windows)
│   └── requirements.txt    # (empty - stdlib only)
├── extension/
│   ├── manifest.json       # MV3 manifest
│   ├── background.js       # service worker
│   ├── content.js          # extracts title/text/images from the page
│   ├── popup.html
│   ├── popup.js
│   └── icons/{16,48,128}.png
└── scripts/
    ├── farshid.sh          # macOS / Linux launcher
    └── farshid.bat         # Windows launcher
```

---

## 9. Useful commands

```bash
bash scripts/farshid.sh help          # show all commands
bash scripts/farshid.sh start         # start Ollama + bridge in foreground
bash scripts/farshid.sh stage         # re-copy runtime into ~/.farshid/runtime
bash scripts/farshid.sh doctor        # diagnose: bridge up? extension staged? autostart loaded?
bash scripts/farshid.sh moc           # rebuild ~/.farshid/MOC.md from current clips
bash scripts/farshid.sh uninstall     # remove auto-start (and Linux/Windows policy)
```

Verify it's running:

```bash
curl http://127.0.0.1:8765/health     # bridge
curl http://127.0.0.1:11434/api/tags  # Ollama
```

---

## 10. Troubleshooting

| Symptom                                                                       | Fix                                                                                                                                              |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Chrome shows "not from the Chrome Web Store" / can't enable** (macOS)       | Use the **Load unpacked** path on `~/.farshid/runtime/extension`. See section 2. Sideloaded `.crx` is blocked on personal Macs and there is no workaround. |
| **Extension not visible after restart** (macOS)                               | Open `chrome://extensions` → it's still there. If not: the staged folder may be missing — run `bash scripts/farshid.sh stage` and Load unpacked again. |
| **Bridge auto-start doesn't run / `~/.farshid/runtime/logs/launchagent.err.log` says `Operation not permitted`** | Your project lives in Dropbox/iCloud. The new staging step copies everything out — re-run `bash scripts/farshid.sh install`. |
| **Popup says "Failed to fetch"**                                              | Bridge isn't running. Check `curl http://127.0.0.1:8765/health`. Run `bash scripts/farshid.sh doctor`.                                            |
| **`ollama unreachable`**                                                      | Start Ollama (`ollama serve` or the desktop app) and confirm the model is pulled (`ollama list`).                                                |
| **`This page cannot be clipped`**                                             | Chrome blocks scripting on `chrome://`, the Web Store, and the PDF viewer. Open a normal site.                                                   |
| **Slow first run**                                                            | Ollama loads the model into memory the first time; subsequent clips are much faster.                                                             |
| **Want to change the model**                                                  | Edit `MODEL` in `scripts/local.env.sh` (or `FARSHID_MODEL` in your shell), then `bash scripts/farshid.sh start`.                                  |

---

## 11. Push to GitHub

```bash
cd farshid-ai-webclip
git init -b main
git add .
git commit -m "Initial commit: farshid-ai-webclip"

# with GitHub CLI:
gh repo create farshid-ai-webclip --public --source . --remote origin --push
```

> **Never commit `dist/*.pem`.** It's the signing key for your extension
> ID; losing it means a new ID and a re-install.
