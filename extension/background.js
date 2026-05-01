// Service worker: orchestrates clipping when the popup or context
// menu asks for it. Supports three modes:
//   "auto"      -> selection if present, else whole page
//   "selection" -> selection only (errors if nothing selected)
//   "page"      -> whole page

const DEFAULTS = {
  bridgeUrl: "http://127.0.0.1:8765",
};

function bridgeBase(urlOrBase) {
  // Tolerate the legacy ".../clip" form people may still have stored.
  const u = (urlOrBase || DEFAULTS.bridgeUrl).trim();
  return u.replace(/\/clip\/?$/, "").replace(/\/+$/, "") || DEFAULTS.bridgeUrl;
}

async function getSettings() {
  const stored = await chrome.storage.sync.get(["bridgeUrl"]);
  return { bridgeUrl: bridgeBase(stored.bridgeUrl) };
}

// Single-shot injection: define + call the extractor in one trip so we
// never depend on a previous file injection landing on `window`. Also
// surfaces the real per-frame error message instead of swallowing it.
async function extractFromTab(tabId, mode) {
  // Step 1: define farshidExtractInPage in the page (isolated world).
  await chrome.scripting.executeScript({
    target: { tabId, allFrames: false },
    files: ["content.js"],
  });
  // Step 2: call it. If it throws, surface that exact message.
  const results = await chrome.scripting.executeScript({
    target: { tabId, allFrames: false },
    func: (m) => {
      try {
        if (typeof window.__farshidExtract !== "function") {
          return { ok: false, error: "Extractor not loaded in this page." };
        }
        return { ok: true, value: window.__farshidExtract(m) };
      } catch (e) {
        return { ok: false, error: String((e && e.message) || e) };
      }
    },
    args: [mode],
  });
  const r = results && results[0];
  if (!r) throw new Error("Could not run extractor in this tab.");
  if (r.error) throw new Error(r.error.message || String(r.error));
  const v = r.result;
  if (!v) throw new Error("Extractor returned no value.");
  if (!v.ok) throw new Error(v.error || "Extractor failed.");
  return v.value;
}

async function clip(mode, modelOverride) {
  const settings = await getSettings();
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.id) throw new Error("No active tab.");
  if (!/^https?:/i.test(tab.url || "")) {
    throw new Error("This page cannot be clipped (not http/https).");
  }

  const page = await extractFromTab(tab.id, mode);

  const body = { page };
  if (modelOverride) body.model = modelOverride;

  const res = await fetch(`${settings.bridgeUrl}/clip`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    throw new Error(`Bridge error ${res.status}: ${errText || res.statusText}`);
  }
  return res.json();
}

// Popup channel.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === "CLIP_NOW") {
    clip(msg.mode || "auto", msg.model)
      .then((data) => sendResponse({ ok: true, data }))
      .catch((err) => sendResponse({ ok: false, error: String(err.message || err) }));
    return true; // async
  }
});

// Right-click context menus.
async function notify(tabId, title, message) {
  // Inline a tiny toast via scripting so we don't need notifications permission.
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: (t, m) => {
        const id = "__farshid_toast";
        document.getElementById(id)?.remove();
        const el = document.createElement("div");
        el.id = id;
        el.textContent = `${t}: ${m}`;
        Object.assign(el.style, {
          position: "fixed", right: "16px", bottom: "16px", zIndex: 2147483647,
          background: "rgba(20,20,20,.92)", color: "#fff",
          font: "13px/1.4 system-ui,sans-serif", padding: "10px 14px",
          borderRadius: "8px", maxWidth: "360px",
          boxShadow: "0 4px 16px rgba(0,0,0,.3)",
        });
        document.body.appendChild(el);
        setTimeout(() => el.remove(), 4500);
      },
      args: [title, message],
    });
  } catch (_) { /* ignore */ }
}

// Re-register menus on every service-worker wake-up. removeAll() is
// idempotent, and create() inside its callback avoids duplicate-id errors.
function ensureContextMenus() {
  try {
    chrome.contextMenus.removeAll(() => {
      chrome.contextMenus.create({
        id: "farshid-clip-selection",
        title: "Clip selection with Farshid AI",
        contexts: ["selection"],
      });
      chrome.contextMenus.create({
        id: "farshid-clip-page",
        title: "Clip whole page with Farshid AI",
        contexts: ["page"],
      });
    });
  } catch (_) { /* ignore */ }
}
chrome.runtime.onInstalled.addListener(ensureContextMenus);
chrome.runtime.onStartup.addListener(ensureContextMenus);
ensureContextMenus(); // also runs on every SW wake

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab?.id) return;
  const mode = info.menuItemId === "farshid-clip-selection" ? "selection" : "page";
  try {
    const data = await clip(mode);
    await notify(tab.id, "Farshid AI WebClip", `Saved ${data.filename}`);
  } catch (e) {
    await notify(tab.id, "Farshid AI WebClip error", String(e.message || e));
  }
});
