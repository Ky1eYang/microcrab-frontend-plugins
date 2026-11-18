(function () {
  "use strict";
  const api = window.microcrab, $ = (id) => document.getElementById(id);
  let state = {}, collapsed = false, rendered = null, identity = "", copyGeneration = 0;
  const words = {
    "zh-CN": { skipped: "已跳过翻译", force: "强制翻译", copy: "复制译文", retry: "重新翻译", retryError: "重试", collapse: "收起", expand: "展开", pending: "正在翻译…", completed: "翻译完成", cancelled: "翻译已取消", error: "翻译失败", copied: "译文已复制", copying: "正在复制…", copyUnavailable: "当前环境无法直接复制，请选择下方译文手动复制。", raw: "原始译文（可选择并复制）", unavailable: "无法提交，请重新打开此页面。", total: "总耗时", custom: "自定义接口" },
    en: { skipped: "Translation skipped", force: "Force translation", copy: "Copy translation", retry: "Retranslate", retryError: "Retry", collapse: "Collapse", expand: "Expand", pending: "Translating…", completed: "Translation completed", cancelled: "Translation cancelled", error: "Translation failed", copied: "Translation copied", copying: "Copying…", copyUnavailable: "Direct copying is unavailable. Select the translation below and copy it manually.", raw: "Raw translation (select to copy)", unavailable: "Unable to submit. Reopen this page.", total: "Total duration", custom: "Custom endpoint" }
  };
  const language = () => String(state.locale || "zh-CN").startsWith("en") ? "en" : "zh-CN";
  const t = (key) => words[language()][key];
  const node = (tag, text) => { const el = document.createElement(tag); if (text !== undefined) el.textContent = text; return el; };
  // Bounded, deliberately passive Markdown subset. Raw HTML, links and images
  // remain literal text; no untrusted value is interpreted as DOM markup or URL.
  function inline(parent, text) {
    if (text.length > 2048) { parent.append(document.createTextNode(text)); return; }
    const pattern = /(`{1,8})([^`\n]{1,2048})\1|\*\*([^*\n]{1,2048})\*\*|\*([^*\n]{1,2048})\*/g;
    let previous = 0, match;
    while ((match = pattern.exec(text))) {
      parent.append(document.createTextNode(text.slice(previous, match.index)));
      parent.append(node(match[2] !== undefined ? "code" : match[3] !== undefined ? "strong" : "em", match[2] ?? match[3] ?? match[4]));
      previous = pattern.lastIndex;
    }
    parent.append(document.createTextNode(text.slice(previous)));
  }
  function markdown(text) {
    const fragment = document.createDocumentFragment(), lines = text.split(/\r?\n/);
    let index = 0, count = 0;
    while (index < lines.length && count++ < 1024) {
      const line = lines[index++];
      if (!line.trim()) continue;
      const fence = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
      if (fence) {
        const content = [], marker = fence[1][0], length = fence[1].length;
        while (index < lines.length) { const next = lines[index++]; if (new RegExp("^\\s{0,3}" + marker + "{" + length + ",}\\s*$").test(next)) break; content.push(next); }
        const pre = node("pre"); pre.append(node("code", content.join("\n"))); fragment.append(pre); continue;
      }
      const heading = line.match(/^\s{0,3}(#{1,6})\s+(.+)$/);
      if (heading) { const el = node("h" + heading[1].length); inline(el, heading[2]); fragment.append(el); continue; }
      const list = line.match(/^\s*([-+*]|\d+[.)])\s+(.+)$/);
      if (list) {
        const ordered = /^\d/.test(list[1]), el = node(ordered ? "ol" : "ul");
        let current = list;
        while (current) { const li = node("li"); inline(li, current[2]); el.append(li); const candidate = (lines[index] || "").match(/^\s*([-+*]|\d+[.)])\s+(.+)$/); if (!candidate || /^\d/.test(candidate[1]) !== ordered) break; current = candidate; index++; }
        fragment.append(el); continue;
      }
      if (/^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/.test(line)) { fragment.append(node("hr")); continue; }
      const quote = line.match(/^\s{0,3}>\s?(.*)$/), el = node(quote ? "blockquote" : "p"); inline(el, quote ? quote[1] : line); fragment.append(el);
    }
    if (index < lines.length) fragment.append(node("pre", lines.slice(index).join("\n")));
    $("markdown").replaceChildren(fragment);
  }
  function message(text) { $("copy-status").textContent = text; $("copy-status").hidden = !text; }
  function fallback(reason) {
    collapsed = false; render();
    message(t("copyUnavailable") + (reason ? " " + reason : ""));
    $("raw-fallback").hidden = false; $("raw").value = state.translation || ""; $("raw").focus(); $("raw").select();
  }
  function render() {
    document.documentElement.lang = language();
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    $("provider").textContent = ({ google: "Google GTX", mymemory: "MyMemory", siliconflow: "SiliconFlow AI", custom: t("custom") })[state.provider] || String(state.provider || "");
    $("languages").textContent = state.source && state.target ? state.source + " → " + state.target : "";
    $("duration").textContent = state.status === "completed" && Number.isFinite(state.duration_ms) && state.duration_ms >= 0 ? t("total") + " " + Math.round(state.duration_ms) + " ms" : "";
    $("status").textContent = t(["pending", "completed", "error", "cancelled", "skipped"].includes(state.status) ? state.status : "pending");
    $("skeleton").hidden = state.status !== "pending";
    $("error").textContent = state.error || ""; $("error").hidden = !state.error;
    $("markdown").hidden = state.status !== "completed";
    $("retry").textContent = t(state.status === "skipped" ? "force" : state.status === "error" || state.status === "cancelled" ? "retryError" : "retry");
    $("retry").disabled = !state.block_id || state.status === "pending";
    $("copy").disabled = state.status !== "completed" || typeof state.translation !== "string";
    $("collapse").textContent = t(collapsed ? "expand" : "collapse"); $("collapse").setAttribute("aria-expanded", String(!collapsed)); $("translation-body").hidden = collapsed;
    const text = state.status === "completed" ? String(state.translation || "") : "";
    if (text !== rendered) { rendered = text; markdown(text); $("raw").value = text; $("raw-fallback").hidden = true; message(""); copyGeneration++; }
  }
  $("collapse").addEventListener("click", () => { collapsed = !collapsed; render(); });
  $("retry").addEventListener("click", () => { if (state.block_id && state.status !== "pending") { try { api.action(state.status === "skipped" ? "block.force" : "block.retry", { block_id: state.block_id }); } catch { message(t("unavailable")); } } });
  $("copy").addEventListener("click", () => {
    if (state.status !== "completed") return;
    const generation = ++copyGeneration;
    if (typeof api.copyText !== "function") { fallback(""); return; }
    try {
      // Invoke immediately in the trusted click; do not defer behind another promise.
      const result = api.copyText(String(state.translation || "")); message(t("copying"));
      Promise.resolve(result).then(() => { if (generation === copyGeneration) message(t("copied")); }, (error) => { if (generation === copyGeneration) fallback(error instanceof Error ? error.message : String(error)); });
    } catch (error) { fallback(error instanceof Error ? error.message : String(error)); }
  });
  api.onViewState((next) => {
    if (!next || typeof next !== "object") return;
    if (identity && identity !== next.block_id) { collapsed = false; rendered = null; copyGeneration++; }
    identity = next.block_id; state = next; render();
  });
  render();
})();
