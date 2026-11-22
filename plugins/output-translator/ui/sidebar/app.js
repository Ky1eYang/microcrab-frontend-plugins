(function () {
  "use strict";
  const api = window.microcrab, $ = (id) => document.getElementById(id);
  let state = {}, config = { provider: "google", source: "auto", target: "zh-CN", model: "", temperature: 0.3, prompt: "", auto_translate: false, assistant_only: true, display_mode: "inline", skip_same_language: true }, dirty = new Set();
  const words = {
    "zh-CN": { display: "显示格式", inline: "译文", after: "原文+译文", behavior: "翻译行为", auto: "自动翻译已完成的内容", assistant: "仅翻译助手回复", assistantHint: "默认开启。关闭后也会翻译已完成的用户文本，并在原文后追加译文卡片；不会替换输入、重新发送消息或修改历史。工具和推理内容仍不翻译。", skip: "高置信度同语言时跳过翻译", title: "翻译控制", intro: "在回复完成后翻译，保留原文。", source: "源语言", target: "目标语言", swap: "交换", provider: "翻译引擎", apply: "应用", metrics: "本次会话", count: "已翻译内容", duration: "平均总耗时", purge: "清空会话翻译缓存", unavailable: "无法提交，请重新打开此页面。", needsKey: "需要配置", custom: "自定义接口", pending: "正在处理…" },
    en: { display: "Display format", inline: "Translation", after: "Original + translation", behavior: "Translation behavior", auto: "Translate completed blocks automatically", assistant: "Assistant responses only", assistantHint: "Enabled by default. Turning this off also translates completed user text and appends a translation card after the original. It does not replace input, resend messages or change history. Tools and reasoning remain excluded.", skip: "Skip translation when confidently in the target language", title: "Translation controls", intro: "Translate completed responses while retaining the original.", source: "Source language", target: "Target language", swap: "Swap", provider: "Translation engine", apply: "Apply", metrics: "This conversation", count: "Translated blocks", duration: "Average total duration", purge: "Clear conversation translation cache", unavailable: "Unable to submit. Reopen this page.", needsKey: "Setup required", custom: "Custom endpoint", pending: "Working…" }
  };
  const languages = { "auto": ["自动检测", "Auto detect"], "en": ["英语", "English"], "zh-CN": ["简体中文", "Simplified Chinese"], "zh-TW": ["繁体中文", "Traditional Chinese"], "ja": ["日语", "Japanese"], "ko": ["韩语", "Korean"], "fr": ["法语", "French"], "de": ["德语", "German"], "es": ["西班牙语", "Spanish"], "pt": ["葡萄牙语", "Portuguese"], "it": ["意大利语", "Italian"], "ru": ["俄语", "Russian"], "ar": ["阿拉伯语", "Arabic"] };
  const lang = () => String(state.locale || "zh-CN").startsWith("en") ? "en" : "zh-CN";
  const t = (key) => words[lang()][key];
  function feedback(text) { $("feedback").textContent = text; $("feedback").hidden = !text; }
  function options(select, entries) {
    const signature = JSON.stringify(entries);
    if (select.dataset.options === signature) return;
    const value = select.value;
    select.replaceChildren(...entries.map(([id, label]) => { const option = document.createElement("option"); option.value = id; option.textContent = label; return option; }));
    select.value = value;
    select.dataset.options = signature;
  }
  function render() {
    document.documentElement.lang = lang();
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    ["source", "target"].forEach((id) => {
      options($(id), Object.entries(languages).filter(([key]) => id === "source" || key !== "auto").map(([key, names]) => [key, names[lang() === "en" ? 1 : 0]]));
    });
    options($("provider"), [["google", "Google GTX"], ["mymemory", "MyMemory"], ["siliconflow", "SiliconFlow AI"], ["custom", t("custom")]].map(([id, label]) => { const resource = (state.resources || []).find((item) => item.id === id); return [id, label + (["siliconflow", "custom"].includes(id) && !(resource?.enabled && !resource.requires_reenable) ? " · " + t("needsKey") : "")]; }));
    ["source", "target", "provider", "auto_translate", "assistant_only", "display_mode", "skip_same_language"].forEach((id) => {
      if (!dirty.has(id)) { if ($(id).type === "checkbox") $(id).checked = Boolean(config[id]); else $(id).value = config[id]; }
      $(id).disabled = Boolean(state.pending);
    });
    $("swap").disabled = Boolean(state.pending) || $("source").value === "auto";
    $("apply").disabled = $("purge").disabled = Boolean(state.pending);
    const metrics = state.stats || {};
    $("translated").textContent = Number.isFinite(metrics.translated) ? String(metrics.translated) : "—";
    $("average").textContent = Number.isFinite(metrics.average_ms) ? Math.round(metrics.average_ms) + " ms" : "—";
    feedback(state.error || state.status || (state.pending ? t("pending") : ""));
  }
  ["source", "target", "provider", "auto_translate", "assistant_only", "display_mode", "skip_same_language"].forEach((id) => $(id).addEventListener("change", () => { dirty.add(id); render(); }));
  function submit() {
    if (state.pending) return;
    const next = { ...config };
    ["source", "target", "provider", "auto_translate", "assistant_only", "display_mode", "skip_same_language"].forEach((id) => { next[id] = $(id).type === "checkbox" ? $(id).checked : $(id).value; });
    try { api.action("control", next); } catch { feedback(t("unavailable")); }
  }
  $("apply").addEventListener("click", (event) => { event.preventDefault(); submit(); });
  $("control-form").addEventListener("submit", (event) => event.preventDefault());
  $("swap").addEventListener("click", () => { if (state.pending || $("source").value === "auto") return; const value = $("source").value; $("source").value = $("target").value; $("target").value = value; dirty.add("source"); dirty.add("target"); render(); submit(); });
  $("purge").addEventListener("click", () => { if (!state.pending) { try { api.action("cache.clear", {}); } catch { feedback(t("unavailable")); } } });
  api.onViewState((next) => {
    if (!next || typeof next !== "object") return;
    state = next; config = { ...config, ...(next.config || {}) };
    dirty.forEach((id) => { const value = $(id).type === "checkbox" ? $(id).checked : $(id).value; if (value === config[id]) dirty.delete(id); });
    render();
  });
  render();
})();
