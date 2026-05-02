# scripts/

Two files. That's it.

- `farshid.bat` — Windows
- `farshid.sh`  — macOS / Linux

Both manage a Chrome extension + local Python bridge that clips pages,
captures a PNG snapshot, and asks Ollama to fill a PKM template (see
the top-level [README](../README.md) for the full feature list).

Both expose the same subcommands:

| Command           | What it does                                                                                                                                       |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setup` *(Windows; default when you double-click `farshid.bat`)* | One-click no-admin flow: pack + stage + install hidden auto-start + start the bridge hidden in the background + open `chrome://extensions` for the one-time Load-unpacked click. Path is auto-copied to your clipboard. |
| `install`         | The big one. Pack + stage + register auto-start. On Linux force-installs into Chrome via enterprise policy. On macOS / Windows opens `chrome://extensions` and tells you the one Load-unpacked click left to do (no admin). |
| `start`           | Start Ollama (if not running) + the local bridge in the foreground (visible window — useful for debugging).                                          |
| `start-hidden`    | *(Windows only)* Start the bridge + Ollama in the background with no console window. Same launcher used by login auto-start.                        |
| `stop`            | *(Windows only)* Stop the running bridge process bound to port 8765.                                                                                 |
| `stage`           | Re-copy the bridge + extension + .crx into `~/.farshid/runtime/`. Run this if you change `extension/` or `bridge/`.                                  |
| `doctor`          | Diagnose: bridge up? extension folder staged? auto-start loaded? PKM template stats? recent clips?                                                  |
| `moc`             | Rebuild `~/.farshid/MOC.md` (Map of Content) from existing clips. Also runs automatically after every save.                                         |
| `pack`            | Just rebuild `dist/farshid-ai-webclip.crx` + `.pem` + `updates.xml` and print the extension ID.                                                     |
| `chrome`          | Launch a dedicated Chrome instance with `--load-extension=extension/`. Mostly useful when developing.                                               |
| `all`             | `start` + `chrome`.                                                                                                                                |
| `cleanup-admin`   | *(Windows only)* One-time admin step (UAC) to delete a leftover HKLM `ExtensionInstallForcelist` policy from older versions of this script. After running once you never need admin again. |
| `forceinstall`    | (Linux only on the new flow) write Chrome's `ExtensionInstallForcelist`. (Windows: removed by default — see `cleanup-admin`. macOS: also generates a `.mobileconfig`, but Apple silently refuses to install unsigned profiles on personal Macs.) |
| `forceuninstall`  | Remove the policy / external-extension JSON written by `forceinstall`.                                                                              |
| `uninstall`       | Remove the auto-start entry.                                                                                                                       |
| `help`            | Show usage.                                                                                                                                        |

```bash
# macOS / Linux
bash scripts/farshid.sh install
bash scripts/farshid.sh start
bash scripts/farshid.sh doctor
bash scripts/farshid.sh uninstall
```

```bat
:: Windows  (no admin needed)
scripts\farshid.bat            :: full one-click setup, then exits;
                               :: bridge keeps running hidden in background.
scripts\farshid.bat doctor     :: health-check
scripts\farshid.bat stop       :: stop the hidden bridge
scripts\farshid.bat uninstall  :: remove auto-start shortcut
```

## Why a separate `~/.farshid/runtime/` staging dir?

Two reasons, both bit me on macOS — and Windows benefits identically:

1. **Dropbox / iCloud / OneDrive paths are unreadable to background
   processes.** On macOS `~/Dropbox/...` resolves to
   `~/Library/CloudStorage/Dropbox/...`, which `/bin/bash` cannot read
   when started by a LaunchAgent — the bridge crashed at every login
   with `Operation not permitted`. On Windows, OneDrive's Files-On-Demand
   can do the same to `.bat` shortcuts. Staging into
   `~/.farshid/runtime/` (or `%USERPROFILE%\.farshid\runtime\`) fixes
   this.

2. **Stable path that survives project moves.** The Chrome extension
   folder you point Load unpacked at must not move, or Chrome silently
   drops the extension on next start. The staged `extension/` folder is
   permanent.

After `install`, the project folder itself is no longer required at runtime.

## PKM template lives at `~/.farshid/template-webclip-ai.md`

The template is what makes each clip a structured note. It is created
on first launch and **never overwritten** by the bridge — your edits
stick. To regenerate it from the latest project version, just delete it.

Add fields with plain English inside `{...}`. The placeholder name is
the prompt sent to the LLM. See the [top-level README, section 6](../README.md#6-template)
for the full list of built-in placeholders, the auto-appended sections,
and the PKM frameworks (Zettelkasten, BASB+PARA, Progressive
Summarization, Evergreen, LYT, Smart Notes) the default template is
based on.

## Override defaults

Create one of these (gitignored — see `.gitignore`):

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
REM optional: set CHROME=C:\Path\To\chrome.exe
```

## What `install` actually does

| OS       | Auto-start mechanism                                                                                                                              | Extension delivery                                                                                  |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| macOS    | LaunchAgent `~/Library/LaunchAgents/com.farshid.aiwebclip.plist` running the staged `farshid.sh start` (`RunAtLoad=true`, `KeepAlive=true`).      | `chrome://extensions` → **Load unpacked** → `~/.farshid/runtime/extension/`. One-time, then forever.|
| Linux    | systemd `--user` unit `~/.config/systemd/user/farshid-ai-webclip.service` running `farshid.sh start`. Use `sudo loginctl enable-linger $USER` to run at boot, not just login. | `ExtensionInstallForcelist` JSON in `/etc/opt/chrome/policies/managed/`, pointing at the staged `~/.farshid/runtime/dist/updates.xml`. Auto-installs. |
| Windows  | One `.lnk` in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` pointing at `wscript.exe %USERPROFILE%\.farshid\runtime\bridge-hidden.vbs`. The VBS launches Ollama (if needed) + the Python bridge with no console window. | `chrome://extensions` → **Load unpacked** → `%USERPROFILE%\.farshid\runtime\extension`. One-time, no admin. The path is auto-copied to your clipboard by `farshid.bat`. |

`uninstall` removes whichever of the above was created.

## Verify it's up

```bash
curl http://127.0.0.1:8765/health
curl http://127.0.0.1:11434/api/tags
# chrome://extensions  -> "Farshid AI WebClip" should be there
```

Or:
```bash
bash scripts/farshid.sh doctor
```

## Manual cleanup

If something is stuck:

- macOS:
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.farshid.aiwebclip.plist
  pkill -f bridge/server.py
  rm -rf ~/.farshid/runtime
  ```
- Linux:
  ```bash
  systemctl --user disable --now farshid-ai-webclip.service
  pkill -f bridge/server.py
  rm -rf ~/.farshid/runtime
  ```
- Windows:
  ```bat
  scripts\farshid.bat stop
  del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Farshid AI WebClip.lnk"
  rmdir /S /Q "%USERPROFILE%\.farshid\runtime"
  :: If `farshid.bat doctor` warns about a leftover HKLM policy from
  :: an old version of this script, also run (one-time UAC):
  scripts\farshid.bat cleanup-admin
  ```
