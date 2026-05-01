# Farshid AI WebClip

<p align="center">
  <img src="farshid.png" alt="Farshid AI WebClip" width="160" />
</p>

A small **Chrome extension + local Python bridge** that:

1. Clips the **current tab** OR your **highlighted selection** (text, links,
   images in that area) when you click the toolbar icon, hit a popup
   button, or right-click.
2. Sends the page text/title/url (or just the selection) to **Ollama**
   (default `minicpm-v:latest`, or any model you set in `FARSHID_MODEL` /
   `scripts/local.env.sh`).
3. Asks the model for a short **summary** and **sentiment**.
4. Reads your template (`template-webclip-ai.md`), fills in the fields, and
   saves the result as Markdown into your PKM folder using the filename
   pattern `<year>-<mainurl>-<N>.md`.

> Project naming follows the pattern **`farshid-<action>-<what>`**, e.g.
> `farshid-ai-webclip` → action = `ai`, what = `webclip`.

Chrome extensions cannot write to the local filesystem or talk to your local
Ollama directly, so we ship a tiny **localhost-only** Python bridge
(`bridge/server.py`) that does both jobs.

---

## TL;DR

```bash
# macOS / Linux
ollama pull minicpm-v:latest
bash scripts/farshid.sh install
```

```bat
:: Windows
ollama pull minicpm-v:latest
scripts\farshid.bat install
```

That single `install` command:

- packs the extension,
- copies a self-contained runtime into `~/.farshid/runtime/` (so it works
  even if this project lives in Dropbox / iCloud / a path with spaces),
- registers the bridge to auto-start at every login,
- opens `chrome://extensions` for you with one-time instructions.

After it finishes, on **macOS** you do one 30-second click-through in
Chrome (load unpacked extension — see step 4 below). On **Windows** and
**Linux** the extension is auto-installed via Chrome's enterprise policy
and you just open Chrome.

---

## 1. Prerequisites

- [Ollama](https://ollama.com/) installed and running locally.
- One of the supported models pulled:
  ```bash
  ollama pull minicpm-v:latest
  # or
  ollama pull qwen3:0.6b
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

```bat
cd farshid-ai-webclip
scripts\farshid.bat install
```

(Self-elevates with UAC; writes the Chrome force-install policy under
`HKLM\Software\Policies\Google\Chrome` and a Startup-folder shortcut.)

### What `install` actually does

| Step | All OSes                                                                       |
| ---- | ------------------------------------------------------------------------------ |
| 1    | Packs the extension into `dist/farshid-ai-webclip.crx` (+ `.pem`, `updates.xml`). The signing key is reused on every run so the extension ID is stable. |
| 2    | Stages a self-contained copy of bridge code, the unpacked extension, the `.crx`, and a copy of the launcher into `~/.farshid/runtime/` (macOS/Linux) or `%USERPROFILE%\.farshid\runtime\` (Windows). Everything below points at that staged copy, so the project folder is no longer required at runtime, and OneDrive / Dropbox / iCloud sandboxing cannot break startup. |
| 3    | Registers the bridge + Ollama to start at login (LaunchAgent on macOS, systemd `--user` unit on Linux, Startup-folder shortcut pointing at the staged launcher on Windows). |
| 4    | **Linux & Windows only:** writes Chrome's `ExtensionInstallForcelist` policy (pointing at the staged `updates.xml`) so the extension installs (and re-installs) automatically with no user action. |

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

---

## 4. Where things live

| Path                                          | What                                                            |
| --------------------------------------------- | --------------------------------------------------------------- |
| `~/.farshid/`                                 | Output folder. All clipped `.md` files land here.               |
| `~/.farshid/template-webclip-ai.md`           | Your editable template (auto-created on first run).             |
| `~/.farshid/settings.json`                    | Bridge runtime info (model name, paths) — auto-managed.         |
| `~/.farshid/runtime/` *(or `%USERPROFILE%\.farshid\runtime\` on Windows)* | Self-contained staged runtime — extension, bridge, `.crx`, logs. |
| `~/.farshid/runtime/extension/`               | The unpacked extension you point Chrome at on macOS.            |
| `~/.farshid/runtime/logs/`                    | Bridge + LaunchAgent logs (`launchagent.out.log`, `.err.log`).  |
| `~/Library/LaunchAgents/com.farshid.aiwebclip.plist` (macOS) | Auto-start LaunchAgent.                          |
| `~/.config/systemd/user/farshid-ai-webclip.service` (Linux)  | Auto-start systemd unit.                         |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Farshid AI WebClip.lnk` (Windows) | Startup shortcut pointing at the staged launcher. |

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
| `FARSHID_MODEL`        | `minicpm-v:latest`                                                   |
| `FARSHID_BRIDGE_HOST`  | `127.0.0.1`                                                          |
| `FARSHID_BRIDGE_PORT`  | `8765`                                                               |

---

## 6. Template

The bridge auto-creates the output folder and template **on first launch**
(and again any time the template file is missing):

- Folder: `<FARSHID_OUT_DIR>` (default `~/.farshid/`)
- File:   `<FARSHID_TEMPLATE>` (default `~/.farshid/template-webclip-ai.md`)

Edit it freely — the bridge only re-creates it if you delete it. Use
`{field}` placeholders. Supported fields:

- `{date}` — `YYYY-MM-DD`
- `{datetime}` — `YYYY-MM-DD HH:MM:SS`
- `{title}` — page `<title>`
- `{url}` — page URL
- `{summary}` — Ollama-generated short summary
- `{image_count}` / `{number_of_images}` — count of `<img>` tags captured
- `{sentiment}` — `positive`, `negative`, or `neutral`
- `{is_selection}` — `True` if this clip came from a highlighted selection
- `{selection}` — the highlighted text (empty when whole-page clipping)
- `{filename}` — the output filename, e.g. `2026-github-1.md`
- `{model}` — model name used

Unknown placeholders are left as-is so they don't get clobbered.

Example template:

```markdown
date: {date}
title: {title}
url: {url}
summary: {summary}
number of images: {image_count}
positive or negative: {sentiment}
file: {filename}
```

---

## 7. Filename rule

`<year>-<mainurl>-<N>.md` where:

- `year` = current year, e.g. `2026`
- `mainurl` = the registrable label of the host
  (`https://www.github.com/x` → `github`,
  `https://news.ycombinator.com` → `ycombinator`)
- `N` = next free integer starting from `1` so existing files are never
  overwritten.

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
