(function () {
  "use strict";
  const api = window.microcrab, $ = (id) => document.getElementById(id);
  let state = {}, config = { provider: "google", source: "auto", target: "zh-CN", model: "", temperature: 0.3, prompt: "", auto_translate: false, assistant_only: true, display_mode: "inline", skip_same_language: true }, dirty = new Set(), operation = "", sequence = 0;
  const operationPrefix = "ui-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
  const words = {
    "zh-CN": { display: "显示格式", inline: "译文", after: "原文+译文", behavior: "翻译行为", auto: "自动翻译已完成的内容", assistant: "仅翻译助手回复", assistantHint: "默认开启。关闭后也会翻译已完成的用户文本，并在原文后追加译文卡片；不会替换输入、重新发送消息或修改历史。工具和推理内容仍不翻译。", skip: "高置信度同语言时跳过翻译", title: "输出翻译", intro: "管理翻译引擎及连接配置。", provider: "翻译引擎", custom: "自定义兼容接口", endpoint: "接口地址", model: "模型", key: "新 API 密钥", keyHint: "留空保留已保存密钥。密钥仅随明确保存发送，提交后立即清空，不会回显。", clearKey: "清除已保存密钥", advanced: "高级参数", temperature: "温度（0–1.5）", prompt: "系统提示词", promptHint: "使用 {targetLang} 表示目标语言。", save: "保存配置", test: "测试已保存配置", reset: "放弃修改", timing: "测试仅显示实际总耗时。", ready: "已就绪", missing: "需要保存接口配置及授权", draft: "有未保存的修改", pending: "正在等待保存确认…", unknown: "保存结果尚未确认，请保留此页面，不要重复提交。", applied: "配置已保存", invalid: "请输入完整 HTTP(S) 地址，且不要在地址中包含凭据。", unavailable: "无法提交，请重新打开此页面。" },
    en: { display: "Display format", inline: "Translation", after: "Original + translation", behavior: "Translation behavior", auto: "Translate completed blocks automatically", assistant: "Assistant responses only", assistantHint: "Enabled by default. Turning this off also translates completed user text and appends a translation card after the original. It does not replace input, resend messages or change history. Tools and reasoning remain excluded.", skip: "Skip translation when confidently in the target language", title: "Output translator", intro: "Manage translation engines and connection configuration.", provider: "Translation engine", custom: "Custom compatible endpoint", endpoint: "Endpoint URL", model: "Model", key: "New API key", keyHint: "Leave blank to retain the saved key. Sent only on explicit Save, cleared after submission, and never echoed back.", clearKey: "Clear saved key", advanced: "Advanced parameters", temperature: "Temperature (0–1.5)", prompt: "System prompt", promptHint: "Use {targetLang} for the target language.", save: "Save configuration", test: "Test saved configuration", reset: "Discard changes", timing: "Tests display actual total duration only.", ready: "Ready", missing: "Save connection configuration and authorization first", draft: "Unsaved changes", pending: "Waiting for save confirmation…", unknown: "Save outcome is not confirmed. Keep this page open; do not resubmit.", applied: "Configuration saved", invalid: "Enter a full HTTP(S) URL without embedded credentials.", unavailable: "Unable to submit. Reopen this page." }
  };
  const language = () => String(state.locale || "zh-CN").startsWith("en") ? "en" : "zh-CN";
  const t = (key) => words[language()][key];
  const resource = () => (state.resources || []).find((item) => item.id === $("provider").value);
  const locked = () => Boolean(operation || state.pending);
  function error(text) { $("local-error").textContent = text; $("local-error").hidden = !text; }
  function render() {
    document.documentElement.lang = language();
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    document.querySelectorAll("[data-field]").forEach((el) => { if (!dirty.has(el.dataset.field)) { if (el.type === "checkbox") el.checked = Boolean(config[el.dataset.field]); else el.value = config[el.dataset.field] ?? ""; } });
    const provider = $("provider").value, paid = provider === "siliconflow" || provider === "custom", saved = resource();
    if (!dirty.has("endpoint")) $("endpoint").value = saved?.endpoint || (provider === "siliconflow" ? "https://api.siliconflow.cn/v1/chat/completions" : "");
    $("engine-fields").hidden = !paid; $("key-link").hidden = provider !== "siliconflow";
    $("readiness").textContent = t(!paid || saved?.enabled && !saved.requires_reenable ? "ready" : "missing");
    $("draft-status").textContent = operation ? t(state.save?.operation_id === operation && state.save.status === "unknown" ? "unknown" : "pending") : dirty.size ? t("draft") : "";
    $("host-status").textContent = state.status || ""; $("host-status").hidden = !state.status;
    document.querySelectorAll("[data-field],#api-key,#clear-key,#save,#reset").forEach((el) => { el.disabled = locked() || !paid && ["endpoint", "model", "temperature", "prompt", "api-key", "clear-key"].includes(el.id); });
    $("api-key").disabled = locked() || !paid || $("clear-key").checked;
    $("test").disabled = locked() || dirty.size > 0 || state.test?.status === "pending";
    const testStatus = state.test?.status;
    const testLabels = language() === "en" ? { pending: "Testing saved configuration…", completed: "Connection test completed", error: "Connection test failed" } : { pending: "正在测试已保存配置…", completed: "连接测试完成", error: "连接测试失败" };
    $("test-status").textContent = (testLabels[testStatus] || "") + (testStatus === "completed" && Number.isFinite(state.test.duration_ms) && state.test.duration_ms >= 0 ? " · " + Math.round(state.test.duration_ms) + " ms" : "");
  }
  document.querySelectorAll("[data-field]").forEach((el) => el.addEventListener("input", () => { dirty.add(el.dataset.field); if (el.id === "provider") { $("api-key").value = ""; $("clear-key").checked = false; dirty.delete("credential"); } error(""); render(); }));
  $("api-key").addEventListener("input", () => { dirty.add("credential"); render(); });
  $("clear-key").addEventListener("change", () => { $("api-key").value = ""; dirty.add("credential"); render(); });
  $("save").addEventListener("click", (event) => {
    event.preventDefault(); if (locked() || !$("settings-form").reportValidity()) return;
    const submitted = { ...config };
    document.querySelectorAll("[data-field]").forEach((el) => { if (el.id !== "endpoint") submitted[el.dataset.field] = el.type === "checkbox" ? el.checked : el.id === "temperature" ? Number(el.value) : el.value; });
    if (["siliconflow", "custom"].includes(submitted.provider)) {
      try { const url = new URL($("endpoint").value); if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new Error(); } catch { error(t("invalid")); return; }
    }
    operation = operationPrefix + "-" + (++sequence).toString(36);
    try {
      api.action("settings.save", { operation_id: operation, config: submitted, endpoint: $("endpoint").value, authorization: $("api-key").value ? (/^Bearer\s/i.test($("api-key").value) ? $("api-key").value : "Bearer " + $("api-key").value) : "", clear_authorization: $("clear-key").checked });
    } catch { operation = ""; error(t("unavailable")); }
    finally { $("api-key").value = ""; }
    render();
  });
  $("test").addEventListener("click", () => { if (!locked() && !dirty.size) { try { api.action("test", {}); } catch { error(t("unavailable")); } } });
  $("reset").addEventListener("click", () => { if (locked()) return; dirty.clear(); $("api-key").value = ""; $("clear-key").checked = false; error(""); render(); });
  window.addEventListener("pagehide", () => { $("api-key").value = ""; });
  api.onViewState((next) => {
    if (!next || typeof next !== "object") return; state = next; config = { ...config, ...(next.config || {}) };
    const receipt = next.save;
    if (operation && receipt?.operation_id === operation) {
      if (receipt.status === "applied") { operation = ""; dirty.clear(); $("clear-key").checked = false; error(""); }
      else if (receipt.status === "failed") { operation = ""; error(receipt.error || next.status || t("unavailable")); }
      else if (receipt.status === "unknown") error(receipt.error || t("unknown"));
    }
    render();
  });
  render();
})();
