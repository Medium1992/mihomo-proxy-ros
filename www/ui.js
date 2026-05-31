const containerName = "mihomo-proxy-ros";
const defaultEnvListName = "MihomoProxyRoS";

function mtEscape(value) {
  let s = String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  // Winbox/SSH-терминал MikroTik режет не-ASCII (особенно supplementary-plane:
  // флаги 🇷🇺 = два U+1F1xx). RouterOS строки поддерживают hex-escape \HH
  // (без `x`, в отличие от C/Python — `\xHH` парсер отвергает как "expected
  // value"). Каждый не-ASCII символ кодируем как набор \HH по байтам UTF-8;
  // после RouterOS-парсинга в env уходят исходные байты, mihomo regex
  // матчит их 1:1. Флаг /u нужен чтобы regex обходил code points, а не
  // 16-битные code units (иначе суррогатные пары ломаются на TextEncoder).
  return s.replace(/[^\x00-\x7F]/gu, (ch) => {
    let out = "";
    for (const b of new TextEncoder().encode(ch)) {
      out += "\\" + b.toString(16).toUpperCase().padStart(2, "0");
    }
    return out;
  });
}

function envKey(name) { return "mihomo-env:" + name; }
function originalKey(name) { return "mihomo-original:" + name; }
function pageKey(name) { return "mihomo-page:" + name; }

// --- Серверная персистентность черновика ---
// Зеркалит localStorage в /dev/shm/mihomo-ui/draft.json на сервере. Нужно
// для случая когда браузер чистит localStorage на закрытии (Chrome/Edge
// privacy option, аддоны и т.п.). Сбрасывается рестартом контейнера.
// Регекс матчит ключи которые надо собирать в server-side draft и которые
// сигнализируют «локальные данные свежие» в draftLoadFromServer. Кроме того
// в whitelist'е ниже есть несколько фиксированных ключей без двоеточия
// (bc-domains, bc1-domains, bc-job, bc1-job) — они проверяются отдельно.
// `invalid` тоже включён: маркеры невалидных значений нужно гонять на сервер,
// иначе после browser-clear localStorage бейджи валидации остаются пустыми
// пока пользователь не зайдёт на проблемную страницу и не запустит валидатор.
const DRAFT_KEYS_RE = /^mihomo-(env|original|page|tab|theme|command-env-list|invalid|bc-form|bc1-form|bdc-form|tool):/;
let draftSyncTimer = null;
let draftLoadInFlight = false;
function draftCollect() {
  const out = {};
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (!k) continue;
    if (k === "mihomo-theme" || k === "mihomo-command-env-list" ||
        k === "mihomo-bc-domains"  || k === "mihomo-bc-job" ||
        k === "mihomo-bc1-domains" || k === "mihomo-bc1-job" ||
        k === "mihomo-bdc-domains" || k === "mihomo-bdc-job" ||
        DRAFT_KEYS_RE.test(k)) {
      out[k] = localStorage.getItem(k);
    }
  }
  return out;
}
function draftSaveDebounced() {
  if (draftSyncTimer) clearTimeout(draftSyncTimer);
  draftSyncTimer = setTimeout(() => {
    draftSyncTimer = null;
    const data = draftCollect();
    const body = JSON.stringify(data);
    fetch("/cgi-bin/draft", { method: "POST", headers: {"Content-Type":"application/json"}, body })
      .then(r => { if (!r.ok) console.warn("draft save HTTP", r.status); })
      .catch((e) => console.warn("draft save failed:", e));
  }, 500);
}
function isPersistedDraftKey(k) {
  if (!k) return false;
  if (DRAFT_KEYS_RE.test(k)) return true;
  // Фиксированные ключи (без двоеточия) — должны учитываться так же.
  if (k === "mihomo-bc-domains"  || k === "mihomo-bc-job")  return true;
  if (k === "mihomo-bc1-domains" || k === "mihomo-bc1-job") return true;
  if (k === "mihomo-bdc-domains" || k === "mihomo-bdc-job") return true;
  return false;
}

function draftLoadFromServer() {
  // Если в localStorage уже есть свои данные — берём локальный (он свежее).
  // Иначе подтягиваем с сервера и наполняем localStorage до того как
  // wireFieldEvents начнёт читать. БЕЗ этой проверки fresh-bc-domains
  // (введённые юзером и сохранённые на input) затирались бы старым серверным
  // снапшотом потому что DRAFT_KEYS_RE их не матчил.
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i);
    if (isPersistedDraftKey(k)) return Promise.resolve(false);
  }
  draftLoadInFlight = true;
  return fetch("/cgi-bin/draft")
    .then(r => r.json())
    .then(data => {
      if (!data || typeof data !== "object") return false;
      let n = 0;
      for (const k in data) {
        if (typeof data[k] === "string") {
          localStorage.setItem(k, data[k]);
          n++;
        }
      }
      return n > 0;
    })
    .catch(() => false)
    .finally(() => { draftLoadInFlight = false; });
}
function draftDeleteOnServer() {
  // resetUiDraft / resetCurrentPageDraft не должны оставлять серверный
  // снапшот — иначе после reload черновик «возродится» с сервера.
  fetch("/cgi-bin/draft", { method: "POST", headers: {"Content-Type":"application/json"}, body: "{}" })
    .catch(() => {});
}

function getEnvListName() {
  const el = document.getElementById("commandEnvList");
  const value = el ? el.value.trim() : "";
  return value || defaultEnvListName;
}

function fieldValue(el) {
  if (el.type === "checkbox") return el.checked ? "true" : "false";
  return el.value.trim();
}

function setFieldValue(el, value) {
  if (el.type === "checkbox") el.checked = value === "true";
  else el.value = value;
}

function rememberField(el) {
  if (!el.name) return;
  if (localStorage.getItem(originalKey(el.name)) === null) {
    localStorage.setItem(originalKey(el.name), fieldValue(el));
  }
  localStorage.setItem(envKey(el.name), fieldValue(el));
  localStorage.setItem(pageKey(el.name), location.pathname);
  draftSaveDebounced();
}

function wireFieldEvents(root) {
  // `el.dataset.fromDraft="true"` is set by restoreMissingIndexedRows so we
  // don't overwrite the stored original (which represents what the SERVER
  // actually had) with a user-typed draft value.
  root.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
    const serverValue = fieldValue(el);
    const fromDraft = el.dataset.fromDraft === "true";
    const storedOriginal = localStorage.getItem(originalKey(el.name));
    if (storedOriginal === null) {
      // First time we see this name. For draft-restored inputs the server
      // never had this env, so original should remain "" (empty).
      localStorage.setItem(originalKey(el.name), fromDraft ? "" : serverValue);
      if (!fromDraft) localStorage.setItem(envKey(el.name), serverValue);
    } else if (!fromDraft && serverValue !== "" && storedOriginal !== serverValue) {
      // Server rendered a NEW value that differs from what we'd seen before.
      // Update original; envKey will be re-saved from server unless user
      // had a draft.
      localStorage.setItem(originalKey(el.name), serverValue);
      if ((localStorage.getItem(envKey(el.name)) || "") === storedOriginal) {
        localStorage.setItem(envKey(el.name), serverValue);
      }
    }
    localStorage.setItem(pageKey(el.name), location.pathname);
    const saved = localStorage.getItem(envKey(el.name));
    if (saved !== null) setFieldValue(el, saved);
    el.addEventListener("input", () => rememberField(el));
    el.addEventListener("change", () => rememberField(el));
  });
}

function normalizeFieldMeta(root) {
  (root || document).querySelectorAll(".field, .toggle").forEach((box) => {
    const status = box.querySelector(":scope > i");
    const hint = box.querySelector(":scope > small");
    if (!status || status.closest(".field-meta")) return;
    const meta = document.createElement("div");
    meta.className = "field-meta";
    if (hint) meta.appendChild(hint);
    meta.appendChild(status);
    box.appendChild(meta);
  });
}

function commandFor(name, original, value) {
  const envListName = getEnvListName();
  const hasOriginal = original !== "";
  const hasValue = value !== "";
  if (!hasOriginal && !hasValue) return "";
  if (hasOriginal && !hasValue) return `/container/envs/remove [find list="${envListName}" key="${name}"]`;
  if (!hasOriginal && hasValue) return `/container/envs/add list="${envListName}" key="${name}" value="${mtEscape(value)}"`;
  if (original !== value) return `/container/envs/set [find list="${envListName}" key="${name}"] value="${mtEscape(value)}"`;
  return "";
}

function collectPageCommands() {
  const fields = [...document.querySelectorAll("#envForm input[name], #envForm textarea[name], #envForm select[name]")];
  const commands = [];
  const seen = new Set();
  fields.forEach((el) => {
    if (seen.has(el.name)) return;
    seen.add(el.name);
    rememberField(el);
    const original = localStorage.getItem(originalKey(el.name)) || "";
    const value = fieldValue(el);
    const cmd = commandFor(el.name, original, value);
    if (cmd) commands.push(cmd);
  });
  return commands;
}

function collectAllCommands() {
  const commands = [];
  const names = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key && key.startsWith("mihomo-env:")) names.push(key.slice("mihomo-env:".length));
  }
  names.sort().forEach((name) => {
    const original = localStorage.getItem(originalKey(name)) || "";
    const value = localStorage.getItem(envKey(name)) || "";
    const cmd = commandFor(name, original, value);
    if (cmd) commands.push(cmd);
  });
  return commands;
}

function formatCommands(title, commands) {
  let text = "# " + title + "\n";
  text += "# container=\"" + containerName + "\" env-list=\"" + getEnvListName() + "\"\n\n";
  text += commands.length ? commands.join("\n") : "# Нет изменений.";
  text += "\n\n/container/stop [find where name=\"" + containerName + "\"]\n";
  text += ":delay 5s\n";
  text += "/container/start [find where name=\"" + containerName + "\"]\n";
  return text;
}

function generateCommands() {
  syncDnsPolicy();
  syncWgDst();
  localStorage.setItem("mihomo-command-env-list", getEnvListName());
  const pageCommands = collectPageCommands();
  const allCommands = collectAllCommands();
  document.getElementById("commandsText").value = formatCommands("Команды для текущей страницы", pageCommands);
  document.getElementById("commandsAllText").value = formatCommands("Суммарные команды для всех измененных env", allCommands);
  document.getElementById("commands").hidden = false;
  document.getElementById("commands").scrollIntoView({behavior: "smooth", block: "start"});
}

function copyText(text, fallbackEl) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(() => {
      if (fallbackEl) { fallbackEl.focus(); fallbackEl.select(); }
      document.execCommand("copy");
    });
  } else {
    if (fallbackEl) { fallbackEl.focus(); fallbackEl.select(); }
    document.execCommand("copy");
  }
}

function copyCommands() {
  const el = document.getElementById("commandsAllText");
  copyText(el ? el.value : "", el);
}

function initToolsPage() {
  document.querySelectorAll(".tools-list [data-tool-tab]").forEach((btn) => {
    btn.addEventListener("click", () => switchToolPane(btn.dataset.toolTab));
  });
  toolRestoreInputs();
  [
    ["toolB64Plain", toolBase64Encode],
    ["toolB64Input", toolBase64Decode],
    ["toolRegexSource", toolRegexTest],
    ["toolRegexText", toolRegexTest],
    ["toolXrayJson", toolXrayConvert]
  ].forEach(([id, fn]) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.addEventListener("input", () => {
      toolSaveInput(el);
      fn();
    });
  });
  toolBase64Encode();
  toolBase64Decode();
  toolRegexTest();
  toolXrayConvert();
}

function switchToolPane(id) {
  document.querySelectorAll(".tools-list [data-tool-tab]").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.toolTab === id);
  });
  document.querySelectorAll(".tool-pane").forEach((pane) => {
    const active = pane.dataset.toolPane === id;
    pane.classList.toggle("active", active);
    pane.hidden = !active;
  });
}

function toolSetStatus(id, text, ok) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text || "";
  el.classList.toggle("tool-status-ok", !!ok);
  el.classList.toggle("tool-status-bad", !!text && !ok);
}

function toolStorageKey(id) {
  return `mihomo-tool:${id}`;
}

function toolSaveInput(el) {
  if (!el || !el.id || el.readOnly) return;
  try {
    localStorage.setItem(toolStorageKey(el.id), el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value);
    draftSaveDebounced();
  } catch (e) {}
}

function toolRestoreInputs() {
  document.querySelectorAll(".tool-pane input[id], .tool-pane textarea[id], .tool-pane select[id]").forEach((el) => {
    if (el.readOnly) return;
    try {
      const key = toolStorageKey(el.id);
      if (!localStorage.getItem(key)) return;
      if (el.type === "checkbox") el.checked = localStorage.getItem(key) === "1";
      else el.value = localStorage.getItem(key);
    } catch (e) {}
  });
}

function toolUtf8ToBase64(text) {
  let bin = "";
  for (const b of new TextEncoder().encode(text)) bin += String.fromCharCode(b);
  return btoa(bin);
}

function toolBase64ToUtf8(text) {
  let s = String(text || "").trim().replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
}

function toolBase64Encode() {
  const src = document.getElementById("toolB64Plain");
  const out = document.getElementById("toolB64Encoded");
  try {
    if (out) out.value = toolUtf8ToBase64(src ? src.value : "");
  } catch (e) {
    if (out) out.value = "";
  }
}

function toolBase64Decode() {
  const src = document.getElementById("toolB64Input");
  const out = document.getElementById("toolB64Decoded");
  try {
    if (out) out.value = toolBase64ToUtf8(src ? src.value : "");
    toolSetStatus("toolB64DecodeStatus", "Готово", true);
  } catch (e) {
    if (out) out.value = "";
    toolSetStatus("toolB64DecodeStatus", "Ошибка Base64: " + e.message, false);
  }
}

function toolParseRegex(src) {
  const raw = String(src || "").trim();
  if (!raw) return { pattern: "", flags: "" };
  if (raw[0] !== "/") return { pattern: raw, flags: "" };
  let escaped = false;
  let inClass = false;
  for (let i = 1; i < raw.length; i++) {
    const ch = raw[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      escaped = true;
      continue;
    }
    if (ch === "[" && !inClass) {
      inClass = true;
      continue;
    }
    if (ch === "]" && inClass) {
      inClass = false;
      continue;
    }
    if (ch === "/" && !inClass) {
      return { pattern: raw.slice(1, i), flags: raw.slice(i + 1) };
    }
  }
  return { pattern: raw, flags: "" };
}

function toolCleanRegexFlags(flagsRaw) {
  const allowed = new Set("dgimsuvy".split(""));
  const out = [];
  for (const ch of String(flagsRaw || "")) {
    if (allowed.has(ch) && !out.includes(ch)) out.push(ch);
  }
  return out.join("");
}

function toolRegexTest() {
  const source = document.getElementById("toolRegexSource")?.value || "";
  const text = document.getElementById("toolRegexText")?.value || "";
  const rows = document.getElementById("toolRegexRows");
  try {
    const parsed = toolParseRegex(source);
    const flags = toolCleanRegexFlags(parsed.flags).replace(/g/g, "");
    if (!parsed.pattern) {
      if (rows) rows.innerHTML = "";
      toolSetStatus("toolRegexStatus", "Введите regex", true);
      return;
    }
    const re = new RegExp(parsed.pattern, flags);
    const lines = text.split(/\r?\n/);
    let matches = 0;
    const resultRows = [];
    lines.forEach((line, idx) => {
      const m = re.test(line);
      if (m) matches++;
      resultRows.push(`<div class="tool-regex-row ${m ? "match" : "no-match"}"><span>${m ? "СОВПАЛО" : "НЕ СОВПАЛО"}</span><code>${String(idx + 1).padStart(3, " ")}</code><pre>${escapeAttr(line)}</pre></div>`);
    });
    if (rows) rows.innerHTML = resultRows.join("");
    toolSetStatus("toolRegexStatus", `Совпадений: ${matches} / ${lines.length}`, true);
  } catch (e) {
    if (rows) rows.innerHTML = "";
    toolSetStatus("toolRegexStatus", "Ошибка regex: " + e.message, false);
  }
}

function toolCopy(id, btn) {
  const el = document.getElementById(id);
  copyText(el ? el.value : "", el);
  if (btn) {
    const old = btn.textContent;
    btn.textContent = "Скопировано";
    setTimeout(() => { btn.textContent = old; }, 900);
  }
}

function toolParam(params, key, value) {
  if (value === undefined || value === null || value === "") return;
  params.set(key, String(value));
}

function toolFirst(obj, keys) {
  for (const k of keys) {
    if (obj && obj[k] !== undefined && obj[k] !== null && obj[k] !== "") return obj[k];
  }
  return "";
}

function toolHostPort(host, port) {
  const h = String(host || "");
  return h.includes(":") && !h.startsWith("[") ? `[${h}]:${port || ""}` : `${h}:${port || ""}`;
}

function toolTag(ob, fallback) {
  return ob.tag || ob.ps || ob.remark || ob.name || fallback || "proxy";
}

function toolUriScheme(uri) {
  const m = String(uri || "").match(/^([a-z0-9+.-]+):\/\//i);
  return m ? m[1].toUpperCase() : "URI";
}

function toolParseJsonString(value) {
  if (typeof value !== "string") return value;
  const s = value.trim();
  if (!s || !"[{".includes(s[0])) return value;
  try { return JSON.parse(s); } catch (e) { return value; }
}

function toolNormalizeJson(value, depth = 0) {
  if (depth > 8) return value;
  value = toolParseJsonString(value);
  if (Array.isArray(value)) return value.map((x) => toolNormalizeJson(x, depth + 1));
  if (!value || typeof value !== "object") return value;
  const out = {};
  Object.keys(value).forEach((k) => { out[k] = toolNormalizeJson(value[k], depth + 1); });
  return out;
}

function toolLooksLikeOutbound(ob) {
  if (!ob || typeof ob !== "object" || Array.isArray(ob)) return false;
  if (ob.protocol || ob.settings || ob.streamSettings) return true;
  if (ob.vnext || ob.servers || ob.address || ob.server || ob.id || ob.password || ob.method) return true;
  return false;
}

function toolFindOutbounds(root) {
  const found = [];
  const seen = new Set();
  function add(ob, path) {
    const norm = toolNormalizeOutbound(ob);
    if (!toolLooksLikeOutbound(norm)) return;
    if (seen.has(norm)) return;
    seen.add(norm);
    found.push({ ob: norm, path });
  }
  function walk(node, path, insideOutbounds) {
    node = toolNormalizeJson(node);
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) {
      node.forEach((item, idx) => {
        if (insideOutbounds && toolLooksLikeOutbound(toolNormalizeJson(item))) add(item, `${path}[${idx}]`);
        walk(item, `${path}[${idx}]`, false);
      });
      return;
    }
    if (insideOutbounds && toolLooksLikeOutbound(node)) add(node, path);
    Object.keys(node).forEach((key) => {
      const val = node[key];
      if (key === "outbounds") walk(val, `${path}.outbounds`, true);
      else if (key === "outbound") {
        if (toolLooksLikeOutbound(toolNormalizeJson(val))) add(val, `${path}.outbound`);
        walk(val, `${path}.outbound`, false);
      } else {
        walk(val, `${path}.${key}`, false);
      }
    });
  }
  if (Array.isArray(root)) walk(root, "$", true);
  else walk(root, "$", false);
  return found;
}

function toolInferProtocol(ob) {
  const proto = String(ob.protocol || ob.type || "").toLowerCase();
  if (proto) return proto;
  const label = String(ob.tag || ob.ps || ob.remark || ob.name || "").toLowerCase();
  if (label.includes("vless")) return "vless";
  if (label.includes("vmess")) return "vmess";
  if (label.includes("trojan")) return "trojan";
  if (label.includes("hysteria2") || label.includes("hy2")) return "hysteria2";
  if (label.includes("shadowsocks") || /\bss\b/.test(label)) return "shadowsocks";
  const s = ob.settings || ob;
  const streamSec = String((ob.streamSettings || {}).security || "").toLowerCase();
  if (s.vnext) {
    const u = s.vnext?.[0]?.users?.[0] || {};
    if (u.encryption === "none" || u.flow || streamSec === "reality") return "vless";
    return "vmess";
  }
  if (s.servers) {
    const srv = s.servers?.[0] || {};
    if (srv.method) return "shadowsocks";
    if (srv.password) return "trojan";
  }
  if (s.id && (s.encryption === "none" || s.flow || streamSec === "reality")) return "vless";
  if (s.id) return "vmess";
  if (s.method && s.password) return "shadowsocks";
  if (s.password || s.auth) return "trojan";
  return "";
}

function toolFinalMaskParams(params, finalmask) {
  if (!finalmask || typeof finalmask !== "object" || Array.isArray(finalmask)) return;
  if (Object.keys(finalmask).length) toolParam(params, "fm", JSON.stringify(finalmask));
}

function toolApplyHy2Salamander(params, finalmask) {
  if (!finalmask || typeof finalmask !== "object") return;
  const masks = Array.isArray(finalmask.udp) ? finalmask.udp : [];
  for (const raw of masks) {
    const mask = raw || {};
    if (mask.type !== "salamander") continue;
    const settings = mask.settings || {};
    if (settings.password) {
      toolParam(params, "obfs", "salamander");
      toolParam(params, "obfs-password", settings.password);
      break;
    }
  }
}

function toolNormalizeOutbound(ob) {
  ob = toolNormalizeJson(ob || {});
  if (!ob || typeof ob !== "object") return {};
  const out = Object.assign({}, ob);
  out.settings = toolNormalizeJson(out.settings || {});
  out.streamSettings = toolNormalizeJson(out.streamSettings || out.stream || {});
  out.protocol = toolInferProtocol(out);
  return out;
}

function toolStreamParams(params, stream) {
  stream = stream || {};
  const net = stream.network || "tcp";
  const sec = stream.security || "";
  toolParam(params, "type", net);
  if (sec && sec !== "none") toolParam(params, "security", sec);
  const tls = stream.tlsSettings || {};
  const reality = stream.realitySettings || {};
  const realityInner = reality.settings || {};
  const ws = stream.wsSettings || {};
  const http = stream.httpSettings || {};
  const httpup = stream.httpupgradeSettings || {};
  const xhttp = stream.xhttpSettings || stream.splithttpSettings || {};
  const grpc = stream.grpcSettings || {};
  const kcp = stream.kcpSettings || {};
  const tcp = stream.tcpSettings || {};
  toolParam(params, "sni", tls.serverName || reality.serverName || (Array.isArray(reality.serverNames) ? reality.serverNames[0] : reality.serverNames));
  toolParam(params, "fp", tls.fingerprint || reality.fingerprint || realityInner.fingerprint);
  toolParam(params, "alpn", Array.isArray(tls.alpn) ? tls.alpn.join(",") : tls.alpn);
  toolParam(params, "pbk", reality.publicKey || reality.public_key || reality.password || realityInner.publicKey || realityInner.public_key || realityInner.password);
  toolParam(params, "sid", reality.shortId || reality.short_id || (Array.isArray(reality.shortIds) ? reality.shortIds[0] : reality.shortIds));
  toolParam(params, "spx", reality.spiderX);
  toolParam(params, "path", ws.path || http.path || httpup.path || xhttp.path);
  toolParam(params, "host", (ws.headers && (ws.headers.Host || ws.headers.host)) || (httpup.headers && (httpup.headers.Host || httpup.headers.host)) || (xhttp.headers && (xhttp.headers.Host || xhttp.headers.host)) || xhttp.host);
  toolParam(params, "mode", xhttp.mode);
  toolParam(params, "x_padding_bytes", xhttp.xPaddingBytes || xhttp.x_padding_bytes);
  if (xhttp && Object.keys(xhttp).some((k) => !["path", "host", "mode", "headers", "xPaddingBytes", "x_padding_bytes"].includes(k))) {
    toolParam(params, "extra", JSON.stringify(xhttp));
  }
  toolParam(params, "serviceName", grpc.serviceName);
  toolParam(params, "seed", kcp.seed);
  if (kcp.header && kcp.header.type) toolParam(params, "headerType", kcp.header.type);
  if (tcp.header && tcp.header.request && tcp.header.request.headers && tcp.header.request.headers.Host) {
    const hosts = tcp.header.request.headers.Host;
    toolParam(params, "host", Array.isArray(hosts) ? hosts.join(",") : hosts);
  }
  toolFinalMaskParams(params, stream.finalmask);
}

function toolVnextEndpoint(settings) {
  const v = settings?.vnext?.[0] || settings || {};
  const u = v?.users?.[0] || settings?.users?.[0] || settings || {};
  return { v, u };
}

function toolBuildVless(ob, notes) {
  const { v, u } = toolVnextEndpoint(ob.settings);
  const id = u.id || ob.settings?.id;
  const host = v.address || ob.settings?.address || ob.address || ob.server;
  const port = v.port || ob.settings?.port || ob.port || 443;
  if (!host || !id) return null;
  const params = new URLSearchParams();
  toolParam(params, "encryption", u.encryption || ob.settings?.encryption || "none");
  toolParam(params, "flow", u.flow || ob.settings?.flow);
  toolStreamParams(params, ob.streamSettings);
  if (!params.has("security")) params.set("security", "none");
  return `vless://${encodeURIComponent(id)}@${toolHostPort(host, port)}?${params.toString()}#${encodeURIComponent(toolTag(ob, host))}`;
}

function toolBuildTrojan(ob) {
  const s = ob.settings?.servers?.[0] || ob.settings || {};
  const host = s.address || s.server || ob.address || ob.server;
  const port = s.port || ob.port || 443;
  const password = s.password || ob.password;
  if (!host || !password) return null;
  const params = new URLSearchParams();
  toolStreamParams(params, ob.streamSettings);
  if (!params.has("security")) params.set("security", "none");
  return `trojan://${encodeURIComponent(password)}@${toolHostPort(host, port)}?${params.toString()}#${encodeURIComponent(toolTag(ob, host))}`;
}

function toolBuildVmess(ob) {
  const { v, u } = toolVnextEndpoint(ob.settings);
  const id = u.id || ob.settings?.id;
  const host = v.address || ob.settings?.address || ob.address || ob.server;
  const port = v.port || ob.settings?.port || ob.port || 443;
  if (!host || !id) return null;
  const stream = ob.streamSettings || {};
  const ws = stream.wsSettings || {};
  const tls = stream.tlsSettings || {};
  const payload = {
    v: "2",
    ps: toolTag(ob, host),
    add: host,
    port: String(port || ""),
    id,
    aid: String(u.alterId || 0),
    scy: u.security || "auto",
    net: stream.network || "tcp",
    type: "none",
    host: (ws.headers && (ws.headers.Host || ws.headers.host)) || tls.serverName || "",
    path: ws.path || "",
    tls: stream.security === "tls" ? "tls" : "",
    sni: tls.serverName || "",
    alpn: Array.isArray(tls.alpn) ? tls.alpn.join(",") : (tls.alpn || ""),
    fp: tls.fingerprint || ""
  };
  return "vmess://" + toolUtf8ToBase64(JSON.stringify(payload));
}

function toolBuildShadowsocks(ob) {
  const s = ob.settings?.servers?.[0] || ob.settings || {};
  const host = s.address || s.server || ob.address || ob.server;
  const port = s.port || ob.port || 8388;
  const method = s.method || ob.method;
  const password = s.password || ob.password;
  if (!method || !password || !host) return null;
  const user = toolUtf8ToBase64(`${method}:${password}`).replace(/=+$/g, "");
  const params = new URLSearchParams();
  toolStreamParams(params, ob.streamSettings);
  return `ss://${user}@${toolHostPort(host, port)}${params.toString() ? "?" + params.toString() : ""}#${encodeURIComponent(toolTag(ob, host))}`;
}

function toolBuildHy2(ob) {
  const s = ob.settings?.servers?.[0] || ob.settings?.server || ob.settings || {};
  const host = s.address || s.server;
  const port = s.port;
  const password = s.password || s.auth || ob.settings?.password || ob.settings?.auth;
  if (!host || !password) return null;
  const params = new URLSearchParams();
  const tls = ob.streamSettings?.tlsSettings || {};
  toolParam(params, "sni", tls.serverName || s.serverName);
  toolParam(params, "alpn", Array.isArray(tls.alpn) ? tls.alpn.join(",") : tls.alpn);
  toolParam(params, "insecure", tls.allowInsecure ? "1" : "");
  toolParam(params, "obfs", ob.settings?.obfs || s.obfs);
  toolApplyHy2Salamander(params, ob.streamSettings?.finalmask);
  toolFinalMaskParams(params, ob.streamSettings?.finalmask);
  const scheme = String(ob.settings?.version || ob.version || "2") === "1" ? "hysteria" : "hysteria2";
  return `${scheme}://${encodeURIComponent(password)}@${toolHostPort(host, port)}?${params.toString()}#${encodeURIComponent(toolTag(ob, host))}`;
}

function toolOutboundToUri(ob, idx, notes) {
  ob = toolNormalizeOutbound(ob);
  const proto = String(ob.protocol || "").toLowerCase();
  try {
    if (proto === "vless") return toolBuildVless(ob, notes);
    if (proto === "vmess") return toolBuildVmess(ob, notes);
    if (proto === "trojan") return toolBuildTrojan(ob, notes);
    if (proto === "shadowsocks") return toolBuildShadowsocks(ob, notes);
    if (proto === "hysteria" || proto === "hysteria2" || proto === "hy2") return toolBuildHy2(ob, notes);
    notes.push(`#${idx + 1} ${toolTag(ob, "outbound")} skipped: protocol ${proto || "(empty)"}`);
    return null;
  } catch (e) {
    notes.push(`#${idx + 1} ${toolTag(ob, "outbound")} error: ${e.message}`);
    return null;
  }
}

function toolRenderXrayCards(links) {
  const wrap = document.getElementById("toolXrayCards");
  if (!wrap) return;
  if (!links.length) {
    wrap.innerHTML = '<div class="tool-link-empty">Нет сконвертированных ссылок</div>';
    return;
  }
  wrap.innerHTML = links.map((item, idx) => `
    <div class="tool-link-card">
      <div class="tool-link-meta"><b>${escapeAttr(item.name)}</b><span>${escapeAttr(item.scheme)} · #${idx + 1}</span></div>
      <code>${escapeAttr(item.uri)}</code>
      <button type="button" onclick="toolCopy('toolXrayLink${idx}', this)">Скопировать</button>
      <textarea id="toolXrayLink${idx}" class="tool-hidden-copy" readonly>${escapeAttr(item.uri)}</textarea>
    </div>
  `).join("");
}

function toolXrayConvert() {
  const input = document.getElementById("toolXrayJson")?.value || "";
  const out = document.getElementById("toolXrayLinks");
  const diag = document.getElementById("toolXrayDiag");
  const notes = [];
  if (!input.trim()) {
    if (out) out.value = "";
    if (diag) diag.value = "";
    toolRenderXrayCards([]);
    return;
  }
  try {
    const json = toolNormalizeJson(JSON.parse(input));
    const outbounds = toolFindOutbounds(json);
    if (!outbounds.length) throw new Error("не найдены outbounds или похожие outbound-объекты");
    const links = [];
    outbounds.forEach((item, idx) => {
      const uri = toolOutboundToUri(item.ob || {}, idx, notes);
      if (uri) links.push({ uri, name: toolTag(item.ob || {}, `outbound-${idx + 1}`), scheme: toolUriScheme(uri) });
      else notes.push(`#${idx + 1} path: ${item.path}`);
    });
    if (out) out.value = links.map((x) => x.uri).join("\n");
    toolRenderXrayCards(links);
    if (diag) diag.value = [
      `found: ${outbounds.length}`,
      `converted: ${links.length}`,
      notes.length ? "" : "diagnostics: ok",
      ...notes
    ].filter(Boolean).join("\n");
  } catch (e) {
    if (out) out.value = "";
    toolRenderXrayCards([]);
    if (diag) diag.value = "Ошибка JSON: " + e.message;
  }
}

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  if (document.body) document.body.dataset.theme = theme;
  localStorage.setItem("mihomo-theme", theme);
  const label = document.getElementById("themeLabel");
  if (label) label.textContent = theme === "dark" ? "Светлая" : "Темная";
}

function toggleTheme() {
  const cur = document.documentElement.dataset.theme || document.body.dataset.theme;
  applyTheme(cur === "dark" ? "light" : "dark");
}

function resetUiDraft() {
  [...Array(localStorage.length)].map((_, i) => localStorage.key(i)).forEach((key) => {
    if (!key) return;
    if (key.startsWith("mihomo-env:") ||
        key.startsWith("mihomo-original:") ||
        key.startsWith("mihomo-page:") ||
        key.startsWith("mihomo-tab:") ||
        key.startsWith("mihomo-tool:")) {
      localStorage.removeItem(key);
    }
  });
  draftDeleteOnServer();
  location.reload(true);
}

function resetCurrentPageDraft() {
  const names = new Set([...document.querySelectorAll("#envForm input[name], #envForm textarea[name], #envForm select[name]")].map((el) => el.name));
  const path = location.pathname;
  [...Array(localStorage.length)].map((_, i) => localStorage.key(i)).forEach((key) => {
    if (!key) return;
    if (document.querySelector(".tools-browser") && key.startsWith("mihomo-tool:")) {
      localStorage.removeItem(key);
      return;
    }
    if (key.startsWith("mihomo-page:") && localStorage.getItem(key) === path) names.add(key.slice("mihomo-page:".length));
  });
  names.forEach((name) => {
    localStorage.removeItem(envKey(name));
    localStorage.removeItem(originalKey(name));
    localStorage.removeItem(pageKey(name));
  });
  draftSaveDebounced();
  location.reload(true);
}

// Single source of truth for every "numbered" ENV family. The HTML still calls
// addRow(id, prefix, startAtOne) for back-compat, but addRow now ignores the
// boolean and consults this table — so SUB_LINK can have min=0 while still
// emitting numeric env names (SUB_LINK0), and LINK can keep its legacy
// "LINK == LINK0" zero-plain spelling.
const INDEXED_PREFIXES = {
  LINK:           { minIndex: 0, zeroPlain: true,  maxIndex: null, containerId: "links" },
  SUB_LINK:       { minIndex: 0, zeroPlain: false, maxIndex: null, containerId: "subs"  },
  SOCKS:          { minIndex: 0, zeroPlain: false, maxIndex: 99,   containerId: "socksRows" },
  BYEDPI_CMD:     { minIndex: 0, zeroPlain: true,  maxIndex: 99,   containerId: "byedpi" },
  ZAPRET_CMD:     { minIndex: 0, zeroPlain: true,  maxIndex: 99,   containerId: "zapret",  packets: "ZAPRET_PACKETS"  },
  ZAPRET2_CMD:    { minIndex: 0, zeroPlain: true,  maxIndex: 99,   containerId: "zapret2", packets: "ZAPRET2_PACKETS" },
  FAKE_IP_FILTER: { minIndex: 1, zeroPlain: false, maxIndex: null, containerId: "fakeFilters" },
  RULES:          { minIndex: 1, zeroPlain: false, maxIndex: null, containerId: "rules" },
  RULE_SET:       { minIndex: 1, zeroPlain: false, maxIndex: null, containerId: "rulesets", suffix: "_BASE64" },
};

function indexedSpec(prefix) { return INDEXED_PREFIXES[prefix] || null; }

// Canonical env name (what entrypoint reads): "LINK" for LINK#0 with
// zeroPlain, "SUB_LINK0" for SUB_LINK#0 (entrypoint requires the digit).
function envNameFor(prefix, idx) {
  const spec = indexedSpec(prefix);
  const suffix = spec && spec.suffix ? spec.suffix : "";
  if (spec && spec.zeroPlain && idx === 0) return prefix + suffix;
  return prefix + idx + suffix;
}

// Human-readable label always carries the number (so "LINK" idx 0 still
// reads as "LINK0" in the UI — but the underlying `name=` stays canonical).
function displayNameFor(prefix, idx) {
  const spec = indexedSpec(prefix);
  const suffix = spec && spec.suffix ? spec.suffix : "";
  return prefix + idx + suffix;
}

// Apply display-name relabeling to a row that's already in the DOM. Walks the
// row's labels and rewrites <span> text so server-rendered rows (where idx 0
// LINK got the bare span "LINK") also pick up the "LINK0" display form.
function relabelIndexedRow(row) {
  const cfg = indexedRowConfig(row);
  if (!cfg) return;
  const idx = Number(row.dataset.index);
  if (!Number.isInteger(idx)) return;
  const envBase = envNameFor(cfg.prefix, idx);                  // "LINK" or "LINK0"
  const displayBase = displayNameFor(cfg.prefix, idx);          // always "LINK0"
  if (envBase === displayBase) return;                          // nothing to relabel
  row.querySelectorAll("label > span, .headers-editor > span").forEach((span) => {
    const txt = span.textContent;
    if (txt === envBase) span.textContent = displayBase;
    else if (txt.indexOf(envBase + "_") === 0) span.textContent = displayBase + txt.slice(envBase.length);
  });
  const titleEl = row.querySelector(".socks-title");
  if (titleEl && titleEl.textContent === envBase) titleEl.textContent = displayBase;
}

function addRow(containerId, prefix, startAtOne) {
  const spec = indexedSpec(prefix);
  // Legacy boolean still honored only if the prefix isn't in the table.
  const minIndex = spec ? spec.minIndex : (startAtOne ? 1 : 0);
  const maxIndex = spec && Number.isInteger(spec.maxIndex) ? spec.maxIndex : null;
  const wrap = document.getElementById(containerId);
  const used = [...wrap.querySelectorAll("[data-index]")].map((x) => Number(x.dataset.index)).filter(Number.isFinite);
  let idx = minIndex;
  while (used.includes(idx)) idx++;
  if (maxIndex !== null && idx > maxIndex) return;
  let key = spec ? envNameFor(prefix, idx) : (idx === 0 && !startAtOne ? prefix : prefix + idx);
  const displayKey = spec ? displayNameFor(prefix, idx) : key;
  if (!spec && prefix === "RULE_SET") key = "RULE_SET" + idx + "_BASE64";
  const div = document.createElement("div");
  div.className = "env-row";
  if (prefix === "RULES" || prefix === "RULE_SET") div.className = "env-row rule-row";
  if (prefix === "BYEDPI_CMD") div.className = "env-row dpi-single-row";
  if (prefix === "ZAPRET_CMD" || prefix === "ZAPRET2_CMD") div.className = "env-row dpi-packet-row";
  if (prefix === "LINK") div.className = "env-row env-row-stack link-row";
  if (prefix === "SUB_LINK") div.className = "env-row env-row-stack sub-link-row";
  div.dataset.index = idx;
  div.dataset.prefix = prefix;
  div.dataset.startAtOne = (spec ? spec.minIndex >= 1 : startAtOne) ? "true" : "false";
  if (maxIndex !== null) div.dataset.maxIndex = String(maxIndex);
  if (prefix === "ZAPRET_CMD" || prefix === "ZAPRET2_CMD") {
    const packets = prefix === "ZAPRET_CMD" ? "ZAPRET_PACKETS" : "ZAPRET2_PACKETS";
    const packetsKey = packets + idx;
    div.innerHTML = `<label><span>${displayKey}</span><input name="${key}" placeholder="--dpi-desync=..."></label><label><span>${packetsKey}</span><input name="${packetsKey}" placeholder="12"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  } else if (prefix === "RULE_SET") {
    div.innerHTML = `<label><span>${displayKey}</span><input name="${key}" placeholder="BASE64#name"></label><button type="button" onclick="openRuleSetModal(this)" title="Редактировать">&#10002;</button><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  } else if (prefix === "RULES") {
    div.innerHTML = `<label><span>${displayKey}</span><input name="${key}" placeholder="DOMAIN,example.com,GLOBAL"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  } else if (prefix === "LINK") {
    div.innerHTML =
      `<label><span>${displayKey}</span><input name="${key}" placeholder="vless:// / vmess:// / ss:// / trojan:// / vpn://"></label>` +
      `<label class="field-validated" data-validate="proxy_name"><span>${displayKey}_DIALER_PROXY</span><input name="${key}_DIALER_PROXY" placeholder="GLOBAL"></label>` +
      `<label><span>${displayKey}_AMNEZIA_COUNTRY</span><input name="${key}_AMNEZIA_COUNTRY" placeholder="nl"></label>` +
      `<button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  } else if (prefix === "SUB_LINK") {
    div.innerHTML =
      `<label><span>${displayKey}</span><input name="${key}" placeholder="https://subscription"></label>` +
      `<label><span>${displayKey}_INTERVAL</span><input type="number" name="${key}_INTERVAL" placeholder="3600"></label>` +
      `<label><span>${displayKey}_PROXY</span><input name="${key}_PROXY" placeholder="DIRECT"></label>` +
      `<label class="field-validated" data-validate="proxy_name"><span>${displayKey}_DIALER_PROXY</span><input name="${key}_DIALER_PROXY" placeholder="GLOBAL"></label>` +
      `<div class="sub-link-extras">` +
        `<label><span>${displayKey}_FILTER</span><input name="${key}_FILTER" placeholder="(?i)hk|hongkong"></label>` +
        `<label><span>${displayKey}_EXCLUDE_FILTER</span><input name="${key}_EXCLUDE_FILTER" placeholder="(?i)test"></label>` +
        `<label class="field-validated" data-validate="exclude_type"><span>${displayKey}_EXCLUDE_TYPE</span><input name="${key}_EXCLUDE_TYPE" placeholder="vmess|direct"></label>` +
        `<label><span>${displayKey}_ADDITIONAL_PREFIX</span><input name="${key}_ADDITIONAL_PREFIX" placeholder="${displayKey} | "></label>` +
        `<label><span>${displayKey}_ADDITIONAL_SUFFIX</span><input name="${key}_ADDITIONAL_SUFFIX" placeholder=" | ${displayKey}"></label>` +
      `</div>` +
      `<div class="headers-editor">` +
        `<span>${displayKey}_HEADERS</span>` +
        `<input type="hidden" class="sub-link-headers-value" name="${key}_HEADERS" value="">` +
        `<div class="headers-rows"></div>` +
        `<button type="button" class="headers-add">Добавить header</button>` +
      `</div>` +
      `<button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  } else if (prefix === "BYEDPI_CMD") {
    div.innerHTML = `<label><span>${displayKey}</span><input name="${key}" placeholder="стратегия BYEDPI без --port и --transparent (например --tlsrec 41+s --udp-fake 1 --oob 1 --auto=torst)"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  } else {
    div.innerHTML = `<label><span>${displayKey}</span><input name="${key}" placeholder="значение env"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  }
  wrap.appendChild(div);
  // New row → all inputs are user drafts, never from server.
  div.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
    el.dataset.fromDraft = "true";
  });
  wireFieldEvents(div);
  ensureIndexedRowControls(div);
  if (prefix === "SUB_LINK" && typeof initHeadersEditors === "function") initHeadersEditors(div);
  if (typeof wirePaneValidators === "function") wirePaneValidators(div);
  sortIndexedRows(wrap);
  if (typeof refreshAllBadges === "function") refreshAllBadges();
  if (typeof renderRulesPreview === 'function') renderRulesPreview();
}

function sortIndexedRows(wrap) {
  if (!wrap) return;
  [...wrap.children]
    .filter((row) => row.dataset && row.dataset.index !== undefined)
    .sort((a, b) => Number(a.dataset.index) - Number(b.dataset.index))
    .forEach((row) => wrap.appendChild(row));
}

function usedIndexes(wrap, skipRow) {
  return [...wrap.querySelectorAll("[data-index]")]
    .filter((row) => row !== skipRow)
    .map((x) => Number(x.dataset.index))
    .filter(Number.isInteger);
}

function nextFreeIndex(wrap, startAtOne, maxIndex) {
  const used = usedIndexes(wrap);
  let idx = startAtOne ? 1 : 0;
  while (used.includes(idx)) idx++;
  if (Number.isInteger(maxIndex) && idx > maxIndex) return null;
  return idx;
}

function escapeAttr(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function fakeFilterName(idx) {
  return "FAKE_IP_FILTER" + idx;
}

function baseIndexedName(prefix, idx, zeroPlain) {
  return idx === 0 && zeroPlain ? prefix : prefix + idx;
}

function indexedRowConfig(row) {
  // Prefer the explicit dataset hint set when the row was built (cheaper +
  // unambiguous). Fall back to scanning input names for legacy server-rendered
  // rows that pre-date the dataset markup.
  const datasetPrefix = row.dataset.prefix;
  if (datasetPrefix && INDEXED_PREFIXES[datasetPrefix]) {
    const spec = INDEXED_PREFIXES[datasetPrefix];
    return {
      kind: spec.suffix ? "ruleset" : (spec.packets ? "zapret" : (datasetPrefix === "LINK" || datasetPrefix === "SUB_LINK" ? "multi" : "base")),
      prefix: datasetPrefix,
      min: spec.minIndex,
      zeroPlain: !!spec.zeroPlain,
      max: Number.isInteger(spec.maxIndex) ? spec.maxIndex : null,
      packets: spec.packets,
    };
  }
  const names = [...row.querySelectorAll("input[name], textarea[name], select[name]")].map((el) => el.name);
  // Walk INDEXED_PREFIXES longest-first to disambiguate SUB_LINK vs LINK and ZAPRET2 vs ZAPRET.
  const ordered = Object.keys(INDEXED_PREFIXES).sort((a, b) => b.length - a.length);
  for (const prefix of ordered) {
    const spec = INDEXED_PREFIXES[prefix];
    const suffix = spec.suffix ? spec.suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") : "";
    // Allow either main "PREFIX(\d*)SUFFIX" or sub "PREFIX(\d*)_X" matches.
    const mainRe = new RegExp("^" + prefix + (spec.zeroPlain ? "\\d*" : "\\d+") + suffix + "$");
    const subRe = !suffix ? new RegExp("^" + prefix + (spec.zeroPlain ? "\\d*" : "\\d+") + "_[A-Z0-9_]+$") : null;
    if (names.some((name) => mainRe.test(name) || (subRe && subRe.test(name)))) {
      return {
        kind: spec.suffix ? "ruleset" : (spec.packets ? "zapret" : (prefix === "LINK" || prefix === "SUB_LINK" ? "multi" : "base")),
        prefix,
        min: spec.minIndex,
        zeroPlain: !!spec.zeroPlain,
        max: Number.isInteger(spec.maxIndex) ? spec.maxIndex : null,
        packets: spec.packets,
      };
    }
  }
  return null;
}

function rewriteIndexedName(name, cfg, oldIdx, newIdx) {
  if (cfg.kind === "ruleset") return name.replace(new RegExp("^RULE_SET" + oldIdx + "_BASE64$"), "RULE_SET" + newIdx + "_BASE64");
  const oldBase = baseIndexedName(cfg.prefix, oldIdx, cfg.zeroPlain);
  const newBase = baseIndexedName(cfg.prefix, newIdx, cfg.zeroPlain);
  if (name === oldBase || name.indexOf(oldBase + "_") === 0) return newBase + name.slice(oldBase.length);
  if (cfg.kind === "zapret") {
    const oldPackets = baseIndexedName(cfg.packets, oldIdx, cfg.zeroPlain);
    const newPackets = baseIndexedName(cfg.packets, newIdx, cfg.zeroPlain);
    if (name === oldPackets) return newPackets;
    if (name === cfg.packets + oldIdx) return cfg.packets + newIdx;
  }
  return name;
}

function renameIndexedRow(row, nextIndex) {
  const cfg = indexedRowConfig(row);
  if (!cfg) return false;
  const oldIndex = Number(row.dataset.index);
  if (usedIndexes(row.parentElement, row).includes(nextIndex)) return false;
  // Delegate to applyIndexedBatch (single-row move) so the wasOnServer /
  // tracker-cleanup / relabel logic lives in one place.
  applyIndexedBatch(row.parentElement, [{row, to: nextIndex}]);
  return true;
}

function applyIndexedRowNumber(row, nextIndex) {
  const cfg = indexedRowConfig(row);
  if (!cfg) return false;
  const minIndex = Number.isInteger(cfg.min) ? cfg.min : 0;
  if (!Number.isInteger(nextIndex) || nextIndex < minIndex || (Number.isInteger(cfg.max) && nextIndex > cfg.max)) return false;
  return renameIndexedRow(row, nextIndex);
}

function indexedRowsIn(wrap) {
  return [...wrap.querySelectorAll(".env-row[data-index]")]
    .filter((item) => indexedRowConfig(item))
    .sort((a, b) => Number(a.dataset.index) - Number(b.dataset.index));
}

function applyIndexedBatch(wrap, moves) {
  const ops = [];
  moves.forEach(({row, to}) => {
    const cfg = indexedRowConfig(row);
    const from = Number(row.dataset.index);
    row.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
      const oldName = el.name;
      const newName = rewriteIndexedName(oldName, cfg, from, to);
      ops.push({row, el, oldName, newName, value: fieldValue(el), to});
    });
  });
  ops.forEach(({oldName, newName, value}) => {
    if (oldName === newName) return;
    const wasOnServer = (localStorage.getItem(originalKey(oldName)) || "") !== "";
    if (wasOnServer) {
      // Server had oldName=V. After rename: remove V from oldName, add V at
      // newName. Keep originalKey(oldName) as the server value so commandFor
      // emits `remove`, and force originalKey(newName)="" so commandFor
      // emits `add` (rather than no-op when the value is unchanged).
      localStorage.setItem(envKey(oldName), "");
      trackRemovedEnv(oldName);
    } else {
      // Pure draft: purge old completely, no command needed.
      localStorage.removeItem(envKey(oldName));
      localStorage.removeItem(originalKey(oldName));
      localStorage.removeItem(pageKey(oldName));
    }
    // Always set originalKey(newName)="" on rename so the new row is treated
    // as an `add` against current value — keeps the "modified" badge and
    // ensures we actually emit a /container/envs/add command. Skip only if
    // the server already exposes newName (collision — leave that record
    // untouched so the rename appears as a `set`).
    if (localStorage.getItem(originalKey(newName)) === null) {
      localStorage.setItem(originalKey(newName), "");
    }
    // Stale tracker cleanup: if newName previously had a trackRemovedEnv
    // hidden input (because it was removed by a prior op), drop it now
    // that newName is being recreated. Otherwise collectPageCommands would
    // emit a phantom `remove newName` alongside the new `add newName`.
    cleanupRemovedEnvTracker(newName);
  });
  ops.forEach(({row, el, newName, value, to}) => {
    el.name = newName;
    if (el.type === "checkbox") el.checked = value === "true";
    else el.value = value;
    const caption = el.closest("label")?.querySelector("span");
    if (caption) caption.textContent = newName;
    localStorage.setItem(envKey(newName), value);
    // pageKey is what updateNavBadges uses to attribute the change to a
    // specific side-nav link. Without it, renamed envs disappear from the
    // sidebar/tab/group count until the user reloads the page (because
    // wireFieldEvents re-sets pageKey on every server-rendered or restored
    // input). Setting it inline here keeps the badge consistent immediately.
    localStorage.setItem(pageKey(newName), location.pathname);
    row.dataset.index = to;
    const indexInput = row.querySelector(".env-index input");
    if (indexInput) indexInput.value = to;
  });
  // Stale-tracker sweep: any name currently present as a real (non-tracker)
  // form input cancels the corresponding trackRemovedEnv hidden, so a row
  // that was renamed away and then renamed back doesn't emit a stale remove.
  sweepStaleRemovedTrackers();
  sortIndexedRows(wrap);
  if (typeof renderRulesPreview === "function") renderRulesPreview();
  // After any batch rename, the relabel (display-name) and indexed-row
  // controls on the moved rows must be re-applied (the index input value
  // is updated above, but the displayed span on the LINK0 alias may have
  // diverged from the new env name).
  moves.forEach(({row}) => relabelIndexedRow(row));
  if (typeof refreshAllBadges === "function") refreshAllBadges();
  // Программный rename меняет localStorage напрямую, без input/change-events,
  // которые подняли бы draftSaveDebounced. Без явного вызова сервер не узнает.
  draftSaveDebounced();
}

function cleanupRemovedEnvTracker(name) {
  document.querySelectorAll('#envForm input[data-removed-env="' + CSS.escape(name) + '"]').forEach((el) => el.remove());
}

function sweepStaleRemovedTrackers() {
  const form = document.getElementById("envForm");
  if (!form) return;
  const realNames = new Set();
  form.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
    if (el.hasAttribute("data-removed-env")) return; // skip tracker inputs themselves
    if (el.name) realNames.add(el.name);
  });
  form.querySelectorAll("input[data-removed-env]").forEach((tracker) => {
    if (realNames.has(tracker.dataset.removedEnv)) tracker.remove();
  });
}

function cleanupRemovedIndexedRows() {
  document.querySelectorAll(".rows").forEach((wrap) => {
    [...wrap.querySelectorAll(".env-row[data-index]")].forEach((row) => {
      const inputs = [...row.querySelectorAll("input[name], textarea[name], select[name]")];
      const allEmpty = inputs.every((el) => (localStorage.getItem(envKey(el.name)) || "") === "");
      const hasOriginal = inputs.some((el) => localStorage.getItem(originalKey(el.name)) !== null);
      if (allEmpty && hasOriginal) row.remove();
    });
  });
}

// Extract numeric idx + spec for any env name that belongs to an indexed
// prefix family — including sub-keys (LINK1_DIALER_PROXY, SUB_LINK2_INTERVAL,
// ZAPRET_PACKETS3). Returns null for non-indexed env names.
function indexFromEnvName(name) {
  // ZAPRET_PACKETS<N> / ZAPRET2_PACKETS<N> are sub-companions of ZAPRET(2)_CMD<N>
  // — treat them as the parent's row so an orphan ZAPRET_PACKETS3 restores
  // ZAPRET_CMD3's row.
  let m = name.match(/^ZAPRET2_PACKETS(\d*)$/);
  if (m) {
    const idx = m[1] === "" ? 0 : Number(m[1]);
    if (idx >= 0) return { prefix: "ZAPRET2_CMD", idx, spec: INDEXED_PREFIXES.ZAPRET2_CMD, kind: "companion", subSuffix: "" };
  }
  m = name.match(/^ZAPRET_PACKETS(\d*)$/);
  if (m) {
    const idx = m[1] === "" ? 0 : Number(m[1]);
    if (idx >= 0) return { prefix: "ZAPRET_CMD", idx, spec: INDEXED_PREFIXES.ZAPRET_CMD, kind: "companion", subSuffix: "" };
  }
  // Walk prefixes longest-first so SUB_LINK wins over LINK and ZAPRET2_CMD
  // wins over ZAPRET_CMD / ZAPRET2_PACKETS.
  const prefixes = Object.keys(INDEXED_PREFIXES).sort((a, b) => b.length - a.length);
  for (const prefix of prefixes) {
    const spec = INDEXED_PREFIXES[prefix];
    const suffix = spec.suffix || "";
    // Main env: PREFIX(\d*)?SUFFIX — zeroPlain allows empty digits.
    let m = name.match(new RegExp("^" + prefix + "(\\d*)" + (suffix ? suffix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") : "") + "$"));
    if (m) {
      if (m[1] === "" && !spec.zeroPlain) continue;
      const idx = m[1] === "" ? 0 : Number(m[1]);
      if (idx < spec.minIndex) continue;
      return { prefix, idx, spec, kind: "main", subSuffix: "" };
    }
    // Sub env: PREFIX(\d*)_SOMETHING (only if no suffix-based prefix like RULE_SET)
    if (!suffix) {
      m = name.match(new RegExp("^" + prefix + "(\\d*)_([A-Z0-9_]+)$"));
      if (m) {
        if (m[1] === "" && !spec.zeroPlain) continue;
        const idx = m[1] === "" ? 0 : Number(m[1]);
        if (idx < spec.minIndex) continue;
        // ZAPRET_PACKETS is its own pseudo-prefix exposed via spec.packets;
        // don't double-claim ZAPRET_PACKETSn as a sub-env of ZAPRET_CMD.
        // (the packets key gets restored as part of its parent's row markup)
        if (spec.packets && (prefix + "_" + m[2]).indexOf(spec.packets) === 0) {
          // accept — it's the packets companion
        }
        return { prefix, idx, spec, kind: "sub", subSuffix: "_" + m[2] };
      }
    }
  }
  return null;
}

function restoreMissingIndexedRows() {
  // Collect every (prefix, idx) that has at least one non-empty draft in
  // localStorage but no matching row in the DOM. Includes orphaned sub-keys
  // (LINK1_DIALER_PROXY without a LINK1) so the row is rebuilt and the user
  // doesn't lose the value silently.
  const needed = new Map();  // key = prefix + "#" + idx → {prefix, idx, spec}
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key || !key.startsWith("mihomo-env:")) continue;
    const value = localStorage.getItem(key) || "";
    if (value === "") continue;
    const info = indexFromEnvName(key.slice("mihomo-env:".length));
    if (!info) continue;
    const tag = info.prefix + "#" + info.idx;
    if (!needed.has(tag)) needed.set(tag, info);
  }
  // Subtract whatever is already in the DOM.
  document.querySelectorAll(".env-row[data-index]").forEach((row) => {
    const cfg = indexedRowConfig(row);
    if (!cfg) return;
    needed.delete(cfg.prefix + "#" + Number(row.dataset.index));
  });

  needed.forEach((info) => {
    const { prefix, idx, spec } = info;
    // SOCKS uses its own bespoke builder — delegate, then prefill from drafts.
    if (prefix === "SOCKS" && typeof addSocksRow === "function") {
      const wrap = document.getElementById(spec.containerId);
      if (!wrap) return;
      // addSocksRow auto-picks lowest free idx; we need a specific one.
      addSocksRow();
      const row = [...wrap.querySelectorAll(".socks-row")].pop();
      if (!row) return;
      row.dataset.index = idx;
      const hidden = row.querySelector('input[type="hidden"]');
      const newName = "SOCKS" + idx;
      if (hidden) {
        hidden.name = newName;
        hidden.value = localStorage.getItem(envKey(newName)) || "";
      }
      const title = row.querySelector(".socks-title");
      if (title) title.textContent = newName;
      const indexInput = row.querySelector(".env-index input");
      if (indexInput) indexInput.value = idx;
      // Decode hidden value back into sub-fields if present.
      if (hidden && hidden.value) {
        const map = {};
        hidden.value.split("#").forEach((kv) => {
          const pos = kv.indexOf("=");
          if (pos > 0) map[kv.slice(0, pos)] = kv.slice(pos + 1);
        });
        const set = (sel, v) => { const el = row.querySelector(sel); if (el && v != null) el.value = v; };
        const chk = (sel, v) => { const el = row.querySelector(sel); if (el) el.checked = v === "true"; };
        set(".socks-server", map.server);
        set(".socks-port", map.port);
        set(".socks-username", map.username);
        set(".socks-password", map.password);
        set(".socks-fingerprint", map.fingerprint);
        set(".socks-ip-version", map["ip-version"]);
        if ("tls" in map) chk(".socks-tls", map.tls);
        if ("skip-cert-verify" in map) chk(".socks-skip-cert-verify", map["skip-cert-verify"]);
        // udp default is true; explicit "false" → unchecked
        const udp = row.querySelector(".socks-udp");
        if (udp) udp.checked = map.udp !== "false";
      }
      return;
    }

    const wrap = document.getElementById(spec.containerId);
    if (!wrap) return;
    const envName = envNameFor(prefix, idx);       // canonical env (LINK / SUB_LINK0)
    const displayName = displayNameFor(prefix, idx); // visual label (LINK0 / SUB_LINK0)
    const value = localStorage.getItem(envKey(envName)) || "";

    const div = document.createElement("div");
    div.className = "env-row";
    if (prefix === "RULES" || prefix === "RULE_SET") div.className = "env-row rule-row";
    else if (prefix === "BYEDPI_CMD") div.className = "env-row dpi-single-row";
    else if (prefix === "ZAPRET_CMD" || prefix === "ZAPRET2_CMD") div.className = "env-row dpi-packet-row";
    else if (prefix === "FAKE_IP_FILTER") div.className = "env-row env-row-stack fake-filter-row";
    else if (prefix === "LINK") div.className = "env-row env-row-stack link-row";
    else if (prefix === "SUB_LINK") div.className = "env-row env-row-stack sub-link-row";
    div.dataset.index = idx;
    div.dataset.prefix = prefix;
    div.dataset.startAtOne = spec.minIndex >= 1 ? "true" : "false";
    if (Number.isInteger(spec.maxIndex)) div.dataset.maxIndex = String(spec.maxIndex);

    if (prefix === "RULE_SET") {
      div.innerHTML = `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="BASE64#name"></label><button type="button" onclick="openRuleSetModal(this)" title="Редактировать">&#10002;</button><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else if (prefix === "RULES") {
      div.innerHTML = `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="DOMAIN,example.com,GLOBAL"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else if (prefix === "FAKE_IP_FILTER") {
      div.innerHTML = `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="DOMAIN,www.youtube.com,real-ip"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else if (prefix === "LINK") {
      div.innerHTML =
        `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="vless://..."></label>` +
        `<label class="field-validated" data-validate="proxy_name"><span>${displayName}_DIALER_PROXY</span><input name="${envName}_DIALER_PROXY" value="${escapeAttr(localStorage.getItem(envKey(envName + "_DIALER_PROXY")) || "")}" placeholder="GLOBAL"></label>` +
        `<label><span>${displayName}_AMNEZIA_COUNTRY</span><input name="${envName}_AMNEZIA_COUNTRY" value="${escapeAttr(localStorage.getItem(envKey(envName + "_AMNEZIA_COUNTRY")) || "")}" placeholder="nl"></label>` +
        `<button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else if (prefix === "SUB_LINK") {
      div.innerHTML =
        `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="https://subscription"></label>` +
        `<label><span>${displayName}_INTERVAL</span><input type="number" name="${envName}_INTERVAL" value="${escapeAttr(localStorage.getItem(envKey(envName + "_INTERVAL")) || "")}" placeholder="3600"></label>` +
        `<label><span>${displayName}_PROXY</span><input name="${envName}_PROXY" value="${escapeAttr(localStorage.getItem(envKey(envName + "_PROXY")) || "")}" placeholder="DIRECT"></label>` +
        `<label class="field-validated" data-validate="proxy_name"><span>${displayName}_DIALER_PROXY</span><input name="${envName}_DIALER_PROXY" value="${escapeAttr(localStorage.getItem(envKey(envName + "_DIALER_PROXY")) || "")}" placeholder="GLOBAL"></label>` +
        `<div class="sub-link-extras">` +
          `<label><span>${displayName}_FILTER</span><input name="${envName}_FILTER" value="${escapeAttr(localStorage.getItem(envKey(envName + "_FILTER")) || "")}" placeholder="(?i)hk|hongkong"></label>` +
          `<label><span>${displayName}_EXCLUDE_FILTER</span><input name="${envName}_EXCLUDE_FILTER" value="${escapeAttr(localStorage.getItem(envKey(envName + "_EXCLUDE_FILTER")) || "")}" placeholder="(?i)test"></label>` +
          `<label class="field-validated" data-validate="exclude_type"><span>${displayName}_EXCLUDE_TYPE</span><input name="${envName}_EXCLUDE_TYPE" value="${escapeAttr(localStorage.getItem(envKey(envName + "_EXCLUDE_TYPE")) || "")}" placeholder="vmess|direct"></label>` +
          `<label><span>${displayName}_ADDITIONAL_PREFIX</span><input name="${envName}_ADDITIONAL_PREFIX" value="${escapeAttr(localStorage.getItem(envKey(envName + "_ADDITIONAL_PREFIX")) || "")}" placeholder="${displayName} | "></label>` +
          `<label><span>${displayName}_ADDITIONAL_SUFFIX</span><input name="${envName}_ADDITIONAL_SUFFIX" value="${escapeAttr(localStorage.getItem(envKey(envName + "_ADDITIONAL_SUFFIX")) || "")}" placeholder=" | ${displayName}"></label>` +
        `</div>` +
        `<div class="headers-editor">` +
          `<span>${displayName}_HEADERS</span>` +
          `<input type="hidden" class="sub-link-headers-value" name="${envName}_HEADERS" value="${escapeAttr(localStorage.getItem(envKey(envName + "_HEADERS")) || "")}">` +
          `<div class="headers-rows"></div>` +
          `<button type="button" class="headers-add">Добавить header</button>` +
        `</div>` +
        `<button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else if (prefix === "ZAPRET_CMD" || prefix === "ZAPRET2_CMD") {
      const packets = spec.packets;
      const packetsName = packets + idx; // ZAPRET_PACKETS / ZAPRET2_PACKETS have no zeroPlain
      const packetsVal = localStorage.getItem(envKey(packetsName)) || "";
      div.innerHTML = `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="--dpi-desync=..."></label><label><span>${packetsName}</span><input name="${packetsName}" value="${escapeAttr(packetsVal)}" placeholder="12"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else if (prefix === "BYEDPI_CMD") {
      div.innerHTML = `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="стратегия BYEDPI без --port и --transparent"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    } else {
      div.innerHTML = `<label><span>${displayName}</span><input name="${envName}" value="${escapeAttr(value)}" placeholder="значение env"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
    }
    wrap.appendChild(div);
    // Mark all inputs so wireFieldEvents knows these came from a draft, not
    // from the server. Without this, wireFieldEvents would overwrite
    // originalKey with the draft value, and any subsequent Delete would
    // emit a spurious `remove` command for an env that never existed.
    div.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
      el.dataset.fromDraft = "true";
    });
    wireFieldEvents(div);
    ensureIndexedRowControls(div);
    if (prefix === "SUB_LINK" && typeof initHeadersEditors === "function") initHeadersEditors(div);
    if (typeof wirePaneValidators === "function") wirePaneValidators(div);
  });
  // Restored rows are appended in localStorage iteration order. Re-sort every
  // wrap we touched so #0 isn't visually orphaned at the bottom.
  document.querySelectorAll(".rows").forEach((wrap) => sortIndexedRows(wrap));
}

function shiftIndexedRow(row, targetIndex) {
  // Minimal-displacement rename used by the manual number input.
  // Rule of thumb: if the target slot is free, just rename — touch nothing
  // else. If it's occupied, locate the nearest empty slot between source
  // and target and only shift the rows in the narrow [gap..target] interval
  // to fill it. So with 1,2,4,5 and a fresh row at 0, moving 0→5 leaves
  // 1 and 2 untouched, slides 4→3 and 5→4, and the moved row lands at 5.
  const cfg = indexedRowConfig(row);
  if (!cfg) return false;
  const current = Number(row.dataset.index);
  const minIndex = Number.isInteger(cfg.min) ? cfg.min : 0;
  if (!Number.isInteger(targetIndex) || targetIndex < minIndex || (Number.isInteger(cfg.max) && targetIndex > cfg.max)) return false;
  if (targetIndex === current) return true;
  const wrap = row.parentElement;
  const rows = indexedRowsIn(wrap);
  const occupied = new Set(rows.filter((r) => r !== row).map((r) => Number(r.dataset.index)));
  const moves = [{row, to: targetIndex}];
  if (occupied.has(targetIndex)) {
    if (targetIndex > current) {
      // Walk back from (target-1) toward current looking for an empty slot.
      // If found at `gap`, only rows in (gap..target] need to shift down by 1.
      let gap = current;
      for (let i = targetIndex - 1; i > current; i--) {
        if (!occupied.has(i)) { gap = i; break; }
      }
      rows.forEach((item) => {
        const idx = Number(item.dataset.index);
        if (item !== row && idx > gap && idx <= targetIndex) moves.push({row: item, to: idx - 1});
      });
    } else {
      let gap = current;
      for (let i = targetIndex + 1; i < current; i++) {
        if (!occupied.has(i)) { gap = i; break; }
      }
      rows.forEach((item) => {
        const idx = Number(item.dataset.index);
        if (item !== row && idx >= targetIndex && idx < gap) moves.push({row: item, to: idx + 1});
      });
    }
  }
  applyIndexedBatch(wrap, moves);
  return true;
}

function moveIndexedRow(row, direction) {
  const cfg = indexedRowConfig(row);
  if (!cfg) return;
  const current = Number(row.dataset.index);
  const minIndex = Number.isInteger(cfg.min) ? cfg.min : 0;
  const target = current + direction;
  if (target < minIndex || (Number.isInteger(cfg.max) && target > cfg.max)) return;
  const other = indexedRowsIn(row.parentElement).find((item) => item !== row && Number(item.dataset.index) === target);
  const moves = [{row, to: target}];
  if (other) moves.push({row: other, to: current});
  applyIndexedBatch(row.parentElement, moves);
}

function ensureIndexedRowControls(row) {
  const cfg = indexedRowConfig(row);
  if (!cfg) return;
  row.classList.add("indexed-row");
  let grip = row.querySelector(":scope > .env-grip");
  if (!grip) {
    grip = document.createElement("div");
    grip.className = "env-grip";
    grip.draggable = true;
    grip.title = "Перетащить";
    grip.textContent = "⋮⋮";
    row.insertBefore(grip, row.firstElementChild);
  } else {
    grip.draggable = true;
  }
  const existing = row.querySelector(".env-index");
  if (existing && existing.querySelector("input")) {
    wireIndexedRow(row);
    return;
  }
  if (existing) existing.remove();
  const current = Number(row.dataset.index);
  const label = document.createElement("label");
  label.className = "env-index";
  label.innerHTML = `<input type="number" step="1" value="${current}" min="${cfg.min}" aria-label="ENV number">`;
  if (Number.isInteger(cfg.max)) label.querySelector("input").max = cfg.max;
  row.insertBefore(label, grip.nextSibling);
  wireIndexedRow(row);
}

function wireIndexedRow(row) {
  const input = row.querySelector(".env-index input");
  if (!input || input.dataset.wired === "true") return;
  input.dataset.wired = "true";
  const cfg = indexedRowConfig(row);
  const minIndex = cfg && Number.isInteger(cfg.min) ? cfg.min : 0;
  input.min = minIndex;
  if (cfg && Number.isInteger(cfg.max)) input.max = cfg.max;
  input.addEventListener("change", () => {
    const nextIndex = Number(input.value);
    const overMax = cfg && Number.isInteger(cfg.max) && nextIndex > cfg.max;
    if (!Number.isInteger(nextIndex) || nextIndex < minIndex || overMax || !shiftIndexedRow(row, nextIndex)) {
      input.value = row.dataset.index;
      input.setCustomValidity("Номер вне допустимого диапазона");
      input.reportValidity();
      setTimeout(() => input.setCustomValidity(""), 1200);
    }
    if (typeof renderRulesPreview === "function") renderRulesPreview();
  });
}

function initDragAndDropForAll() {
  document.querySelectorAll(".rows").forEach((wrap) => initDragAndDrop(wrap));
}

function initDragAndDrop(wrap) {
  if (!wrap || wrap.dataset.dragWired === "true") return;
  wrap.dataset.dragWired = "true";
  let draggedRow = null;

  wrap.addEventListener("dragstart", (e) => {
    const grip = e.target.closest(".env-grip");
    const row = e.target.closest(".env-row[data-index]");
    if (!grip || !row || !indexedRowConfig(row)) {
      e.preventDefault();
      return;
    }
    draggedRow = row;
    row.classList.add("dragging");
    e.dataTransfer.effectAllowed = "move";
    try { e.dataTransfer.setData("text/plain", row.dataset.index); } catch (_) {}
  });

  wrap.addEventListener("dragend", (e) => {
    const row = e.target.closest(".env-row[data-index]");
    if (row) row.classList.remove("dragging");
    draggedRow = null;
    dropIndicatorClear(wrap);
  });

  wrap.addEventListener("dragover", (e) => {
    e.preventDefault();
    if (!draggedRow) return;
    const target = computeDropTarget(wrap, e.clientY);
    dropIndicatorClear(wrap);
    if (target && target.row !== draggedRow) {
      target.row.classList.add(target.after ? "drop-target-bottom" : "drop-target-top");
    }
    const scrollZone = 60;
    const scrollSpeed = 16;
    if (e.clientY < scrollZone) {
      window.scrollBy(0, -scrollSpeed);
    } else if (e.clientY > window.innerHeight - scrollZone) {
      window.scrollBy(0, scrollSpeed);
    }
  });

  wrap.addEventListener("drop", (e) => {
    e.preventDefault();
    if (!draggedRow) return;
    const target = computeDropTarget(wrap, e.clientY);
    dropIndicatorClear(wrap);
    if (!target || target.row === draggedRow) return;
    reorderIndexedRowsByVisualOrder(draggedRow, target.row, target.after);
  });
}

function computeDropTarget(wrap, clientY) {
  const rows = [...wrap.querySelectorAll(".env-row[data-index]")].filter((r) => indexedRowConfig(r) && !r.classList.contains("dragging"));
  let closest = null;
  let minDist = Infinity;
  for (const row of rows) {
    const rect = row.getBoundingClientRect();
    const center = rect.top + rect.height / 2;
    const dist = Math.abs(clientY - center);
    if (dist < minDist) {
      minDist = dist;
      closest = {row, after: clientY > center};
    }
  }
  return closest;
}

function dropIndicatorClear(wrap) {
  wrap.querySelectorAll(".env-row[data-index]").forEach((r) => {
    r.classList.remove("drop-target-top", "drop-target-bottom");
  });
}

function reorderIndexedRowsByVisualOrder(draggedRow, targetRow, after) {
  // Drag-drop is now a thin wrapper over shiftIndexedRow — derive the desired
  // numeric target from the row at the drop position and let the minimal-
  // displacement algorithm decide what (if anything) to shift. Previously
  // we collapsed every row to a sequential cfg.min..cfg.min+N range, which
  // gratuitously renumbered untouched rows and yanked LINK15 down to LINK8
  // just because the user dragged it above LINK10.
  const cfg = indexedRowConfig(draggedRow);
  if (!cfg) return;
  const currentIdx = Number(draggedRow.dataset.index);
  const targetIdx = Number(targetRow.dataset.index);
  if (!Number.isInteger(currentIdx) || !Number.isInteger(targetIdx)) return;
  // Visually "above" → take the target's slot. "Below" → next slot after target.
  let desired = after ? targetIdx + 1 : targetIdx;
  // Skip no-op: drop is on dragged row itself or right after it where it already sits.
  if (desired === currentIdx) return;
  const minIndex = Number.isInteger(cfg.min) ? cfg.min : 0;
  if (desired < minIndex) desired = minIndex;
  if (Number.isInteger(cfg.max) && desired > cfg.max) desired = cfg.max;
  shiftIndexedRow(draggedRow, desired);
}

function ruleSetB64Decode(value) {
  const text = String(value || "");
  const hash = text.indexOf("#");
  const name = hash >= 0 ? text.slice(hash + 1) : "";
  const b64 = hash >= 0 ? text.slice(0, hash) : text;
  try {
    const plain = decodeURIComponent(escape(atob(b64)));
    return {plain, name};
  } catch (e) {
    return {plain: "", name: name || ""};
  }
}

function ruleSetB64Encode(plain, name) {
  if (!plain) return "";
  return btoa(unescape(encodeURIComponent(plain))) + (name ? "#" + name : "");
}

let ruleSetModalTarget = null;

function openRuleSetModal(btn) {
  const row = btn.closest(".env-row");
  if (!row) return;
  const input = row.querySelector('input[name^="RULE_SET"]');
  if (!input) return;
  ruleSetModalTarget = input;
  const decoded = ruleSetB64Decode(input.value);
  const nameEl = document.getElementById("ruleSetModalName");
  const plainEl = document.getElementById("ruleSetModalPlain");
  const previewEl = document.getElementById("ruleSetModalPreview");
  if (nameEl) nameEl.value = decoded.name;
  if (plainEl) plainEl.value = decoded.plain;
  if (previewEl) previewEl.textContent = input.value;
  if (plainEl) {
    const sync = () => {
      const v = ruleSetB64Encode(plainEl.value, nameEl ? nameEl.value : "");
      if (previewEl) previewEl.textContent = v;
    };
    plainEl.oninput = sync;
    if (nameEl) nameEl.oninput = sync;
    sync();
  }
  document.getElementById("ruleSetModal").hidden = false;
}

function closeRuleSetModal() {
  document.getElementById("ruleSetModal").hidden = true;
  ruleSetModalTarget = null;
}

function saveRuleSetModal() {
  if (!ruleSetModalTarget) return;
  const nameEl = document.getElementById("ruleSetModalName");
  const plainEl = document.getElementById("ruleSetModalPlain");
  const value = ruleSetB64Encode(plainEl.value, nameEl ? nameEl.value : "");
  ruleSetModalTarget.value = value;
  rememberField(ruleSetModalTarget);
  closeRuleSetModal();
}

let fileEditTarget = null;
let fileEditName = "";

function addRuleSetFileRow(name, size) {
  const wrap = document.querySelector(".mount-links");
  if (!wrap) return;
  const div = document.createElement("div");
  div.className = "mount-link rule-set-file";
  div.dataset.file = name;
  const displayName = name.replace(/\.txt$/, '');
  div.innerHTML = `<span>${escapeAttr(displayName)}</span><small>${size} bytes</small><div class="file-actions"><button type="button" onclick="editRuleSetFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteRuleSetFile(this)" title="Удалить">&#10005;</button></div>`;
  wrap.appendChild(div);
}

function editRuleSetFile(btn) {
  const row = btn.closest(".rule-set-file");
  if (!row) return;
  fileEditName = row.dataset.file;
  const displayName = fileEditName.replace(/\.txt$/, '');
  const titleEl = document.getElementById("fileEditTitle");
  if (titleEl) titleEl.textContent = displayName;
  const nameEl = document.getElementById("fileEditName");
  if (nameEl) { nameEl.value = displayName; nameEl.readOnly = true; }
  fetch('/cgi-bin/read-file?file=' + encodeURIComponent(fileEditName) + '&type=ruleset')
    .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
    .then((text) => {
      const plainEl = document.getElementById("fileEditPlain");
      if (plainEl) plainEl.value = text;
      document.getElementById("fileEditModal").hidden = false;
    })
    .catch((e) => alert('Не удалось прочитать файл: ' + e.message));
}

function createRuleSetFile() {
  fileEditName = "";
  const titleEl = document.getElementById("fileEditTitle");
  if (titleEl) titleEl.textContent = "Новый файл";
  const nameEl = document.getElementById("fileEditName");
  if (nameEl) { nameEl.value = ""; nameEl.readOnly = false; nameEl.focus(); }
  const plainEl = document.getElementById("fileEditPlain");
  if (plainEl) plainEl.value = "";
  document.getElementById("fileEditModal").hidden = false;
}

function closeFileEditModal() {
  document.getElementById("fileEditModal").hidden = true;
  fileEditName = "";
}

function saveFileEditModal() {
  const nameEl = document.getElementById("fileEditName");
  const plainEl = document.getElementById("fileEditPlain");
  if (!plainEl || !nameEl) return;
  const name = nameEl.value.trim();
  if (!name) { alert("Укажите имя файла"); return; }
  const fileName = name.endsWith(".txt") ? name : name + ".txt";
  const isNew = !nameEl.readOnly;
  const b64 = btoa(unescape(encodeURIComponent(plainEl.value)));
  fetch('/cgi-bin/save-file', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'file=' + encodeURIComponent(fileName) + '&b64=' + encodeURIComponent(b64) + '&type=ruleset'
  })
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() === "OK") {
        closeFileEditModal();
        if (isNew) {
          const size = new Blob([plainEl.value]).size;
          addRuleSetFileRow(fileName, size);
        }
      } else {
        alert('Ошибка сохранения: ' + text);
      }
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

function deleteRuleSetFile(btn) {
  const row = btn.closest(".rule-set-file");
  if (!row) return;
  const name = row.dataset.file;
  if (!window.confirm("Удалить файл " + name.replace(/\.txt$/, '') + "?")) return;
  row.remove();
  fetch('/cgi-bin/delete-file?file=' + encodeURIComponent(name) + '&type=ruleset')
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() !== "OK") {
        alert('Ошибка удаления: ' + text);
      }
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

let proxyEditName = "";

function yamlAnchorForFile(name) {
  return name.replace(/\.(conf|ovpn|toml)$/i, '.yaml');
}

function addProxyFileRow(name, size) {
  const wrap = document.getElementById("proxy-mount-links");
  if (!wrap) return;
  const empty = wrap.querySelector(".empty");
  if (empty) empty.remove();
  const div = document.createElement("div");
  div.className = "mount-link proxy-file";
  div.dataset.file = name;
  const anchor = yamlAnchorForFile(name);
  div.dataset.anchor = anchor;
  const displayName = name.replace(/\.(yaml|yml|conf)$/, '');
  div.innerHTML = `<a class="mount-link-title" href="yaml.html#${encodeURIComponent(anchor)}"><span>${escapeAttr(displayName)}</span><small>${size} bytes</small></a><div class="file-actions"><button type="button" onclick="editProxyFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteProxyFile(this)" title="Удалить">&#10005;</button></div>`;
  wrap.appendChild(div);
}

function resetProxyValidateResult() {
  const box = document.getElementById("proxyValidateResult");
  if (!box) return;
  box.hidden = true;
  box.className = "validate-result";
  box.textContent = "";
}

function editProxyFile(btn) {
  const row = btn.closest(".proxy-file");
  if (!row) return;
  proxyEditName = row.dataset.file;
  const displayName = proxyEditName.replace(/\.(yaml|yml|conf)$/, '');
  const titleEl = document.getElementById("proxyEditTitle");
  if (titleEl) titleEl.textContent = displayName;
  const nameEl = document.getElementById("proxyEditName");
  if (nameEl) { nameEl.value = displayName; nameEl.readOnly = true; }
  const tplRow = document.getElementById("proxyTemplateRow");
  if (tplRow) tplRow.style.display = "none";
  resetProxyValidateResult();
  fetch('/cgi-bin/read-file?file=' + encodeURIComponent(proxyEditName) + '&type=proxy')
    .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
    .then((text) => {
      const plainEl = document.getElementById("proxyEditPlain");
      if (plainEl) plainEl.value = text;
      document.getElementById("proxyEditModal").hidden = false;
    })
    .catch((e) => alert('Не удалось прочитать файл: ' + e.message));
}

function createProxyFile() {
  proxyEditName = "";
  const titleEl = document.getElementById("proxyEditTitle");
  if (titleEl) titleEl.textContent = "Новый файл";
  const nameEl = document.getElementById("proxyEditName");
  if (nameEl) { nameEl.value = ""; nameEl.readOnly = false; nameEl.focus(); }
  const plainEl = document.getElementById("proxyEditPlain");
  if (plainEl) plainEl.value = "";
  const tplRow = document.getElementById("proxyTemplateRow");
  if (tplRow) tplRow.style.display = "";
  const tplSel = document.getElementById("proxyTemplateSelect");
  if (tplSel) tplSel.value = "";
  resetProxyValidateResult();
  document.getElementById("proxyEditModal").hidden = false;
}

function closeProxyFileModal() {
  document.getElementById("proxyEditModal").hidden = true;
  proxyEditName = "";
  resetProxyValidateResult();
}

function loadProxyTemplate() {
  const sel = document.getElementById("proxyTemplateSelect");
  const plainEl = document.getElementById("proxyEditPlain");
  if (!sel || !plainEl) return;
  const tpl = sel.value;
  if (!tpl) { alert("Сначала выберите шаблон в списке"); return; }
  if (plainEl.value.trim() && !window.confirm("Заменить текущее содержимое выбранным шаблоном?")) return;
  fetch('templates/proxy/' + encodeURIComponent(tpl) + '.yaml')
    .then((r) => { if (!r.ok) throw new Error("HTTP " + r.status); return r.text(); })
    .then((text) => { plainEl.value = text; resetProxyValidateResult(); })
    .catch((e) => alert('Не удалось загрузить шаблон: ' + e.message));
}

function showProxyValidateResult(ok, message) {
  const box = document.getElementById("proxyValidateResult");
  if (!box) return;
  box.hidden = false;
  box.className = "validate-result " + (ok ? "validate-ok" : "validate-fail");
  box.textContent = message;
}

function decodeB64Utf8(b64) {
  if (!b64) return "";
  try {
    const bin = atob(b64);
    // Convert binary string to UTF-8
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    if (typeof TextDecoder !== "undefined") {
      return new TextDecoder("utf-8").decode(bytes);
    }
    return decodeURIComponent(escape(bin));
  } catch (e) {
    return "[не удалось декодировать base64: " + e.message + "]";
  }
}

function validateProxyYaml() {
  const plainEl = document.getElementById("proxyEditPlain");
  if (!plainEl) return Promise.resolve(false);
  const yaml = plainEl.value;
  if (!yaml.trim()) {
    showProxyValidateResult(false, "Пустое содержимое");
    return Promise.resolve(false);
  }
  showProxyValidateResult(true, "Проверка через mihomo -t…");
  const b64 = btoa(unescape(encodeURIComponent(yaml)));
  return fetch('/cgi-bin/validate-proxy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'b64=' + encodeURIComponent(b64)
  })
    .then((r) => r.text())
    .then((text) => {
      let data;
      try { data = JSON.parse(text); }
      catch (e) {
        showProxyValidateResult(false, "Сервер вернул не-JSON:\n" + text.slice(0, 4000));
        return false;
      }
      const output = decodeB64Utf8(data.output_b64) || decodeB64Utf8(data.error_b64);
      if (data && data.ok) {
        showProxyValidateResult(true, "OK — mihomo -t прошёл успешно.\n" + output);
        return true;
      }
      showProxyValidateResult(false, "Ошибка валидации:\n" + (output || "неизвестно"));
      return false;
    })
    .catch((e) => {
      showProxyValidateResult(false, "Сеть/CGI: " + e);
      return false;
    });
}

function extractProxyNames(yamlText) {
  const out = [];
  const lines = yamlText.split(/\r?\n/);
  const re = /^\s*-?\s*name:\s*(.+?)\s*$/;
  for (const line of lines) {
    const m = re.exec(line);
    if (m) {
      let v = m[1];
      v = v.replace(/^['"]/, "").replace(/['"]$/, "");
      if (v) out.push(v);
    }
  }
  return out;
}

function fetchProxyList() {
  return fetch('/cgi-bin/list-files?type=proxy')
    .then((r) => r.json())
    .catch(() => ({ ok: false, files: [] }));
}

function saveProxyFileModal() {
  const nameEl = document.getElementById("proxyEditName");
  const plainEl = document.getElementById("proxyEditPlain");
  if (!plainEl || !nameEl) return;
  const name = nameEl.value.trim();
  if (!name) { alert("Укажите имя файла"); return; }
  const fileName = name.endsWith(".yaml") || name.endsWith(".yml") ? name : name + ".yaml";
  const isNew = !nameEl.readOnly;
  const newNames = extractProxyNames(plainEl.value);

  fetchProxyList()
    .then((data) => {
      const existing = (data && data.files) || [];
      // Filename uniqueness (only for new file)
      if (isNew && existing.some((f) => f.file === fileName)) {
        throw new Error("Файл с именем " + fileName + " уже существует");
      }
      // Proxy `name:` uniqueness — across other files
      const collisions = [];
      const ownFile = isNew ? null : fileName;
      for (const f of existing) {
        if (ownFile && f.file === ownFile) continue;
        if (!f.name) continue;
        for (const n of f.name.split(",")) {
          if (n && newNames.includes(n)) collisions.push(n + " (в файле " + f.file + ")");
        }
      }
      if (collisions.length) throw new Error("Конфликт имён proxy:\n" + collisions.join("\n"));

      // Run mihomo -t validation
      return validateProxyYaml();
    })
    .then((valid) => {
      if (!valid) throw new Error("Валидация не пройдена — сохранение отменено");
      const b64 = btoa(unescape(encodeURIComponent(plainEl.value)));
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(fileName) + '&b64=' + encodeURIComponent(b64) + '&type=proxy'
      }).then((r) => r.text());
    })
    .then((text) => {
      if (text.trim() === "OK") {
        closeProxyFileModal();
        if (isNew) {
          const size = new Blob([plainEl.value]).size;
          addProxyFileRow(fileName, size);
        }
      } else {
        alert('Ошибка сохранения: ' + text);
      }
    })
    .catch((e) => alert(e.message || String(e)));
}

function deleteProxyFile(btn) {
  const row = btn.closest(".proxy-file");
  if (!row) return;
  const name = row.dataset.file;
  if (!window.confirm("Удалить файл " + name.replace(/\.(yaml|yml|conf)$/, '') + "?")) return;
  row.remove();
  fetch('/cgi-bin/delete-file?file=' + encodeURIComponent(name) + '&type=proxy')
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() !== "OK") {
        alert('Ошибка удаления: ' + text);
      }
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

// ===== AWG conf editor =====

let awgEditName = "";

function addAwgFileRow(name, size) {
  const wrap = document.getElementById("awg-mount-links");
  if (!wrap) return;
  const empty = wrap.querySelector(".empty");
  if (empty) empty.remove();
  const existing = wrap.querySelector('.awg-file[data-file="' + name.replace(/"/g, '\\"') + '"]');
  if (existing) existing.remove();
  const div = document.createElement("div");
  div.className = "mount-link awg-file";
  div.dataset.file = name;
  const anchor = yamlAnchorForFile(name);
  div.dataset.anchor = anchor;
  const displayName = name.replace(/\.conf$/, '');
  div.innerHTML = `<a class="mount-link-title" href="yaml.html#${encodeURIComponent(anchor)}"><span>${escapeAttr(displayName)}</span><small>${size} bytes</small></a><div class="file-actions"><button type="button" onclick="editAwgFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteAwgFile(this)" title="Удалить">&#10005;</button></div>`;
  wrap.appendChild(div);
}

function uploadAwgConf() {
  const input = document.getElementById("awgUpload");
  if (!input || !input.files || !input.files.length) return;
  const file = input.files[0];
  if (!/\.conf$/i.test(file.name)) {
    alert("Ожидается файл с расширением .conf");
    input.value = ""; return;
  }
  const reader = new FileReader();
  reader.onload = function () {
    const data = String(reader.result || "");
    const idx = data.indexOf(",");
    const b64 = idx >= 0 ? data.slice(idx + 1) : "";
    if (!b64) { alert("Не удалось прочитать файл"); return; }
    fetch('/cgi-bin/list-files?type=awg').then((r) => r.json()).then((listData) => {
      const existing = (listData && listData.files) || [];
      if (existing.some((f) => f.file === file.name) && !window.confirm("Файл " + file.name + " существует. Перезаписать?")) {
        input.value = ""; return;
      }
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(file.name) + '&b64=' + encodeURIComponent(b64) + '&type=awg'
      })
        .then((r) => r.text())
        .then((text) => {
          if (text.trim() === "OK") {
            addAwgFileRow(file.name, file.size);
            input.value = "";
          } else {
            alert('Ошибка загрузки: ' + text);
          }
        });
    }).catch((e) => alert('Ошибка сети: ' + e));
  };
  reader.onerror = function () { alert("Ошибка чтения файла"); };
  reader.readAsDataURL(file);
}

function uploadProxyYaml() {
  const input = document.getElementById("proxyUpload");
  if (!input || !input.files || !input.files.length) return;
  const file = input.files[0];
  if (!/\.(yaml|yml)$/i.test(file.name)) {
    alert("Ожидается файл с расширением .yaml или .yml");
    input.value = ""; return;
  }
  const reader = new FileReader();
  reader.onload = function () {
    const data = String(reader.result || "");
    const idx = data.indexOf(",");
    const b64 = idx >= 0 ? data.slice(idx + 1) : "";
    if (!b64) { alert("Не удалось прочитать файл"); return; }
    fetch('/cgi-bin/list-files?type=proxy').then((r) => r.json()).then((listData) => {
      const existing = (listData && listData.files) || [];
      if (existing.some((f) => f.file === file.name) && !window.confirm("Файл " + file.name + " существует. Перезаписать?")) {
        input.value = ""; return;
      }
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(file.name) + '&b64=' + encodeURIComponent(b64) + '&type=proxy'
      })
        .then((r) => r.text())
        .then((text) => {
          if (text.trim() === "OK") {
            // Replace existing row or add new
            const wrap = document.getElementById("proxy-mount-links");
            const existingRow = wrap && wrap.querySelector('.proxy-file[data-file="' + file.name.replace(/"/g, '\\"') + '"]');
            if (existingRow) existingRow.remove();
            addProxyFileRow(file.name, file.size);
            input.value = "";
          } else {
            alert('Ошибка загрузки: ' + text);
          }
        });
    }).catch((e) => alert('Ошибка сети: ' + e));
  };
  reader.onerror = function () { alert("Ошибка чтения файла"); };
  reader.readAsDataURL(file);
}

function editAwgFile(btn) {
  const row = btn.closest(".awg-file");
  if (!row) return;
  awgEditName = row.dataset.file;
  const displayName = awgEditName.replace(/\.conf$/, '');
  const titleEl = document.getElementById("awgEditTitle");
  if (titleEl) titleEl.textContent = displayName;
  const nameEl = document.getElementById("awgEditName");
  if (nameEl) { nameEl.value = displayName; nameEl.readOnly = true; }
  const tplRow = document.getElementById("awgTemplateRow");
  if (tplRow) tplRow.style.display = "none";
  fetch('/cgi-bin/read-file?file=' + encodeURIComponent(awgEditName) + '&type=awg')
    .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
    .then((text) => {
      const plainEl = document.getElementById("awgEditPlain");
      if (plainEl) plainEl.value = text;
      document.getElementById("awgEditModal").hidden = false;
    })
    .catch((e) => alert('Не удалось прочитать файл: ' + e.message));
}

function createAwgFile() {
  awgEditName = "";
  const titleEl = document.getElementById("awgEditTitle");
  if (titleEl) titleEl.textContent = "Новый AWG config";
  const nameEl = document.getElementById("awgEditName");
  if (nameEl) { nameEl.value = ""; nameEl.readOnly = false; nameEl.focus(); }
  const plainEl = document.getElementById("awgEditPlain");
  if (plainEl) plainEl.value = "";
  const tplRow = document.getElementById("awgTemplateRow");
  if (tplRow) tplRow.style.display = "";
  document.getElementById("awgEditModal").hidden = false;
}

function closeAwgFileModal() {
  document.getElementById("awgEditModal").hidden = true;
  awgEditName = "";
}

function loadAwgTemplate() {
  const plainEl = document.getElementById("awgEditPlain");
  if (!plainEl) return;
  if (plainEl.value.trim() && !window.confirm("Заменить текущее содержимое шаблоном?")) return;
  fetch('templates/awg.conf')
    .then((r) => { if (!r.ok) throw new Error("HTTP " + r.status); return r.text(); })
    .then((text) => { plainEl.value = text; })
    .catch((e) => alert('Не удалось загрузить шаблон: ' + e.message));
}

function saveAwgFileModal() {
  const nameEl = document.getElementById("awgEditName");
  const plainEl = document.getElementById("awgEditPlain");
  if (!plainEl || !nameEl) return;
  const name = nameEl.value.trim();
  if (!name) { alert("Укажите имя файла"); return; }
  const fileName = name.endsWith(".conf") ? name : name + ".conf";
  const isNew = !nameEl.readOnly;

  // Filename uniqueness for new files
  const checkPromise = isNew
    ? fetch('/cgi-bin/list-files?type=awg').then((r) => r.json()).then((data) => {
        const existing = (data && data.files) || [];
        if (existing.some((f) => f.file === fileName)) {
          throw new Error("Файл с именем " + fileName + " уже существует");
        }
      })
    : Promise.resolve();

  checkPromise
    .then(() => {
      const b64 = btoa(unescape(encodeURIComponent(plainEl.value)));
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(fileName) + '&b64=' + encodeURIComponent(b64) + '&type=awg'
      }).then((r) => r.text());
    })
    .then((text) => {
      if (text.trim() === "OK") {
        closeAwgFileModal();
        if (isNew) {
          const size = new Blob([plainEl.value]).size;
          addAwgFileRow(fileName, size);
        }
      } else {
        alert('Ошибка сохранения: ' + text);
      }
    })
    .catch((e) => alert(e.message || String(e)));
}

function deleteAwgFile(btn) {
  const row = btn.closest(".awg-file");
  if (!row) return;
  const name = row.dataset.file;
  if (!window.confirm("Удалить файл " + name.replace(/\.conf$/, '') + "?")) return;
  row.remove();
  fetch('/cgi-bin/delete-file?file=' + encodeURIComponent(name) + '&type=awg')
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() !== "OK") {
        alert('Ошибка удаления: ' + text);
      }
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

// ===== TrustTunnel/OpenVPN mounted config editors =====

const mountedConfigMeta = {
  trusttunnel: {
    rowClass: "trusttunnel-file",
    linksId: "trusttunnel-mount-links",
    editModalId: "trusttunnelEditModal",
    editTitleId: "trusttunnelEditTitle",
    editNameId: "trusttunnelEditName",
    editPlainId: "trusttunnelEditPlain",
    templateRowId: "trusttunnelTemplateRow",
    uploadId: "trustTunnelUpload",
    ext: ".toml",
    extRe: /\.toml$/i,
    stripRe: /\.toml$/i,
    templateUrl: "templates/trusttunnel.toml",
    titleNew: "Новый TrustTunnel config",
    expected: "Ожидается файл с расширением .toml"
  },
  openvpn: {
    rowClass: "openvpn-file",
    linksId: "openvpn-mount-links",
    editModalId: "openvpnEditModal",
    editTitleId: "openvpnEditTitle",
    editNameId: "openvpnEditName",
    editPlainId: "openvpnEditPlain",
    templateRowId: "openvpnTemplateRow",
    uploadId: "openVpnUpload",
    ext: ".ovpn",
    extRe: /\.(ovpn|conf)$/i,
    stripRe: /\.(ovpn|conf)$/i,
    templateUrl: "templates/openvpn.conf",
    titleNew: "Новый OpenVPN config",
    expected: "Ожидается файл с расширением .ovpn или .conf"
  }
};
const mountedConfigEditName = { trusttunnel: "", openvpn: "" };

function addMountedConfigRow(type, name, size) {
  const meta = mountedConfigMeta[type];
  const wrap = document.getElementById(meta.linksId);
  if (!wrap) return;
  const empty = wrap.querySelector(".empty");
  if (empty) empty.remove();
  const existing = wrap.querySelector("." + meta.rowClass + '[data-file="' + name.replace(/"/g, '\\"') + '"]');
  if (existing) existing.remove();
  const div = document.createElement("div");
  div.className = "mount-link " + meta.rowClass;
  div.dataset.file = name;
  const anchor = yamlAnchorForFile(name);
  div.dataset.anchor = anchor;
  const displayName = name.replace(meta.stripRe, "");
  div.innerHTML = `<a class="mount-link-title" href="yaml.html#${encodeURIComponent(anchor)}"><span>${escapeAttr(displayName)}</span><small>${size} bytes</small></a><div class="file-actions"><button type="button" onclick="${type === "trusttunnel" ? "editTrustTunnelFile" : "editOpenVpnFile"}(this)" title="Редактировать">&#10002;</button><button type="button" onclick="${type === "trusttunnel" ? "deleteTrustTunnelFile" : "deleteOpenVpnFile"}(this)" title="Удалить">&#10005;</button></div>`;
  wrap.appendChild(div);
}

function uploadMountedConfig(type) {
  const meta = mountedConfigMeta[type];
  const input = document.getElementById(meta.uploadId);
  if (!input || !input.files || !input.files.length) return;
  const file = input.files[0];
  if (!meta.extRe.test(file.name)) {
    alert(meta.expected);
    input.value = ""; return;
  }
  const reader = new FileReader();
  reader.onload = function () {
    const data = String(reader.result || "");
    const idx = data.indexOf(",");
    const b64 = idx >= 0 ? data.slice(idx + 1) : "";
    if (!b64) { alert("Не удалось прочитать файл"); return; }
    fetch('/cgi-bin/list-files?type=' + encodeURIComponent(type)).then((r) => r.json()).then((listData) => {
      const existing = (listData && listData.files) || [];
      if (existing.some((f) => f.file === file.name) && !window.confirm("Файл " + file.name + " существует. Перезаписать?")) {
        input.value = ""; return;
      }
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(file.name) + '&b64=' + encodeURIComponent(b64) + '&type=' + encodeURIComponent(type)
      })
        .then((r) => r.text())
        .then((text) => {
          if (text.trim() === "OK") {
            addMountedConfigRow(type, file.name, file.size);
            input.value = "";
          } else {
            alert('Ошибка загрузки: ' + text);
          }
        });
    }).catch((e) => alert('Ошибка сети: ' + e));
  };
  reader.onerror = function () { alert("Ошибка чтения файла"); };
  reader.readAsDataURL(file);
}

function editMountedConfigFile(type, btn) {
  const meta = mountedConfigMeta[type];
  const row = btn.closest("." + meta.rowClass);
  if (!row) return;
  mountedConfigEditName[type] = row.dataset.file;
  const displayName = mountedConfigEditName[type].replace(meta.stripRe, "");
  const titleEl = document.getElementById(meta.editTitleId);
  if (titleEl) titleEl.textContent = displayName;
  const nameEl = document.getElementById(meta.editNameId);
  if (nameEl) { nameEl.value = displayName; nameEl.readOnly = true; }
  const tplRow = document.getElementById(meta.templateRowId);
  if (tplRow) tplRow.style.display = "none";
  fetch('/cgi-bin/read-file?file=' + encodeURIComponent(mountedConfigEditName[type]) + '&type=' + encodeURIComponent(type))
    .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
    .then((text) => {
      const plainEl = document.getElementById(meta.editPlainId);
      if (plainEl) plainEl.value = text;
      document.getElementById(meta.editModalId).hidden = false;
    })
    .catch((e) => alert('Не удалось прочитать файл: ' + e.message));
}

function createMountedConfigFile(type) {
  const meta = mountedConfigMeta[type];
  mountedConfigEditName[type] = "";
  const titleEl = document.getElementById(meta.editTitleId);
  if (titleEl) titleEl.textContent = meta.titleNew;
  const nameEl = document.getElementById(meta.editNameId);
  if (nameEl) { nameEl.value = ""; nameEl.readOnly = false; nameEl.focus(); }
  const plainEl = document.getElementById(meta.editPlainId);
  if (plainEl) plainEl.value = "";
  const tplRow = document.getElementById(meta.templateRowId);
  if (tplRow) tplRow.style.display = "";
  document.getElementById(meta.editModalId).hidden = false;
}

function closeMountedConfigModal(type) {
  const meta = mountedConfigMeta[type];
  document.getElementById(meta.editModalId).hidden = true;
  mountedConfigEditName[type] = "";
}

function loadMountedConfigTemplate(type) {
  const meta = mountedConfigMeta[type];
  const plainEl = document.getElementById(meta.editPlainId);
  if (!plainEl) return;
  if (plainEl.value.trim() && !window.confirm("Заменить текущее содержимое шаблоном?")) return;
  fetch(meta.templateUrl)
    .then((r) => { if (!r.ok) throw new Error("HTTP " + r.status); return r.text(); })
    .then((text) => { plainEl.value = text; })
    .catch((e) => alert('Не удалось загрузить шаблон: ' + e.message));
}

function saveMountedConfigModal(type) {
  const meta = mountedConfigMeta[type];
  const nameEl = document.getElementById(meta.editNameId);
  const plainEl = document.getElementById(meta.editPlainId);
  if (!plainEl || !nameEl) return;
  const name = nameEl.value.trim();
  if (!name) { alert("Укажите имя файла"); return; }
  const fileName = meta.extRe.test(name) ? name : name + meta.ext;
  const isNew = !nameEl.readOnly;
  const checkPromise = isNew
    ? fetch('/cgi-bin/list-files?type=' + encodeURIComponent(type)).then((r) => r.json()).then((data) => {
        const existing = (data && data.files) || [];
        if (existing.some((f) => f.file === fileName)) {
          throw new Error("Файл с именем " + fileName + " уже существует");
        }
      })
    : Promise.resolve();

  checkPromise
    .then(() => {
      const b64 = btoa(unescape(encodeURIComponent(plainEl.value)));
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(fileName) + '&b64=' + encodeURIComponent(b64) + '&type=' + encodeURIComponent(type)
      }).then((r) => r.text());
    })
    .then((text) => {
      if (text.trim() === "OK") {
        closeMountedConfigModal(type);
        if (isNew) {
          const size = new Blob([plainEl.value]).size;
          addMountedConfigRow(type, fileName, size);
        }
      } else {
        alert('Ошибка сохранения: ' + text);
      }
    })
    .catch((e) => alert(e.message || String(e)));
}

function deleteMountedConfigFile(type, btn) {
  const meta = mountedConfigMeta[type];
  const row = btn.closest("." + meta.rowClass);
  if (!row) return;
  const name = row.dataset.file;
  if (!window.confirm("Удалить файл " + name.replace(meta.stripRe, "") + "?")) return;
  row.remove();
  fetch('/cgi-bin/delete-file?file=' + encodeURIComponent(name) + '&type=' + encodeURIComponent(type))
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() !== "OK") {
        alert('Ошибка удаления: ' + text);
      }
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

function uploadTrustTunnelToml() { uploadMountedConfig("trusttunnel"); }
function editTrustTunnelFile(btn) { editMountedConfigFile("trusttunnel", btn); }
function createTrustTunnelFile() { createMountedConfigFile("trusttunnel"); }
function closeTrustTunnelFileModal() { closeMountedConfigModal("trusttunnel"); }
function loadTrustTunnelTemplate() { loadMountedConfigTemplate("trusttunnel"); }
function saveTrustTunnelFileModal() { saveMountedConfigModal("trusttunnel"); }
function deleteTrustTunnelFile(btn) { deleteMountedConfigFile("trusttunnel", btn); }

function uploadOpenVpnConfig() { uploadMountedConfig("openvpn"); }
function editOpenVpnFile(btn) { editMountedConfigFile("openvpn", btn); }
function createOpenVpnFile() { createMountedConfigFile("openvpn"); }
function closeOpenVpnFileModal() { closeMountedConfigModal("openvpn"); }
function loadOpenVpnTemplate() { loadMountedConfigTemplate("openvpn"); }
function saveOpenVpnFileModal() { saveMountedConfigModal("openvpn"); }
function deleteOpenVpnFile(btn) { deleteMountedConfigFile("openvpn", btn); }

// ===== /zapret-fakebin (binary upload) =====

function filterDpiList(input, listId) {
  const q = String(input.value || "").trim().toLowerCase();
  const id = listId || (input && input.dataset && input.dataset.list);
  const wrap = id ? document.getElementById(id) : null;
  if (!wrap) return;
  wrap.querySelectorAll(".mount-link").forEach((row) => {
    const name = (row.dataset.name || row.dataset.file || row.textContent || "").toLowerCase();
    if (!q || name.indexOf(q) !== -1) row.classList.remove("hidden");
    else row.classList.add("hidden");
  });
}

function addFakebinRow(name, size) {
  const wrap = document.getElementById("fakebin-list");
  if (!wrap) return;
  const empty = wrap.querySelector(".empty");
  if (empty) empty.remove();
  const div = document.createElement("div");
  div.className = "mount-link mount-link-compact fakebin-file";
  div.dataset.file = name;
  div.dataset.name = name.toLowerCase();
  const esc = escapeAttr(name);
  div.innerHTML = `<div class="mount-link-title"><span>${esc}</span><small>${size} bytes</small></div><div class="file-actions"><a href="/cgi-bin/read-file?type=fakebin&file=${encodeURIComponent(name)}" download="${esc}" title="Скачать">&#8681;</a><button type="button" onclick="deleteFakebin(this)" title="Удалить">&#10005;</button></div>`;
  wrap.appendChild(div);
}

function uploadFakebin() {
  const input = document.getElementById("fakebinUpload");
  if (!input || !input.files || !input.files.length) {
    alert("Выберите файл для загрузки");
    return;
  }
  const file = input.files[0];
  const reader = new FileReader();
  reader.onload = function () {
    // result is data URL: "data:...;base64,<b64>"
    const data = String(reader.result || "");
    const idx = data.indexOf(",");
    const b64 = idx >= 0 ? data.slice(idx + 1) : "";
    if (!b64) { alert("Не удалось прочитать файл"); return; }
    fetch('/cgi-bin/save-file', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'file=' + encodeURIComponent(file.name) + '&b64=' + encodeURIComponent(b64) + '&type=fakebin'
    })
      .then((r) => r.text())
      .then((text) => {
        if (text.trim() === "OK") {
          // Replace existing row or add new
          const wrap = document.getElementById("fakebin-list");
          const existing = wrap && wrap.querySelector('.fakebin-file[data-file="' + file.name.replace(/"/g, '\\"') + '"]');
          if (existing) existing.remove();
          addFakebinRow(file.name, file.size);
          input.value = "";
        } else {
          alert('Ошибка загрузки: ' + text);
        }
      })
      .catch((e) => alert('Ошибка сети: ' + e));
  };
  reader.onerror = function () { alert("Ошибка чтения файла"); };
  reader.readAsDataURL(file);
}

function deleteFakebin(btn) {
  const row = btn.closest(".fakebin-file");
  if (!row) return;
  const name = row.dataset.file;
  if (!window.confirm("Удалить " + name + "?")) return;
  row.remove();
  fetch('/cgi-bin/delete-file?file=' + encodeURIComponent(name) + '&type=fakebin')
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() !== "OK") alert('Ошибка удаления: ' + text);
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

// ===== /zapret-lists (text list editor) =====

let zlistEditName = "";

function addZlistRow(name, size) {
  const wrap = document.getElementById("zlist-list");
  if (!wrap) return;
  const empty = wrap.querySelector(".empty");
  if (empty) empty.remove();
  const div = document.createElement("div");
  div.className = "mount-link mount-link-compact zlist-file";
  div.dataset.file = name;
  div.dataset.name = name.toLowerCase();
  const esc = escapeAttr(name);
  div.innerHTML = `<div class="mount-link-title"><span>${esc}</span><small>${size} bytes</small></div><div class="file-actions"><button type="button" onclick="editZlistFile(this)" title="Редактировать">&#10002;</button><button type="button" onclick="deleteZlistFile(this)" title="Удалить">&#10005;</button></div>`;
  wrap.appendChild(div);
}

function editZlistFile(btn) {
  const row = btn.closest(".zlist-file");
  if (!row) return;
  zlistEditName = row.dataset.file;
  const titleEl = document.getElementById("zlistEditTitle");
  if (titleEl) titleEl.textContent = zlistEditName;
  const nameEl = document.getElementById("zlistEditName");
  if (nameEl) { nameEl.value = zlistEditName; nameEl.readOnly = true; }
  fetch('/cgi-bin/read-file?file=' + encodeURIComponent(zlistEditName) + '&type=zlist')
    .then((r) => { if (!r.ok) throw new Error(r.statusText); return r.text(); })
    .then((text) => {
      const plainEl = document.getElementById("zlistEditPlain");
      if (plainEl) plainEl.value = text;
      document.getElementById("zlistEditModal").hidden = false;
    })
    .catch((e) => alert('Не удалось прочитать файл: ' + e.message));
}

function createZlistFile() {
  zlistEditName = "";
  const titleEl = document.getElementById("zlistEditTitle");
  if (titleEl) titleEl.textContent = "Новый список";
  const nameEl = document.getElementById("zlistEditName");
  if (nameEl) { nameEl.value = ""; nameEl.readOnly = false; nameEl.focus(); }
  const plainEl = document.getElementById("zlistEditPlain");
  if (plainEl) plainEl.value = "";
  document.getElementById("zlistEditModal").hidden = false;
}

function closeZlistFileModal() {
  document.getElementById("zlistEditModal").hidden = true;
  zlistEditName = "";
}

function saveZlistFileModal() {
  const nameEl = document.getElementById("zlistEditName");
  const plainEl = document.getElementById("zlistEditPlain");
  if (!plainEl || !nameEl) return;
  const name = nameEl.value.trim();
  if (!name) { alert("Укажите имя файла"); return; }
  const isNew = !nameEl.readOnly;

  const checkPromise = isNew
    ? fetch('/cgi-bin/list-files?type=zlist').then((r) => r.json()).then((data) => {
        const existing = (data && data.files) || [];
        if (existing.some((f) => f.file === name)) {
          throw new Error("Файл с именем " + name + " уже существует");
        }
      })
    : Promise.resolve();

  checkPromise
    .then(() => {
      const b64 = btoa(unescape(encodeURIComponent(plainEl.value)));
      return fetch('/cgi-bin/save-file', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'file=' + encodeURIComponent(name) + '&b64=' + encodeURIComponent(b64) + '&type=zlist'
      }).then((r) => r.text());
    })
    .then((text) => {
      if (text.trim() === "OK") {
        closeZlistFileModal();
        if (isNew) {
          const size = new Blob([plainEl.value]).size;
          addZlistRow(name, size);
        }
      } else {
        alert('Ошибка сохранения: ' + text);
      }
    })
    .catch((e) => alert(e.message || String(e)));
}

function deleteZlistFile(btn) {
  const row = btn.closest(".zlist-file");
  if (!row) return;
  const name = row.dataset.file;
  if (!window.confirm("Удалить " + name + "?")) return;
  row.remove();
  fetch('/cgi-bin/delete-file?file=' + encodeURIComponent(name) + '&type=zlist')
    .then((r) => r.text())
    .then((text) => {
      if (text.trim() !== "OK") alert('Ошибка удаления: ' + text);
    })
    .catch((e) => alert('Ошибка сети: ' + e));
}

function enhanceIndexedRows(root) {
  (root || document).querySelectorAll(".env-row[data-index]").forEach((row) => {
    ensureIndexedRowControls(row);
    wireIndexedRow(row);
    relabelIndexedRow(row);
  });
}

function addFakeIpFilterRow(idx, value) {
  const wrap = document.getElementById("fakeFilters");
  if (!wrap) return;
  let wanted = Number(idx);
  if (!Number.isInteger(wanted) || wanted < 1) wanted = nextFreeIndex(wrap, true);
  const busy = [...wrap.querySelectorAll("[data-index]")].some((row) => Number(row.dataset.index) === wanted);
  if (busy) wanted = nextFreeIndex(wrap, true);
  const key = fakeFilterName(wanted);
  const div = document.createElement("div");
  div.className = "env-row env-row-stack fake-filter-row";
  div.dataset.index = wanted;
  div.innerHTML = `
    <label><span>${key}</span><input name="${key}" value="${escapeAttr(value)}" placeholder="DOMAIN,www.youtube.com,real-ip"></label>
    <button type="button" onclick="removeEnvRow(this)">Удалить</button>
  `;
  wrap.appendChild(div);
  wireFieldEvents(div);
  ensureIndexedRowControls(div);
  sortIndexedRows(wrap);
}

function addPair(containerId, key) {
  const custom = window.prompt("ENV name", key);
  if (!custom) return;
  const wrap = document.getElementById(containerId);
  const div = document.createElement("div");
  div.className = "env-row";
  div.innerHTML = `<label><span>${custom}</span><input name="${custom}" placeholder="значение env"></label><button type="button" onclick="removeEnvRow(this)">Удалить</button>`;
  wrap.appendChild(div);
  wireFieldEvents(div);
}

function groupEnvPrefix(name) {
  return String(name || "").trim().replace(/-/g, "_").toUpperCase().replace(/[^A-Z0-9_]/g, "_");
}

function groupListValue() {
  const el = document.querySelector('input[name="GROUP"]');
  return el ? el.value.split(",").map((x) => x.trim()).filter(Boolean) : [];
}

function setGroupListValue(names) {
  const el = document.querySelector('input[name="GROUP"]');
  if (!el) return;
  el.value = [...new Set(names.filter((name) => name && name !== "DEFAULT" && name !== "GLOBAL" && name !== "DNS"))].join(",");
  rememberField(el);
}

function groupHasCustomParams(pane) {
  const prefix = pane?.dataset?.prefix;
  if (!prefix) return false;
  return [...pane.querySelectorAll("input[name], textarea[name], select[name]")].some((el) => {
    if (!el.name || el.name === "GROUP" || el.classList.contains("group-name-input")) return false;
    if (el.name.indexOf(prefix + "_") !== 0) return false;
    const state = el.closest(".field")?.querySelector(":scope > i, .field-meta i")?.textContent.trim();
    const saved = localStorage.getItem(envKey(el.name));
    const value = saved !== null ? saved : fieldValue(el);
    if (state === "set") return true;
    return value !== "" && value !== (el.dataset.default || "");
  });
}

function ruleSetSourceDeleted(pane) {
  const sourceEnv = pane?.dataset?.sourceEnv;
  if (!sourceEnv) return false;
  return localStorage.getItem(originalKey(sourceEnv)) !== null && (localStorage.getItem(envKey(sourceEnv)) || "") === "";
}

function demoteOrPromoteRuleSetGroups() {
  const names = groupListValue();
  let changed = false;
  document.querySelectorAll('.group-pane[data-source="ruleset"]').forEach((pane) => {
    const name = pane.dataset.group;
    const button = findGroupButton(name);
    const hasCustom = groupHasCustomParams(pane);
    if (ruleSetSourceDeleted(pane) && !hasCustom) {
      pane.remove();
      if (button) button.remove();
      const next = document.querySelector(".group-list button[data-group]");
      if (next && !document.querySelector(".group-pane.active")) switchGroupPane(next.dataset.group);
      changed = true;
      return;
    }
    const listed = names.includes(name);
    if (hasCustom && !listed) {
      names.push(name);
      changed = true;
    }
    if (!hasCustom && listed) {
      const idx = names.indexOf(name);
      if (idx >= 0) names.splice(idx, 1);
      changed = true;
    }
  });
  if (changed) setGroupListValue(names);
}

function switchGroupPane(name) {
  document.querySelectorAll(".group-pane").forEach((pane) => {
    const active = pane.dataset.group === name;
    pane.hidden = !active;
    pane.classList.toggle("active", active);
  });
  document.querySelectorAll(".group-list button[data-group]").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.group === name);
  });
}

function findGroupButton(name) {
  return [...document.querySelectorAll(".group-list button[data-group]")].find((btn) => btn.dataset.group === name);
}

function groupFieldMarkup(prefix, suffix, label, hint, placeholder, type, value) {
  const name = prefix + "_" + suffix;
  return `<label class="field" data-env="${name}"><span><b>${label}</b><em>${name}</em></span><input type="${type || "text"}" name="${name}" value="${escapeAttr(value)}" placeholder="${escapeAttr(placeholder || "")}" data-default=""><small>${hint || ""}</small><i>new</i></label>`;
}

// Validated-вариант (для USE / PROXIES / EXCLUDE_TYPE — типы валидируются JS).
function groupValidatedFieldMarkup(prefix, suffix, validateKind, label, hint, placeholder) {
  const name = prefix + "_" + suffix;
  return `<label class="field field-validated" data-env="${name}" data-validate="${validateKind}"><span><b>${label}</b><em>${name}</em></span><input type="text" name="${name}" value="" placeholder="${escapeAttr(placeholder || "")}" data-default=""><small>${hint || ""}</small><i>new</i></label>`;
}

function groupTypeHint() {
  return `Тип <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#type" target="_blank" rel="noopener">proxy-groups type</a>: select/url-test/load-balance/fallback/relay.`;
}

function addGroupPane(name) {
  const clean = String(name || window.prompt("Group name", "") || "").trim();
  if (!clean) return;
  if ([...document.querySelectorAll(".group-pane")].some((pane) => pane.dataset.group === clean)) {
    switchGroupPane(clean);
    return;
  }
  const prefix = groupEnvPrefix(clean);
  const list = document.getElementById("groupList");
  const panes = document.getElementById("groupPanes");
  if (!list || !panes) return;
  setGroupListValue([...groupListValue(), clean]);
  const btn = document.createElement("button");
  btn.type = "button";
  btn.dataset.group = clean;
  btn.onclick = () => switchGroupPane(clean);
  btn.innerHTML = `<b>${escapeAttr(clean)}</b><small>${prefix}_*</small>`;
  list.insertBefore(btn, list.querySelector(".add-group-btn"));
  const pane = document.createElement("article");
  pane.className = "group-pane";
  pane.dataset.group = clean;
  pane.dataset.prefix = prefix;
  pane.hidden = true;
  pane.innerHTML = `
    <div class="group-pane-head">
      <button class="group-delete" type="button" onclick="removeGroupPane(this.closest('.group-pane').dataset.group)">Удалить группу</button>
      <label class="field"><span><b>Group name</b><em>GROUP</em></span><input class="group-name-input" value="${escapeAttr(clean)}" data-original="${escapeAttr(clean)}"><small>Имя группы и prefix env.</small><i>${prefix}</i></label>
    </div>
    <div class="grid">
      ${groupValidatedFieldMarkup(prefix, "PROXIES", "proxies", "Proxies", `Явные <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#proxies" target="_blank" rel="noopener">proxies</a> через запятую: имена других прокси-групп (регистрозависимо) либо служебные <code>DIRECT</code>, <code>REJECT</code>, <code>REJECT-DROP</code>, <code>PASS</code>.`, "DIRECT,REJECT,YOUTUBE")}
      ${groupValidatedFieldMarkup(prefix, "USE", "use", "Use", `Список <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#use" target="_blank" rel="noopener">providers</a> через запятую или <code>none</code>. Регистрозависимо.`, "LINK1,SUB_LINK1,BYEDPI")}
      <label class="field" data-env="${prefix}_TYPE"><span><b>Type</b><em>${prefix}_TYPE</em></span><select name="${prefix}_TYPE" data-default="select"><option value="select">select</option><option value="url-test">url-test</option><option value="load-balance">load-balance</option><option value="fallback">fallback</option><option value="relay">relay</option></select><small>${groupTypeHint()}</small><i>new</i></label>
      ${groupFieldMarkup(prefix, "INTERVAL", "Interval", `<a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#interval" target="_blank" rel="noopener">Интервал</a> проверки в секундах. Пусто → наследует <code>GROUP_INTERVAL</code>.`, "", "number", "")}
      ${groupFieldMarkup(prefix, "URL", "URL", `URL <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#url" target="_blank" rel="noopener">health-check</a>. Пусто → наследует <code>GROUP_URL</code>.`, "", "text", "")}
      ${groupFieldMarkup(prefix, "URL_STATUS", "URL status", `Ожидаемый <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#expected-status" target="_blank" rel="noopener">expected-status</a>. Пусто → наследует <code>GROUP_URL_STATUS</code>.`, "", "number", "")}
      <label class="field" data-env="${prefix}_STRATEGY"><span><b>Strategy</b><em>${prefix}_STRATEGY</em></span><select name="${prefix}_STRATEGY" data-default=""><option value="" selected>— inherit GROUP_STRATEGY —</option><option value="round-robin">round-robin</option><option value="consistent-hashing">consistent-hashing</option><option value="sticky-sessions">sticky-sessions</option></select><small><a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/load-balance/#strategy" target="_blank" rel="noopener">Стратегия</a> для load-balance. Пусто → наследует <code>GROUP_STRATEGY</code>.</small><i>new</i></label>
      ${groupFieldMarkup(prefix, "TOLERANCE", "Tolerance", `<a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/url-test/#tolerance" target="_blank" rel="noopener">Tolerance</a> для url-test в мс. Пусто → наследует <code>GROUP_TOLERANCE</code>.`, "", "number", "")}
      ${groupFieldMarkup(prefix, "FILTER", "Filter", `Regex <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#filter" target="_blank" rel="noopener">filter</a> по именам прокси.`, "", "text", "")}
      ${groupFieldMarkup(prefix, "EXCLUDE", "Exclude", `Regex <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-filter" target="_blank" rel="noopener">exclude-filter</a>.`, "", "text", "")}
      ${groupValidatedFieldMarkup(prefix, "EXCLUDE_TYPE", "exclude_type", "Exclude type", `<a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#exclude-type" target="_blank" rel="noopener">exclude-type</a> — исключить прокси указанных типов, разделитель <code>|</code>. <a class="doc-link" href="https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45" target="_blank" rel="noopener">Adapter Type</a>, регистр не важен.`, "vmess|direct")}
      ${groupFieldMarkup(prefix, "ICON", "Icon", `URL <a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#icon" target="_blank" rel="noopener">иконки</a> группы.`, "", "text", "")}
      <label class="field" data-env="${prefix}_HIDDEN"><span><b>Hidden</b><em>${prefix}_HIDDEN</em></span><select name="${prefix}_HIDDEN" data-default=""><option value="" selected>— показать (default) —</option><option value="true">true (скрыть из веб-панели)</option><option value="false">false (показать)</option></select><small><a class="doc-link" href="https://wiki.metacubex.one/ru/config/proxy-groups/#hidden" target="_blank" rel="noopener">hidden</a> — скрыть/показать группу в веб-панели mihomo.</small><i>new</i></label>
      ${groupFieldMarkup(prefix, "GEOSITE", "Geosite", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">GEOSITE</a> списком через запятую.`, "youtube,category-ru", "text", "")}
      ${groupFieldMarkup(prefix, "GEOIP", "Geoip", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">GEOIP</a> списком через запятую.`, "telegram,discord", "text", "")}
      ${groupFieldMarkup(prefix, "AS", "ASN", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">IP-ASN</a>: AS123,AS456.`, "AS15169", "text", "")}
      ${groupFieldMarkup(prefix, "PRIORITY", "Priority", "Чем меньше, тем выше в rules.", "", "number", "")}
      ${groupFieldMarkup(prefix, "DOMAIN", "Domain", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">DOMAIN</a> через запятую.`, "example.com", "text", "")}
      ${groupFieldMarkup(prefix, "SUFFIX", "Suffix", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">DOMAIN-SUFFIX</a> через запятую.`, "example.com", "text", "")}
      ${groupFieldMarkup(prefix, "KEYWORD", "Keyword", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">DOMAIN-KEYWORD</a> через запятую.`, "google", "text", "")}
      ${groupFieldMarkup(prefix, "IPCIDR", "IP CIDR", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">IP-CIDR</a> через запятую.`, "1.1.1.0/24", "text", "")}
      ${groupFieldMarkup(prefix, "SRCIPCIDR", "Source CIDR", `Правила <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">SRC-IP-CIDR</a> через запятую.`, "192.168.88.0/24", "text", "")}
      ${groupFieldMarkup(prefix, "DSCP", "DSCP", `Правило <a class="doc-link" href="https://wiki.metacubex.one/ru/config/rules/" target="_blank" rel="noopener">DSCP</a> для отдельного входа.`, "", "number", "")}
      ${groupFieldMarkup(prefix, "DNS", "DNS policy", "DNS resolver для rule-set этой группы.", "https://dns.google/dns-query", "text", "")}
    </div>`;
  panes.appendChild(pane);
  wireFieldEvents(pane);
  wireGroupRename(pane);
  wirePaneValidators(pane);
  switchGroupPane(clean);
  // Новая группа сразу должна засветиться в бейджах (модификация GROUP env
  // + добавленные originals). rememberField в setGroupListValue пишет в
  // localStorage без input-события, поэтому form-bubble listener мимо.
  if (typeof refreshAllBadges === "function") refreshAllBadges();
}

// Подцепляет валидаторы (use / proxies / exclude_type) к динамически созданной
// панели — initFieldValidators при загрузке страницы трогает только серверные
// поля, новые группы создаются позже.
function wirePaneValidators(pane) {
  const fns = {
    use: validateUseInput,
    proxies: validateProxiesInput,
    exclude_type: validateExcludeTypeInput,
    proxy_name: validateProxyNameInput,
  };
  pane.querySelectorAll(".field-validated").forEach((box) => {
    const kind = box.dataset.validate;
    const fn = fns[kind];
    if (!fn) return;
    const input = box.querySelector("input, textarea");
    if (!input || input.dataset.validatorWired === "true") return;
    input.dataset.validatorWired = "true";
    const run = () => fn(input);
    input.addEventListener("input", run);
    input.addEventListener("change", run);
    run();
  });
}

function removeGroupPane(name) {
  if (!name || name === "DEFAULT" || name === "GLOBAL" || name === "DNS") return;
  const pane = [...document.querySelectorAll(".group-pane")].find((item) => item.dataset.group === name);
  const btn = findGroupButton(name);
  if (!pane || !btn) return;
  pane.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
    if (localStorage.getItem(originalKey(el.name)) === null) {
      localStorage.setItem(originalKey(el.name), fieldValue(el));
    }
    localStorage.setItem(envKey(el.name), "");
    trackRemovedEnv(el.name);
  });
  setGroupListValue(groupListValue().filter((item) => item !== name));
  pane.remove();
  btn.remove();
  const first = document.querySelector(".group-list button[data-group]");
  if (first) switchGroupPane(first.dataset.group);
  draftSaveDebounced();
}

function wireGroupRename(pane) {
  const input = pane.querySelector(".group-name-input");
  if (!input || input.dataset.wired === "true" || input.readOnly) return;
  input.dataset.wired = "true";
  input.addEventListener("change", () => {
    const oldName = pane.dataset.group;
    const newName = input.value.trim();
    if (!newName || newName === oldName) {
      input.value = oldName;
      return;
    }
    const oldPrefix = pane.dataset.prefix;
    const newPrefix = groupEnvPrefix(newName);
    pane.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
      if (!el.name || el.name === "GROUP" || el.name.indexOf(oldPrefix + "_") !== 0) return;
      const oldEnv = el.name;
      const newEnv = newPrefix + el.name.slice(oldPrefix.length);
      localStorage.setItem(envKey(oldEnv), "");
      trackRemovedEnv(oldEnv);
      if (localStorage.getItem(originalKey(newEnv)) === null) localStorage.setItem(originalKey(newEnv), "");
      el.name = newEnv;
      const caption = el.closest("label")?.querySelector("em");
      if (caption) caption.textContent = newEnv;
      rememberField(el);
    });
    pane.dataset.group = newName;
    pane.dataset.prefix = newPrefix;
    input.dataset.original = newName;
    const state = input.closest(".field")?.querySelector("i");
    if (state) state.textContent = newPrefix;
    const btn = findGroupButton(oldName);
    if (btn) {
      btn.dataset.group = newName;
      btn.innerHTML = `<b>${escapeAttr(newName)}</b><small>${newPrefix}_*</small>`;
      btn.onclick = () => switchGroupPane(newName);
    }
    setGroupListValue(groupListValue().map((item) => item === oldName ? newName : item));
    switchGroupPane(newName);
  });
}

function initGroupEditor() {
  document.querySelectorAll(".group-pane").forEach(wireGroupRename);
  // Восстановление групп, существующих только в draft'е GROUP: сервер их
  // не рендерит до Применить, но в localStorage GROUP=... уже содержит имя,
  // плюс могут быть драфты <prefix>_USE/_PROXIES/... — без этого блока
  // новая группа исчезает из колонки при переходе на другую страницу и обратно.
  restoreDraftGroups();
  demoteOrPromoteRuleSetGroups();
  document.querySelectorAll('.group-pane[data-source="ruleset"] input[name], .group-pane[data-source="ruleset"] textarea[name], .group-pane[data-source="ruleset"] select[name]').forEach((el) => {
    el.addEventListener("input", demoteOrPromoteRuleSetGroups);
    el.addEventListener("change", demoteOrPromoteRuleSetGroups);
  });
  const first = document.querySelector(".group-list button[data-group]");
  if (first) switchGroupPane(first.dataset.group);
}

function restoreDraftGroups() {
  if (!document.getElementById("groupPanes")) return;
  const existing = new Set([...document.querySelectorAll(".group-pane")].map((p) => p.dataset.group));
  // groupListValue читает текущее значение input[name=GROUP] — wireFieldEvents
  // уже применил draft из localStorage к этому полю на момент initGroupEditor.
  groupListValue().forEach((name) => {
    if (!name || existing.has(name)) return;
    if (name === "DEFAULT" || name === "GLOBAL" || name === "DNS") return;
    addGroupPane(name);
  });
}

function addDnsPolicyRow(match, server, params) {
  const rows = document.getElementById("dnsPolicyRows");
  if (!rows) return;
  const div = document.createElement("div");
  div.className = "dns-policy-grid dns-policy-row";
  div.innerHTML = `
    <input class="dns-policy-match" value="${match || ""}" placeholder="+.example.com или rule-set:name">
    <input class="dns-policy-server" value="${server || ""}" placeholder="https://dns.quad9.net/dns-query">
    <input class="dns-policy-params" value="${params || ""}" placeholder="disable-ipv6=true&disable-qtype-65=true">
    <button type="button" onclick="removeDnsPolicyRow(this)">Удалить</button>
  `;
  rows.appendChild(div);
  div.querySelectorAll("input").forEach((input) => input.addEventListener("input", syncDnsPolicy));
  syncDnsPolicy();
}

function splitHeaderItem(raw) {
  const pos = String(raw || "").indexOf("=");
  if (pos < 0) return {key: raw || "", value: ""};
  return {key: raw.slice(0, pos), value: raw.slice(pos + 1)};
}

function addHeadersRow(editor, key, value) {
  const row = document.createElement("div");
  row.className = "headers-row";
  row.innerHTML = `<input class="headers-key" value="${escapeAttr(key)}" placeholder="Header"><input class="headers-value" value="${escapeAttr(value)}" placeholder="value"><button type="button">Удалить</button>`;
  editor.querySelector(".headers-rows").appendChild(row);
  row.querySelectorAll("input").forEach((input) => input.addEventListener("input", () => syncHeadersEditor(editor)));
  row.querySelector("button").addEventListener("click", () => {
    row.remove();
    syncHeadersEditor(editor);
  });
}

function syncHeadersEditor(editor) {
  const hidden = editor.querySelector("input.sub-link-headers-value");
  const items = [];
  editor.querySelectorAll(".headers-row").forEach((row) => {
    const key = row.querySelector(".headers-key").value.trim();
    const value = row.querySelector(".headers-value").value.trim();
    if (key) items.push(key + "=" + value);
  });
  hidden.value = items.join("#");
  rememberField(hidden);
}

function initHeadersEditors(root) {
  (root || document).querySelectorAll(".headers-editor").forEach((editor) => {
    if (editor.dataset.wired === "true") return;
    editor.dataset.wired = "true";
    const hidden = editor.querySelector("input.sub-link-headers-value");
    const current = hidden.value.trim();
    if (current) {
      current.split("#").forEach((item) => {
        const pair = splitHeaderItem(item);
        addHeadersRow(editor, pair.key, pair.value);
      });
    }
    editor.querySelector(".headers-add").addEventListener("click", () => addHeadersRow(editor, "", ""));
    if (!current) addHeadersRow(editor, "", "");
  });
}

function splitEndpointItem(raw) {
  const text = String(raw || "").trim();
  const pos = text.lastIndexOf(":");
  if (pos < 0) return {host: text, port: ""};
  return {host: text.slice(0, pos), port: text.slice(pos + 1)};
}

function addWgEndpointRow(editor, host, port) {
  const row = document.createElement("div");
  row.className = "wg-endpoint-row";
  row.innerHTML = `<input class="wg-host" value="${escapeAttr(host)}" placeholder="example.com"><input class="wg-port" value="${escapeAttr(port)}" placeholder="51820"><button type="button">Удалить</button>`;
  editor.querySelector(".wg-endpoint-rows").appendChild(row);
  row.querySelectorAll("input").forEach((input) => input.addEventListener("input", () => syncWgDst(editor)));
  row.querySelector("button").addEventListener("click", () => {
    row.remove();
    syncWgDst(editor);
  });
}

function syncWgDst(scope) {
  const editors = scope && scope.classList && scope.classList.contains("wg-endpoint-editor") ? [scope] : [...document.querySelectorAll(".wg-endpoint-editor")];
  editors.forEach((editor) => {
    const hidden = editor.querySelector('input[name="ZAPRET2_WG_DST"]');
    if (!hidden) return;
    const items = [...editor.querySelectorAll(".wg-endpoint-row")].map((row) => {
      const host = row.querySelector(".wg-host").value.trim();
      const port = row.querySelector(".wg-port").value.trim();
      if (!host || !port) return "";
      return host + ":" + port;
    }).filter(Boolean);
    hidden.value = items.join(",");
    rememberField(hidden);
  });
}

function initWgEndpointEditors(root) {
  (root || document).querySelectorAll(".wg-endpoint-editor").forEach((editor) => {
    if (editor.dataset.wired === "true") return;
    editor.dataset.wired = "true";
    const hidden = editor.querySelector('input[name="ZAPRET2_WG_DST"]');
    const rows = editor.querySelector(".wg-endpoint-rows");
    const current = hidden.value.trim();
    if (current) current.split(",").map(splitEndpointItem).forEach((item) => addWgEndpointRow(editor, item.host, item.port));
    if (!rows.children.length) addWgEndpointRow(editor, "", "");
    editor.querySelector(".wg-endpoint-add").addEventListener("click", () => {
      addWgEndpointRow(editor, "", "");
      syncWgDst(editor);
    });
    syncWgDst(editor);
  });
}

function previewEnvMap() {
  const map = new Map();
  const raw = document.getElementById("rulesPreviewEnv")?.value || "";
  raw.split(/\n/).forEach((line) => {
    const pos = line.indexOf("=");
    if (pos > 0) map.set(line.slice(0, pos), line.slice(pos + 1));
  });
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key && key.startsWith("mihomo-env:")) map.set(key.slice("mihomo-env:".length), localStorage.getItem(key) || "");
  }
  document.querySelectorAll("#envForm input[name], #envForm textarea[name], #envForm select[name]").forEach((el) => map.set(el.name, fieldValue(el)));
  return map;
}

function splitList(value) {
  return String(value || "").split(/[,\s]+/).map((x) => x.trim()).filter(Boolean);
}

function previewRuleSetSources(env) {
  const sources = [];
  [...env.keys()].filter((name) => /^RULE_SET[0-9]+_BASE64$/.test(name)).sort((a, b) => Number(a.match(/\d+/)[0]) - Number(b.match(/\d+/)[0])).forEach((key) => {
    const value = env.get(key) || "";
    const hash = value.indexOf("#");
    if (hash < 0) return;
    const name = value.slice(hash + 1).trim().replace(/[^a-zA-Z0-9_-]/g, "");
    if (name) sources.push({name, source: key});
  });
  (document.getElementById("rulesPreviewMounts")?.value || "").split(/\n/).map((x) => x.trim()).filter(Boolean).forEach((name) => sources.push({name, source: "mount"}));
  const seen = new Set();
  return sources.filter((item) => {
    if (seen.has(item.name)) return false;
    seen.add(item.name);
    return true;
  });
}

function buildPreviewRules() {
  const env = previewEnvMap();
  const rules = [{prio: -1, origin: "generated", detail: "fixed", rule: "RULE-SET,DNS_ruleset,DNS", editable: false}];
  [...env.keys()].filter((name) => /^RULES[0-9]+$/.test(name)).sort((a, b) => Number(a.slice(5)) - Number(b.slice(5))).forEach((name) => {
    const prio = Number(name.slice(5));
    const value = env.get(name) || "";
    const parts = value.split(";").map((x) => x.trim()).filter(Boolean);
    parts.forEach((rule) => rules.push({prio, origin: name, detail: "editable", rule, editable: true}));
  });
  const groupNames = splitList(env.get("GROUP"));
  let groupIdx = 0;
  groupNames.forEach((group) => {
    const prefix = groupEnvPrefix(group);
    const resources = ["GEOSITE", "GEOIP", "AS", "DOMAIN", "SUFFIX", "IPCIDR", "KEYWORD", "SRCIPCIDR", "DSCP"];
    const hasResource = resources.some((suffix) => (env.get(prefix + "_" + suffix) || "").trim() !== "");
    const hasUse = (env.get(prefix + "_USE") || "").trim() !== "";
    if (!hasResource && !hasUse) return;
    const prioRaw = (env.get(prefix + "_PRIORITY") || "").trim();
    const prio = prioRaw !== "" && Number.isFinite(Number(prioRaw)) ? Number(prioRaw) : 1000 + groupIdx;
    splitList(env.get(prefix + "_GEOSITE")).forEach((item) => rules.push({prio, origin: prefix + "_GEOSITE", detail: group, rule: `RULE-SET,${group}_geosite_${item},${group}`}));
    splitList(env.get(prefix + "_GEOIP")).forEach((item) => {
      const rs = `${group}_geoip_${item}`;
      const rule = item === "discord" ? `AND,((RULE-SET,${rs}),(NETWORK,UDP),(DST-PORT,19294-19344/50000-50100)),${group}` : `RULE-SET,${rs},${group}`;
      rules.push({prio, origin: prefix + "_GEOIP", detail: group, rule});
    });
    splitList(env.get(prefix + "_AS")).forEach((item) => {
      if (!/^AS/i.test(item)) return;
      rules.push({prio, origin: prefix + "_AS", detail: group, rule: `RULE-SET,${group}_as_${item},${group}`});
    });
    const custom = ["DOMAIN", "SUFFIX", "KEYWORD", "IPCIDR", "SRCIPCIDR"].some((suffix) => splitList(env.get(prefix + "_" + suffix)).length > 0);
    if (custom) rules.push({prio, origin: prefix + "_CUSTOM", detail: group, rule: `RULE-SET,${group}_custom_rules,${group}`});
    const dscp = (env.get(prefix + "_DSCP") || "").trim();
    if (dscp) {
      rules.push({prio, origin: prefix + "_DSCP", detail: group, rule: `DSCP,${dscp},${group}`});
      rules.push({prio, origin: prefix + "_DSCP", detail: group, rule: `IN-NAME,redir-in-dscp-${dscp},${group}`});
    }
    groupIdx += 1;
  });
  previewRuleSetSources(env).forEach((item, idx) => {
    const prefix = groupEnvPrefix(item.name);
    const prioRaw = (env.get(prefix + "_PRIORITY") || "").trim();
    const prio = prioRaw !== "" && Number.isFinite(Number(prioRaw)) ? Number(prioRaw) : 2000 + idx;
    rules.push({prio, origin: item.source, detail: item.name, rule: `RULE-SET,${item.name}_ruleset,${item.name}`});
  });
  rules.push({prio: 900000, origin: "generated", detail: "fixed", rule: "IN-NAME,redir-in,GLOBAL"});
  rules.push({prio: 900001, origin: "generated", detail: "fixed", rule: "IN-NAME,tun-in,GLOBAL"});
  rules.push({prio: 900002, origin: "generated", detail: "fixed", rule: "IN-NAME,mixed-in,GLOBAL"});
  rules.push({prio: 900003, origin: "generated", detail: "fixed", rule: "MATCH,DIRECT"});
  return rules.sort((a, b) => a.prio - b.prio);
}

function renderRulesPreview() {
  const wrap = document.getElementById("finalRulesPreview");
  if (!wrap) return;
  wrap.innerHTML = "";
  buildPreviewRules().forEach((item, index) => {
    const row = document.createElement("div");
    row.className = item.editable ? "final-rule-row editable-rule-row" : "final-rule-row readonly-rule-row";
    row.innerHTML = `
      <label class="env-index"><input type="number" value="${index + 1}" readonly></label>
      <span class="rule-origin"><b>${escapeAttr(item.origin)}</b><small>priority: ${escapeAttr(item.prio)}</small><small>${escapeAttr(item.detail || "")}</small></span>
      <input type="text" value="${escapeAttr(item.rule)}" readonly>
    `;
    wrap.appendChild(row);
  });
}

function addPreviewRule() {
  addRow("rules", "RULES", true);
}

function removeDnsPolicyRow(btn) {
  const row = btn.closest(".dns-policy-row");
  if (row) row.remove();
  syncDnsPolicy();
}

function syncDnsPolicy() {
  const hidden = document.getElementById("nameserverPolicyValue");
  const rows = document.querySelectorAll(".dns-policy-row");
  if (!hidden) return;
  const items = [];
  rows.forEach((row) => {
    const match = row.querySelector(".dns-policy-match")?.value.trim() || "";
    const server = row.querySelector(".dns-policy-server")?.value.trim() || "";
    const params = row.querySelector(".dns-policy-params")?.value.trim() || "";
    if (!match || !server) return;
    items.push(match + "#" + server + (params ? "#" + params : ""));
  });
  hidden.value = items.join(",");
  rememberField(hidden);
}

function trackRemovedEnv(name) {
  if (!name) return;
  const form = document.getElementById("envForm");
  if (!form || [...form.querySelectorAll("input[data-removed-env]")].some((el) => el.dataset.removedEnv === name)) return;
  const hidden = document.createElement("input");
  hidden.type = "hidden";
  hidden.name = name;
  hidden.value = "";
  hidden.dataset.removedEnv = name;
  form.appendChild(hidden);
}

function removeEnvRow(btn) {
  const row = btn.closest(".env-row");
  if (!row) return;
  row.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
    const wasOnServer = (localStorage.getItem(originalKey(el.name)) || "") !== "";
    if (wasOnServer) {
      localStorage.setItem(envKey(el.name), "");
      trackRemovedEnv(el.name);
    } else {
      // Pure draft — purge from localStorage instead of leaving an empty
      // record that would later look "modified to empty" or trigger a
      // spurious /container/envs/remove.
      localStorage.removeItem(envKey(el.name));
      localStorage.removeItem(originalKey(el.name));
      localStorage.removeItem(pageKey(el.name));
    }
  });
  row.remove();
  if (document.getElementById("finalRulesPreview")) renderRulesPreview();
  // Badges + pending-removals panel need an explicit refresh: removing a row
  // doesn't trigger any input/change event that the form's bubble listener
  // would catch, so without this call the modified-count chip and the
  // "будут удалены" banner stay stale until the user touches another field
  // or navigates away and back.
  if (typeof refreshAllBadges === "function") refreshAllBadges();
  // Аналогично draftSaveDebounced — программное удаление не триггерит
  // input/change, без этого сервер-side draft не узнает о удалении и
  // следующий browser-restart с очищенной localStorage воскресит строку.
  draftSaveDebounced();
}

function switchYaml(name) {
  document.querySelectorAll(".yaml-file").forEach((el) => {
    el.hidden = el.dataset.name !== name;
    el.classList.toggle("active", el.dataset.name === name);
  });
  document.querySelectorAll(".file-list button").forEach((el) => el.classList.toggle("active", el.dataset.name === name));
  if (name && location.hash.slice(1) !== encodeURIComponent(name)) {
    history.replaceState(null, "", "#" + encodeURIComponent(name));
  }
}

let activeYamlPre = null;

function copyActiveYaml(btn) {
  const active = document.querySelector(".yaml-file.active pre");
  if (!active) return;
  const text = active.textContent || "";
  const finish = () => {
    if (!btn) return;
    const oldText = btn.textContent;
    btn.textContent = "Скопировано";
    btn.classList.add("copied");
    setTimeout(() => {
      btn.textContent = oldText;
      btn.classList.remove("copied");
    }, 1800);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(finish).catch(() => {
      const area = document.createElement("textarea");
      area.value = text;
      area.style.cssText = "position:fixed;left:-9999px";
      document.body.appendChild(area);
      area.focus();
      area.select();
      document.execCommand("copy");
      document.body.removeChild(area);
      finish();
    });
  } else {
    const area = document.createElement("textarea");
    area.value = text;
    area.style.cssText = "position:fixed;left:-9999px";
    document.body.appendChild(area);
    area.focus();
    area.select();
    document.execCommand("copy");
    document.body.removeChild(area);
    finish();
  }
}

function selectPreText(pre) {
  const range = document.createRange();
  range.selectNodeContents(pre);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

document.addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey) || event.key.toLowerCase() !== "a") return;
  const targetPre = event.target && event.target.closest ? event.target.closest(".yaml-file.active pre") : null;
  const pre = targetPre || activeYamlPre;
  if (!pre || !pre.closest(".yaml-file.active")) return;
  event.preventDefault();
  selectPreText(pre);
});

document.addEventListener("pointerdown", (event) => {
  const pre = event.target && event.target.closest ? event.target.closest(".yaml-file.active pre") : null;
  if (pre) activeYamlPre = pre;
});

// ===== SOCKS5 provider editor (Providers → SOCKS* tab) =====
// Each SOCKS<N>= env is a single '#'-separated key=value string. The visible
// editor breaks it into named sub-fields; on every input we rebuild the
// hidden ENV value.

function socksRowReadSubfields(row) {
  const get = (sel) => row.querySelector(sel);
  const trim = (v) => (v == null ? "" : String(v).trim());
  return {
    server:   trim(get(".socks-server")?.value),
    port:     trim(get(".socks-port")?.value),
    username: trim(get(".socks-username")?.value),
    password: trim(get(".socks-password")?.value),
    fingerprint: trim(get(".socks-fingerprint")?.value),
    "ip-version": trim(get(".socks-ip-version")?.value),
    tls: get(".socks-tls")?.checked ? "true" : "",
    "skip-cert-verify": get(".socks-skip-cert-verify")?.checked ? "true" : "",
    // udp defaults to true in entrypoint, so we emit explicit false only.
    udp: get(".socks-udp")?.checked ? "" : "false",
  };
}

function syncSocksRow(row) {
  if (!row) return;
  const hidden = row.querySelector('input[type="hidden"]');
  if (!hidden) return;
  const vals = socksRowReadSubfields(row);
  // Keep deterministic order matching entrypoint expectations:
  const order = ["server", "port", "username", "password", "tls", "fingerprint", "skip-cert-verify", "udp", "ip-version"];
  const parts = [];
  order.forEach((k) => {
    const v = vals[k];
    if (v !== "" && v !== undefined && v !== null) parts.push(k + "=" + v);
  });
  hidden.value = parts.join("#");
  // Bubble to localStorage / draft system + badges.
  rememberField(hidden);
  refreshAllBadges();
}

function wireSocksRow(row) {
  row.querySelectorAll("input, select").forEach((el) => {
    if (el.type === "hidden") return;
    el.addEventListener("input",  () => syncSocksRow(row));
    el.addEventListener("change", () => syncSocksRow(row));
  });
}

function socksTitleEl(row) {
  return row.querySelector(".socks-title");
}

function addSocksRow() {
  const wrap = document.getElementById("socksRows");
  if (!wrap) return;
  const usedIdx = new Set();
  wrap.querySelectorAll(".socks-row").forEach((r) => {
    const i = parseInt(r.dataset.index || "-1", 10);
    if (!isNaN(i)) usedIdx.add(i);
  });
  let idx = 0;
  while (usedIdx.has(idx)) idx += 1;
  const name = "SOCKS" + idx;
  const div = document.createElement("div");
  div.className = "env-row socks-row";
  div.dataset.index = String(idx);
  div.dataset.maxIndex = "99";
  div.innerHTML = `
    <input type="hidden" name="${name}" value="" data-default="" data-base="SOCKS">
    <div class="socks-content">
      <b class="socks-title">${name}</b>
      <div class="socks-grid">
        <label><span>server *</span><input class="socks-server" placeholder="1.2.3.4 / host"></label>
        <label><span>port *</span><input class="socks-port" type="number" placeholder="1080"></label>
        <label><span>username</span><input class="socks-username"></label>
        <label><span>password</span><input class="socks-password"></label>
        <label><span>fingerprint</span><input class="socks-fingerprint" placeholder="chrome / firefox / …"></label>
        <label><span>ip-version</span>
          <select class="socks-ip-version">
            <option value="" selected>— (default ipv4) —</option>
            <option value="ipv4">ipv4</option>
            <option value="ipv6">ipv6</option>
            <option value="dual">dual</option>
            <option value="ipv4-prefer">ipv4-prefer</option>
            <option value="ipv6-prefer">ipv6-prefer</option>
          </select>
        </label>
      </div>
      <div class="socks-toggles">
        <label class="socks-toggle"><input type="checkbox" class="socks-tls"><span>tls</span></label>
        <label class="socks-toggle"><input type="checkbox" class="socks-skip-cert-verify"><span>skip-cert-verify</span></label>
        <label class="socks-toggle"><input type="checkbox" class="socks-udp" checked><span>udp</span></label>
      </div>
    </div>
    <button type="button" onclick="removeSocksRow(this)">Удалить</button>
  `;
  wrap.appendChild(div);
  // New SOCKS row is a draft, not from server.
  div.querySelectorAll("input[name], textarea[name], select[name]").forEach((el) => {
    el.dataset.fromDraft = "true";
  });
  // Re-use existing indexed-row machinery (grip + index input + drag).
  if (typeof ensureIndexedRowControls === "function") ensureIndexedRowControls(div);
  if (typeof initDragAndDrop === "function") initDragAndDrop(wrap);
  wireSocksRow(div);
  syncSocksRow(div);
  sortIndexedRows(wrap);
  if (typeof refreshAllBadges === "function") refreshAllBadges();
}

function removeSocksRow(btn) {
  const row = btn.closest(".socks-row");
  if (!row) return;
  const hidden = row.querySelector('input[type="hidden"]');
  if (hidden && hidden.name) {
    try { localStorage.setItem(envKey(hidden.name), ""); } catch (e) {}
  }
  row.remove();
  refreshAllBadges();
}

function initSocksEditor() {
  const wrap = document.getElementById("socksRows");
  if (!wrap) return;
  wrap.querySelectorAll(".socks-row").forEach((row) => wireSocksRow(row));
  // Keep title <b> in sync with the index input from indexed-row machinery.
  wrap.addEventListener("input", (e) => {
    if (!e.target.matches(".env-index input")) return;
    const row = e.target.closest(".socks-row");
    if (!row) return;
    const hidden = row.querySelector('input[type="hidden"]');
    const title = socksTitleEl(row);
    if (hidden && title) title.textContent = hidden.name;
  });
}

// ===== Validation for *_USE and *_PROXIES inputs (proxy groups page) =====

function readKnownProvidersSeed() {
  const el = document.getElementById("known-providers-seed");
  if (!el) return { awg: [], mounted: [] };
  try { return JSON.parse(el.textContent || "{}"); }
  catch (e) { return { awg: [], mounted: [] }; }
}

function knownProviders() {
  const set = new Set();
  const seed = readKnownProvidersSeed();
  (seed.awg || []).forEach((n) => set.add(n));
  (seed.mounted || []).forEach((n) => set.add(n));
  // `envs` is the server-emitted snapshot of LINK*/SUB_LINK*/SOCKS*/DPI names
  // (see groups_page in cgi-bin/index.sh). Without it the validator could only
  // see ENV names that already had localStorage drafts — i.e. ones the user
  // had visited at least once.
  (seed.envs || []).forEach((n) => set.add(n));
  // Dynamic providers derived from currently-set ENVs (LINK/SUB_LINK/SOCKS
  // and DPI variants). Read from localStorage so this works cross-page.
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key || !key.startsWith("mihomo-env:")) continue;
    const name = key.slice("mihomo-env:".length);
    const val = (localStorage.getItem(key) || "").trim();
    if (!val) continue;
    let m;
    if (/^LINK\d*$/.test(name) || /^SUB_LINK\d+$/.test(name) || /^SOCKS\d+$/.test(name)) {
      set.add(name);
    } else if ((m = name.match(/^BYEDPI_CMD(\d*)$/))) {
      set.add(m[1] ? "BYEDPI_" + m[1] : "BYEDPI");
    } else if ((m = name.match(/^ZAPRET_CMD(\d*)$/))) {
      set.add(m[1] ? "ZAPRET_" + m[1] : "ZAPRET");
    } else if ((m = name.match(/^ZAPRET2_CMD(\d*)$/))) {
      set.add(m[1] ? "ZAPRET2_" + m[1] : "ZAPRET2");
    }
  }
  return set;
}

function knownGroups() {
  // Group names case-sensitive: validator matches exactly what user typed
  // in GROUP env. Hard-coded system groups are uppercase by entrypoint
  // contract — they're always referenced as DEFAULT/GLOBAL/DNS.
  const set = new Set(["DEFAULT", "GLOBAL", "DNS"]);
  const env = localStorage.getItem("mihomo-env:GROUP") || "";
  env.split(",").forEach((g) => {
    const t = g.trim();
    if (t) set.add(t);
  });
  document.querySelectorAll('.group-pane[data-source="ruleset"]').forEach((p) => {
    if (p.dataset.group) set.add(p.dataset.group);
  });
  return set;
}

const PROXIES_SPECIALS = new Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS"]);

// Adapter Type из mihomo/constant/adapters.go (Direct..Ssh).
// Сравнение регистронезависимое — храним lower-case.
// https://github.com/MetaCubeX/mihomo/blob/fbead56ec97ae93f904f4476df1741af718c9c2a/constant/adapters.go#L18-L45
const EXCLUDE_TYPE_VALUES = new Set([
  "direct", "reject", "rejectdrop", "compatible", "pass", "dns",
  "relay", "selector", "fallback", "urltest", "loadbalance",
  "shadowsocks", "shadowsocksr", "snell", "socks5", "http",
  "vmess", "vless", "trojan", "hysteria", "hysteria2",
  "wireguard", "tuic", "ssh",
]);

function invalidKey(name) { return "mihomo-invalid:" + name; }

function setFieldValidity(box, kind, message) {
  box.classList.remove("field-invalid", "field-warn");
  const input = box.querySelector("input, textarea");
  const name = input && input.name;
  if (kind === "ok") {
    box.removeAttribute("data-tooltip");
    if (input) input.removeAttribute("aria-invalid");
    if (name) {
      try { localStorage.removeItem(invalidKey(name)); } catch (e) {}
    }
    return;
  }
  box.setAttribute("data-tooltip", message || "");
  box.classList.add(kind === "warn" ? "field-warn" : "field-invalid");
  if (input) input.setAttribute("aria-invalid", kind === "invalid" ? "true" : "false");
  // Persist invalid status so other pages can count it in the nav badge.
  // 'warn' is informational only and does not count toward the error badge.
  if (name) {
    try {
      if (kind === "invalid") {
        localStorage.setItem(invalidKey(name), "1");
        // Ensure we know what page this field belongs to (validators may
        // run before the field has ever been modified, so pageKey may be unset).
        if (!localStorage.getItem(pageKey(name))) {
          localStorage.setItem(pageKey(name), location.pathname);
        }
      } else {
        localStorage.removeItem(invalidKey(name));
      }
    } catch (e) {}
  }
}

// Returns { items, syntaxError } parsing a comma-separated list.
// syntaxError fires on trailing comma, double comma, or leading/trailing
// whitespace inside an element (e.g. "LINK1 ,LINK2" / " LINK1").
function parseCsvField(raw) {
  if (!raw) return { items: [], syntaxError: null };
  // Strict: no leading/trailing whitespace in the raw value either.
  if (/^\s|\s$/.test(raw)) {
    return { items: [], syntaxError: "лишние пробелы по краям значения" };
  }
  const parts = raw.split(",");
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === "") {
      return { items: [], syntaxError: i === parts.length - 1
        ? "висячая запятая в конце"
        : "пустой элемент между запятыми" };
    }
    if (/^\s|\s$/.test(parts[i])) {
      return { items: [], syntaxError: 'лишний пробел вокруг "' + parts[i].trim() + '"' };
    }
  }
  return { items: parts, syntaxError: null };
}

function validateUseInput(input) {
  const box = input.closest(".field-validated");
  if (!box) return;
  const raw = input.value || "";
  if (!raw) { setFieldValidity(box, "ok"); return; }
  if (raw === "none") { setFieldValidity(box, "ok"); return; }
  const parsed = parseCsvField(raw);
  if (parsed.syntaxError) { setFieldValidity(box, "invalid", "Синтаксис: " + parsed.syntaxError); return; }
  const providers = knownProviders();
  const unknown = parsed.items.filter((it) => !providers.has(it));
  if (unknown.length) {
    setFieldValidity(box, "invalid", "Не найдены провайдеры (регистрозависимо): " + unknown.join(", "));
  } else {
    setFieldValidity(box, "ok");
  }
}

function validateProxiesInput(input) {
  const box = input.closest(".field-validated");
  if (!box) return;
  const raw = input.value || "";
  if (!raw) { setFieldValidity(box, "ok"); return; }
  const parsed = parseCsvField(raw);
  if (parsed.syntaxError) { setFieldValidity(box, "invalid", "Синтаксис: " + parsed.syntaxError); return; }
  const groups = knownGroups();
  const unknown = parsed.items.filter((it) => {
    if (PROXIES_SPECIALS.has(it)) return false;     // strict-case specials
    if (groups.has(it)) return false;               // strict-case group name
    return true;
  });
  if (unknown.length) {
    setFieldValidity(box, "invalid", "Допустимы только имена прокси-групп (регистрозависимо) и DIRECT/REJECT/REJECT-DROP/PASS. Неизвестно: " + unknown.join(", "));
  } else {
    setFieldValidity(box, "ok");
  }
}

// exclude-type использует `|` как разделитель (см. mihomo wiki).
// Допустимы только Adapter Type'ы (case-insensitive).
function validateExcludeTypeInput(input) {
  const box = input.closest(".field-validated");
  if (!box) return;
  const raw = input.value || "";
  if (!raw) { setFieldValidity(box, "ok"); return; }
  if (/^\s|\s$/.test(raw)) {
    setFieldValidity(box, "invalid", "Синтаксис: лишние пробелы по краям значения");
    return;
  }
  const parts = raw.split("|");
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === "") {
      setFieldValidity(box, "invalid", "Синтаксис: " + (i === parts.length - 1
        ? 'висячий "|" в конце'
        : 'пустой элемент между "|"'));
      return;
    }
    if (/^\s|\s$/.test(parts[i])) {
      setFieldValidity(box, "invalid", 'Синтаксис: лишний пробел вокруг "' + parts[i].trim() + '"');
      return;
    }
  }
  const unknown = parts.filter((it) => !EXCLUDE_TYPE_VALUES.has(it.toLowerCase()));
  if (unknown.length) {
    setFieldValidity(box, "invalid", "Не Adapter Type (регистр не важен): " + unknown.join(", "));
  } else {
    setFieldValidity(box, "ok");
  }
}

// Одно имя прокси-группы / служебка (DIRECT/REJECT/...). Используется
// для *_DIALER_PROXY (SUB_LINK*, LINK*) — там mihomo принимает один токен,
// CSV невалидно. Допустимый набор совпадает с _PROXIES (групп + спецы).
function validateProxyNameInput(input) {
  const box = input.closest(".field-validated");
  if (!box) return;
  const raw = input.value || "";
  if (!raw) { setFieldValidity(box, "ok"); return; }
  if (/^\s|\s$/.test(raw)) {
    setFieldValidity(box, "invalid", "Лишние пробелы по краям");
    return;
  }
  if (raw.indexOf(",") !== -1) {
    setFieldValidity(box, "invalid", "Одно имя — без запятых");
    return;
  }
  if (PROXIES_SPECIALS.has(raw) || knownGroups().has(raw)) {
    setFieldValidity(box, "ok");
  } else {
    setFieldValidity(box, "invalid", "Неизвестная прокси-группа (регистрозависимо). Допустимы группы + DIRECT/REJECT/REJECT-DROP/PASS.");
  }
}

function initFieldValidators() {
  const validators = {
    use: validateUseInput,
    proxies: validateProxiesInput,
    exclude_type: validateExcludeTypeInput,
    proxy_name: validateProxyNameInput,
  };
  document.querySelectorAll(".field-validated").forEach((box) => {
    const kind = box.dataset.validate;
    const fn = validators[kind];
    if (!fn) return;
    const input = box.querySelector("input, textarea");
    if (!input) return;
    const run = () => fn(input);
    input.addEventListener("input", run);
    input.addEventListener("change", run);
    run();
  });
  // Re-validate when other ENVs change (providers list might've grown).
  window.addEventListener("storage", (e) => {
    if (!e.key || !e.key.startsWith("mihomo-env:")) return;
    document.querySelectorAll(".field-validated").forEach((box) => {
      const kind = box.dataset.validate;
      const fn = validators[kind];
      if (!fn) return;
      const input = box.querySelector("input, textarea");
      if (input) fn(input);
    });
  });
}

// ===== Sticky page tabs + modified-count badges =====

function activeTabKey() {
  return "mihomo-tab:" + location.pathname;
}

function activatePageTab(tabId) {
  const tabs = document.querySelectorAll(".page-tabs .page-tab");
  const panels = document.querySelectorAll(".tab-panel");
  if (!tabs.length || !panels.length) return;
  let matched = false;
  panels.forEach((p) => {
    const on = p.dataset.tab === tabId;
    p.hidden = !on;
    if (on) matched = true;
  });
  if (!matched) {
    const first = tabs[0] && tabs[0].dataset.tab;
    if (first) {
      panels.forEach((p) => { p.hidden = p.dataset.tab !== first; });
      tabId = first;
    }
  }
  tabs.forEach((btn) => {
    const on = btn.dataset.tab === tabId;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  });
  try { localStorage.setItem(activeTabKey(), tabId); } catch (e) {}
  // Скрываем нижнюю «Сгенерировать команды MikroTik» на BlockCheck-вкладках:
  // там нет name-полей env-формы, кнопка бесполезна и только путает.
  const bottomSubmit = document.querySelector(".bottom-submit");
  if (bottomSubmit) {
    bottomSubmit.hidden = (tabId === "blockcheck" || tabId === "blockcheck2" || tabId === "byedpicheck");
  }
}

function initPageTabs() {
  const nav = document.querySelector(".page-tabs");
  if (!nav) return;
  nav.querySelectorAll(".page-tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.dataset.tab;
      activatePageTab(id);
      // Update hash without scroll jump
      if (history && history.replaceState) {
        history.replaceState(null, "", "#" + encodeURIComponent(id));
      } else {
        location.hash = id;
      }
    });
  });
  window.addEventListener("hashchange", () => {
    const id = decodeURIComponent(location.hash.slice(1));
    if (id && nav.querySelector('.page-tab[data-tab="' + CSS.escape(id) + '"]')) {
      activatePageTab(id);
    }
  });
  // Pick initial tab: URL hash > localStorage > first
  const fromHash = decodeURIComponent(location.hash.slice(1));
  const fromLs = (() => { try { return localStorage.getItem(activeTabKey()) || ""; } catch (e) { return ""; } })();
  const firstId = nav.querySelector(".page-tab") && nav.querySelector(".page-tab").dataset.tab;
  const candidates = [fromHash, fromLs, firstId].filter(Boolean);
  let initial = firstId;
  for (const c of candidates) {
    if (nav.querySelector('.page-tab[data-tab="' + CSS.escape(c) + '"]')) { initial = c; break; }
  }
  activatePageTab(initial);
}

// Walks every named form field, marks both the input and its nearest visual
// container (.field / .toggle / .env-row) as modified. Updates the status <i>
// indicator if present. Handles dynamic rows (LINK/SUB_LINK/SOCKS/etc) too.
function refreshFieldMarkers() {
  // Reset: drop all field-modified markers and restore server statuses.
  document.querySelectorAll("#envForm .field-modified").forEach((el) => el.classList.remove("field-modified"));
  document.querySelectorAll("#envForm i[data-server-status]").forEach((el) => {
    el.textContent = el.dataset.serverStatus;
    delete el.dataset.serverStatus;
  });

  document.querySelectorAll("#envForm input[name], #envForm textarea[name], #envForm select[name]").forEach((input) => {
    if (input.type === "submit" || input.type === "button") return;
    if (!input.name) return;
    const original = localStorage.getItem(originalKey(input.name));
    if (original === null) return;
    const current = fieldValue(input);
    const modified = current !== original;
    input.dataset.modified = modified ? "true" : "false";
    if (!modified) return;

    // Mark closest visual container: prefer .field / .toggle (server-rendered
    // fields), fall back to .env-row (dynamic rows like LINK/SUB_LINK/SOCKS).
    const box = input.closest(".field, .toggle") || input.closest(".env-row");
    if (box) box.classList.add("field-modified");

    const statusEl = box && box.querySelector(":scope > .field-meta > i, :scope > i");
    if (statusEl) {
      statusEl.dataset.serverStatus = statusEl.textContent;
      statusEl.textContent = "modified";
    }
  });
}

// Count modified by inspecting actual inputs (works for dynamic rows where
// .field-modified class might not be applied to a single anchor box).
function countModifiedInScope(scope) {
  if (!scope) return 0;
  let n = 0;
  scope.querySelectorAll("input[name], textarea[name], select[name]").forEach((input) => {
    if (input.type === "submit" || input.type === "button") return;
    if (!input.name) return;
    const original = localStorage.getItem(originalKey(input.name));
    if (original === null) return;
    if (fieldValue(input) !== original) n += 1;
  });
  return n;
}

function countInvalidInScope(scope) {
  if (!scope) return 0;
  return scope.querySelectorAll(".field-invalid").length;
}

function setBadge(badgeEl, count) {
  if (!badgeEl) return;
  if (count > 0) {
    badgeEl.textContent = String(count);
    badgeEl.hidden = false;
  } else {
    badgeEl.hidden = true;
    badgeEl.textContent = "";
  }
}

function updateTabBadges() {
  document.querySelectorAll(".page-tabs .page-tab").forEach((btn) => {
    const panel = document.querySelector('.tab-panel[data-tab="' + CSS.escape(btn.dataset.tab) + '"]');
    setBadge(btn.querySelector('.badge[data-kind="changed"]'), countModifiedInScope(panel));
    setBadge(btn.querySelector('.badge[data-kind="error"]'),   countInvalidInScope(panel));
  });
}

// Side-nav badges: both changed-count and error-count are cross-page,
// computed from localStorage. Invalid status is persisted by setFieldValidity
// under mihomo-invalid:<name>, paired with mihomo-page:<name>.
function updateNavBadges() {
  const byPathChanged = {};
  const byPathErrors = {};
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key) continue;
    if (key.startsWith("mihomo-env:")) {
      const name = key.slice("mihomo-env:".length);
      const cur = localStorage.getItem(key) || "";
      const orig = localStorage.getItem(originalKey(name));
      if (orig === null) continue;
      if (cur === orig) continue;
      const path = localStorage.getItem(pageKey(name));
      if (!path) continue;
      byPathChanged[path] = (byPathChanged[path] || 0) + 1;
    } else if (key.startsWith("mihomo-invalid:")) {
      const name = key.slice("mihomo-invalid:".length);
      const path = localStorage.getItem(pageKey(name));
      if (!path) continue;
      byPathErrors[path] = (byPathErrors[path] || 0) + 1;
    }
  }
  // For the current page, prefer the live DOM count — it reflects the most
  // recent validator pass before persistence has caught up.
  const currentPath = location.pathname;
  const errorsHere = document.querySelectorAll("#envForm .field-invalid").length;
  byPathErrors[currentPath] = errorsHere;

  document.querySelectorAll(".side nav a").forEach((a) => {
    const href = a.getAttribute("href") || "";
    const absPath = href.startsWith("/") ? href : "/" + href.replace(/^\.\//, "");
    let changed = 0;
    let errors = 0;
    for (const p in byPathChanged) {
      if (p === absPath || p.endsWith("/" + href) || p === href) changed += byPathChanged[p];
    }
    for (const p in byPathErrors) {
      if (p === absPath || p.endsWith("/" + href) || p === href) errors += byPathErrors[p];
    }

    let changedBadge = a.querySelector('.nav-badge[data-kind="changed"]');
    if (!changedBadge) {
      changedBadge = document.createElement("span");
      changedBadge.className = "nav-badge badge-changed";
      changedBadge.dataset.kind = "changed";
      changedBadge.hidden = true;
      a.appendChild(changedBadge);
    }
    let errorBadge = a.querySelector('.nav-badge[data-kind="error"]');
    if (!errorBadge) {
      errorBadge = document.createElement("span");
      errorBadge.className = "nav-badge badge-error";
      errorBadge.dataset.kind = "error";
      errorBadge.hidden = true;
      a.appendChild(errorBadge);
    }
    setBadge(changedBadge, changed);
    setBadge(errorBadge,   errors);
  });
}

// Modified-count + error-count chips on the left-column group list
// (proxy-groups page). Mirrors updateTabBadges but scopes to .group-pane.
function updateGroupBadges() {
  document.querySelectorAll(".group-list button[data-group]").forEach((btn) => {
    const name = btn.dataset.group;
    const pane = [...document.querySelectorAll(".group-pane")].find((p) => p.dataset.group === name);
    // Right-side column wrapper so badges span the full button height
    // instead of falling into a third row under the small/prefix label.
    let holder = btn.querySelector(".group-badges");
    if (!holder) {
      holder = document.createElement("span");
      holder.className = "group-badges";
      btn.appendChild(holder);
    }
    let changedBadge = holder.querySelector('.nav-badge[data-kind="changed"]');
    if (!changedBadge) {
      changedBadge = document.createElement("span");
      changedBadge.className = "nav-badge badge-changed";
      changedBadge.dataset.kind = "changed";
      changedBadge.hidden = true;
      holder.appendChild(changedBadge);
    }
    let errorBadge = holder.querySelector('.nav-badge[data-kind="error"]');
    if (!errorBadge) {
      errorBadge = document.createElement("span");
      errorBadge.className = "nav-badge badge-error";
      errorBadge.dataset.kind = "error";
      errorBadge.hidden = true;
      holder.appendChild(errorBadge);
    }
    setBadge(changedBadge, countModifiedInScope(pane));
    setBadge(errorBadge,   countInvalidInScope(pane));
  });
}

// Walk localStorage for env names that *had* a server value but now have an
// empty draft — these are the names that will turn into /container/envs/remove
// commands. Without this panel a user shuffling indexed rows can't tell why
// the command output also contains a remove (e.g. LINK10 → LINK11 leaves
// LINK10 as a pending removal because LINK10 was the on-server slot).
function collectPendingRemovals() {
  const list = [];
  const seen = new Set();
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key || !key.startsWith("mihomo-env:")) continue;
    const name = key.slice("mihomo-env:".length);
    if (seen.has(name)) continue;
    seen.add(name);
    const cur = localStorage.getItem(key) || "";
    if (cur !== "") continue;                            // still has a value
    const orig = localStorage.getItem(originalKey(name));
    if (!orig) continue;                                  // wasn't on server
    const path = localStorage.getItem(pageKey(name)) || "";
    list.push({name, orig, path});
  }
  // Also pick up originalKey entries with no corresponding envKey at all —
  // happens when removeEnvRow ran on a server-backed row that was later
  // deleted entirely from the draft envKey (purged by some operation).
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key || !key.startsWith("mihomo-original:")) continue;
    const name = key.slice("mihomo-original:".length);
    if (seen.has(name)) continue;
    const orig = localStorage.getItem(key) || "";
    if (!orig) continue;
    if (localStorage.getItem(envKey(name)) !== null) continue;
    seen.add(name);
    list.push({name, orig, path: localStorage.getItem(pageKey(name)) || ""});
  }
  list.sort((a, b) => a.name.localeCompare(b.name, undefined, {numeric: true}));
  return list;
}

function updatePendingRemovalsPanel() {
  const form = document.getElementById("envForm");
  if (!form) return;
  let panel = document.getElementById("pendingRemovalsPanel");
  const items = collectPendingRemovals();
  if (!panel) {
    panel = document.createElement("section");
    panel.id = "pendingRemovalsPanel";
    panel.className = "pending-removals panel";
    panel.hidden = true;
    form.insertBefore(panel, form.firstElementChild);
  }
  if (!items.length) {
    panel.hidden = true;
    panel.innerHTML = "";
    return;
  }
  panel.hidden = false;
  const intro = `<div class="pending-removals-head"><b>Будут удалены при применении (${items.length}):</b><span>значения были на сервере, но в черновике пусты. Откатить — «Сбросить страницу» или «Сбросить черновик».</span></div>`;
  const chips = items.map((it) => {
    const safeName = escapeAttr(it.name);
    const tip = escapeAttr(it.orig.length > 80 ? it.orig.slice(0, 77) + "…" : it.orig);
    return `<span class="pending-chip" title="Прежнее значение: ${tip}"><code>${safeName}</code></span>`;
  }).join("");
  panel.innerHTML = intro + '<div class="pending-removals-list">' + chips + '</div>';
}

function refreshAllBadges() {
  refreshFieldMarkers();
  updateTabBadges();
  updateNavBadges();
  updateGroupBadges();
  updatePendingRemovalsPanel();
}

function bootstrapUI() {
  applyTheme(localStorage.getItem("mihomo-theme") || "dark");
  const envListInput = document.getElementById("commandEnvList");
  if (envListInput) envListInput.value = localStorage.getItem("mihomo-command-env-list") || defaultEnvListName;
  wireFieldEvents(document.getElementById("envForm"));
  normalizeFieldMeta(document);
  enhanceIndexedRows(document);
  document.querySelectorAll(".rows").forEach(sortIndexedRows);
  cleanupRemovedIndexedRows();
  restoreMissingIndexedRows();
  initDragAndDropForAll();
  initGroupEditor();
  initHeadersEditors(document);
  initWgEndpointEditors(document);
  initPageTabs();
  initSocksEditor();
  initFieldValidators();
  initToolsPage();
  initBlockcheck();
  initBlockcheck1();
  initByedpiCheck();
  renderRulesPreview();
  refreshAllBadges();
  document.querySelectorAll("#envForm input[name], #envForm textarea[name], #envForm select[name]").forEach((el) => {
    el.addEventListener("input", renderRulesPreview);
    el.addEventListener("change", renderRulesPreview);
    el.addEventListener("input", refreshAllBadges);
    el.addEventListener("change", refreshAllBadges);
  });
  // Delegated catcher: any input bubbling up from dynamically-added rows
  // (LINK/SUB_LINK/SOCKS/ZAPRET extra fields, group panes added at runtime,
  // SOCKS sub-fields that write to hidden inputs, etc.) also triggers badge
  // and field-marker refresh.
  const envForm = document.getElementById("envForm");
  if (envForm) {
    envForm.addEventListener("input",  refreshAllBadges);
    envForm.addEventListener("change", refreshAllBadges);
    envForm.addEventListener("input",  renderRulesPreview);
    envForm.addEventListener("change", renderRulesPreview);
  }
  window.addEventListener("storage", (event) => {
    if (event.key && event.key.startsWith("mihomo-env:")) {
      renderRulesPreview();
      refreshAllBadges();
    }
  });
  document.querySelectorAll(".dns-policy-row input").forEach((input) => input.addEventListener("input", syncDnsPolicy));
  syncDnsPolicy();
  const requestedYaml = decodeURIComponent(location.hash.slice(1));
  const requestedButton = requestedYaml ? [...document.querySelectorAll(".file-list button")].find((btn) => btn.dataset.name === requestedYaml) : null;
  const first = requestedButton || document.querySelector(".file-list button");
  if (first) switchYaml(first.dataset.name);
}

document.addEventListener("DOMContentLoaded", () => {
  // Сначала пробуем подтянуть черновик с сервера (если localStorage пуст —
  // напр. браузер чистит storage на close, или открыли с другого устройства).
  // Только после этого инициализируем форму, иначе значения серверного
  // черновика не лягут в поля.
  draftLoadFromServer().then(() => bootstrapUI());
});

// Emergency flush before tab close / navigate so we don't lose the last
// few keystrokes that haven't been debounced yet.
function draftFlushSync() {
  if (draftSyncTimer) { clearTimeout(draftSyncTimer); draftSyncTimer = null; }
  const data = JSON.stringify(draftCollect());
  const url = "/cgi-bin/draft";
  if (typeof navigator !== "undefined" && navigator.sendBeacon) {
    try { navigator.sendBeacon(url, new Blob([data], { type: "application/json" })); } catch (e) {}
  } else {
    try {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", url, false);
      xhr.setRequestHeader("Content-Type", "application/json");
      xhr.send(data);
    } catch (e) {}
  }
}
window.addEventListener("beforeunload", draftFlushSync);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") draftFlushSync();
});

// ===== Blockcheck (DPI strategy scanner) =====

const BC = {
  inited: false,
  jobId: null,
  pollTimer: null,
  pollInFlight: false,
  offset: 0,
  results: [],
  counts: { ok: 0, fail: 0, skip: 0 },
  seenStrategies: new Set(),  // защита от двойного учёта event'а на UI
};
const BC_JOB_KEY = "mihomo-bc-job";

function initBlockcheck() {
  if (!document.getElementById("bcDomains")) return;
  // Идемпотентность: если функция уже отработала (повторный init из других
  // render-цепочек Mihomo UI), не вешать второй input-listener и не плодить
  // второй setInterval — иначе каждый event ndjson обрабатывался бы N раз
  // и счётчики пухли (наблюдаемое было 8635 при 1075 done — 2-3 параллельных таймера).
  if (BC.inited) return;
  BC.inited = true;

  try {
    const saved = localStorage.getItem("mihomo-bc-domains");
    if (saved) document.getElementById("bcDomains").value = saved;
  } catch (e) {}
  document.getElementById("bcDomains").addEventListener("input", (e) => {
    try { localStorage.setItem("mihomo-bc-domains", e.target.value); } catch (e2) {}
    // Дублируем в server-side draft (/dev/shm/mihomo-ui/draft.json) чтобы значения
    // переживали закрытие браузера даже если localStorage чистится приватными
    // настройками. По /dev/shm — сбрасываются только рестартом контейнера.
    draftSaveDebounced();
  });

  // Остальные контролы формы blockcheck — persist по id в mihomo-bc-form:<id>.
  // Используется и в draftCollect (см. DRAFT_KEYS_RE), чтобы значения уезжали
  // на сервер вместе с остальным черновиком и переживали F5 / переоткрытие.
  const bcPersistFields = [
    "bcWorkers", "bcLevel", "bcHardMinKb", "bcRndRepeats",
    "bcTestHttp", "bcTestTls12", "bcTestTls13", "bcTestQuic",
    "bcUseFakebin",
    "bcCustomArgs",
    "bcCustomHttp", "bcCustomTls12", "bcCustomTls13", "bcCustomQuic",
  ];
  bcPersistFields.forEach((id) => {
    const el = document.getElementById(id);
    if (!el) return;
    const key = "mihomo-bc-form:" + id;
    try {
      const v = localStorage.getItem(key);
      if (v !== null) {
        if (el.type === "checkbox") el.checked = v === "1";
        else el.value = v;
      }
    } catch (e) {}
    const ev = el.type === "checkbox" || el.tagName === "SELECT" ? "change" : "input";
    el.addEventListener(ev, () => {
      try {
        const val = el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value;
        localStorage.setItem(key, val);
      } catch (e2) {}
      draftSaveDebounced();
    });
  });

  const filter = document.getElementById("bcFilterOk");
  if (filter) filter.addEventListener("change", bcApplyFilter);

  // Recover an in-flight or recently-finished job after page reload.
  let savedJob = null;
  try { savedJob = localStorage.getItem(BC_JOB_KEY); } catch (e) {}
  if (savedJob) {
    bcResumeJob(savedJob);
    return;
  }
  // localStorage пуст — спрашиваем сервер «есть ли активный job?».
  // Сценарий: пользователь нажал Запустить, gen-strategies генерит ~5-10с,
  // закрыл браузер до того как client успел сделать setItem(JOB_KEY).
  // Сервер job уже создал и запустил — UI должен подобрать.
  fetch("/cgi-bin/blockcheck2-status?discover=1")
    .then(r => r.json()).then(data => {
      if (data && data.ok && data.job_id) {
        try { localStorage.setItem(BC_JOB_KEY, data.job_id); } catch (e) {}
        bcResumeJob(data.job_id);
      }
    }).catch(() => {});
}

function bcResumeJob(jobId) {
  BC.jobId = jobId;
  bcSetStatus("восстановлен job " + jobId + "…", true);
  if (BC.pollTimer) { clearInterval(BC.pollTimer); BC.pollTimer = null; }
  BC.pollTimer = setInterval(blockcheck2Poll, 1000);
  blockcheck2Poll();
}

function bcSetStatus(text, busy) {
  const el = document.getElementById("bcStatus");
  if (el) el.textContent = text;
  document.getElementById("bcCancelBtn").disabled = !busy;
  document.getElementById("bcStartBtn").disabled  = busy;
}

function bcAppendLog(text) {
  if (!text) return;
  const pre = document.getElementById("bcLog");
  if (!pre) return;
  if (pre.textContent.indexOf("(пусто") === 0) pre.textContent = "";
  pre.textContent += text;
  pre.scrollTop = pre.scrollHeight;
}

function bcUpdateCounts() {
  document.getElementById("bcCounts").hidden = false;
  document.getElementById("bcCountOk").textContent   = BC.counts.ok   + " рабочих";
  document.getElementById("bcCountFail").textContent = BC.counts.fail + " не сработали";
  document.getElementById("bcCountSkip").textContent = BC.counts.skip + " пропущено";
}

function bcApplyFilter() {
  const onlyOk = document.getElementById("bcFilterOk").checked;
  document.querySelectorAll("#bcTable tbody tr").forEach((tr) => {
    if (onlyOk && !tr.classList.contains("bc-row-ok")) tr.hidden = true;
    else tr.hidden = false;
  });
}

// Apply the filter every time we add a new row, otherwise newly-arrived
// `fail` rows would appear even when "only working" is checked.
function bcApplyFilterToRow(tr) {
  const onlyOk = document.getElementById("bcFilterOk").checked;
  if (onlyOk && !tr.classList.contains("bc-row-ok")) tr.hidden = true;
}

function bcHandleEvent(ev) {
  if (!ev || !ev.type) return;
  switch (ev.type) {
    case "start": {
      bcSetStatus("инициализация (workers=" + (ev.workers || "?") + ")", true);
      break;
    }
    case "resolve": {
      bcSetStatus("резолв " + (ev.host || "") + " → " + (ev.ip || ""), true);
      break;
    }
    case "resolve_fail": {
      bcAppendLog("[resolve_fail] " + (ev.host || "") + "\n");
      break;
    }
    case "nft_ready": {
      bcSetStatus("nft готов, начинаю перебор", true);
      break;
    }
    case "queue": {
      const total = parseInt(ev.total, 10) || 0;
      const bar = document.getElementById("bcProgressBar");
      const txt = document.getElementById("bcProgressText");
      document.getElementById("bcProgress").hidden = false;
      bar.max = total;
      bar.value = 0;
      txt.textContent = "0 / " + total;
      bcSetStatus("тестирую " + total + " стратегий", true);
      break;
    }
    case "strategy_start": {
      const cur = document.getElementById("bcCurrent");
      if (cur) cur.textContent = "▶ " + (ev.name || "");
      break;
    }
    case "progress": {
      const bar = document.getElementById("bcProgressBar");
      const txt = document.getElementById("bcProgressText");
      bar.value = parseInt(ev.done, 10) || 0;
      txt.textContent = (ev.done || 0) + " / " + (ev.total || 0);
      break;
    }
    case "strategy": {
      // Дубль того же strategy-события — отбрасываем, иначе при повторной
      // обработке ndjson (F5, race fetch'ей) счётчики и таблица плодятся.
      const sig = (ev.name || "") + "|" + (ev.ts || "");
      if (BC.seenStrategies.has(sig)) break;
      BC.seenStrategies.add(sig);
      const pass = parseInt(ev.pass, 10) || 0;
      const fail = parseInt(ev.fail, 10) || 0;
      const skip = parseInt(ev.skip, 10) || 0;
      if (pass > 0) BC.counts.ok++;
      else if (fail > 0) BC.counts.fail++;
      else BC.counts.skip++;
      BC.results.push(ev);
      bcRenderResultsRow(ev);
      bcUpdateCounts();
      // Recompute combined-from-best whenever a new row arrives.
      // Throttle: при потоке strategy-событий перестраивать DOM на каждый кадр
      // дорого; склеиваем до 250мс через requestAnimationFrame.
      if (pass > 0) {
        try { bcCombinedRefreshThrottled(); } catch (e) {}
      }
      // Custom-test inline result widget: this row came from the user's
      // "test one strategy" button — show pass/fail right next to it.
      if (BC.lastCustomTag && ev.name === BC.lastCustomTag) {
        const cr = document.getElementById("bcCustomResult");
        if (cr) {
          if (pass > 0) {
            cr.textContent = "✓ pass=" + pass + " · " + (ev.detail || "");
            cr.className = "bc-custom-result ok";
          } else {
            cr.textContent = "✗ fail=" + (ev.fail || 0) + " · " + (ev.detail || "");
            cr.className = "bc-custom-result fail";
          }
        }
        BC.lastCustomTag = null;
      }
      break;
    }
    case "strategy_skip": {
      BC.counts.skip++;
      bcUpdateCounts();
      break;
    }
    case "warn":
    case "error":
      bcAppendLog("[" + ev.type + "] " + (ev.msg || "") + "\n");
      if (ev.type === "error") bcSetStatus("ошибка: " + (ev.msg || ""), false);
      break;
    case "end": {
      bcSetStatus("готово (" + BC.counts.ok + " рабочих из " + BC.results.length + ")", false);
      document.getElementById("bcDownloadBtn").disabled = false;
      const cur = document.getElementById("bcCurrent");
      if (cur) cur.textContent = "";
      if (BC.pollTimer) { clearInterval(BC.pollTimer); BC.pollTimer = null; }
      // Финальный refresh без throttle — гарантируем что combined-блок
      // отрисовал ВСЕ найденные комбинации, а не последний промежуточный кадр.
      try { bcCombinedRefresh(); } catch (e) {}
      break;
    }
  }
}

// "Combined-from-best": enumerate ALL working strategies and produce the
// full http×tls×quic cross-product as combined `--new`-chained lines.
// Each combination becomes its own row with Copy / → ZAPRET2_CMD buttons.
// Cap row count to keep the UI sane.
const BC_COMBINED_CAP = 60;

// Throttle bcCombinedRefresh — при потоке strategy-событий перестраивать DOM
// на каждое срабатывает дорого. RAF-coalescing склеивает в один кадр.
let _bcCombinedRAF = null;
function bcCombinedRefreshThrottled() {
  if (_bcCombinedRAF != null) return;
  _bcCombinedRAF = (window.requestAnimationFrame || function(cb){ return setTimeout(cb, 16); })(() => {
    _bcCombinedRAF = null;
    try { bcCombinedRefresh(); } catch (e) {}
  });
}

function bcCombinedRefresh() {
  const box  = document.getElementById("bcCombinedBox");
  const list = document.getElementById("bcCombinedList");
  if (!box || !list) return;
  const wins = BC.results.filter(r => (parseInt(r.pass, 10) || 0) > 0);
  const https = wins.filter(r => r.proto === "http");
  const tlss  = wins.filter(r => r.proto === "tls" || r.proto === "tls12" || r.proto === "tls13");
  // De-dupe by args (in case the same args got reported twice).
  const dedup = arr => {
    const seen = new Set(); const out = [];
    for (const r of arr) { if (!seen.has(r.args)) { seen.add(r.args); out.push(r); } }
    return out;
  };
  const H = dedup(https);
  const T = dedup(tlss);
  const realQ = dedup(wins.filter(r => r.proto === "quic"));
  if (!H.length && !T.length) { box.hidden = true; return; }
  const DEFAULT_Q = {
    name: "(QUIC по умолчанию)",
    proto: "quic",
    args: "--filter-udp=0-65535 --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=20",
  };
  const Q = realQ.length ? realQ : [DEFAULT_Q];
  // Also allow "no QUIC at all" as a valid choice (HTTP+TLS only combo).
  const NO_Q = { name: "(без QUIC)", proto: null, args: null };
  const qOptions = [NO_Q].concat(Q);

  // Build all combinations. Treat empty H/T like an empty placeholder so
  // we still emit a combined even if only one of the two is present.
  const HOpts = H.length ? H : [{ name: "(без HTTP)", proto: null, args: null }];
  const TOpts = T.length ? T : [{ name: "(без TLS)",  proto: null, args: null }];

  const variants = [];
  for (const h of HOpts) {
    for (const t of TOpts) {
      for (const q of qOptions) {
        if (!h.args && !t.args && !q.args) continue; // empty combined
        const parts = [];
        if (h.args) parts.push(h.args);
        if (t.args) parts.push(t.args);
        if (q.args) parts.push(q.args);
        variants.push({
          combined: parts.join(" --new "),
          tag: [
            h.args ? "HTTP=" + h.name : "—",
            t.args ? "TLS="  + t.name : "—",
            q.args ? "QUIC=" + q.name : "—"
          ].join(", "),
        });
        if (variants.length >= BC_COMBINED_CAP) break;
      }
      if (variants.length >= BC_COMBINED_CAP) break;
    }
    if (variants.length >= BC_COMBINED_CAP) break;
  }

  if (variants.length === 0) { box.hidden = true; return; }
  box.hidden = false;

  // Render. We rebuild fully each time — combined-from-best is small.
  list.innerHTML = "";
  for (const v of variants) {
    const row = document.createElement("div");
    row.className = "bc-combined-row";
    const argsAttr = v.combined.replace(/"/g, "&quot;");
    row.innerHTML =
      `<div class="bc-combined-tag">${v.tag}</div>` +
      `<textarea class="bc-combined-args" readonly rows="2">${v.combined}</textarea>` +
      `<div class="bc-combined-row-actions">` +
        `<button type="button" class="primary" title="Применить: добавить новую строку ZAPRET2_CMD на вкладке ZAPRET2 с этими аргументами (затем сохранить и применить команды MikroTik)" data-args="${argsAttr}" onclick="bcCombinedApplyOne(this)">→ ZAPRET2_CMD</button>` +
        `<button type="button" data-args="${argsAttr}" onclick="bcCombinedCopyOne(this)">⧉</button>` +
      `</div>`;
    list.appendChild(row);
  }
  document.getElementById("bcCombinedSummary").textContent =
    "— " + variants.length + " вариант(ов) из " + H.length + " HTTP × " + T.length + " TLS × " + qOptions.length + " QUIC" +
    (variants.length >= BC_COMBINED_CAP ? " (обрезано)" : "");
}

function bcCombinedCopyOne(btn) {
  const args = btn.dataset.args || "";
  if (!args) return;
  bcCopyFallback(args, () => {
    const o = btn.textContent;
    btn.textContent = "✓";
    setTimeout(() => { btn.textContent = o; }, 1200);
  });
}
function bcCombinedApplyOne(btn) {
  const args = btn.dataset.args || "";
  const fake = document.createElement("button");
  fake.dataset.args = args;
  fake.dataset.name = "combined";
  bcApplyStrategy(fake);
}

function bcRenderResultsRow(ev) {
  const table = document.getElementById("bcTable");
  const tbox  = document.getElementById("bcTableBox");
  if (tbox) tbox.hidden = false;
  const tbody = table.querySelector("tbody");
  const tr = document.createElement("tr");
  const pass = parseInt(ev.pass, 10) || 0;
  if (pass > 0) tr.classList.add("bc-row-ok");
  else if ((parseInt(ev.fail, 10) || 0) > 0) tr.classList.add("bc-row-fail");
  const args = ev.args || "";
  // Every row gets a copy button so users can grab strategies that didn't
  // pass too (sometimes they want to compare or tweak). Apply button only
  // for working ones — applying a failing strategy makes no sense.
  const argsAttr = escapeAttr(args);
  const nameAttr = escapeAttr(ev.name || "");
  const copyBtn  = args ? `<button type="button" class="ghost" title="Скопировать аргументы стратегии в буфер обмена" onclick="bcCopyStrategy(this)" data-args="${argsAttr}">⧉</button>` : "";
  const applyBtn = pass > 0 && args ? `<button type="button" class="ghost" title="Применить: добавить новую строку ZAPRET2_CMD на вкладке ZAPRET2 с этими аргументами (затем сохранить и применить команды MikroTik)" onclick="bcApplyStrategy(this)" data-args="${argsAttr}" data-name="${nameAttr}">→ ZAPRET2_CMD</button>` : "";
  tr.innerHTML =
    `<td><code title="${argsAttr}">${escapeAttr(ev.name || "")}</code></td>` +
    `<td>${escapeAttr(ev.proto || "")}</td>` +
    `<td>${pass}</td>` +
    `<td>${ev.fail || 0}</td>` +
    `<td>${ev.skip || 0}</td>` +
    `<td><small>${escapeAttr(ev.detail || "")}</small></td>` +
    `<td class="bc-row-actions">${copyBtn}${applyBtn}</td>`;
  tr.dataset.pass = String(pass);
  // Insert in sorted position (PASS DESC). Linear walk; fine even at 1000+ rows.
  const tbody2 = tbody;
  let inserted = false;
  for (const existing of tbody2.children) {
    const ep = parseInt(existing.dataset.pass || "0", 10);
    if (pass > ep) {
      tbody2.insertBefore(tr, existing);
      inserted = true;
      break;
    }
  }
  if (!inserted) tbody2.appendChild(tr);
  bcApplyFilterToRow(tr);
}

// Copy strategy args to clipboard. Fallback path covers ancient browsers
// and the not-uncommon case of HTTP origin (clipboard API requires
// secure context).
function bcCopyStrategy(btn) {
  const args = btn.dataset.args || "";
  if (!args) return;
  const ok = () => {
    const orig = btn.textContent;
    btn.textContent = "✓";
    setTimeout(() => { btn.textContent = orig; }, 1200);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(args).then(ok).catch(() => bcCopyFallback(args, ok));
  } else {
    bcCopyFallback(args, ok);
  }
}
function bcCopyFallback(text, onDone) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); if (onDone) onDone(); }
  catch (e) { window.prompt("Скопируй вручную:", text); }
  document.body.removeChild(ta);
}

// blockcheck → DPI handoff. blockcheck UI lives on /tools; ZAPRET2_CMD rows
// live on /dpi. Plain navigation drops the strategy args; we persist them
// in localStorage under a fixed key and the /dpi page picks them up on load.
const BC_PENDING_KEY = "mihomo-bc-pending-zapret2";

function bcApplyStrategy(btn) {
  const args = btn.dataset.args || "";
  const name = btn.dataset.name || "strategy";
  if (!args) return;

  if (location.pathname.endsWith("/dpi") || document.getElementById("zapret2")) {
    // Same page — apply immediately.
    bcInsertZapret2Row(args, name);
    return;
  }
  // Cross-page: stash and navigate. Pickup happens on the dpi page load
  // (see bcConsumePendingZapret2 below).
  try {
    localStorage.setItem(BC_PENDING_KEY, JSON.stringify({ args, name, ts: Date.now() }));
  } catch (e) {}
  location.href = "/cgi-bin/index?p=dpi#zapret2";
}

function bcInsertZapret2Row(args, name) {
  if (typeof addRow !== "function") return;
  // Click-add then locate the just-added row deterministically via dataset.
  const before = new Set([...document.querySelectorAll('#zapret2 .env-row')].map(r => r));
  addRow("zapret2", "ZAPRET2_CMD", false);
  // Find the freshly inserted row.
  let target = null;
  for (const r of document.querySelectorAll('#zapret2 .env-row')) {
    if (!before.has(r)) { target = r; break; }
  }
  if (!target) target = document.querySelector('#zapret2 .env-row:last-child');
  if (!target) return;
  const input = target.querySelector('input[name^="ZAPRET2_CMD"]:not([name$="_PACKETS"])');
  if (!input) return;
  input.value = args;
  input.dispatchEvent(new Event("input",  { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  input.scrollIntoView({ behavior: "smooth", block: "center" });
  input.focus();
  // Friendly toast (or fallback alert if no toast helper).
  if (typeof showToast === "function") {
    showToast("Стратегия «" + name + "» добавлена в ZAPRET2_CMD. Сохраните, чтобы применить.");
  }
}

// Run on /dpi page load to consume a pending blockcheck handoff.
function bcConsumePendingZapret2() {
  let raw = null;
  try { raw = localStorage.getItem(BC_PENDING_KEY); } catch (e) {}
  if (!raw) return;
  try { localStorage.removeItem(BC_PENDING_KEY); } catch (e) {}
  let payload;
  try { payload = JSON.parse(raw); } catch (e) { return; }
  if (!payload || !payload.args) return;
  // Ignore stale handoffs (>5 minutes) — user probably gave up.
  if (payload.ts && Date.now() - payload.ts > 5 * 60 * 1000) return;
  // Defer slightly so the rest of /dpi DOM/JS is ready (env restore, etc).
  setTimeout(() => bcInsertZapret2Row(payload.args, payload.name || "strategy"), 100);
}
// Auto-run on /dpi page load.
if (typeof window !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      if (document.getElementById("zapret2")) bcConsumePendingZapret2();
    });
  } else if (document.getElementById("zapret2")) {
    bcConsumePendingZapret2();
  }
}

function bcDecode(b64) {
  if (!b64) return "";
  try {
    const bin = atob(b64);
    // We expect ASCII/UTF-8 from runner; pass through as-is.
    try { return decodeURIComponent(escape(bin)); } catch (e) { return bin; }
  } catch (e) { return ""; }
}

function bcFormValues() {
  const tests = [];
  if (document.getElementById("bcTestHttp").checked)  tests.push("http");
  if (document.getElementById("bcTestTls12").checked) tests.push("tls12");
  if (document.getElementById("bcTestTls13").checked) tests.push("tls13");
  if (document.getElementById("bcTestQuic").checked)  tests.push("quic");
  const fb = document.getElementById("bcUseFakebin");
  return {
    domains:     (document.getElementById("bcDomains").value || "").trim(),
    workers:     parseInt(document.getElementById("bcWorkers").value, 10) || 8,
    level:       document.getElementById("bcLevel").value,
    fakebin:     fb && fb.checked ? "1" : "0",
    // Per-domain body-gate: triggered automatically when a domain line
    // contains a path (e.g. `rutracker.org/forum`). The min-KB field
    // here applies to all such domains in this run.
    hard_min_kb: parseInt(document.getElementById("bcHardMinKb").value, 10) || 16,
    rnd_repeats: parseInt(document.getElementById("bcRndRepeats").value, 10) || 2,
    tests:       tests,
  };
}

// "Test custom strategy" — wraps a single user-supplied nfqws args line in a
// 1-line strategies file and starts a normal blockcheck job with workers=1.
// The job goes through the same runner/probe pipeline as a regular run, so
// results land in the table next to the others. We emit proto=combined so
// the runner exercises the strategy against every test-type the user
// checked (HTTP / TLS 1.2 / TLS 1.3 / QUIC).
function blockcheck2Custom() {
  const args = (document.getElementById("bcCustomArgs").value || "").trim();
  const v    = bcFormValues();
  if (!args) { alert("Введите аргументы nfqws"); return; }
  if (!v.domains) { alert("Укажите хотя бы один домен (поле выше)."); return; }
  const tests = [];
  if (document.getElementById("bcCustomHttp").checked)  tests.push("http");
  if (document.getElementById("bcCustomTls12").checked) tests.push("tls12");
  if (document.getElementById("bcCustomTls13").checked) tests.push("tls13");
  if (document.getElementById("bcCustomQuic")  && document.getElementById("bcCustomQuic").checked)  tests.push("quic");
  if (!tests.length) { alert("Выберите хотя бы один протокол."); return; }

  // Если идёт подбор — НЕ пытаемся cancel+restart: рейс с lock-ом приводит
  // к подвисанию (новый POST падает на «another job is running», а custom-
  // индикатор остаётся в «тестирую…» навсегда). Просим остановить вручную.
  if (BC.jobId && document.getElementById("bcCancelBtn").disabled === false) {
    alert("Сейчас идёт подбор стратегий. Сначала остановите его кнопкой «Остановить», потом запустите custom-тест.");
    return;
  }
  // NB: deliberately NOT wiping BC.results / counts / table / combined box —
  // a custom-test should *append* to whatever the user already scanned.
  // Only the offset is reset so we read this job's ndjson from the start.
  BC.offset = 0;
  // Tag this run's strategy so the strategy-event handler can recognise it
  // as custom and update the inline result widget.
  const customTag = "custom_" + Date.now();
  BC.lastCustomTag = customTag;
  const cr = document.getElementById("bcCustomResult");
  if (cr) {
    cr.textContent = "(тестирую " + tests.join("/") + "…)";
    cr.className = "bc-custom-result running";
  }
  bcSetStatus("отправка custom-теста…", true);

  // Synthesise one strategies.list line: NAME|PROTO|ARGS. proto=combined
  // means run.sh will dispatch this strategy against every enabled test
  // type (http / tls12 / tls13).
  const line = customTag + "|combined|" + args + "\n";
  const body = new URLSearchParams();
  body.set("domains_b64",    btoa(unescape(encodeURIComponent(v.domains))));
  body.set("workers",        "1");
  body.set("tests",          tests.join(","));
  body.set("strategies_b64", btoa(unescape(encodeURIComponent(line))));
  // level is ignored when strategies_b64 is set, but send it for completeness
  body.set("level",          v.level);
  body.set("hard_min_kb",    String(v.hard_min_kb));
  body.set("rnd_repeats",    String(v.rnd_repeats));

  fetch("/cgi-bin/blockcheck2", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  }).then(r => r.json()).then(data => {
    if (!data.ok) {
      bcSetStatus("ошибка: " + bcDecode(data.error_b64), false);
      BC.jobId = null;
      return;
    }
    BC.jobId = data.job_id;
    try { localStorage.setItem(BC_JOB_KEY, BC.jobId); } catch (e) {}
    bcSetStatus("custom-test запущен, job " + BC.jobId, true);
    BC.pollTimer = setInterval(blockcheck2Poll, 500);
    blockcheck2Poll();
  }).catch(err => {
    bcSetStatus("ошибка запуска: " + err, false);
    BC.jobId = null;
  });
}

function blockcheck2Start() {
  if (BC.jobId && document.getElementById("bcCancelBtn").disabled === false) {
    if (!window.confirm("Уже запущен job " + BC.jobId + ". Остановить и запустить новый?")) return;
    blockcheck2Cancel(true);
  }
  const v = bcFormValues();
  if (!v.domains) { alert("Укажите хотя бы один домен."); return; }
  if (!v.tests.length) { alert("Выберите хотя бы один тип теста."); return; }

  // Reset UI + останавливаем фоновое опрашивание прошлого job'а на всякий —
  // иначе оно может дописать в UI события, пока новый job ещё не стартовал.
  if (BC.pollTimer) { clearInterval(BC.pollTimer); BC.pollTimer = null; }
  BC.jobId = null;
  BC.pollInFlight = false;
  BC.results = [];
  BC.offset = 0;
  BC.counts = { ok: 0, fail: 0, skip: 0 };
  BC.seenStrategies = new Set();
  document.getElementById("bcLog").textContent = "";
  document.getElementById("bcTable").querySelector("tbody").innerHTML = "";
  const _tbox = document.getElementById("bcTableBox");
  if (_tbox) _tbox.hidden = true;
  document.getElementById("bcCounts").hidden = true;
  document.getElementById("bcProgress").hidden = true;
  document.getElementById("bcCurrent").textContent = "";
  document.getElementById("bcDownloadBtn").disabled = true;
  const cb = document.getElementById("bcCombinedBox");
  if (cb) cb.hidden = true;
  bcSetStatus("отправка запроса…", true);

  const body = new URLSearchParams();
  body.set("domains_b64", btoa(unescape(encodeURIComponent(v.domains))));
  body.set("workers", String(v.workers));
  body.set("tests", v.tests.join(","));
  body.set("level",       v.level);
  body.set("fakebin",     v.fakebin);
  body.set("hard_min_kb", String(v.hard_min_kb));
  body.set("rnd_repeats", String(v.rnd_repeats));

  fetch("/cgi-bin/blockcheck2", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  }).then(r => r.json()).then(data => {
    if (!data.ok) {
      bcSetStatus("ошибка: " + bcDecode(data.error_b64), false);
      try { localStorage.removeItem(BC_JOB_KEY); } catch (e) {}
      BC.jobId = null;
      return;
    }
    BC.jobId = data.job_id;
    try { localStorage.setItem(BC_JOB_KEY, BC.jobId); } catch (e) {}
    bcSetStatus("запущен job " + BC.jobId, true);
    BC.pollTimer = setInterval(blockcheck2Poll, 700);
    blockcheck2Poll();
  }).catch(err => {
    bcSetStatus("ошибка запуска: " + err, false);
    BC.jobId = null;
    try { localStorage.removeItem(BC_JOB_KEY); } catch (e) {}
  });
}

function blockcheck2Poll() {
  if (!BC.jobId) return;
  // Не запускать второй fetch если предыдущий ещё в полёте — иначе при
  // тормозящем сервере очередь fetch'ей растёт, страница виснет.
  if (BC.pollInFlight) return;
  BC.pollInFlight = true;
  fetch("/cgi-bin/blockcheck2-status?job=" + encodeURIComponent(BC.jobId) + "&offset=" + BC.offset)
    .then(r => r.json()).then(data => {
      if (!data.ok) {
        // Job dir gone (server restart, manual cleanup) → reset.
        if (BC.pollTimer) { clearInterval(BC.pollTimer); BC.pollTimer = null; }
        bcSetStatus("job недоступен: " + (data.error || ""), false);
        BC.jobId = null;
        try { localStorage.removeItem(BC_JOB_KEY); } catch (e) {}
        return;
      }
      BC.offset = data.offset;
      const tail = bcDecode(data.log_b64);
      if (tail) {
        tail.split("\n").forEach(line => {
          line = line.trim();
          if (!line || line[0] !== "{") return;
          let ev;
          try { ev = JSON.parse(line); } catch (e) { return; }
          bcHandleEvent(ev);
          // Show only meaningful events in the log pane — the table and
          // progress bar already convey the rest. Without this filter the
          // log is a wall of `progress` / `strategy_start` noise.
          if (!ev.type) return;
          switch (ev.type) {
            case "progress":
            case "strategy_start":
              return;
            case "strategy":
              // Only surface working strategies in the log; failed ones
              // live in the table.
              if ((parseInt(ev.pass, 10) || 0) > 0) {
                bcAppendLog("[OK] " + ev.name + " (" + ev.proto + ") — " +
                            (ev.detail || "") + "\n");
              }
              return;
            case "start":
              bcAppendLog("=== blockcheck2 начат: workers=" + (ev.workers || "?") +
                          " tests=" + (ev.tests || "?") + " ===\n");
              return;
            case "end":
              bcAppendLog("=== blockcheck2 завершён ===\n");
              return;
            case "queue":
              bcAppendLog("В очереди: " + (ev.total || "?") + " стратегий\n");
              return;
            case "resolve":
              bcAppendLog("DoH " + (ev.host || "") + " → " + (ev.ip || "") + "\n");
              return;
            case "resolve_fail":
              bcAppendLog("[!] не разрешил " + (ev.host || "") + " через DoH\n");
              return;
            case "baseline":
              bcAppendLog("baseline " + (ev.host || "") + " (" + (ev.ip || "") +
                          "): " + (ev.result || "?") +
                          (ev.warn ? "\n   ⚠ " + ev.warn : "") + "\n");
              return;
            case "nft_ready":
              bcAppendLog("nft-таблица готова, маркировка по dst-IP + sport-range\n");
              return;
            case "warn":
            case "error":
              bcAppendLog("[" + ev.type + "] " + (ev.msg || "") + "\n");
              return;
            case "teardown":
            case "strategy_skip":
              // silent
              return;
            case "report_building":
              bcSetStatus("формирую отчёт…", true);
              return;
            case "generating":
              bcAppendLog("генерирую стратегии (level=" + (ev.level || "?") +
                          (ev.fakebin === "1" ? ", fakebin" : "") +
                          (ev.include ? ", include=" + ev.include : "") + ")…\n");
              bcSetStatus("генерирую стратегии (level=" + (ev.level || "?") + ")…", true);
              return;
            case "generated":
              bcAppendLog("сгенерировано стратегий: " + (ev.count || "?") + "\n");
              bcSetStatus("сгенерировано " + (ev.count || "?") + " стратегий, запуск воркеров…", true);
              return;
            default:
              bcAppendLog(line + "\n");
          }
        });
      }
      // Download button enabled как только есть job — отчёт-снимок CGI
      // сам отдаст с пометкой PARTIAL пока тест идёт, или полный после.
      if (BC.jobId) document.getElementById("bcDownloadBtn").disabled = false;
      if (data.status === "done" || data.status === "error" || data.status === "cancelled") {
        if (BC.pollTimer) { clearInterval(BC.pollTimer); BC.pollTimer = null; }
        bcSetStatus(data.status === "done"
          ? "готово (" + BC.counts.ok + " рабочих из " + BC.results.length + ")"
          : data.status, false);
      }
    }).catch(() => {}).finally(() => { BC.pollInFlight = false; });
}

function blockcheck2Cancel(silent) {
  if (!BC.jobId) return;
  const body = new URLSearchParams(); body.set("job", BC.jobId);
  fetch("/cgi-bin/blockcheck2-cancel", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  }).then(r => r.json()).then(() => {
    if (!silent) bcSetStatus("остановлен", false);
    if (BC.pollTimer) { clearInterval(BC.pollTimer); BC.pollTimer = null; }
  }).catch(() => {});
}

function blockcheck2Download() {
  if (!BC.jobId) return;
  window.location.href = "/cgi-bin/blockcheck2-status?job=" + encodeURIComponent(BC.jobId) + "&download=1";
}

// (blockcheck2Preview removed — generated count is shown right in the
//  level dropdown labels; running gen-strategies twice was redundant.)

// ===== Blockcheck1 (DPI strategy scanner for zapret v1) =====

const BC1 = {
  inited: false,
  jobId: null,
  pollTimer: null,
  pollInFlight: false,
  offset: 0,
  results: [],
  counts: { ok: 0, fail: 0, skip: 0 },
  seenStrategies: new Set(),  // защита от двойного учёта event'а на UI
};
const BC1_JOB_KEY = "mihomo-bc1-job";

function initBlockcheck1() {
  if (!document.getElementById("bc1Domains")) return;
  // Идемпотентность: если функция уже отработала (повторный init из других
  // render-цепочек Mihomo UI), не вешать второй input-listener и не плодить
  // второй setInterval — иначе каждый event ndjson обрабатывался бы N раз
  // и счётчики пухли (наблюдаемое было 8635 при 1075 done — 2-3 параллельных таймера).
  if (BC1.inited) return;
  BC1.inited = true;

  try {
    const saved = localStorage.getItem("mihomo-bc1-domains");
    if (saved) document.getElementById("bc1Domains").value = saved;
  } catch (e) {}
  document.getElementById("bc1Domains").addEventListener("input", (e) => {
    try { localStorage.setItem("mihomo-bc1-domains", e.target.value); } catch (e2) {}
    draftSaveDebounced();
  });

  // Остальные контролы формы blockcheck — persist по id в mihomo-bc1-form:<id>.
  // Используется и в draftCollect (см. DRAFT_KEYS_RE), чтобы значения уезжали
  // на сервер вместе с остальным черновиком и переживали F5 / переоткрытие.
  const bcPersistFields = [
    "bc1Workers", "bc1Level", "bc1HardMinKb", "bc1RndRepeats",
    "bc1TestHttp", "bc1TestTls12", "bc1TestTls13", "bc1TestQuic",
    "bc1UseFakebin",
    "bc1CustomArgs",
    "bc1CustomHttp", "bc1CustomTls12", "bc1CustomTls13", "bc1CustomQuic",
  ];
  bcPersistFields.forEach((id) => {
    const el = document.getElementById(id);
    if (!el) return;
    const key = "mihomo-bc1-form:" + id;
    try {
      const v = localStorage.getItem(key);
      if (v !== null) {
        if (el.type === "checkbox") el.checked = v === "1";
        else el.value = v;
      }
    } catch (e) {}
    const ev = el.type === "checkbox" || el.tagName === "SELECT" ? "change" : "input";
    el.addEventListener(ev, () => {
      try {
        const val = el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value;
        localStorage.setItem(key, val);
      } catch (e2) {}
      draftSaveDebounced();
    });
  });

  const filter = document.getElementById("bc1FilterOk");
  if (filter) filter.addEventListener("change", bc1ApplyFilter);

  // Recover an in-flight or recently-finished job after page reload.
  let savedJob = null;
  try { savedJob = localStorage.getItem(BC1_JOB_KEY); } catch (e) {}
  if (savedJob) {
    bc1ResumeJob(savedJob);
    return;
  }
  // localStorage пуст — спрашиваем сервер «есть ли активный job?».
  // Сценарий: пользователь нажал Запустить, gen-strategies генерит ~5-10с,
  // закрыл браузер до того как client успел сделать setItem(JOB_KEY).
  // Сервер job уже создал и запустил — UI должен подобрать.
  fetch("/cgi-bin/blockcheck1-status?discover=1")
    .then(r => r.json()).then(data => {
      if (data && data.ok && data.job_id) {
        try { localStorage.setItem(BC1_JOB_KEY, data.job_id); } catch (e) {}
        bc1ResumeJob(data.job_id);
      }
    }).catch(() => {});
}

function bc1ResumeJob(jobId) {
  BC1.jobId = jobId;
  bc1SetStatus("восстановлен job " + jobId + "…", true);
  if (BC1.pollTimer) { clearInterval(BC1.pollTimer); BC1.pollTimer = null; }
  BC1.pollTimer = setInterval(blockcheck1Poll, 1000);
  blockcheck1Poll();
}

function bc1SetStatus(text, busy) {
  const el = document.getElementById("bc1Status");
  if (el) el.textContent = text;
  document.getElementById("bc1CancelBtn").disabled = !busy;
  document.getElementById("bc1StartBtn").disabled  = busy;
}

function bc1AppendLog(text) {
  if (!text) return;
  const pre = document.getElementById("bc1Log");
  if (!pre) return;
  if (pre.textContent.indexOf("(пусто") === 0) pre.textContent = "";
  pre.textContent += text;
  pre.scrollTop = pre.scrollHeight;
}

function bc1UpdateCounts() {
  document.getElementById("bc1Counts").hidden = false;
  document.getElementById("bc1CountOk").textContent   = BC1.counts.ok   + " рабочих";
  document.getElementById("bc1CountFail").textContent = BC1.counts.fail + " не сработали";
  document.getElementById("bc1CountSkip").textContent = BC1.counts.skip + " пропущено";
}

function bc1ApplyFilter() {
  const onlyOk = document.getElementById("bc1FilterOk").checked;
  document.querySelectorAll("#bc1Table tbody tr").forEach((tr) => {
    if (onlyOk && !tr.classList.contains("bc-row-ok")) tr.hidden = true;
    else tr.hidden = false;
  });
}

// Apply the filter every time we add a new row, otherwise newly-arrived
// `fail` rows would appear even when "only working" is checked.
function bc1ApplyFilterToRow(tr) {
  const onlyOk = document.getElementById("bc1FilterOk").checked;
  if (onlyOk && !tr.classList.contains("bc-row-ok")) tr.hidden = true;
}

function bc1HandleEvent(ev) {
  if (!ev || !ev.type) return;
  switch (ev.type) {
    case "start": {
      bc1SetStatus("инициализация (workers=" + (ev.workers || "?") + ")", true);
      break;
    }
    case "resolve": {
      bc1SetStatus("резолв " + (ev.host || "") + " → " + (ev.ip || ""), true);
      break;
    }
    case "resolve_fail": {
      bc1AppendLog("[resolve_fail] " + (ev.host || "") + "\n");
      break;
    }
    case "nft_ready": {
      bc1SetStatus("nft готов, начинаю перебор", true);
      break;
    }
    case "queue": {
      const total = parseInt(ev.total, 10) || 0;
      const bar = document.getElementById("bc1ProgressBar");
      const txt = document.getElementById("bc1ProgressText");
      document.getElementById("bc1Progress").hidden = false;
      bar.max = total;
      bar.value = 0;
      txt.textContent = "0 / " + total;
      bc1SetStatus("тестирую " + total + " стратегий", true);
      break;
    }
    case "strategy_start": {
      const cur = document.getElementById("bc1Current");
      if (cur) cur.textContent = "▶ " + (ev.name || "");
      break;
    }
    case "progress": {
      const bar = document.getElementById("bc1ProgressBar");
      const txt = document.getElementById("bc1ProgressText");
      bar.value = parseInt(ev.done, 10) || 0;
      txt.textContent = (ev.done || 0) + " / " + (ev.total || 0);
      break;
    }
    case "strategy": {
      // Дубль того же strategy-события — отбрасываем, иначе при повторной
      // обработке ndjson (F5, race fetch'ей) счётчики и таблица плодятся.
      const sig = (ev.name || "") + "|" + (ev.ts || "");
      if (BC1.seenStrategies.has(sig)) break;
      BC1.seenStrategies.add(sig);
      const pass = parseInt(ev.pass, 10) || 0;
      const fail = parseInt(ev.fail, 10) || 0;
      const skip = parseInt(ev.skip, 10) || 0;
      if (pass > 0) BC1.counts.ok++;
      else if (fail > 0) BC1.counts.fail++;
      else BC1.counts.skip++;
      BC1.results.push(ev);
      bc1RenderResultsRow(ev);
      bc1UpdateCounts();
      // Recompute combined-from-best whenever a new row arrives.
      // Throttle: при потоке strategy-событий перестраивать DOM на каждый кадр
      // дорого; склеиваем до 250мс через requestAnimationFrame.
      if (pass > 0) {
        try { bc1CombinedRefreshThrottled(); } catch (e) {}
      }
      // Custom-test inline result widget: this row came from the user's
      // "test one strategy" button — show pass/fail right next to it.
      if (BC1.lastCustomTag && ev.name === BC1.lastCustomTag) {
        const cr = document.getElementById("bc1CustomResult");
        if (cr) {
          if (pass > 0) {
            cr.textContent = "✓ pass=" + pass + " · " + (ev.detail || "");
            cr.className = "bc-custom-result ok";
          } else {
            cr.textContent = "✗ fail=" + (ev.fail || 0) + " · " + (ev.detail || "");
            cr.className = "bc-custom-result fail";
          }
        }
        BC1.lastCustomTag = null;
      }
      break;
    }
    case "strategy_skip": {
      BC1.counts.skip++;
      bc1UpdateCounts();
      break;
    }
    case "warn":
    case "error":
      bc1AppendLog("[" + ev.type + "] " + (ev.msg || "") + "\n");
      if (ev.type === "error") bc1SetStatus("ошибка: " + (ev.msg || ""), false);
      break;
    case "end": {
      bc1SetStatus("готово (" + BC1.counts.ok + " рабочих из " + BC1.results.length + ")", false);
      document.getElementById("bc1DownloadBtn").disabled = false;
      const cur = document.getElementById("bc1Current");
      if (cur) cur.textContent = "";
      if (BC1.pollTimer) { clearInterval(BC1.pollTimer); BC1.pollTimer = null; }
      // Финальный refresh без throttle — гарантируем что combined-блок
      // отрисовал ВСЕ найденные комбинации, а не последний промежуточный кадр.
      try { bc1CombinedRefresh(); } catch (e) {}
      break;
    }
  }
}

// "Combined-from-best": enumerate ALL working strategies and produce the
// full http×tls×quic cross-product as combined `--new`-chained lines.
// Each combination becomes its own row with Copy / → ZAPRET_CMD buttons.
// Cap row count to keep the UI sane.
const BC1_COMBINED_CAP = 60;

// Throttle bc1CombinedRefresh — при потоке strategy-событий перестраивать DOM
// на каждое срабатывает дорого. RAF-coalescing склеивает в один кадр.
let _bc1CombinedRAF = null;
function bc1CombinedRefreshThrottled() {
  if (_bc1CombinedRAF != null) return;
  _bc1CombinedRAF = (window.requestAnimationFrame || function(cb){ return setTimeout(cb, 16); })(() => {
    _bc1CombinedRAF = null;
    try { bc1CombinedRefresh(); } catch (e) {}
  });
}

function bc1CombinedRefresh() {
  const box  = document.getElementById("bc1CombinedBox");
  const list = document.getElementById("bc1CombinedList");
  if (!box || !list) return;
  const wins = BC1.results.filter(r => (parseInt(r.pass, 10) || 0) > 0);
  const https = wins.filter(r => r.proto === "http");
  const tlss  = wins.filter(r => r.proto === "tls" || r.proto === "tls12" || r.proto === "tls13");
  // De-dupe by args (in case the same args got reported twice).
  const dedup = arr => {
    const seen = new Set(); const out = [];
    for (const r of arr) { if (!seen.has(r.args)) { seen.add(r.args); out.push(r); } }
    return out;
  };
  const H = dedup(https);
  const T = dedup(tlss);
  const realQ = dedup(wins.filter(r => r.proto === "quic"));
  if (!H.length && !T.length) { box.hidden = true; return; }
  // BC1 = nfqws v1 синтаксис, не lua. Дефолтная QUIC-стратегия отличается
  // от BC2 — здесь --dpi-desync=fake без lua-цепочки.
  const DEFAULT_Q = {
    name: "(QUIC по умолчанию)",
    proto: "quic",
    args: "--filter-udp=0-65535 --dpi-desync=fake --dpi-desync-repeats=20",
  };
  const Q = realQ.length ? realQ : [DEFAULT_Q];
  // Also allow "no QUIC at all" as a valid choice (HTTP+TLS only combo).
  const NO_Q = { name: "(без QUIC)", proto: null, args: null };
  const qOptions = [NO_Q].concat(Q);

  // Build all combinations. Treat empty H/T like an empty placeholder so
  // we still emit a combined even if only one of the two is present.
  const HOpts = H.length ? H : [{ name: "(без HTTP)", proto: null, args: null }];
  const TOpts = T.length ? T : [{ name: "(без TLS)",  proto: null, args: null }];

  const variants = [];
  for (const h of HOpts) {
    for (const t of TOpts) {
      for (const q of qOptions) {
        if (!h.args && !t.args && !q.args) continue; // empty combined
        const parts = [];
        if (h.args) parts.push(h.args);
        if (t.args) parts.push(t.args);
        if (q.args) parts.push(q.args);
        variants.push({
          combined: parts.join(" --new "),
          tag: [
            h.args ? "HTTP=" + h.name : "—",
            t.args ? "TLS="  + t.name : "—",
            q.args ? "QUIC=" + q.name : "—"
          ].join(", "),
        });
        if (variants.length >= BC1_COMBINED_CAP) break;
      }
      if (variants.length >= BC1_COMBINED_CAP) break;
    }
    if (variants.length >= BC1_COMBINED_CAP) break;
  }

  if (variants.length === 0) { box.hidden = true; return; }
  box.hidden = false;

  // Render. We rebuild fully each time — combined-from-best is small.
  list.innerHTML = "";
  for (const v of variants) {
    const row = document.createElement("div");
    row.className = "bc-combined-row";
    const argsAttr = v.combined.replace(/"/g, "&quot;");
    row.innerHTML =
      `<div class="bc-combined-tag">${v.tag}</div>` +
      `<textarea class="bc-combined-args" readonly rows="2">${v.combined}</textarea>` +
      `<div class="bc-combined-row-actions">` +
        `<button type="button" class="primary" title="Применить: добавить новую строку ZAPRET_CMD на вкладке ZAPRET с этими аргументами (затем сохранить и применить команды MikroTik)" data-args="${argsAttr}" onclick="bc1CombinedApplyOne(this)">→ ZAPRET_CMD</button>` +
        `<button type="button" data-args="${argsAttr}" onclick="bc1CombinedCopyOne(this)">⧉</button>` +
      `</div>`;
    list.appendChild(row);
  }
  document.getElementById("bc1CombinedSummary").textContent =
    "— " + variants.length + " вариант(ов) из " + H.length + " HTTP × " + T.length + " TLS × " + qOptions.length + " QUIC" +
    (variants.length >= BC1_COMBINED_CAP ? " (обрезано)" : "");
}

function bc1CombinedCopyOne(btn) {
  const args = btn.dataset.args || "";
  if (!args) return;
  bc1CopyFallback(args, () => {
    const o = btn.textContent;
    btn.textContent = "✓";
    setTimeout(() => { btn.textContent = o; }, 1200);
  });
}
function bc1CombinedApplyOne(btn) {
  const args = btn.dataset.args || "";
  const fake = document.createElement("button");
  fake.dataset.args = args;
  fake.dataset.name = "combined";
  bc1ApplyStrategy(fake);
}

function bc1RenderResultsRow(ev) {
  const table = document.getElementById("bc1Table");
  const tbox  = document.getElementById("bc1TableBox");
  if (tbox) tbox.hidden = false;
  const tbody = table.querySelector("tbody");
  const tr = document.createElement("tr");
  const pass = parseInt(ev.pass, 10) || 0;
  if (pass > 0) tr.classList.add("bc-row-ok");
  else if ((parseInt(ev.fail, 10) || 0) > 0) tr.classList.add("bc-row-fail");
  const args = ev.args || "";
  // Every row gets a copy button so users can grab strategies that didn't
  // pass too (sometimes they want to compare or tweak). Apply button only
  // for working ones — applying a failing strategy makes no sense.
  const argsAttr = escapeAttr(args);
  const nameAttr = escapeAttr(ev.name || "");
  const copyBtn  = args ? `<button type="button" class="ghost" title="Скопировать аргументы стратегии в буфер обмена" onclick="bc1CopyStrategy(this)" data-args="${argsAttr}">⧉</button>` : "";
  const applyBtn = pass > 0 && args ? `<button type="button" class="ghost" title="Применить: добавить новую строку ZAPRET_CMD на вкладке ZAPRET с этими аргументами (затем сохранить и применить команды MikroTik)" onclick="bc1ApplyStrategy(this)" data-args="${argsAttr}" data-name="${nameAttr}">→ ZAPRET_CMD</button>` : "";
  tr.innerHTML =
    `<td><code title="${argsAttr}">${escapeAttr(ev.name || "")}</code></td>` +
    `<td>${escapeAttr(ev.proto || "")}</td>` +
    `<td>${pass}</td>` +
    `<td>${ev.fail || 0}</td>` +
    `<td>${ev.skip || 0}</td>` +
    `<td><small>${escapeAttr(ev.detail || "")}</small></td>` +
    `<td class="bc-row-actions">${copyBtn}${applyBtn}</td>`;
  tr.dataset.pass = String(pass);
  // Insert in sorted position (PASS DESC). Linear walk; fine even at 1000+ rows.
  const tbody2 = tbody;
  let inserted = false;
  for (const existing of tbody2.children) {
    const ep = parseInt(existing.dataset.pass || "0", 10);
    if (pass > ep) {
      tbody2.insertBefore(tr, existing);
      inserted = true;
      break;
    }
  }
  if (!inserted) tbody2.appendChild(tr);
  bc1ApplyFilterToRow(tr);
}

// Copy strategy args to clipboard. Fallback path covers ancient browsers
// and the not-uncommon case of HTTP origin (clipboard API requires
// secure context).
function bc1CopyStrategy(btn) {
  const args = btn.dataset.args || "";
  if (!args) return;
  const ok = () => {
    const orig = btn.textContent;
    btn.textContent = "✓";
    setTimeout(() => { btn.textContent = orig; }, 1200);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(args).then(ok).catch(() => bc1CopyFallback(args, ok));
  } else {
    bc1CopyFallback(args, ok);
  }
}
function bc1CopyFallback(text, onDone) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); if (onDone) onDone(); }
  catch (e) { window.prompt("Скопируй вручную:", text); }
  document.body.removeChild(ta);
}

// blockcheck → DPI handoff. blockcheck UI lives on /tools; ZAPRET_CMD rows
// live on /dpi. Plain navigation drops the strategy args; we persist them
// in localStorage under a fixed key and the /dpi page picks them up on load.
const BC1_PENDING_KEY = "mihomo-bc1-pending-zapret";

function bc1ApplyStrategy(btn) {
  const args = btn.dataset.args || "";
  const name = btn.dataset.name || "strategy";
  if (!args) return;

  if (location.pathname.endsWith("/dpi") || document.getElementById("zapret")) {
    // Same page — apply immediately.
    bc1InsertZapretRow(args, name);
    return;
  }
  // Cross-page: stash and navigate. Pickup happens on the dpi page load
  // (see bc1ConsumePendingZapret below).
  try {
    localStorage.setItem(BC1_PENDING_KEY, JSON.stringify({ args, name, ts: Date.now() }));
  } catch (e) {}
  location.href = "/cgi-bin/index?p=dpi#zapret";
}

function bc1InsertZapretRow(args, name) {
  if (typeof addRow !== "function") return;
  // Click-add then locate the just-added row deterministically via dataset.
  const before = new Set([...document.querySelectorAll('#zapret .env-row')].map(r => r));
  addRow("zapret", "ZAPRET_CMD", false);
  // Find the freshly inserted row.
  let target = null;
  for (const r of document.querySelectorAll('#zapret .env-row')) {
    if (!before.has(r)) { target = r; break; }
  }
  if (!target) target = document.querySelector('#zapret .env-row:last-child');
  if (!target) return;
  const input = target.querySelector('input[name^="ZAPRET_CMD"]:not([name$="_PACKETS"])');
  if (!input) return;
  input.value = args;
  input.dispatchEvent(new Event("input",  { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  input.scrollIntoView({ behavior: "smooth", block: "center" });
  input.focus();
  // Friendly toast (or fallback alert if no toast helper).
  if (typeof showToast === "function") {
    showToast("Стратегия «" + name + "» добавлена в ZAPRET_CMD. Сохраните, чтобы применить.");
  }
}

// Run on /dpi page load to consume a pending blockcheck handoff.
function bc1ConsumePendingZapret() {
  let raw = null;
  try { raw = localStorage.getItem(BC1_PENDING_KEY); } catch (e) {}
  if (!raw) return;
  try { localStorage.removeItem(BC1_PENDING_KEY); } catch (e) {}
  let payload;
  try { payload = JSON.parse(raw); } catch (e) { return; }
  if (!payload || !payload.args) return;
  // Ignore stale handoffs (>5 minutes) — user probably gave up.
  if (payload.ts && Date.now() - payload.ts > 5 * 60 * 1000) return;
  // Defer slightly so the rest of /dpi DOM/JS is ready (env restore, etc).
  setTimeout(() => bc1InsertZapretRow(payload.args, payload.name || "strategy"), 100);
}
// Auto-run on /dpi page load.
if (typeof window !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      if (document.getElementById("zapret")) bc1ConsumePendingZapret();
    });
  } else if (document.getElementById("zapret")) {
    bc1ConsumePendingZapret();
  }
}

function bc1Decode(b64) {
  if (!b64) return "";
  try {
    const bin = atob(b64);
    // We expect ASCII/UTF-8 from runner; pass through as-is.
    try { return decodeURIComponent(escape(bin)); } catch (e) { return bin; }
  } catch (e) { return ""; }
}

function bc1FormValues() {
  const tests = [];
  if (document.getElementById("bc1TestHttp").checked)  tests.push("http");
  if (document.getElementById("bc1TestTls12").checked) tests.push("tls12");
  if (document.getElementById("bc1TestTls13").checked) tests.push("tls13");
  if (document.getElementById("bc1TestQuic").checked)  tests.push("quic");
  const fb = document.getElementById("bc1UseFakebin");
  return {
    domains:     (document.getElementById("bc1Domains").value || "").trim(),
    workers:     parseInt(document.getElementById("bc1Workers").value, 10) || 8,
    level:       document.getElementById("bc1Level").value,
    fakebin:     fb && fb.checked ? "1" : "0",
    // Per-domain body-gate: triggered automatically when a domain line
    // contains a path (e.g. `rutracker.org/forum`). The min-KB field
    // here applies to all such domains in this run.
    hard_min_kb: parseInt(document.getElementById("bc1HardMinKb").value, 10) || 16,
    rnd_repeats: parseInt(document.getElementById("bc1RndRepeats").value, 10) || 2,
    tests:       tests,
  };
}

// "Test custom strategy" — wraps a single user-supplied nfqws args line in a
// 1-line strategies file and starts a normal blockcheck job with workers=1.
// The job goes through the same runner/probe pipeline as a regular run, so
// results land in the table next to the others. We emit proto=combined so
// the runner exercises the strategy against every test-type the user
// checked (HTTP / TLS 1.2 / TLS 1.3 / QUIC).
function blockcheck1Custom() {
  const args = (document.getElementById("bc1CustomArgs").value || "").trim();
  const v    = bc1FormValues();
  if (!args) { alert("Введите аргументы nfqws"); return; }
  if (!v.domains) { alert("Укажите хотя бы один домен (поле выше)."); return; }
  const tests = [];
  if (document.getElementById("bc1CustomHttp").checked)  tests.push("http");
  if (document.getElementById("bc1CustomTls12").checked) tests.push("tls12");
  if (document.getElementById("bc1CustomTls13").checked) tests.push("tls13");
  if (document.getElementById("bc1CustomQuic")  && document.getElementById("bc1CustomQuic").checked)  tests.push("quic");
  if (!tests.length) { alert("Выберите хотя бы один протокол."); return; }

  if (BC1.jobId && document.getElementById("bc1CancelBtn").disabled === false) {
    alert("Сейчас идёт подбор стратегий. Сначала остановите его кнопкой «Остановить», потом запустите custom-тест.");
    return;
  }
  // NB: deliberately NOT wiping BC1.results / counts / table / combined box —
  // a custom-test should *append* to whatever the user already scanned.
  // Only the offset is reset so we read this job's ndjson from the start.
  BC1.offset = 0;
  // Tag this run's strategy so the strategy-event handler can recognise it
  // as custom and update the inline result widget.
  const customTag = "custom_" + Date.now();
  BC1.lastCustomTag = customTag;
  const cr = document.getElementById("bc1CustomResult");
  if (cr) {
    cr.textContent = "(тестирую " + tests.join("/") + "…)";
    cr.className = "bc-custom-result running";
  }
  bc1SetStatus("отправка custom-теста…", true);

  // Synthesise one strategies.list line: NAME|PROTO|ARGS. proto=combined
  // means run.sh will dispatch this strategy against every enabled test
  // type (http / tls12 / tls13).
  const line = customTag + "|combined|" + args + "\n";
  const body = new URLSearchParams();
  body.set("domains_b64",    btoa(unescape(encodeURIComponent(v.domains))));
  body.set("workers",        "1");
  body.set("tests",          tests.join(","));
  body.set("strategies_b64", btoa(unescape(encodeURIComponent(line))));
  // level is ignored when strategies_b64 is set, but send it for completeness
  body.set("level",          v.level);
  body.set("hard_min_kb",    String(v.hard_min_kb));
  body.set("rnd_repeats",    String(v.rnd_repeats));

  fetch("/cgi-bin/blockcheck1", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  }).then(r => r.json()).then(data => {
    if (!data.ok) {
      bc1SetStatus("ошибка: " + bc1Decode(data.error_b64), false);
      BC1.jobId = null;
      return;
    }
    BC1.jobId = data.job_id;
    try { localStorage.setItem(BC1_JOB_KEY, BC1.jobId); } catch (e) {}
    bc1SetStatus("custom-test запущен, job " + BC1.jobId, true);
    BC1.pollTimer = setInterval(blockcheck1Poll, 500);
    blockcheck1Poll();
  }).catch(err => {
    bc1SetStatus("ошибка запуска: " + err, false);
    BC1.jobId = null;
  });
}

function blockcheck1Start() {
  if (BC1.jobId && document.getElementById("bc1CancelBtn").disabled === false) {
    if (!window.confirm("Уже запущен job " + BC1.jobId + ". Остановить и запустить новый?")) return;
    blockcheck1Cancel(true);
  }
  const v = bc1FormValues();
  if (!v.domains) { alert("Укажите хотя бы один домен."); return; }
  if (!v.tests.length) { alert("Выберите хотя бы один тип теста."); return; }

  // Reset UI + останавливаем фоновое опрашивание прошлого job'а на всякий —
  // иначе оно может дописать в UI события, пока новый job ещё не стартовал.
  if (BC1.pollTimer) { clearInterval(BC1.pollTimer); BC1.pollTimer = null; }
  BC1.jobId = null;
  BC1.pollInFlight = false;
  BC1.results = [];
  BC1.offset = 0;
  BC1.counts = { ok: 0, fail: 0, skip: 0 };
  BC1.seenStrategies = new Set();
  document.getElementById("bc1Log").textContent = "";
  document.getElementById("bc1Table").querySelector("tbody").innerHTML = "";
  const _tbox = document.getElementById("bc1TableBox");
  if (_tbox) _tbox.hidden = true;
  document.getElementById("bc1Counts").hidden = true;
  document.getElementById("bc1Progress").hidden = true;
  document.getElementById("bc1Current").textContent = "";
  document.getElementById("bc1DownloadBtn").disabled = true;
  const cb = document.getElementById("bc1CombinedBox");
  if (cb) cb.hidden = true;
  bc1SetStatus("отправка запроса…", true);

  const body = new URLSearchParams();
  body.set("domains_b64", btoa(unescape(encodeURIComponent(v.domains))));
  body.set("workers", String(v.workers));
  body.set("tests", v.tests.join(","));
  body.set("level",       v.level);
  body.set("fakebin",     v.fakebin);
  body.set("hard_min_kb", String(v.hard_min_kb));
  body.set("rnd_repeats", String(v.rnd_repeats));

  fetch("/cgi-bin/blockcheck1", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  }).then(r => r.json()).then(data => {
    if (!data.ok) {
      bc1SetStatus("ошибка: " + bc1Decode(data.error_b64), false);
      try { localStorage.removeItem(BC1_JOB_KEY); } catch (e) {}
      BC1.jobId = null;
      return;
    }
    BC1.jobId = data.job_id;
    try { localStorage.setItem(BC1_JOB_KEY, BC1.jobId); } catch (e) {}
    bc1SetStatus("запущен job " + BC1.jobId, true);
    BC1.pollTimer = setInterval(blockcheck1Poll, 700);
    blockcheck1Poll();
  }).catch(err => {
    bc1SetStatus("ошибка запуска: " + err, false);
    BC1.jobId = null;
    try { localStorage.removeItem(BC1_JOB_KEY); } catch (e) {}
  });
}

function blockcheck1Poll() {
  if (!BC1.jobId) return;
  // Не запускать второй fetch если предыдущий ещё в полёте — иначе при
  // тормозящем сервере очередь fetch'ей растёт, страница виснет.
  if (BC1.pollInFlight) return;
  BC1.pollInFlight = true;
  fetch("/cgi-bin/blockcheck1-status?job=" + encodeURIComponent(BC1.jobId) + "&offset=" + BC1.offset)
    .then(r => r.json()).then(data => {
      if (!data.ok) {
        // Job dir gone (server restart, manual cleanup) → reset.
        if (BC1.pollTimer) { clearInterval(BC1.pollTimer); BC1.pollTimer = null; }
        bc1SetStatus("job недоступен: " + (data.error || ""), false);
        BC1.jobId = null;
        try { localStorage.removeItem(BC1_JOB_KEY); } catch (e) {}
        return;
      }
      BC1.offset = data.offset;
      const tail = bc1Decode(data.log_b64);
      if (tail) {
        tail.split("\n").forEach(line => {
          line = line.trim();
          if (!line || line[0] !== "{") return;
          let ev;
          try { ev = JSON.parse(line); } catch (e) { return; }
          bc1HandleEvent(ev);
          // Show only meaningful events in the log pane — the table and
          // progress bar already convey the rest. Without this filter the
          // log is a wall of `progress` / `strategy_start` noise.
          if (!ev.type) return;
          switch (ev.type) {
            case "progress":
            case "strategy_start":
              return;
            case "strategy":
              // Only surface working strategies in the log; failed ones
              // live in the table.
              if ((parseInt(ev.pass, 10) || 0) > 0) {
                bc1AppendLog("[OK] " + ev.name + " (" + ev.proto + ") — " +
                            (ev.detail || "") + "\n");
              }
              return;
            case "start":
              bc1AppendLog("=== blockcheck1 начат: workers=" + (ev.workers || "?") +
                          " tests=" + (ev.tests || "?") + " ===\n");
              return;
            case "end":
              bc1AppendLog("=== blockcheck1 завершён ===\n");
              return;
            case "queue":
              bc1AppendLog("В очереди: " + (ev.total || "?") + " стратегий\n");
              return;
            case "resolve":
              bc1AppendLog("DoH " + (ev.host || "") + " → " + (ev.ip || "") + "\n");
              return;
            case "resolve_fail":
              bc1AppendLog("[!] не разрешил " + (ev.host || "") + " через DoH\n");
              return;
            case "baseline":
              bc1AppendLog("baseline " + (ev.host || "") + " (" + (ev.ip || "") +
                          "): " + (ev.result || "?") +
                          (ev.warn ? "\n   ⚠ " + ev.warn : "") + "\n");
              return;
            case "nft_ready":
              bc1AppendLog("nft-таблица готова, маркировка по dst-IP + sport-range\n");
              return;
            case "warn":
            case "error":
              bc1AppendLog("[" + ev.type + "] " + (ev.msg || "") + "\n");
              return;
            case "teardown":
            case "strategy_skip":
              // silent
              return;
            case "report_building":
              bc1SetStatus("формирую отчёт…", true);
              return;
            case "generating":
              bc1AppendLog("генерирую стратегии (level=" + (ev.level || "?") +
                          (ev.fakebin === "1" ? ", fakebin" : "") +
                          (ev.include ? ", include=" + ev.include : "") + ")…\n");
              bc1SetStatus("генерирую стратегии (level=" + (ev.level || "?") + ")…", true);
              return;
            case "generated":
              bc1AppendLog("сгенерировано стратегий: " + (ev.count || "?") + "\n");
              bc1SetStatus("сгенерировано " + (ev.count || "?") + " стратегий, запуск воркеров…", true);
              return;
            default:
              bc1AppendLog(line + "\n");
          }
        });
      }
      // Download button enabled как только есть job — отчёт-снимок CGI
      // сам отдаст с пометкой PARTIAL пока тест идёт, или полный после.
      if (BC1.jobId) document.getElementById("bc1DownloadBtn").disabled = false;
      if (data.status === "done" || data.status === "error" || data.status === "cancelled") {
        if (BC1.pollTimer) { clearInterval(BC1.pollTimer); BC1.pollTimer = null; }
        bc1SetStatus(data.status === "done"
          ? "готово (" + BC1.counts.ok + " рабочих из " + BC1.results.length + ")"
          : data.status, false);
      }
    }).catch(() => {}).finally(() => { BC1.pollInFlight = false; });
}

function blockcheck1Cancel(silent) {
  if (!BC1.jobId) return;
  const body = new URLSearchParams(); body.set("job", BC1.jobId);
  fetch("/cgi-bin/blockcheck1-cancel", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  }).then(r => r.json()).then(() => {
    if (!silent) bc1SetStatus("остановлен", false);
    if (BC1.pollTimer) { clearInterval(BC1.pollTimer); BC1.pollTimer = null; }
  }).catch(() => {});
}

function blockcheck1Download() {
  if (!BC1.jobId) return;
  window.location.href = "/cgi-bin/blockcheck1-status?job=" + encodeURIComponent(BC1.jobId) + "&download=1";
}

// ===== ByeDPI Check =====
const BDC_JOB_KEY = "mihomo-bdc-job";
const BDC = { jobId: null, offset: 0, pollTimer: null, pollInFlight: false, results: [], counts: { ok: 0, fail: 0, skip: 0 }, seenStrategies: new Set(), lastCustomTag: null };

function initByedpiCheck() {
  if (!document.getElementById("bdcDomains")) return;
  const saved = localStorage.getItem("mihomo-bdc-domains");
  if (saved) document.getElementById("bdcDomains").value = saved;
  document.getElementById("bdcDomains").addEventListener("input", (e) => {
    try { localStorage.setItem("mihomo-bdc-domains", e.target.value); draftSaveDebounced(); } catch (e2) {}
  });
  ["bdcWorkers","bdcLevel","bdcHardMinKb","bdcRndRepeats","bdcTestHttp","bdcTestTls12","bdcTestTls13","bdcTestQuic","bdcUseFakebin","bdcCustomArgs","bdcCustomHttp","bdcCustomTls12","bdcCustomTls13","bdcCustomQuic"].forEach((id) => {
    const el = document.getElementById(id); if (!el) return;
    const key = "mihomo-bdc-form:" + id;
    const val = localStorage.getItem(key);
    if (val !== null) { if (el.type === "checkbox") el.checked = val === "1"; else el.value = val; }
    const save = () => { try { localStorage.setItem(key, el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value); draftSaveDebounced(); } catch (e) {} };
    el.addEventListener("change", save);
    el.addEventListener("input", () => { if (el.type !== "checkbox") save(); });
  });
  const filter = document.getElementById("bdcFilterOk");
  if (filter) filter.addEventListener("change", bdcApplyFilter);
  const savedJob = localStorage.getItem(BDC_JOB_KEY);
  if (savedJob) bdcResumeJob(savedJob);
  fetch("/cgi-bin/byedpi-check-status?discover=1").then(r => r.json()).then(data => {
    if (data && data.ok && data.job_id && data.job_id !== savedJob) bdcResumeJob(data.job_id);
  }).catch(() => {});
}

function bdcResumeJob(jobId) {
  BDC.jobId = jobId; BDC.offset = 0;
  bdcSetStatus("восстановлен job " + jobId + "…", true);
  if (BDC.pollTimer) clearInterval(BDC.pollTimer);
  BDC.pollTimer = setInterval(byedpiCheckPoll, 1000);
  byedpiCheckPoll();
}

function bdcSetStatus(text, busy) {
  const el = document.getElementById("bdcStatus"); if (el) el.textContent = text;
  document.getElementById("bdcCancelBtn").disabled = !busy;
  document.getElementById("bdcStartBtn").disabled = busy;
}

function bdcAppendLog(text) {
  const pre = document.getElementById("bdcLog"); if (!pre) return;
  if (pre.textContent.startsWith("(")) pre.textContent = "";
  pre.textContent += text;
  pre.scrollTop = pre.scrollHeight;
}

function bdcUpdateCounts() {
  document.getElementById("bdcCounts").hidden = false;
  document.getElementById("bdcCountOk").textContent = BDC.counts.ok + " рабочих";
  document.getElementById("bdcCountFail").textContent = BDC.counts.fail + " не сработали";
  document.getElementById("bdcCountSkip").textContent = BDC.counts.skip + " пропущено";
}

function bdcApplyFilter() { document.querySelectorAll("#bdcTable tbody tr").forEach(bdcApplyFilterToRow); }
function bdcApplyFilterToRow(tr) {
  const onlyOk = document.getElementById("bdcFilterOk").checked;
  tr.hidden = onlyOk && tr.dataset.ok !== "1";
}

function bdcHandleEvent(ev) {
  if (!ev || !ev.type) return;
  switch (ev.type) {
    case "start": {
      bdcSetStatus("инициализация (workers=" + (ev.workers || "?") + ")", true);
      bdcAppendLog("=== ByeDPI Check начат: workers=" + (ev.workers || "?") + " tests=" + (ev.tests || "?") + " ===\n");
      break;
    }
    case "resolve": {
      bdcSetStatus("резолв " + (ev.host || "") + " → " + (ev.ip || ""), true);
      bdcAppendLog("DoH " + (ev.host || "") + " → " + (ev.ip || "") + "\n");
      break;
    }
    case "resolve_fail": {
      bdcAppendLog("[resolve_fail] " + (ev.host || "") + "\n");
      break;
    }
    case "nft_ready": {
      bdcAppendLog("nft/hs5t готовы, начинаю перебор\n");
      break;
    }
    case "generating": {
      bdcAppendLog("генерирую стратегии (level=" + (ev.level || "?") + ")\n");
      bdcSetStatus("генерирую стратегии…", true);
      break;
    }
    case "generated": {
      bdcAppendLog("сгенерировано стратегий: " + (ev.count || "?") + "\n");
      bdcSetStatus("запуск воркеров…", true);
      break;
    }
    case "runner_start": {
      bdcAppendLog("runner стартует: " + (ev.cmd || "") + "\n");
      bdcSetStatus("runner стартует…", true);
      break;
    }
    case "queue": {
      const total = parseInt(ev.total || "0", 10) || 0;
      const bar = document.getElementById("bdcProgressBar");
      document.getElementById("bdcProgress").hidden = false;
      if (bar) { bar.max = total; bar.value = 0; }
      document.getElementById("bdcProgressText").textContent = "0 / " + (ev.total || "?");
      bdcSetStatus("тестирую " + (ev.total || "?") + " стратегий", true);
      bdcAppendLog("В очереди: " + (ev.total || "?") + " стратегий\n");
      break;
    }
    case "progress": {
      const done = parseInt(ev.done || "0", 10), total = parseInt(ev.total || "0", 10);
      const bar = document.getElementById("bdcProgressBar");
      if (bar && total) { bar.max = total; bar.value = done; }
      document.getElementById("bdcProgressText").textContent = done + " / " + total;
      bdcSetStatus("тестирую " + done + " / " + total, true);
      break;
    }
    case "strategy_start": {
      const cur = document.getElementById("bdcCurrent");
      if (cur) cur.textContent = "▶ " + (ev.name || "");
      break;
    }
    case "strategy": {
      bdcRenderResultsRow(ev); bdcUpdateCounts(); bdcCombinedRefresh();
      if (BDC.lastCustomTag && ev.name === BDC.lastCustomTag) {
        const cr = document.getElementById("bdcCustomResult");
        if (cr) {
          const pass = parseInt(ev.pass, 10) || 0;
          const ok = pass > 0;
          if (ok) {
            cr.textContent = "✓ pass=" + pass + " · " + (ev.detail || "");
            cr.className = "bc-custom-result ok";
          } else {
            cr.textContent = "✗ fail=" + (ev.fail || 0) + " · " + (ev.detail || "");
            cr.className = "bc-custom-result fail";
          }
        }
        BDC.lastCustomTag = null;
      }
      if ((parseInt(ev.pass, 10) || 0) > 0) {
        bdcAppendLog("[OK] " + (ev.name || "") + " (" + (ev.proto || "") + ") — " +
                     (ev.detail || "") + "\n");
      }
      break;
    }
    case "strategy_skip": {
      BDC.counts.skip++; bdcUpdateCounts();
      if (BDC.lastCustomTag && ev.name === BDC.lastCustomTag) {
        const cr = document.getElementById("bdcCustomResult");
        if (cr) {
          cr.textContent = "skip: " + (ev.reason || "strategy skipped");
          cr.title = ev.args || "";
          cr.className = "bc-custom-result fail";
        }
        BDC.lastCustomTag = null;
      }
      break;
    }
    case "error": {
      const extra = ev.runner_tail || ev.syntax_tail || ev.byedpi_tail || ev.diag || "";
      bdcAppendLog("[error] " + (ev.msg || "") + "\n" + (extra ? extra + "\n" : ""));
      bdcSetStatus("ошибка: " + (ev.msg || ""), false);
      break;
    }
    case "end": {
      bdcSetStatus("готово (" + BDC.counts.ok + " рабочих из " + BDC.results.length + ")", false);
      document.getElementById("bdcDownloadBtn").disabled = false;
      document.getElementById("bdcCurrent").textContent = "";
      bdcAppendLog("=== ByeDPI Check завершён ===\n");
      break;
    }
  }
}

function bdcCombinedRefresh() {
  const box = document.getElementById("bdcCombinedBox"), list = document.getElementById("bdcCombinedList");
  if (!box || !list) return;
  const lines = [], seen = new Set();
  BDC.results.forEach((r) => { if (parseInt(r.pass || "0", 10) > 0 && r.args && !seen.has(r.args)) { seen.add(r.args); lines.push({ args: r.args, name: r.name || "strategy" }); } });
  if (!lines.length) { box.hidden = true; return; }
  box.hidden = false;
  list.innerHTML = lines.map((item) => {
    const a = escapeAttr(item.args);
    const n = escapeAttr(item.name);
    return `<div class="bc-combined-item"><textarea class="bc-combined-args" readonly>${a}</textarea><button type="button" class="primary" data-args="${a}" data-name="${n}" onclick="bdcApplyStrategy(this)">→ BYEDPI_CMD</button><button type="button" data-args="${a}" onclick="bdcCopyStrategy(this)">⧉</button></div>`;
  }).join("");
  document.getElementById("bdcCombinedSummary").textContent = lines.length + " вариантов";
}

function bdcRenderResultsRow(ev) {
  const table = document.getElementById("bdcTable"), tbox = document.getElementById("bdcTableBox");
  if (!table) return;
  tbox.hidden = false;
  const pass = parseInt(ev.pass || "0", 10), fail = parseInt(ev.fail || "0", 10), skip = parseInt(ev.skip || "0", 10);
  const works = pass > 0;
  const key = (ev.name || "") + "|" + (ev.args || "");
  if (BDC.seenStrategies.has(key)) return;
  BDC.seenStrategies.add(key);
  BDC.results.push(ev);
  if (works) BDC.counts.ok++; else if (fail > 0) BDC.counts.fail++; else BDC.counts.skip++;
  const args = ev.args || "", a = escapeAttr(args);
  const tr = document.createElement("tr");
  tr.dataset.ok = works ? "1" : "0";
  tr.dataset.pass = String(pass);
  const apply = works ? `<button type="button" class="ghost" data-args="${a}" onclick="bdcApplyStrategy(this)">BYEDPI_CMD</button>` : "";
  tr.innerHTML = `<td><code title="${a}">${escapeAttr(ev.name || "")}</code></td><td>${escapeAttr(ev.proto || "")}</td><td>${pass}</td><td>${fail}</td><td>${skip}</td><td><small>${escapeAttr(ev.detail || "")}</small></td><td>${args ? `<button type="button" class="ghost" data-args="${a}" onclick="bdcCopyStrategy(this)">Copy</button>${apply}` : ""}</td>`;
  const tbody2 = table.querySelector("tbody");
  let inserted = false;
  for (const existing of tbody2.children) {
    const ep = parseInt(existing.dataset.pass || "0", 10);
    if (pass > ep) { tbody2.insertBefore(tr, existing); inserted = true; break; }
  }
  if (!inserted) tbody2.appendChild(tr);
  bdcApplyFilterToRow(tr);
}

function bdcDecode(b64) { return bcDecode(b64); }
function bdcFormValues() {
  const tests = [];
  if (document.getElementById("bdcTestHttp").checked) tests.push("http");
  if (document.getElementById("bdcTestTls12").checked) tests.push("tls12");
  if (document.getElementById("bdcTestTls13").checked) tests.push("tls13");
  if (document.getElementById("bdcTestQuic").checked) tests.push("quic");
  return { domains: (document.getElementById("bdcDomains").value || "").trim(), workers: parseInt(document.getElementById("bdcWorkers").value, 10) || 4, level: document.getElementById("bdcLevel").value, fakebin: document.getElementById("bdcUseFakebin").checked ? "1" : "0", hard_min_kb: parseInt(document.getElementById("bdcHardMinKb").value, 10) || 16, rnd_repeats: parseInt(document.getElementById("bdcRndRepeats").value, 10) || 2, tests };
}

function byedpiCheckCustom() {
  const args = (document.getElementById("bdcCustomArgs").value || "").trim(), v = bdcFormValues();
  if (!args) { alert("Введите аргументы byedpi"); return; }
  if (!v.domains) { alert("Укажите хотя бы один домен."); return; }
  const tests = [];
  if (document.getElementById("bdcCustomHttp").checked) tests.push("http");
  if (document.getElementById("bdcCustomTls12").checked) tests.push("tls12");
  if (document.getElementById("bdcCustomTls13").checked) tests.push("tls13");
  if (document.getElementById("bdcCustomQuic").checked) tests.push("quic");
  if (!tests.length) { alert("Выберите хотя бы один протокол."); return; }
  if (BDC.jobId && document.getElementById("bdcCancelBtn").disabled === false) { alert("Сначала остановите текущий ByeDPI Check."); return; }
  BDC.offset = 0;
  const tag = "custom_" + Date.now(); BDC.lastCustomTag = tag;
  const cr = document.getElementById("bdcCustomResult");
  if (cr) {
    cr.textContent = "(тестирую " + tests.join("/") + "…)";
    cr.className = "bc-custom-result running";
  }
  const body = new URLSearchParams();
  body.set("domains_b64", btoa(unescape(encodeURIComponent(v.domains))));
  body.set("workers", "1"); body.set("tests", tests.join(","));
  body.set("strategies_b64", btoa(unescape(encodeURIComponent(tag + "|all|" + args + "\n"))));
  body.set("level", v.level); body.set("hard_min_kb", String(v.hard_min_kb)); body.set("rnd_repeats", String(v.rnd_repeats));
  bdcPostStart(body, "custom-test запущен");
}

function byedpiCheckStart() {
  if (BDC.jobId && document.getElementById("bdcCancelBtn").disabled === false) {
    if (!window.confirm("Уже запущен job " + BDC.jobId + ". Остановить и запустить новый?")) return;
    byedpiCheckCancel(true);
  }
  const v = bdcFormValues();
  if (!v.domains) { alert("Укажите хотя бы один домен."); return; }
  if (!v.tests.length) { alert("Выберите хотя бы один тип теста."); return; }
  if (BDC.pollTimer) { clearInterval(BDC.pollTimer); BDC.pollTimer = null; }
  BDC.jobId = null; BDC.offset = 0; BDC.results = []; BDC.counts = { ok: 0, fail: 0, skip: 0 }; BDC.seenStrategies = new Set();
  document.getElementById("bdcLog").textContent = "";
  document.getElementById("bdcTable").querySelector("tbody").innerHTML = "";
  document.getElementById("bdcTableBox").hidden = true; document.getElementById("bdcCounts").hidden = true; document.getElementById("bdcProgress").hidden = true; document.getElementById("bdcCurrent").textContent = ""; document.getElementById("bdcDownloadBtn").disabled = true; document.getElementById("bdcCombinedBox").hidden = true;
  const body = new URLSearchParams();
  body.set("domains_b64", btoa(unescape(encodeURIComponent(v.domains))));
  body.set("workers", String(v.workers)); body.set("tests", v.tests.join(",")); body.set("level", v.level); body.set("fakebin", v.fakebin); body.set("hard_min_kb", String(v.hard_min_kb)); body.set("rnd_repeats", String(v.rnd_repeats));
  bdcPostStart(body, "запущен");
}

function bdcPostStart(body, okText) {
  bdcSetStatus("отправка запроса…", true);
  fetch("/cgi-bin/byedpi-check", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body.toString() })
    .then(r => r.json()).then(data => {
      if (!data.ok) { bdcSetStatus("ошибка: " + bdcDecode(data.error_b64), false); BDC.jobId = null; return; }
      BDC.jobId = data.job_id; try { localStorage.setItem(BDC_JOB_KEY, BDC.jobId); } catch (e) {}
      bdcSetStatus(okText + " job " + BDC.jobId, true);
      if (BDC.pollTimer) clearInterval(BDC.pollTimer);
      BDC.pollTimer = setInterval(byedpiCheckPoll, 700); byedpiCheckPoll();
    }).catch(err => { bdcSetStatus("ошибка запуска: " + err, false); BDC.jobId = null; });
}

function byedpiCheckPoll() {
  if (!BDC.jobId || BDC.pollInFlight) return;
  BDC.pollInFlight = true;
  fetch("/cgi-bin/byedpi-check-status?job=" + encodeURIComponent(BDC.jobId) + "&offset=" + BDC.offset)
    .then(r => r.json()).then(data => {
      BDC.pollInFlight = false;
      if (!data.ok) { bdcSetStatus("job недоступен: " + (data.error || ""), false); return; }
      BDC.offset = data.offset || BDC.offset;
      const tail = bdcDecode(data.log_b64);
      if (tail) tail.split(/\n/).forEach((line) => { if (!line.trim()) return; try { bdcHandleEvent(JSON.parse(line)); } catch (e) { bdcAppendLog(line + "\n"); } });
      if (data.status === "done" || data.status === "error" || data.status === "cancelled") {
        if (BDC.pollTimer) { clearInterval(BDC.pollTimer); BDC.pollTimer = null; }
        document.getElementById("bdcDownloadBtn").disabled = false;
        bdcSetStatus(data.status === "done" ? "готово" : data.status, false);
      }
    }).catch(err => { BDC.pollInFlight = false; bdcSetStatus("ошибка polling: " + err, false); });
}

function byedpiCheckCancel(silent) {
  if (!BDC.jobId) return;
  fetch("/cgi-bin/byedpi-check-cancel", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "job=" + encodeURIComponent(BDC.jobId) })
    .finally(() => { if (BDC.pollTimer) { clearInterval(BDC.pollTimer); BDC.pollTimer = null; } if (!silent) bdcSetStatus("остановлен", false); });
}
function byedpiCheckDownload() { if (BDC.jobId) window.location.href = "/cgi-bin/byedpi-check-status?job=" + encodeURIComponent(BDC.jobId) + "&download=1"; }
function bdcCopyStrategy(btn) {
  const args = btn.dataset.args || ""; if (!args) return;
  const ok = () => { btn.textContent = "✓"; setTimeout(() => { btn.textContent = "⧉"; }, 900); };
  if (navigator.clipboard) navigator.clipboard.writeText(args).then(ok).catch(() => bcCopyFallback(args, ok)); else bcCopyFallback(args, ok);
}
function bdcApplyStrategy(btn) {
  const args = btn.dataset.args || "";
  const name = btn.dataset.name || "strategy";
  if (!args || typeof addRow !== "function") return;
  const wrap = document.getElementById("byedpi");
  if (!wrap) return;

  const before = new Set([...wrap.querySelectorAll(".env-row")].map(r => r));
  addRow("byedpi", "BYEDPI_CMD", false);

  let target = null;
  for (const r of wrap.querySelectorAll(".env-row")) {
    if (!before.has(r)) { target = r; break; }
  }
  if (!target) target = wrap.querySelector(".env-row:last-child");
  if (!target) return;

  const input = target.querySelector('input[name^="BYEDPI_CMD"]');
  if (!input) return;
  input.value = args;
  input.dispatchEvent(new Event("input",  { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));

  if (typeof showToast === "function") {
    showToast("Стратегия «" + name + "» добавлена в BYEDPI_CMD. Сохраните, чтобы применить.");
  }
}
function bdcCopyAllCombined(ev) { _bcCopyAllText([...document.querySelectorAll('#bdcCombinedList .bc-combined-args')].map(t => t.value).join('\n'), ev.target); }
function bdcCopyAllTable(ev) {
  const lines = [...document.querySelectorAll('#bdcTable tbody tr')].filter(tr => !tr.hidden).map(tr => {
    const cells = tr.querySelectorAll('td');
    return [...cells].slice(0, 6).map(td => td.innerText.trim()).join('\t');
  });
  _bcCopyAllText(lines.join('\n'), ev.target);
}
function bdcCopyAllLog(ev) { const pre = document.getElementById('bdcLog'); _bcCopyAllText(pre ? (pre.textContent || '') : '', ev.target); }

// (blockcheck1Preview removed — generated count is shown right in the
//  level dropdown labels; running gen-strategies twice was redundant.)

// ===== Copy-all helpers for both Blockcheck and Blockcheck1 =====

function _bcCopyAllText(text, anchorBtn) {
  if (!text) return;
  const ok = () => {
    if (!anchorBtn) return;
    const orig = anchorBtn.textContent;
    anchorBtn.textContent = "✓";
    setTimeout(() => { anchorBtn.textContent = orig; }, 1200);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(ok).catch(() => bcCopyFallback(text, ok));
  } else {
    bcCopyFallback(text, ok);
  }
}

function bcCopyAllCombined(ev) {
  const btn = ev && ev.target;
  const lines = [...document.querySelectorAll('#bcCombinedList .bc-combined-args')].map(t => t.value);
  _bcCopyAllText(lines.join('\n'), btn);
}
function bcCopyAllTable(ev) {
  const btn = ev && ev.target;
  const tbody = document.querySelector('#bcTable tbody');
  if (!tbody) return;
  const lines = [...tbody.querySelectorAll('tr')].filter(tr => !tr.hidden).map(tr => {
    const tds = tr.querySelectorAll('td');
    const name = (tds[0]?.textContent || '').trim();
    const proto = (tds[1]?.textContent || '').trim();
    const pass = (tds[2]?.textContent || '').trim();
    const fail = (tds[3]?.textContent || '').trim();
    const skip = (tds[4]?.textContent || '').trim();
    const det = (tds[5]?.textContent || '').trim();
    const argsBtn = tds[6]?.querySelector('button[data-args]');
    const args = argsBtn ? argsBtn.dataset.args : '';
    return `[${proto}] ${name}\n  pass=${pass} fail=${fail} skip=${skip}\n  detail: ${det}\n  args:   ${args}`;
  });
  _bcCopyAllText(lines.join('\n\n'), btn);
}
function bcCopyAllLog(ev) {
  const btn = ev && ev.target;
  const pre = document.getElementById('bcLog');
  _bcCopyAllText(pre ? (pre.textContent || '') : '', btn);
}

function bc1CopyAllCombined(ev) {
  const btn = ev && ev.target;
  const lines = [...document.querySelectorAll('#bc1CombinedList .bc-combined-args')].map(t => t.value);
  _bcCopyAllText(lines.join('\n'), btn);
}
function bc1CopyAllTable(ev) {
  const btn = ev && ev.target;
  const tbody = document.querySelector('#bc1Table tbody');
  if (!tbody) return;
  const lines = [...tbody.querySelectorAll('tr')].filter(tr => !tr.hidden).map(tr => {
    const tds = tr.querySelectorAll('td');
    const name = (tds[0]?.textContent || '').trim();
    const proto = (tds[1]?.textContent || '').trim();
    const pass = (tds[2]?.textContent || '').trim();
    const fail = (tds[3]?.textContent || '').trim();
    const skip = (tds[4]?.textContent || '').trim();
    const det = (tds[5]?.textContent || '').trim();
    const argsBtn = tds[6]?.querySelector('button[data-args]');
    const args = argsBtn ? argsBtn.dataset.args : '';
    return `[${proto}] ${name}\n  pass=${pass} fail=${fail} skip=${skip}\n  detail: ${det}\n  args:   ${args}`;
  });
  _bcCopyAllText(lines.join('\n\n'), btn);
}
function bc1CopyAllLog(ev) {
  const btn = ev && ev.target;
  const pre = document.getElementById('bc1Log');
  _bcCopyAllText(pre ? (pre.textContent || '') : '', btn);
}
