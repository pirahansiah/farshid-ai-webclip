// Popup logic.
//
// Model list comes from the bridge (`GET /models`, which proxies
// Ollama's local /api/tags). The chosen model is persisted in the
// bridge's settings file (~/.farshid/settings.json) via `POST /settings`,
// so the choice survives Chrome reinstalls and is shared across all
// callers (popup, context menu, future CLI, etc.). The bridge URL
// itself stays in chrome.storage.sync because we need it to even
// reach the bridge.

const DEFAULTS = {
  bridgeUrl: "http://127.0.0.1:8765",
};

const $ = (id) => document.getElementById(id);

try {
  const v = chrome.runtime.getManifest().version;
  $("ver").textContent = `v${v}`;
} catch (_) {}

function setStatus(text, cls = "") {
  const el = $("status");
  el.textContent = text;
  el.className = cls;
}

function bridgeBase(urlOrBase) {
  // Accept both the legacy ".../clip" URL and the new base URL.
  const u = (urlOrBase || DEFAULTS.bridgeUrl).trim();
  return u.replace(/\/clip\/?$/, "").replace(/\/+$/, "") || DEFAULTS.bridgeUrl;
}

async function getStoredBridge() {
  const s = await chrome.storage.sync.get(["bridgeUrl"]);
  return bridgeBase(s.bridgeUrl);
}

async function fetchJson(url, opts) {
  const res = await fetch(url, opts);
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = { error: text }; }
  if (!res.ok || data.error) {
    throw new Error(data.error || `${res.status} ${res.statusText}`);
  }
  return data;
}

async function loadModels() {
  const base = await getStoredBridge();
  $("bridgeUrl").value = base;
  setStatus("Loading models from Ollama\u2026");
  try {
    const data = await fetchJson(`${base}/models`);
    const sel = $("model");
    sel.innerHTML = "";
    for (const name of data.models || []) {
      const opt = document.createElement("option");
      opt.value = name; opt.textContent = name;
      sel.appendChild(opt);
    }
    if (data.current && !data.models?.includes(data.current)) {
      // Surface a missing default so the user knows they need to pull it.
      const opt = document.createElement("option");
      opt.value = data.current;
      opt.textContent = `${data.current}  (not pulled)`;
      sel.appendChild(opt);
    }
    sel.value = data.current || (data.models && data.models[0]) || "";
    $("modelHint").textContent = data.models?.length
      ? `${data.models.length} model(s) installed. Default is saved on the bridge.`
      : "No Ollama models installed yet. Use 'Pull a new model' below.";
    setStatus("");
  } catch (e) {
    setStatus(`Cannot reach bridge at ${base}: ${e.message}`, "err");
  }
}

async function saveModel() {
  const base = await getStoredBridge();
  const model = $("model").value;
  if (!model) return;
  try {
    await fetchJson(`${base}/settings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model }),
    });
    setStatus(`Default model set to ${model}.`, "ok");
  } catch (e) {
    setStatus(`Could not save model: ${e.message}`, "err");
  }
}

async function clip(mode, label) {
  setStatus(`Clipping ${label}\u2026 (calling Ollama, can take a moment)`);
  try {
    // We deliberately pass the popup's selected model so this clip
    // uses what the user sees, even if they haven't hit Save yet.
    const model = $("model").value || undefined;
    const resp = await chrome.runtime.sendMessage({ type: "CLIP_NOW", mode, model });
    if (!resp?.ok) throw new Error(resp?.error || "Unknown error");
    const tag = resp.data?.fields?.is_selection ? " [selection]" : "";
    setStatus(`Saved${tag}: ${resp.data.path}`, "ok");
  } catch (e) {
    setStatus(`Error: ${e.message || e}`, "err");
  }
}

async function pullModel() {
  const base = await getStoredBridge();
  const name = $("pullName").value.trim();
  if (!name) { setStatus("Type a model name (e.g. llama3.2:3b).", "err"); return; }
  setStatus(`Pulling ${name}\u2026 this may take a while.`);
  $("pullBtn").disabled = true;
  try {
    await fetchJson(`${base}/pull`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: name }),
    });
    setStatus(`Pulled ${name}.`, "ok");
    await loadModels();
    $("model").value = name;
  } catch (e) {
    setStatus(`Pull failed: ${e.message}`, "err");
  } finally {
    $("pullBtn").disabled = false;
  }
}

$("model").addEventListener("change", saveModel);
$("clipAuto").addEventListener("click", () => clip("auto", "page or selection"));
$("clipSelection").addEventListener("click", () => clip("selection", "selection"));
$("clipPage").addEventListener("click", () => clip("page", "whole page"));
$("pullBtn").addEventListener("click", pullModel);
$("save").addEventListener("click", async () => {
  await chrome.storage.sync.set({ bridgeUrl: bridgeBase($("bridgeUrl").value) });
  setStatus("Bridge URL saved.", "ok");
  await loadModels();
});

loadModels();
