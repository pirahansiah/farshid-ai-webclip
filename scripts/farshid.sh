#!/usr/bin/env bash
# ============================================================
#  Farshid AI WebClip - macOS / Linux launcher
#
#  ONLY TWO COMMANDS YOU NEED:
#
#    ./farshid.sh install   One-time setup:
#                             - packs the extension
#                             - stages a self-contained copy of the
#                               bridge + extension under ~/.farshid/runtime
#                               (so it works even if this project lives in
#                                Dropbox / iCloud / a path with spaces)
#                             - registers the bridge to auto-start at login
#                             - opens chrome://extensions and tells you
#                               exactly where to point 'Load unpacked'
#                           Linux ONLY: also writes Chrome's enterprise
#                           ExtensionInstallForcelist policy so the
#                           extension auto-installs without Load unpacked.
#
#    ./farshid.sh start     Start Ollama (if needed) + the local bridge.
#                           The auto-start from `install` runs this at
#                           every login, so you rarely need to type it.
#
#  (Internal commands `pack`, `stage`, `forceinstall`, `forceuninstall`,
#   `uninstall`, `chrome`, `all`, `doctor` still exist for advanced use.)
#
#  Optional override file: scripts/local.env.sh (gitignored)
#    export PYTHON=/opt/homebrew/bin/python3
#    export OLLAMA=/opt/homebrew/bin/ollama
#    export MODEL=qwen3:0.6b
#    export CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BRIDGE_DIR="$PROJECT_DIR/bridge"
EXT_DIR="$PROJECT_DIR/extension"
DIST_DIR="$PROJECT_DIR/dist"
LOG_DIR="$PROJECT_DIR/logs"
CRX_FILE="$DIST_DIR/farshid-ai-webclip.crx"
PEM_FILE="$DIST_DIR/farshid-ai-webclip.pem"
UPDATES_XML="$DIST_DIR/updates.xml"
mkdir -p "$LOG_DIR"

# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/local.env.sh" ] && source "$SCRIPT_DIR/local.env.sh"

PYTHON="${PYTHON:-python3}"
OLLAMA="${OLLAMA:-ollama}"
MODEL="${MODEL:-minicpm-v:latest}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
CHROME_PROFILE="${CHROME_PROFILE:-$HOME/.farshid-ai-webclip/chrome-profile}"

# Staging dir OUTSIDE Dropbox/iCloud/CloudStorage so launchd (which runs
# /bin/bash without Full Disk Access) can actually read these files at login.
# Without this, a project living in ~/Dropbox/... resolves to
# ~/Library/CloudStorage/Dropbox/... and the LaunchAgent + Chrome policy
# both fail at boot with "Operation not permitted".
#
# Everything the running system needs (bridge code, packed .crx,
# signing key, updates.xml, launcher copy) is copied into here by
# `install` so the project folder itself is no longer required at runtime.
STAGE_DIR="${STAGE_DIR:-$HOME/.farshid/runtime}"
STAGE_BRIDGE="$STAGE_DIR/bridge"
STAGE_DIST="$STAGE_DIR/dist"
STAGE_LAUNCHER="$STAGE_DIR/farshid.sh"
STAGE_LOG_DIR="$STAGE_DIR/logs"

usage() {
    cat <<'EOF'

Farshid AI WebClip

  1)  ./farshid.sh install   One-time setup:
                                - packs the extension
                                - stages bridge + extension into
                                  ~/.farshid/runtime  (stable path)
                                - registers the bridge auto-start at login
                                - opens chrome://extensions for you
                              On macOS, finish with "Load unpacked" pointed
                              at  ~/.farshid/runtime/extension  (one click,
                              survives reboots).
                              On Linux, the extension is force-installed via
                              Chrome's enterprise policy automatically.

  2)  ./farshid.sh start     Start Ollama (if needed) + the local bridge.
                              The auto-start from `install` runs this at
                              every login, so you rarely need to type it.

  3)  ./farshid.sh doctor    Diagnose what's missing.

Advanced: pack | stage | forceinstall | forceuninstall | uninstall | chrome | all

EOF
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

ping_ollama() {
    curl -fsS --max-time 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1
}

resolve_chrome() {
    if [ -n "${CHROME:-}" ] && [ -x "$CHROME" ]; then return 0; fi
    case "$(uname -s)" in
        Darwin)
            for c in \
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
                [ -x "$c" ] && CHROME="$c" && return 0
            done
            ;;
        Linux)
            for c in google-chrome google-chrome-stable chromium chromium-browser brave-browser; do
                if command -v "$c" >/dev/null 2>&1; then
                    CHROME="$(command -v "$c")"
                    return 0
                fi
            done
            ;;
    esac
    return 1
}

# Kill any chrome.exe / Google Chrome process that has our dedicated
# CHROME_PROFILE in its command line. Without this, a stale Chrome
# attached to that --user-data-dir will accept new tabs without
# reloading --load-extension, so on-disk extension changes are ignored.
kill_dedicated_chrome() {
    local prof="$CHROME_PROFILE"
    [ -z "$prof" ] && return 0
    case "$(uname -s)" in
        Darwin|Linux)
            # pgrep -f matches against the full command line.
            local pids
            pids=$(pgrep -f "user-data-dir=$prof" 2>/dev/null || true)
            if [ -n "$pids" ]; then
                echo "[farshid] Stopping stale dedicated Chrome (pids: $pids)"
                # shellcheck disable=SC2086
                kill $pids 2>/dev/null || true
                sleep 1
                # shellcheck disable=SC2086
                kill -9 $pids 2>/dev/null || true
            fi
            ;;
    esac
}

# Compute the Chrome extension ID from a .pem private key.
# Algorithm: take the public key in DER, SHA-256 it, take first 16 bytes,
# and map each nibble (0..15) to a..p.
compute_ext_id() {
    local pem="$1"
    "$PYTHON" - "$pem" <<'PY'
import sys, base64, hashlib, subprocess
pem = sys.argv[1]
# Use openssl to extract the public key in DER.
der = subprocess.check_output(
    ["openssl", "rsa", "-in", pem, "-pubout", "-outform", "DER"],
    stderr=subprocess.DEVNULL,
)
h = hashlib.sha256(der).digest()[:16]
out = "".join(chr(ord('a') + ((b >> 4) & 0xF)) + chr(ord('a') + (b & 0xF)) for b in h)
print(out)
PY
}

# ------------------------------------------------------------
# start / chrome / all
# ------------------------------------------------------------

cmd_start() {
    echo "[farshid] Checking Ollama on $OLLAMA_URL ..."
    if ! ping_ollama; then
        echo "[farshid] Starting Ollama in background..."
        nohup "$OLLAMA" serve >>"$LOG_DIR/ollama.log" 2>&1 &
        for _ in $(seq 1 20); do
            ping_ollama && break
            sleep 0.5
        done
        if ! ping_ollama; then
            echo "[farshid] Ollama failed to start. Check $LOG_DIR/ollama.log"
            exit 1
        fi
    else
        echo "[farshid] Ollama already running."
    fi

    echo "[farshid] Ensuring model '$MODEL' is pulled..."
    "$OLLAMA" pull "$MODEL" >>"$LOG_DIR/ollama.log" 2>&1 || true

    if [ "${LAUNCH_CHROME:-0}" = "1" ]; then
        echo "[farshid] Launching Chrome with extension..."
        cmd_chrome || true
    fi

    echo "[farshid] Starting bridge from $BRIDGE_DIR"
    # Prefer the staged copy under ~/.farshid/runtime/bridge if present.
    # That path is always reachable by launchd, even when the project
    # itself lives in Dropbox/iCloud.
    local bridge_dir="$BRIDGE_DIR"
    if [ -f "$STAGE_BRIDGE/server.py" ]; then
        bridge_dir="$STAGE_BRIDGE"
        echo "[farshid] Using staged bridge: $bridge_dir"
    fi
    cd "$bridge_dir"
    exec "$PYTHON" server.py
}

cmd_chrome() {
    if ! resolve_chrome; then
        echo "[farshid] Cannot find Chrome. Set CHROME in scripts/local.env.sh"
        exit 1
    fi
    kill_dedicated_chrome
    mkdir -p "$CHROME_PROFILE"
    echo "[farshid] Chrome:        $CHROME"
    echo "[farshid] Extension:     $EXT_DIR"
    echo "[farshid] User profile:  $CHROME_PROFILE"
    nohup "$CHROME" \
        --user-data-dir="$CHROME_PROFILE" \
        --load-extension="$EXT_DIR" \
        --no-first-run \
        --no-default-browser-check \
        >/dev/null 2>&1 &
    disown || true
}

cmd_all() {
    LAUNCH_CHROME=1 cmd_start
}

# ------------------------------------------------------------
# pack
# ------------------------------------------------------------

cmd_pack() {
    if ! resolve_chrome; then
        echo "[farshid] Cannot find Chrome. Set CHROME in scripts/local.env.sh"
        exit 1
    fi
    mkdir -p "$DIST_DIR"

    # Chrome --pack-extension writes extension.crx + extension.pem next to extension/.
    local tmp_crx="$EXT_DIR.crx"
    local tmp_pem="$EXT_DIR.pem"
    rm -f "$tmp_crx" "$tmp_pem"

    if [ -f "$PEM_FILE" ]; then
        echo "[farshid] Reusing existing key: $PEM_FILE"
        "$CHROME" --pack-extension="$EXT_DIR" --pack-extension-key="$PEM_FILE" >/dev/null 2>&1 || true
    else
        echo "[farshid] Generating new signing key (will be saved to $PEM_FILE)"
        "$CHROME" --pack-extension="$EXT_DIR" >/dev/null 2>&1 || true
    fi

    if [ ! -f "$tmp_crx" ]; then
        echo "[farshid] Packing failed: $tmp_crx not produced." >&2
        exit 1
    fi
    mv -f "$tmp_crx" "$CRX_FILE"
    if [ ! -f "$PEM_FILE" ] && [ -f "$tmp_pem" ]; then
        mv -f "$tmp_pem" "$PEM_FILE"
        chmod 600 "$PEM_FILE" || true
    elif [ -f "$tmp_pem" ]; then
        rm -f "$tmp_pem"
    fi

    local ext_id
    ext_id="$(compute_ext_id "$PEM_FILE")"
    local version
    version="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$EXT_DIR/manifest.json")"

    cat > "$UPDATES_XML" <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$ext_id'>
    <updatecheck codebase='file://$CRX_FILE' version='$version' />
  </app>
</gupdate>
EOF

    echo
    echo "[farshid] Packed:"
    echo "  .crx        $CRX_FILE"
    echo "  .pem        $PEM_FILE   (KEEP SECRET, do not commit)"
    echo "  updates.xml $UPDATES_XML"
    echo "  ID          $ext_id"
    echo "  version     $version"
}

# ------------------------------------------------------------
# forceinstall  (Chrome managed policy)
# ------------------------------------------------------------
#
# macOS:  Managed policies live under
#           /Library/Managed Preferences/com.google.Chrome.plist
#         Writing them needs sudo. We use `defaults write` so the
#         file is properly typed.
#
# Linux:  Chrome reads JSON files in
#           /etc/opt/chrome/policies/managed/      (Google Chrome)
#           /etc/chromium/policies/managed/        (Chromium)
#         We write farshid-ai-webclip.json into the appropriate one
#         (or both if present). Needs sudo.

forceinstall_macos() {
    local ext_id="$1"
    local crx="$STAGE_DIST/farshid-ai-webclip.crx"
    local updates_xml="$STAGE_DIST/updates.xml"
    local version
    version="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$EXT_DIR/manifest.json")"

    # ----------------------------------------------------------------------
    # Path 1: External Extensions JSON (fast, no profile install needed,
    # but Chrome WILL block it as "not from the Web Store" on personal
    # Macs unless the .mobileconfig in Path 2 is also installed).
    # ----------------------------------------------------------------------
    local ext_dirs=(
        "$HOME/Library/Application Support/Google/Chrome/External Extensions"
        "$HOME/Library/Application Support/Chromium/External Extensions"
        "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/External Extensions"
    )
    chmod 644 "$crx" 2>/dev/null || true
    for d in "${ext_dirs[@]}"; do
        local parent
        parent="$(dirname "$d")"
        if [ -d "$parent" ]; then
            mkdir -p "$d"
            cat > "$d/$ext_id.json" <<EOF
{
  "external_crx": "$crx",
  "external_version": "$version"
}
EOF
            echo "[farshid] Wrote $d/$ext_id.json"
        fi
    done

    # ----------------------------------------------------------------------
    # Path 2: Configuration Profile (.mobileconfig).
    #
    # On a personal (non-MDM) Mac, Chrome's ExtensionInstallForcelist is
    # only honored when delivered through a real macOS configuration
    # profile -- NOT through `defaults write`. Once the user installs
    # this .mobileconfig from System Settings -> Privacy & Security ->
    # Profiles, Chrome treats the extension as enterprise-managed and
    # the "not from the Web Store" warning disappears.
    # ----------------------------------------------------------------------
    local profile="$STAGE_DIR/farshid-ai-webclip.mobileconfig"
    local entry="$ext_id;file://$updates_xml"
    # Stable but per-machine UUIDs derived from the extension ID and host.
    local payload_uuid profile_uuid host
    host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
    payload_uuid="$("$PYTHON" -c "import uuid,sys;print(str(uuid.uuid5(uuid.NAMESPACE_DNS,'farshid-ai-webclip-payload-'+sys.argv[1]+'-'+sys.argv[2])).upper())" "$ext_id" "$host")"
    profile_uuid="$("$PYTHON" -c "import uuid,sys;print(str(uuid.uuid5(uuid.NAMESPACE_DNS,'farshid-ai-webclip-profile-'+sys.argv[1]+'-'+sys.argv[2])).upper())" "$ext_id" "$host")"

    cat > "$profile" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key><string>com.google.Chrome</string>
            <key>PayloadDisplayName</key><string>Farshid AI WebClip - Chrome policy</string>
            <key>PayloadIdentifier</key><string>com.farshid.aiwebclip.chrome</string>
            <key>PayloadUUID</key><string>$payload_uuid</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadEnabled</key><true/>
            <key>ExtensionInstallForcelist</key>
            <array>
                <string>$entry</string>
            </array>
            <key>ExtensionInstallSources</key>
            <array>
                <string>file:///*</string>
            </array>
        </dict>
    </array>
    <key>PayloadDisplayName</key><string>Farshid AI WebClip</string>
    <key>PayloadIdentifier</key><string>com.farshid.aiwebclip</string>
    <key>PayloadType</key><string>Configuration</string>
    <key>PayloadUUID</key><string>$profile_uuid</string>
    <key>PayloadVersion</key><integer>1</integer>
    <key>PayloadScope</key><string>System</string>
    <key>PayloadOrganization</key><string>Farshid AI WebClip</string>
    <key>PayloadDescription</key><string>Allows Chrome to install the local Farshid AI WebClip extension from a file:// URL.</string>
</dict>
</plist>
EOF
    echo "[farshid] Wrote configuration profile: $profile"

    if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        echo
        echo "[farshid] Chrome is currently running. It must be FULLY quit"
        echo "          (Cmd+Q) before the profile can take effect."
        read -rp "Quit Chrome now? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            osascript -e 'tell application "Google Chrome" to quit' 2>/dev/null || true
            sleep 2
            pkill -x "Google Chrome" 2>/dev/null || true
        fi
    fi

    echo
    echo "[farshid] Opening the profile in System Settings..."
    open "$profile"
    cat <<EOF

[farshid] FINAL MANUAL STEP - install the profile (one time):

    1. macOS will (or just did) open System Settings.
       Look for: System Settings -> General -> Device Management
                 (or "Privacy & Security -> Profiles" on older macOS).
    2. Find "Farshid AI WebClip" under "Downloaded".
    3. Double-click it -> Install -> enter your Mac password.
    4. Open Chrome. The extension will appear under chrome://extensions
       with an "Installed by your administrator" badge.
       The "not from the Chrome Web Store" warning will be gone.

EOF
}

forceuninstall_macos() {
    local ext_id
    ext_id="$(compute_ext_id "$PEM_FILE" 2>/dev/null || echo '')"
    echo "[farshid] Removing External Extension JSON files..."
    for d in \
        "$HOME/Library/Application Support/Google/Chrome/External Extensions" \
        "$HOME/Library/Application Support/Chromium/External Extensions" \
        "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/External Extensions"; do
        if [ -n "$ext_id" ] && [ -f "$d/$ext_id.json" ]; then
            rm -f "$d/$ext_id.json"
            echo "[farshid] Removed $d/$ext_id.json"
        fi
    done
    echo "[farshid] To remove the configuration profile:"
    echo "          System Settings -> General -> Device Management"
    echo "          select 'Farshid AI WebClip' and click the minus button."
    # Best-effort cleanup of the old plist approach in case it was
    # written by a previous version.
    for prefs in "/Library/Preferences/com.google.Chrome" \
                 "/Library/Managed Preferences/com.google.Chrome"; do
        sudo -n defaults delete "$prefs" ExtensionInstallForcelist 2>/dev/null || true
        sudo -n defaults delete "$prefs" ExtensionInstallSources    2>/dev/null || true
    done
    echo "[farshid] Done. Fully quit and relaunch Chrome."
}

forceinstall_linux() {
    local ext_id="$1"
    local entry="$ext_id;file://$UPDATES_XML"
    local json
    json=$(cat <<EOF
{
  "ExtensionInstallForcelist": ["$entry"],
  "ExtensionInstallSources": ["file:///*"]
}
EOF
)
    local wrote=0
    for dir in /etc/opt/chrome/policies/managed /etc/chromium/policies/managed; do
        local parent
        parent="$(dirname "$dir")"
        if [ -d "$parent" ] || [ -d "$(dirname "$parent")" ]; then
            echo "[farshid] Writing $dir/farshid-ai-webclip.json (sudo)..."
            sudo mkdir -p "$dir"
            echo "$json" | sudo tee "$dir/farshid-ai-webclip.json" >/dev/null
            sudo chmod 644 "$dir/farshid-ai-webclip.json"
            wrote=1
        fi
    done
    if [ "$wrote" = "0" ]; then
        # Default to Chrome path even if not present yet.
        echo "[farshid] No Chrome/Chromium install detected. Writing /etc/opt/chrome/policies/managed/farshid-ai-webclip.json anyway (sudo)..."
        sudo mkdir -p /etc/opt/chrome/policies/managed
        echo "$json" | sudo tee /etc/opt/chrome/policies/managed/farshid-ai-webclip.json >/dev/null
        sudo chmod 644 /etc/opt/chrome/policies/managed/farshid-ai-webclip.json
    fi
    echo "[farshid] Done. Fully quit Chrome and reopen."
    echo "[farshid] Verify in Chrome:  chrome://policy"
}

forceuninstall_linux() {
    echo "[farshid] Removing Linux managed policy files (sudo required)..."
    for f in /etc/opt/chrome/policies/managed/farshid-ai-webclip.json \
             /etc/chromium/policies/managed/farshid-ai-webclip.json; do
        if [ -f "$f" ]; then
            sudo rm -f "$f"
            echo "[farshid] Removed $f"
        fi
    done
}

cmd_forceinstall() {
    if [ ! -f "$CRX_FILE" ] || [ ! -f "$PEM_FILE" ] || [ ! -f "$UPDATES_XML" ]; then
        echo "[farshid] Pack output missing. Running 'pack' first..."
        cmd_pack
    fi
    local ext_id
    ext_id="$(compute_ext_id "$PEM_FILE")"
    echo "[farshid] Extension ID: $ext_id"
    case "$(uname -s)" in
        Darwin) forceinstall_macos "$ext_id" ;;
        Linux)  forceinstall_linux "$ext_id" ;;
        *) echo "[farshid] Unsupported OS for forceinstall: $(uname -s)"; exit 1 ;;
    esac
}

cmd_forceuninstall() {
    case "$(uname -s)" in
        Darwin) forceuninstall_macos ;;
        Linux)  forceuninstall_linux ;;
        *) echo "[farshid] Unsupported OS for forceuninstall: $(uname -s)"; exit 1 ;;
    esac
}

# ------------------------------------------------------------
# stage - copy everything the runtime needs into ~/.farshid/runtime
# ------------------------------------------------------------
#
# The project folder may live anywhere (Dropbox, iCloud, an external
# disk, a path with spaces). LaunchAgents and Chrome both struggle
# with those locations. After `stage`, ~/.farshid/runtime is
# self-contained: bridge code, packed .crx, signing key, updates.xml,
# and a copy of this launcher. The LaunchAgent and Chrome's
# ExtensionInstallForcelist both point ONLY at files under there.

cmd_stage() {
    if [ ! -f "$CRX_FILE" ] || [ ! -f "$PEM_FILE" ]; then
        echo "[farshid] Pack output missing - running 'pack' first..."
        cmd_pack
    fi
    echo "[farshid] Staging runtime into $STAGE_DIR"
    mkdir -p "$STAGE_BRIDGE" "$STAGE_DIST" "$STAGE_LOG_DIR"

    # Bridge code
    cp -f "$BRIDGE_DIR"/*.py "$STAGE_BRIDGE"/ 2>/dev/null || true

    # Unpacked extension folder. This is what the user loads via
    # chrome://extensions -> Load unpacked when the .crx / managed
    # policy paths are blocked by Chrome's Web-Store check (which is
    # the case on personal, non-MDM macOS). Keeping it under
    # ~/.farshid/runtime/extension means the path is stable even if
    # the project folder lives in Dropbox/iCloud and gets moved.
    local stage_ext="$STAGE_DIR/extension"
    rm -rf "$stage_ext"
    mkdir -p "$stage_ext"
    cp -R "$EXT_DIR"/. "$stage_ext"/

    # Packed extension + signing key
    cp -f "$CRX_FILE" "$STAGE_DIST/farshid-ai-webclip.crx"
    cp -f "$PEM_FILE" "$STAGE_DIST/farshid-ai-webclip.pem"
    chmod 600 "$STAGE_DIST/farshid-ai-webclip.pem" || true

    # Re-write updates.xml so it points at the STAGED .crx, not the
    # one inside the (possibly Dropbox-sandboxed) project folder.
    local ext_id version
    ext_id="$(compute_ext_id "$PEM_FILE")"
    version="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$EXT_DIR/manifest.json")"
    cat > "$STAGE_DIST/updates.xml" <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$ext_id'>
    <updatecheck codebase='file://$STAGE_DIST/farshid-ai-webclip.crx' version='$version' />
  </app>
</gupdate>
EOF

    # Self-contained launcher copy so the LaunchAgent never touches
    # the original project path.
    cp -f "$SELF" "$STAGE_LAUNCHER"
    chmod +x "$STAGE_LAUNCHER"

    echo "[farshid] Staged:"
    echo "    bridge      $STAGE_BRIDGE"
    echo "    .crx        $STAGE_DIST/farshid-ai-webclip.crx"
    echo "    updates.xml $STAGE_DIST/updates.xml"
    echo "    launcher    $STAGE_LAUNCHER"
}

# ------------------------------------------------------------
# install / uninstall  (autostart + force-install)
# ------------------------------------------------------------

# The bridge autostart runs `start` (NOT `all`) so we don't open a
# stale dedicated-profile Chrome window at every login. The extension
# lives in the user's normal Chrome via the managed policy.

install_autostart_macos() {
    local agents="$HOME/Library/LaunchAgents"
    local label="com.farshid.aiwebclip"
    local plist="$agents/$label.plist"
    mkdir -p "$agents"
    # Run the STAGED launcher and bridge so launchd never has to read
    # the original project folder (which may be in Dropbox/iCloud and
    # therefore unreadable to /bin/bash under launchd).
    chmod +x "$STAGE_LAUNCHER" 2>/dev/null || true
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$STAGE_LAUNCHER</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key><string>$STAGE_DIR</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$STAGE_LOG_DIR/launchagent.out.log</string>
    <key>StandardErrorPath</key><string>$STAGE_LOG_DIR/launchagent.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF
    echo "[farshid] Wrote $plist"
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load   "$plist"
    echo "[farshid] LaunchAgent loaded. Bridge will start at every login."
}

uninstall_autostart_macos() {
    local plist="$HOME/Library/LaunchAgents/com.farshid.aiwebclip.plist"
    if [ -f "$plist" ]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "[farshid] Removed $plist"
    else
        echo "[farshid] No LaunchAgent at $plist"
    fi
}

install_autostart_linux() {
    local unit_dir="$HOME/.config/systemd/user"
    local unit="$unit_dir/farshid-ai-webclip.service"
    mkdir -p "$unit_dir"
    chmod +x "$SELF"
    cat > "$unit" <<EOF
[Unit]
Description=Farshid AI WebClip bridge + Ollama
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
ExecStart=/bin/bash $SELF start
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    echo "[farshid] Wrote $unit"
    systemctl --user daemon-reload
    systemctl --user enable --now farshid-ai-webclip.service
    echo "[farshid] To run even when not logged in:  sudo loginctl enable-linger \$USER"
}

uninstall_autostart_linux() {
    systemctl --user disable --now farshid-ai-webclip.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/farshid-ai-webclip.service"
    systemctl --user daemon-reload
    echo "[farshid] Removed systemd --user unit."
}

cmd_install() {
    echo "[farshid] Step 1/3 - packing extension..."
    cmd_pack

    echo
    echo "[farshid] Step 2/3 - staging runtime into $STAGE_DIR ..."
    cmd_stage

    echo
    echo "[farshid] Step 3/3 - installing bridge auto-start at login..."
    case "$(uname -s)" in
        Darwin) install_autostart_macos ;;
        Linux)  install_autostart_linux ;;
        *) echo "[farshid] Unsupported OS: $(uname -s)"; exit 1 ;;
    esac

    # On Linux we ALSO write the enterprise force-install policy
    # because Chrome on Linux honours it without an MDM profile.
    # On macOS we do NOT, because Apple silently refuses to install
    # unsigned config profiles on personal Macs, so we just guide the
    # user through the one-time "Load unpacked" flow below.
    if [ "$(uname -s)" = "Linux" ]; then
        echo
        echo "[farshid] Bonus - writing Chrome force-install policy (Linux only)..."
        cmd_forceinstall || true
    fi

    local stage_ext="$STAGE_DIR/extension"
    cat <<EOF

[farshid] DONE. The bridge + Ollama now start automatically at every login.

[farshid] FINAL ONE-TIME STEP (~30 seconds) - load the extension into Chrome:

   1. A Chrome tab will open at chrome://extensions.
   2. Top-right of that page: turn ON 'Developer mode'.
   3. Top-left of that page: click 'Load unpacked'.
   4. In the file picker, press Cmd+Shift+G  and paste exactly:
          $stage_ext
      Press Enter, then click 'Select'.
   5. 'Farshid AI WebClip' now appears - fully enabled, no warnings.
   6. Click the puzzle-piece icon in Chrome's toolbar -> pin
      'Farshid AI WebClip' so the icon is always visible.

   The extension lives at a stable path under \$HOME/.farshid/runtime
   so it survives reboots, Chrome updates, and project moves.

EOF

    if [ "$(uname -s)" = "Darwin" ]; then
        # Open Chrome on the extensions page so the user is one click
        # away from "Load unpacked".
        if pgrep -x "Google Chrome" >/dev/null 2>&1; then
            open -a "Google Chrome" "chrome://extensions" 2>/dev/null || true
        else
            open -a "Google Chrome" --args --new-window "chrome://extensions" 2>/dev/null \
                || open -a "Google Chrome" "chrome://extensions" 2>/dev/null || true
        fi
    fi
}

cmd_uninstall() {
    case "$(uname -s)" in
        Darwin) uninstall_autostart_macos ;;
        Linux)
            uninstall_autostart_linux
            cmd_forceuninstall || true
            ;;
    esac
    echo
    echo "[farshid] To remove the extension from Chrome:"
    echo "          chrome://extensions -> find 'Farshid AI WebClip' -> Remove."
    echo "[farshid] To wipe the staged runtime as well:"
    echo "          rm -rf $STAGE_DIR"
}

# ------------------------------------------------------------
# doctor - diagnose why the extension isn't showing up
# ------------------------------------------------------------

cmd_doctor() {
    echo "=== Farshid AI WebClip - doctor ==="
    echo
    echo "[1] OS:                $(uname -s) $(uname -r)"
    echo "[2] Project dir:       $PROJECT_DIR"
    echo "[3] Pack outputs:"
    for f in "$CRX_FILE" "$PEM_FILE" "$UPDATES_XML"; do
        if [ -f "$f" ]; then
            echo "    OK   $f"
        else
            echo "    MISS $f   (run: $SELF install)"
        fi
    done
    if [ -f "$PEM_FILE" ]; then
        echo "[4] Extension ID:      $(compute_ext_id "$PEM_FILE")"
    fi
    echo "[5] Bridge /health:"
    if curl -fsS --max-time 2 "http://127.0.0.1:8765/health" 2>/dev/null; then
        echo
    else
        echo "    DOWN  (run: $SELF start  - or wait for login autostart)"
    fi
    echo "[6] Settings file:"
    local settings="$HOME/.farshid/settings.json"
    if [ -f "$settings" ]; then echo "    OK   $settings"; cat "$settings" | sed 's/^/         /'
    else echo "    MISS $settings"; fi
    echo "[7] Staged extension folder (for chrome://extensions -> Load unpacked):"
    local stage_ext="$STAGE_DIR/extension"
    if [ -f "$stage_ext/manifest.json" ]; then
        echo "    OK   $stage_ext"
    else
        echo "    MISS $stage_ext   (run: $SELF stage)"
    fi
    case "$(uname -s)" in
        Darwin)
            local agent="$HOME/Library/LaunchAgents/com.farshid.aiwebclip.plist"
            echo "[8] LaunchAgent:       $agent"
            if [ -f "$agent" ]; then
                echo "    OK loaded? $(launchctl list | grep com.farshid.aiwebclip || echo NO)"
            else
                echo "    MISS  -> bridge will not start at login."
            fi
            echo
            echo "If the extension is missing in Chrome:"
            echo "  - Open chrome://extensions"
            echo "  - Turn ON 'Developer mode' (top right)"
            echo "  - Click 'Load unpacked' (top left)"
            echo "  - Pick: $stage_ext"
            ;;
        Linux)
            for d in /etc/opt/chrome/policies/managed /etc/chromium/policies/managed; do
                local f="$d/farshid-ai-webclip.json"
                if [ -f "$f" ]; then echo "[7] Policy: OK   $f"
                else echo "[7] Policy: MISS $f"; fi
            done
            local unit="$HOME/.config/systemd/user/farshid-ai-webclip.service"
            if [ -f "$unit" ]; then
                echo "[8] Service: OK $(systemctl --user is-active farshid-ai-webclip.service 2>/dev/null)"
            else
                echo "[8] Service: MISS  -> bridge will not start at login."
            fi
            ;;
    esac
}

# ------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------

case "${1:-help}" in
    start)            cmd_start ;;
    chrome)           cmd_chrome ;;
    all)              cmd_all ;;
    pack)             cmd_pack ;;
    stage)            cmd_stage ;;
    forceinstall)     cmd_forceinstall ;;
    forceuninstall)   cmd_forceuninstall ;;
    install)          cmd_install ;;
    uninstall)        cmd_uninstall ;;
    doctor)           cmd_doctor ;;
    help|-h|--help)   usage ;;
    *) echo "[farshid] Unknown command: $1"; usage; exit 1 ;;
esac
