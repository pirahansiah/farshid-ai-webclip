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
      .map((a) => ({
        href: a.href,
        text: (a.innerText || a.textContent || "").replace(/\s+/g, " ").trim(),
      }))
      .filter((l) => l.href && !l.href.startsWith("javascript:"));
  }
  function cleanText(t) {
    return (t || "").replace(/\s+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  }

  // ----- YouTube --------------------------------------------------------
  // Lightweight: pull the obvious DOM-rendered metadata + any visible
  // transcript panel ("Show transcript"). No external API calls, no auth.
  function isYouTubeWatch() {
    return /^(?:https?:)?\/\/(?:www\.)?(?:youtube\.com\/watch|youtu\.be\/)/i
      .test(location.href);
  }
  function ytVideoId() {
    try {
      const u = new URL(location.href);
      if (u.hostname.includes("youtu.be")) {
        return u.pathname.replace(/^\//, "").split(/[/?#]/)[0] || "";
      }
      return u.searchParams.get("v") || "";
    } catch (_) { return ""; }
  }
  function ytText(sel) {
    const el = document.querySelector(sel);
    return (el?.innerText || el?.textContent || "").trim();
  }
  function extractYouTubeTranscript() {
    // Intentionally disabled. The transcript panel only exists in the
    // DOM after the user clicks "Show transcript", which is fragile and
    // brittle across YouTube redesigns. We rely on the video
    // description (always present) instead.
    return "";
  }
  function extractYouTube() {
    const vid = ytVideoId();
    const title =
      ytText("h1.ytd-watch-metadata") ||
      ytText("h1.title") ||
      document.title.replace(/ - YouTube$/, "");
    const channel =
      ytText("ytd-channel-name #text a") ||
      ytText("ytd-channel-name a") ||
      ytText("#owner #channel-name");
    const views = ytText("#info span.view-count, ytd-watch-info-text");
    const description =
      ytText("#description-inline-expander") ||
      ytText("ytd-text-inline-expander") ||
      document.querySelector('meta[name="description"]')?.content || "";
    const parts = [];
    if (channel) parts.push(`Channel: ${channel}`);
    if (views)   parts.push(views);
    if (description) parts.push("Description:\n" + description);
    const text = parts.join("\n\n").slice(0, 20000);
    const images = vid
      ? [`https://i.ytimg.com/vi/${vid}/maxresdefault.jpg`]
      : collectImagesFromRoot(document).slice(0, 5);
    return {
      title: title || document.title,
      url: location.href,
      description: (description || "").slice(0, 280),
      text,
      images,
      image_count: images.length,
      links: collectLinksFromRoot(document).slice(0, 50),
      is_selection: false,
      kind: "youtube",
      youtube_id: vid,
      has_transcript: false,
    };
  }
  // ---------------------------------------------------------------------

  function extractWholePage() {
    if (isYouTubeWatch()) return extractYouTube();
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
