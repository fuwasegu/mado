/* ============================================================
   Markdown Viewer — rendering core
   - markdown-it + highlight.js + mermaid
   - morphdom による差分更新(スクロール位置・描画済み図を保持)
   - mermaid SVG はソースのハッシュでキャッシュし、無関係な編集で再描画しない
   ============================================================ */
"use strict";

const bridge = (type, payload = {}) =>
  window.webkit?.messageHandlers?.bridge?.postMessage({ type, ...payload });

const isDark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

// ---------- mermaid ----------
// SVG キャッシュ。テーマ変更時以外クリアされないため、長時間使用での無制限な
// メモリ肥大(→メモリ圧→スクロール劣化)を防ぐべく LRU で上限を設ける。
const MERMAID_CACHE_LIMIT = 100;
const mermaidCache = new Map(); // hash -> svg string(挿入順 = LRU の古い順)
let mermaidSeq = 0;

function mermaidCacheGet(hash) {
  const svg = mermaidCache.get(hash);
  if (svg !== undefined) {
    // 参照したものを末尾へ移動し、LRU 順を保つ
    mermaidCache.delete(hash);
    mermaidCache.set(hash, svg);
  }
  return svg;
}

function mermaidCacheSet(hash, svg) {
  mermaidCache.delete(hash);
  mermaidCache.set(hash, svg);
  while (mermaidCache.size > MERMAID_CACHE_LIMIT) {
    mermaidCache.delete(mermaidCache.keys().next().value); // 最も古いものを捨てる
  }
}

function initMermaid() {
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "loose",
    theme: isDark() ? "dark" : "neutral",
    fontFamily: '-apple-system, "Helvetica Neue", "Hiragino Sans", sans-serif',
  });
}
initMermaid();

function hashString(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h.toString(36) + "_" + s.length.toString(36);
}

// ---------- markdown-it ----------
const md = window
  .markdownit({
    html: true,
    linkify: true,
    typographer: false,
    highlight(code, lang) {
      if (lang && hljs.getLanguage(lang)) {
        try {
          return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
        } catch (_) {}
      }
      return md.utils.escapeHtml(code);
    },
  })
  .use(window.markdownitTaskLists, { enabled: false, label: false });

// fence: mermaid は専用コンテナ、その他は言語バッジ+コピーボタン付きラッパー
const defaultFence = md.renderer.rules.fence;
md.renderer.rules.fence = (tokens, idx, options, env, self) => {
  const token = tokens[idx];
  const lang = (token.info || "").trim().split(/\s+/)[0];
  if (lang === "mermaid") {
    const src = token.content.trim();
    const h = hashString(src + (isDark() ? ":d" : ":l"));
    return (
      `<div class="mermaid" id="mm-${h}" data-hash="${h}" data-src="${encodeURIComponent(src)}"></div>`
    );
  }
  const inner = defaultFence(tokens, idx, options, env, self);
  const langBadge = lang
    ? `<span class="code-lang">${md.utils.escapeHtml(lang)}</span>`
    : "";
  return `<div class="code-block">${langBadge}<button class="copy-btn">Copy</button>${inner}</div>`;
};

// 画像: 相対パスを表示中ファイルのディレクトリ基準の file:// に解決
const defaultImage = md.renderer.rules.image;
md.renderer.rules.image = (tokens, idx, options, env, self) => {
  const token = tokens[idx];
  const src = token.attrGet("src");
  if (src && !/^[a-z][a-z0-9+.-]*:/i.test(src)) {
    const abs = src.startsWith("/") ? src : joinPath(env.dir || "/", src);
    token.attrSet("src", "file://" + encodeURI(abs));
  }
  return defaultImage(tokens, idx, options, env, self);
};

function joinPath(dir, rel) {
  const parts = dir.split("/").filter(Boolean);
  for (const seg of rel.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") parts.pop();
    else parts.push(seg);
  }
  return "/" + parts.join("/");
}

// ---------- file-type renderers ----------

function renderMarkdownDoc(src) {
  // YAML front matter は折りたたみ表示
  let fmHtml = "";
  const fm = src.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (fm) {
    src = src.slice(fm[0].length);
    fmHtml =
      `<details class="front-matter"><summary>front matter</summary>` +
      `<pre>${md.utils.escapeHtml(fm[1])}</pre></details>`;
  }
  return fmHtml + md.render(src, { dir: currentDir });
}

// json / yaml: 全体を1つのコードブロックとして表示
const HIGHLIGHT_SIZE_LIMIT = 400_000; // これ以上はハイライトせず即表示

function renderCodeDoc(src, lang) {
  // 1行に潰された JSON は整形して表示
  if (lang === "json" && src.length < 2_000_000 && !src.trim().includes("\n")) {
    try {
      src = JSON.stringify(JSON.parse(src), null, 2);
    } catch (_) {}
  }
  const code =
    src.length > HIGHLIGHT_SIZE_LIMIT
      ? md.utils.escapeHtml(src)
      : hljs.highlight(src, { language: lang, ignoreIllegals: true }).value;
  return (
    `<div class="code-block file-view"><span class="code-lang">${lang}</span>` +
    `<button class="copy-btn">Copy</button>` +
    `<pre><code class="hljs">${code}</code></pre></div>`
  );
}

// .mermaid / .mmd: ファイル全体を1つの図として描画(キャッシュ機構は fence と共通)
function renderMermaidDoc(src) {
  const s = src.trim();
  const h = hashString(s + (isDark() ? ":d" : ":l"));
  return `<div class="mermaid" id="mm-${h}" data-hash="${h}" data-src="${encodeURIComponent(s)}"></div>`;
}

// csv / tsv: RFC4180 準拠パーサ(クォート・エスケープ・セル内改行対応)
const MAX_TABLE_ROWS = 5000;

function parseDSV(src, delim, maxRows) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (inQuotes) {
      if (c === '"') {
        if (src[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"' && field === "") {
      inQuotes = true;
    } else if (c === delim) {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && src[i + 1] === "\n") i++;
      row.push(field);
      field = "";
      rows.push(row);
      row = [];
      if (rows.length > maxRows) return { rows, truncated: true };
    } else {
      field += c;
    }
  }
  if (field !== "" || row.length) {
    row.push(field);
    rows.push(row);
  }
  return { rows, truncated: false };
}

function renderTableDoc(src, delim) {
  const { rows, truncated } = parseDSV(src, delim, MAX_TABLE_ROWS);
  const clean = rows.filter((r) => !(r.length === 1 && r[0] === ""));
  if (!clean.length) return `<p class="empty-note">(空のファイル)</p>`;
  const esc = md.utils.escapeHtml;
  const head = clean[0];
  const body = clean.slice(1);
  const parts = [
    `<div class="data-table"><table><thead><tr><th class="row-num">#</th>`,
    ...head.map((c) => `<th>${esc(c)}</th>`),
    `</tr></thead><tbody>`,
  ];
  for (let i = 0; i < body.length; i++) {
    parts.push(`<tr><td class="row-num">${i + 1}</td>`);
    for (const c of body[i]) parts.push(`<td>${esc(c)}</td>`);
    parts.push(`</tr>`);
  }
  parts.push(`</tbody></table>`);
  if (truncated) {
    parts.push(`<p class="truncate-note">大きなファイルのため先頭 ${MAX_TABLE_ROWS} 行のみ表示しています</p>`);
  }
  parts.push(`</div>`);
  return parts.join("");
}

// ---------- OpenAPI (Redoc) ----------

// yaml/json の先頭付近に openapi/swagger キーがあればドキュメントモード
function detectOpenAPI(src, ext) {
  const head = src.slice(0, 4096);
  if (ext === "json") return /"(openapi|swagger)"\s*:/.test(head);
  return /^[ \t]*["']?(openapi|swagger)["']?[ \t]*:/m.test(head);
}

const readFileViaBridge = (path) =>
  window.webkit.messageHandlers.readFile.postMessage({ path });

let redocLoading = null;
function loadRedoc() {
  // 1.1MB あるので OpenAPI ファイルを開いた時だけロードする
  if (window.Redoc) return Promise.resolve();
  if (!redocLoading) {
    redocLoading = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "vendor/redoc.standalone.js";
      s.onload = resolve;
      s.onerror = () => reject(new Error("failed to load redoc.standalone.js"));
      document.head.appendChild(s);
    });
  }
  return redocLoading;
}

function dirOf(p) {
  return p.slice(0, p.lastIndexOf("/")) || "/";
}

function escapePointerSegment(s) {
  return s.replace(/~/g, "~0").replace(/\//g, "~1");
}

function getByPointer(obj, pointer) {
  let cur = obj;
  for (const raw of pointer.split("/").slice(1)) {
    const key = decodeURIComponent(raw).replace(/~1/g, "/").replace(/~0/g, "~");
    if (cur == null) return undefined;
    cur = cur[key];
  }
  return cur;
}

// 外部ファイル $ref を解決してスペックに埋め込む。
// - 同一参照は最初に展開した場所への内部 $ref に書き換え(重複排除 + 循環参照対応)
// - 外部ファイル内の内部 $ref はそのファイル基準の外部 ref に書き換えてから再帰解決
async function bundleExternalRefs(doc, mainDir) {
  const registry = new Map(); // "absPath#/frag" -> "#/path/in/main/doc"
  const fileCache = new Map();

  async function loadExternalDoc(absPath) {
    if (!fileCache.has(absPath)) {
      const text = await readFileViaBridge(absPath);
      fileCache.set(
        absPath,
        absPath.toLowerCase().endsWith(".json") ? JSON.parse(text) : jsyaml.load(text)
      );
    }
    return fileCache.get(absPath);
  }

  function rewriteInternalRefs(node, absFile) {
    if (Array.isArray(node)) {
      for (const c of node) rewriteInternalRefs(c, absFile);
    } else if (node && typeof node === "object") {
      if (typeof node.$ref === "string" && node.$ref.startsWith("#")) {
        node.$ref = absFile + node.$ref;
      }
      for (const k of Object.keys(node)) rewriteInternalRefs(node[k], absFile);
    }
  }

  async function walk(node, baseDir, pathFromRoot) {
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) {
        const replaced = await walk(node[i], baseDir, [...pathFromRoot, String(i)]);
        if (replaced !== undefined) node[i] = replaced;
      }
      return undefined;
    }
    if (!node || typeof node !== "object") return undefined;

    if (typeof node.$ref === "string" && !node.$ref.startsWith("#")) {
      const hashIdx = node.$ref.indexOf("#");
      const filePart = hashIdx === -1 ? node.$ref : node.$ref.slice(0, hashIdx);
      const frag = hashIdx === -1 ? "" : node.$ref.slice(hashIdx + 1);
      const abs = filePart.startsWith("/") ? filePart : joinPath(baseDir, filePart);
      const key = abs + "#" + frag;

      if (registry.has(key)) return { $ref: registry.get(key) };
      // 再帰前に登録することで循環参照を内部 $ref に変換できる
      registry.set(key, "#/" + pathFromRoot.join("/"));

      const extDoc = await loadExternalDoc(abs);
      const target = frag ? getByPointer(extDoc, frag) : extDoc;
      if (target === undefined) {
        return { description: `⚠️ unresolved $ref: ${node.$ref}` };
      }
      const clone = structuredClone(target);
      rewriteInternalRefs(clone, abs);
      await walk(clone, dirOf(abs), pathFromRoot);
      return clone;
    }

    for (const k of Object.keys(node)) {
      const replaced = await walk(node[k], baseDir, [
        ...pathFromRoot,
        escapePointerSegment(k),
      ]);
      if (replaced !== undefined) node[k] = replaced;
    }
    return undefined;
  }

  await walk(doc, mainDir, []);
  return doc;
}

function redocTheme() {
  const sans =
    '-apple-system, BlinkMacSystemFont, "Helvetica Neue", "Hiragino Sans", sans-serif';
  const mono = 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace';
  const dark = isDark();
  return {
    typography: {
      fontFamily: sans,
      fontSize: "14.5px",
      headings: { fontFamily: sans, fontWeight: "650" },
      code: { fontFamily: mono },
    },
    sidebar: dark
      ? { backgroundColor: "#161b22", textColor: "#e6edf3" }
      : { backgroundColor: "#f6f8fa" },
    rightPanel: { backgroundColor: dark ? "#0d1117" : "#263238" },
    colors: dark
      ? {
          primary: { main: "#4493f8" },
          text: { primary: "#e6edf3", secondary: "#9198a1" },
          border: { dark: "#3d444d", light: "#30363d" },
          http: { get: "#3fb950", post: "#4493f8", put: "#d29922", delete: "#f85149" },
        }
      : { primary: { main: "#0969da" } },
  };
}

let lastApiKey = null; // path + content hash + theme(再初期化スキップ用)

async function renderOpenAPIDoc(payload, ext) {
  const container = document.getElementById("content");
  const key = payload.path + ":" + hashString(payload.content) + (isDark() ? ":d" : ":l");
  if (key === lastApiKey && document.getElementById("redoc-root")) return;
  lastApiKey = key;

  container.innerHTML = `<div id="redoc-root" class="redoc-loading">OpenAPI ドキュメントを生成中…</div>`;
  const t0 = performance.now();
  try {
    const [, spec] = await Promise.all([
      loadRedoc(),
      (async () => {
        const doc =
          ext === "json" ? JSON.parse(payload.content) : jsyaml.load(payload.content);
        if (!doc || typeof doc !== "object") throw new Error("スペックが空です");
        return bundleExternalRefs(doc, payload.dir);
      })(),
    ]);
    window.__lastBundledSpec = spec; // テスト・デバッグ用
    const parseMs = Math.round(performance.now() - t0);

    // 解決中にファイルが切り替わっていたら捨てる
    if (lastApiKey !== key) return;
    const root = document.getElementById("redoc-root");
    if (!root) return;

    Redoc.init(
      spec,
      {
        hideDownloadButton: true,
        nativeScrollbars: true,
        expandResponses: "200,201",
        theme: redocTheme(),
      },
      root,
      () => {
        root.classList.remove("redoc-loading");
        console.log(
          `[mado] openapi rendered: parse+bundle ${parseMs}ms, total ${Math.round(performance.now() - t0)}ms`
        );
        window.__find?.refresh();
      }
    );
  } catch (err) {
    if (lastApiKey === key) {
      container.innerHTML =
        `<div class="openapi-error"><strong>OpenAPI のパースに失敗しました</strong>` +
        `<pre>${md.utils.escapeHtml(String(err?.message || err))}</pre></div>`;
      showApiToggle(true);
    }
  }
}

function showApiToggle(visible) {
  const btn = document.getElementById("api-toggle");
  btn.hidden = !visible;
  btn.textContent = apiSourceMode ? "📖 ドキュメント表示" : "{ } ソース表示";
}

// ---------- render ----------
let currentPath = null;
let currentDir = "/";
let lastPayload = null;
let apiSourceMode = false; // OpenAPI をソース表示するか
let forceReplace = false; // 次回レンダリングで morphdom を使わず全面差し替える

window.__render = function (payload) {
  const t0 = performance.now();
  const realFileChange = payload.path !== currentPath;
  const isNewFile = realFileChange || forceReplace;
  forceReplace = false;
  currentPath = payload.path;
  currentDir = payload.dir || "/";
  lastPayload = payload;
  // 表示モードのリセットは本当にファイルが変わった時だけ
  // (トグルやテーマ変更による再描画でリセットしてはいけない)
  if (realFileChange) apiSourceMode = false;

  const src = payload.content || "";
  const ext = (currentPath.split(".").pop() || "").toLowerCase();

  const isOpenAPI =
    (ext === "json" || ext === "yaml" || ext === "yml") && detectOpenAPI(src, ext);
  showApiToggle(isOpenAPI);

  if (isOpenAPI && !apiSourceMode) {
    document.body.classList.add("api-file");
    document.body.classList.remove("data-file");
    if (isNewFile) window.scrollTo(0, 0);
    renderOpenAPIDoc(payload, ext);
    return { ms: Math.round((performance.now() - t0) * 10) / 10, mode: "openapi" };
  }
  document.body.classList.remove("api-file");

  let html;
  let isData = false;
  if (ext === "json") {
    html = renderCodeDoc(src, "json");
  } else if (ext === "yaml" || ext === "yml") {
    html = renderCodeDoc(src, "yaml");
  } else if (ext === "mermaid" || ext === "mmd") {
    html = renderMermaidDoc(src);
  } else if (ext === "csv" || ext === "tsv") {
    html = renderTableDoc(src, ext === "csv" ? "," : "\t");
    isData = true;
  } else {
    html = renderMarkdownDoc(src);
  }
  document.body.classList.toggle("data-file", isData);

  const container = document.getElementById("content");

  if (isNewFile) {
    // ファイル切替は差分比較せず一括差し替え(巨大テーブルでも最速)
    container.innerHTML = html;
    transformAlerts(container);
    assignHeadingIds(container);
    window.scrollTo(0, 0);
  } else {
    const next = document.createElement("div");
    next.id = "content";
    next.innerHTML = html;
    transformAlerts(next);
    assignHeadingIds(next);
    // キャッシュ済みの mermaid SVG は morph 前に流し込む(描画の空白を出さない)
    for (const el of next.querySelectorAll(".mermaid[data-hash]")) {
      const cached = mermaidCacheGet(el.dataset.hash);
      if (cached) {
        el.innerHTML = cached;
        el.setAttribute("data-rendered", el.dataset.hash);
      }
    }
    morphdom(container, next, {
      onBeforeElUpdated(fromEl, toEl) {
        // 描画済みの mermaid はソースが同じなら触らない
        if (
          toEl.classList?.contains("mermaid") &&
          fromEl.getAttribute("data-rendered") === toEl.getAttribute("data-hash")
        ) {
          return false;
        }
        if (fromEl.isEqualNode(toEl)) return false;
        return true;
      },
    });
  }

  renderMermaidBlocks();
  window.__find?.refresh();
  return { ms: Math.round((performance.now() - t0) * 10) / 10 };
};

// ---------- mermaid rendering ----------
async function renderMermaidBlocks() {
  const blocks = document.querySelectorAll(".mermaid[data-hash]");
  for (const el of blocks) {
    const h = el.dataset.hash;
    if (el.getAttribute("data-rendered") === h) continue;
    const src = decodeURIComponent(el.dataset.src || "");
    const cached = mermaidCacheGet(h);
    if (cached) {
      el.innerHTML = cached;
      el.setAttribute("data-rendered", h);
      continue;
    }
    try {
      const { svg } = await mermaid.render(`mmsvg-${h}-${mermaidSeq++}`, src);
      mermaidCacheSet(h, svg);
      // 描画中にファイルが更新された場合に備えて要素の生存を確認
      if (el.isConnected && el.dataset.hash === h) {
        el.innerHTML = svg;
        el.classList.remove("mermaid-error");
        el.setAttribute("data-rendered", h);
      }
    } catch (err) {
      if (el.isConnected) {
        el.classList.add("mermaid-error");
        el.textContent = `Mermaid error:\n${err?.message || err}\n\n${src}`;
        el.setAttribute("data-rendered", h);
      }
      // mermaid.render の失敗はダングリング要素を残すことがあるので掃除
      document.querySelectorAll('[id^="dmmsvg-"], [id^="mmsvg-"]:not(svg)').forEach((d) => {
        if (!d.closest("#content")) d.remove();
      });
    }
  }
}

// ダーク/ライト切替: テーマが変わるので mermaid を再初期化して全部描き直す
// (ハッシュはテーマを含むため data-src から再計算する)
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  initMermaid();
  mermaidCache.clear();
  document.querySelectorAll(".mermaid[data-hash]").forEach((el) => {
    const src = decodeURIComponent(el.dataset.src || "");
    const h = hashString(src + (isDark() ? ":d" : ":l"));
    el.dataset.hash = h;
    el.id = `mm-${h}`;
    el.removeAttribute("data-rendered");
  });
  renderMermaidBlocks();
  // OpenAPI ドキュメント表示中は Redoc をテーマごと作り直す
  if (document.body.classList.contains("api-file") && lastPayload) {
    forceReplace = true;
    window.__render(lastPayload);
  }
});

// OpenAPI のドキュメント/ソース表示切替
document.getElementById("api-toggle").addEventListener("click", () => {
  apiSourceMode = !apiSourceMode;
  if (!apiSourceMode) lastApiKey = null;
  forceReplace = true; // Redoc の DOM と morphdom を混ぜないため全面再描画を強制
  window.__render(lastPayload);
});

// ---------- GitHub alerts ----------
const ALERT_ICONS = {
  note: "ℹ︎",
  tip: "✦",
  important: "✱",
  warning: "⚠︎",
  caution: "⛔︎",
};

function transformAlerts(root) {
  for (const bq of root.querySelectorAll("blockquote")) {
    const first = bq.querySelector("p");
    if (!first) continue;
    const m = first.textContent.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/);
    if (!m) continue;
    const kind = m[1].toLowerCase();
    bq.classList.add("alert", `alert-${kind}`);
    first.innerHTML = first.innerHTML.replace(/^\[!\w+\]\s*(<br\s*\/?>)?\s*/, "");
    const title = document.createElement("div");
    title.className = "alert-title";
    title.textContent = `${ALERT_ICONS[kind]} ${m[1][0] + m[1].slice(1).toLowerCase()}`;
    bq.insertBefore(title, bq.firstChild);
  }
}

// ---------- heading anchors ----------
function assignHeadingIds(root) {
  const used = new Set();
  for (const h of root.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    let slug = h.textContent
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s+/g, "-");
    let unique = slug;
    let i = 1;
    while (used.has(unique)) unique = `${slug}-${i++}`;
    used.add(unique);
    h.id = unique;
  }
}

// ---------- interactions ----------
document.addEventListener("click", (e) => {
  // コードコピー
  const btn = e.target.closest(".copy-btn");
  if (btn) {
    const code = btn.parentElement.querySelector("pre code");
    if (code) {
      navigator.clipboard.writeText(code.textContent).then(() => {
        btn.textContent = "Copied";
        btn.classList.add("copied");
        setTimeout(() => {
          btn.textContent = "Copy";
          btn.classList.remove("copied");
        }, 1200);
      });
    }
    return;
  }

  // リンク
  const a = e.target.closest("a");
  if (!a) return;
  const href = a.getAttribute("href");
  if (!href) return;

  if (href.startsWith("#")) {
    e.preventDefault();
    document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
    return;
  }

  e.preventDefault();
  if (/^(https?|mailto):/i.test(href)) {
    bridge("openExternal", { url: href });
  } else if (!/^[a-z][a-z0-9+.-]*:/i.test(href)) {
    // 相対パス → アプリ内でファイルを開く
    const clean = href.split("#")[0];
    if (!clean) return;
    const abs = clean.startsWith("/") ? clean : joinPath(currentDir, clean);
    bridge("openFile", { path: abs });
  }
});

// ---------- find (⌘F) ----------
// CSS Custom Highlight API を使用: DOM を一切変更せず Range にスタイルを当てるため、
// 巨大ドキュメントでも再レイアウト・再ペイントが最小で済む。
window.__find = (() => {
  const MAX_MATCHES = 5000;
  const bar = document.getElementById("findbar");
  const input = document.getElementById("find-input");
  const countEl = document.getElementById("find-count");
  const supported = typeof Highlight !== "undefined" && CSS.highlights;

  let ranges = [];
  let current = -1;
  let query = "";

  function open() {
    bar.hidden = false;
    input.focus();
    input.select();
    if (input.value) search(input.value);
  }

  function close() {
    bar.hidden = true;
    clearHighlights();
    ranges = [];
    current = -1;
    countEl.textContent = "";
    input.blur();
  }

  function clearHighlights() {
    if (!supported) return;
    CSS.highlights.delete("mdv-search");
    CSS.highlights.delete("mdv-search-current");
  }

  function search(q, keepPosition = false) {
    query = q;
    const prevCurrent = keepPosition ? current : -1;
    clearHighlights();
    ranges = [];
    current = -1;
    if (!q) {
      countEl.textContent = "";
      return;
    }
    const needle = q.toLowerCase();
    const root = document.getElementById("content");
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    outer: while ((node = walker.nextNode())) {
      const text = node.data.toLowerCase();
      let idx = 0;
      while ((idx = text.indexOf(needle, idx)) !== -1) {
        const r = document.createRange();
        r.setStart(node, idx);
        r.setEnd(node, idx + needle.length);
        ranges.push(r);
        idx += needle.length;
        if (ranges.length >= MAX_MATCHES) break outer;
      }
    }
    if (supported && ranges.length) {
      CSS.highlights.set("mdv-search", new Highlight(...ranges));
    }
    if (ranges.length) {
      setCurrent(Math.min(Math.max(prevCurrent, 0), ranges.length - 1), prevCurrent < 0);
    } else {
      countEl.textContent = "0";
    }
  }

  function setCurrent(i, scroll = true) {
    current = i;
    if (supported) {
      CSS.highlights.set("mdv-search-current", new Highlight(ranges[i]));
    }
    countEl.textContent = `${i + 1}/${ranges.length}`;
    if (scroll) {
      const rect = ranges[i].getBoundingClientRect();
      // 折りたたまれた details 内などは rect が取れないのでスキップ
      if (rect.width || rect.height) {
        window.scrollBy({ top: rect.top - window.innerHeight / 2, behavior: "instant" });
      }
    }
  }

  function next() {
    if (ranges.length) setCurrent((current + 1) % ranges.length);
  }
  function prev() {
    if (ranges.length) setCurrent((current - 1 + ranges.length) % ranges.length);
  }

  // コンテンツ更新後の再検索(バーが開いている間だけ)
  function refresh() {
    if (!bar.hidden && query) search(query, true);
  }

  input.addEventListener("input", () => search(input.value));
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      e.shiftKey ? prev() : next();
    } else if (e.key === "Escape") {
      e.preventDefault();
      close();
    }
  });
  document.getElementById("find-next").addEventListener("click", next);
  document.getElementById("find-prev").addEventListener("click", prev);
  document.getElementById("find-close").addEventListener("click", close);

  document.addEventListener("keydown", (e) => {
    if (e.metaKey && e.key === "f") {
      e.preventDefault();
      open();
    } else if (e.metaKey && e.key === "g" && !bar.hidden) {
      e.preventDefault();
      e.shiftKey ? prev() : next();
    } else if (e.key === "Escape" && !bar.hidden) {
      close();
    }
  });

  return { open, close, refresh };
})();

bridge("ready");
