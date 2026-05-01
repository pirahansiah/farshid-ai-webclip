// Self-contained page-context extractor. Injected via chrome.scripting
// using `func:` so there's no need to also inject a file. Returns the
// extracted page object (or throws a descriptive error).
//
// mode:
//   "selection" -> extract ONLY what the user has highlighted; throw if empty.
//   "page"      -> extract the whole page.
//   "auto"      -> selection if non-empty, else whole page.
//
// Exported on window for legacy callers as well.
function farshidExtractInPage(mode) {
  mode = mode || "auto";

  function collectImagesFromRoot(root) {
    if (!root || !root.querySelectorAll) return [];
    return Array.from(root.querySelectorAll("img"))
      .map((i) => i.currentSrc || i.src)
      .filter((s) => s && !s.startsWith("data:"));
  }
  function collectLinksFromRoot(root) {
    if (!root || !root.querySelectorAll) return [];
    return Array.from(root.querySelectorAll("a[href]"))
      .map((a) => a.href)
      .filter((h) => h && !h.startsWith("javascript:"));
  }
  function cleanText(t) {
    return (t || "").replace(/\s+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  function extractWholePage() {
    const main =
      document.querySelector("article") ||
      document.querySelector("main") ||
      document.body;
    const clone = main.cloneNode(true);
    clone.querySelectorAll(
      "script,style,noscript,svg,iframe,nav,footer,header,aside,form"
    ).forEach((el) => el.remove());
    const text = cleanText(clone.innerText);
    const images = collectImagesFromRoot(document);
    return {
      title: document.title || "",
      url: location.href,
      description:
        document.querySelector('meta[name="description"]')?.content ||
        document.querySelector('meta[property="og:description"]')?.content ||
        "",
      text: text.slice(0, 20000),
      images,
      image_count: images.length,
      links: collectLinksFromRoot(document).slice(0, 50),
      is_selection: false,
    };
  }

  function extractSelection() {
    const sel = window.getSelection && window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
    const rawText = sel.toString();
    const text = cleanText(rawText);
    if (!text) return null;

    // Build a fragment containing the selected DOM so we can pull
    // images / links that fall inside the selection.
    const frag = document.createDocumentFragment();
    for (let i = 0; i < sel.rangeCount; i++) {
      frag.appendChild(sel.getRangeAt(i).cloneContents());
    }
    const wrap = document.createElement("div");
    wrap.appendChild(frag);

    let images = collectImagesFromRoot(wrap);
    const links = collectLinksFromRoot(wrap);

    // If the selection is text-only (e.g. a LinkedIn post body), also
    // include images from the smallest common ancestor element so the
    // saved clip captures nearby media the user clearly meant.
    if (images.length === 0 && sel.rangeCount > 0) {
      const range = sel.getRangeAt(0);
      let anc = range.commonAncestorContainer;
      if (anc && anc.nodeType === Node.TEXT_NODE) anc = anc.parentElement;
      if (anc && anc.querySelectorAll) {
        images = collectImagesFromRoot(anc);
      }
    }

    return {
      title: document.title || "",
      url: location.href,
      description: text.slice(0, 280),
      text: text.slice(0, 20000),
      images,
      image_count: images.length,
      links: links.slice(0, 50),
      is_selection: true,
    };
  }

  if (mode === "selection") {
    const s = extractSelection();
    if (!s) {
      throw new Error(
        "No text is selected on this page. Highlight some text first, " +
        "then try again. (If you opened the popup before selecting, your " +
        "selection may have been cleared - try right-click \u2192 'Clip selection " +
        "with Farshid AI' instead.)"
      );
    }
    return s;
  }
  if (mode === "auto") {
    const s = extractSelection();
    if (s) return s;
  }
  return extractWholePage();
}

// Legacy global so older background.js (file-injection style) keeps working.
window.__farshidExtract = farshidExtractInPage;
