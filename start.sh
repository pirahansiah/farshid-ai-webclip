#!/usr/bin/env bash
# ============================================================
#  start.sh - Boot all background services for Farshid AI
#
#  Run this once after an OS reboot (or add to your login items
#  / systemd user service / crontab @reboot).
#  Starts everything in the BACKGROUND, no terminal windows:
#
#    1. Ollama         (http://127.0.0.1:11434)
#    2. SearXNG        (http://127.0.0.1:8888, via Docker)
#    3. Farshid bridge (http://127.0.0.1:8765)
#
#  Safe to run multiple times: each service is only started
#  if its port isn't already listening.
#
#  Logs:  ~/.farshid/{ollama,searxng,bridge}.log
# ============================================================
set -u

HOME_DIR="${HOME}/.farshid"
mkdir -p "$HOME_DIR"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SEARXNG_CONTAINER="${SEARXNG_CONTAINER:-searxng}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"

echo
echo "=== start.sh - launching background services ==="
echo

# ---- helpers -----------------------------------------------
is_listening() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" -q && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | grep -E "[:.]${port}[[:space:]]+.*LISTEN" -q && return 0
    fi
    return 1
}

run_bg() {
    # run_bg <log> <cmd...>
    local log="$1"; shift
    nohup "$@" >>"$log" 2>&1 </dev/null &
    disown 2>/dev/null || true
}

# ---- 1) Ollama ---------------------------------------------
if is_listening 11434; then
    echo "[ollama]   already running on 11434"
elif command -v ollama >/dev/null 2>&1; then
    echo "[ollama]   starting in background..."
    run_bg "$HOME_DIR/ollama.log" ollama serve
else
    echo "[ollama]   SKIP - 'ollama' not on PATH"
fi

# ---- 2) SearXNG (Docker container) -------------------------
if is_listening "$SEARXNG_PORT"; then
    echo "[searxng]  already running on $SEARXNG_PORT"
elif ! command -v docker >/dev/null 2>&1; then
    echo "[searxng]  SKIP - docker not on PATH"
elif ! docker inspect "$SEARXNG_CONTAINER" >/dev/null 2>&1; then
    echo "[searxng]  SKIP - no docker container named \"$SEARXNG_CONTAINER\""
    echo "           create one with e.g.:"
    echo "           docker run -d --name searxng -p ${SEARXNG_PORT}:8080 --restart unless-stopped searxng/searxng"
else
    echo "[searxng]  starting container \"$SEARXNG_CONTAINER\"..."
    docker start "$SEARXNG_CONTAINER" >>"$HOME_DIR/searxng.log" 2>&1
fi

# ---- 3) Farshid bridge -------------------------------------
if is_listening 8765; then
    echo "[bridge]   already running on 8765"
else
    BRIDGE="$SCRIPT_DIR/bridge/server.py"
    [ -f "$BRIDGE" ] || BRIDGE="$HOME/.farshid/runtime/bridge/server.py"
    if [ -f "$BRIDGE" ]; then
        PY="${PYTHON:-python3}"
        command -v "$PY" >/dev/null 2>&1 || PY=python
        echo "[bridge]   starting in background ($BRIDGE)..."
        run_bg "$HOME_DIR/bridge.log" "$PY" "$BRIDGE"
    else
        echo "[bridge]   SKIP - server.py not found"
        echo "           expected: $SCRIPT_DIR/bridge/server.py"
    fi
fi

echo
echo "Done. Tail logs in: $HOME_DIR"
