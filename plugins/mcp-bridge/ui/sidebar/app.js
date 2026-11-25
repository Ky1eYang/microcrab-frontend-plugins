(function () {
  "use strict";
  const api = window.microcrab;
  const $ = (id) => document.getElementById(id);
  let state = { locale: "zh-CN", session_id: "", has_session: false, services: [], records: [], metrics: {}, page: 0, total_records: 0, selected_id: null, detail: null };
  const dictionaries = {
    "zh-CN": {
      servicesTitle: "已启用的服务", servicesEmpty: "没有已启用的 MCP 服务。", serviceUnchecked: "未检测", serviceChecking: "正在检查", serviceConnected: "已连接", serviceUnavailable: "不可用", tools: (n) => `${n} 个工具`, checked: (s) => `检查时间：${s}`,
      title: "工具调用记录", clear: "清空记录", retention: "仅保留当前会话最近 128 条记录；切换会话或刷新后清空。", metrics: "保留记录统计", total: "调用数", successRate: "成功率", average: "平均耗时", noSession: "打开会话后，可查看本次会话的工具调用记录。", empty: "当前没有调用记录。", previous: "上一页", next: "下一页", pagination: "调用记录分页", pending: "进行中", completed: "已完成", failed: "失败", cancelled: "已取消", unknown: "结果不确定", unknownNotice: "操作可能已产生效果。请先核实结果，再决定是否重新调用。", arguments: "参数", output: "输出", close: "收起详情", loading: "正在读取详情…", selectHint: "可直接选择下方原文。", nextChunk: "下一片段", firstChunk: "返回首片段", omitted: "当前片段仅显示部分原文。", duration: (n) => `${n} 毫秒`, turn: (n) => `轮次 ${n}`, round: (n) => `步骤 ${n}`, page: (p, count) => `第 ${p} / ${count} 页`, chunk: (start, end, total) => `原文片段 · 字节 ${start}–${end} / ${total}`, more: "后续还有内容，请读取下一片段。", unavailable: "无法提交，请重新打开此页面。"
    },
    en: {
      servicesTitle: "Enabled services", servicesEmpty: "No enabled MCP services.", serviceUnchecked: "Not tested", serviceChecking: "Checking", serviceConnected: "Connected", serviceUnavailable: "Unavailable", tools: (n) => `${n} tools`, checked: (s) => `Checked: ${s}`,
      title: "Tool call history", clear: "Clear history", retention: "Only the latest 128 calls in this session are retained. Switching sessions or refreshing clears them.", metrics: "Retained-window metrics", total: "Calls", successRate: "Success rate", average: "Avg. duration", noSession: "Open a conversation to observe its tool calls.", empty: "No calls in the current history.", previous: "Previous page", next: "Next page", pagination: "Call history pages", pending: "Pending", completed: "Completed", failed: "Failed", cancelled: "Cancelled", unknown: "Outcome unknown", unknownNotice: "This operation may have taken effect. Verify the outcome before deciding whether to call it again.", arguments: "Arguments", output: "Output", close: "Close details", loading: "Loading details…", selectHint: "Select the original text below directly.", nextChunk: "Next chunk", firstChunk: "First chunk", omitted: "Only part of the source is shown in this chunk.", duration: (n) => `${n} ms`, turn: (n) => `Turn ${n}`, round: (n) => `Round ${n}`, page: (p, count) => `Page ${p} of ${count}`, chunk: (start, end, total) => `Source chunk · bytes ${start}–${end} of ${total}`, more: "More content follows. Read the next chunk to continue.", unavailable: "Unable to submit. Reopen this page."
    }
  };
  const language = () => String(state.locale).startsWith("en") ? "en" : "zh-CN";
  const t = (key, ...args) => typeof dictionaries[language()][key] === "function" ? dictionaries[language()][key](...args) : dictionaries[language()][key];
  function node(tag, text, className) {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  }
  function action(name, payload) {
    try { api.action(name, payload); }
    catch { $("sidebar-error").textContent = t("unavailable"); $("sidebar-error").hidden = false; }
  }
  function button(text, testid, handler) {
    const element = node("button", text);
    element.type = "button";
    element.dataset.testid = testid;
    element.addEventListener("click", handler);
    return element;
  }
  function inspect(id, field, offset) { action("inspect-history", { id, field, offset }); }
  const serviceStatusLabels = new Map([
    ["unchecked", "serviceUnchecked"], ["checking", "serviceChecking"],
    ["connected", "serviceConnected"], ["unavailable", "serviceUnavailable"]
  ]);
  function renderServices() {
    const list = $("services-list");
    list.replaceChildren();
    const services = Array.isArray(state.services) ? state.services : [];
    for (const service of services.slice(0, 32)) {
      if (typeof service?.id !== "string") continue;
      const row = node("li", undefined, "service-row");
      row.dataset.testid = "enabled-service-row";
      const id = node("span", service.id, "service-id");
      id.title = service.id;
      const status = serviceStatusLabels.has(service.status) ? service.status : "unavailable";
      const label = node("span", t(serviceStatusLabels.get(status)), `service-status ${status}`);
      label.dataset.testid = "enabled-service-status";
      row.append(id, label);
      const parts = [];
      if (Number.isFinite(service.tool_count)) parts.push(t("tools", new Intl.NumberFormat(language()).format(service.tool_count)));
      if (Number.isFinite(service.checked_at_ms)) {
        const date = new Date(service.checked_at_ms);
        if (Number.isFinite(date.getTime())) parts.push(t("checked", date.toLocaleString(language())));
      }
      if (parts.length) row.append(node("span", parts.join(" · "), "service-meta"));
      list.append(row);
    }
    list.hidden = !list.childElementCount;
    $("services-empty").hidden = Boolean(list.childElementCount || state.error);
  }
  function render() {
    document.documentElement.lang = language();
    document.querySelectorAll("[data-i18n]").forEach((element) => { element.textContent = t(element.dataset.i18n); });
    renderServices();
    $("history-pagination").setAttribute("aria-label", t("pagination"));
    const metrics = state.metrics || {};
    $("metric-total").textContent = String(metrics.total ?? 0);
    $("metric-success-rate").textContent = Number.isFinite(metrics.success_rate) ? new Intl.NumberFormat(language(), { style: "percent", maximumFractionDigits: 1 }).format(metrics.success_rate) : "—";
    $("metric-average-duration").textContent = Number.isFinite(metrics.avg_duration_ms) ? t("duration", Math.round(metrics.avg_duration_ms)) : "—";
    $("sidebar-error").textContent = state.error || "";
    $("sidebar-error").hidden = !state.error;
    $("no-session").hidden = Boolean(state.has_session);
    $("history-empty").hidden = !state.has_session || state.total_records > 0;
    $("clear-history").disabled = !state.has_session || !state.total_records;
    const pageCount = Math.max(1, Math.ceil((state.total_records || 0) / 10));
    $("history-pagination").hidden = !state.has_session || !state.total_records;
    $("history-page").textContent = t("page", state.page + 1, pageCount);
    $("history-prev").disabled = state.page <= 0;
    $("history-next").disabled = state.page + 1 >= pageCount;
    const list = $("history-records");
    const active = document.activeElement;
    const focusKey = list.contains(active) ? [active.closest("[data-record-id]")?.dataset.recordId, active.dataset.testid] : null;
    // Retain a native text selection while an unrelated record update arrives.
    const selectedText = window.getSelection();
    const selection = selectedText && !selectedText.isCollapsed && list.contains(selectedText.anchorNode) ? { anchor: selectedText.anchorOffset, focus: selectedText.focusOffset, id: selectedText.anchorNode.parentElement?.closest("[data-record-id]")?.dataset.recordId, text: selectedText.anchorNode.textContent } : null;
    list.replaceChildren();
    if (state.has_session) state.records.slice(0, 10).forEach((record, index) => {
      const row = node("article", undefined, "record");
      row.dataset.testid = "history-row";
      row.dataset.recordId = record.id;
      const selected = state.selected_id === record.id;
      const detailId = `history-detail-${index}`;
      const summary = button("", "history-summary", () => selected ? action("close-history", {}) : inspect(record.id, "arguments", 0));
      summary.className = "record-summary";
      summary.setAttribute("aria-expanded", String(selected));
      summary.setAttribute("aria-controls", detailId);
      summary.append(node("span", record.tool, "tool"));
      const meta = node("span", undefined, "record-meta");
      const status = ["pending", "completed", "failed", "cancelled"].includes(record.status) ? record.status : "";
      meta.append(node("span", record.server), node("span", status ? t(status) : record.status, "badge " + status));
      if (record.outcome_unknown) meta.append(node("span", t("unknown"), "badge unknown"));
      if (Number.isFinite(record.duration_ms)) meta.append(node("span", t("duration", Math.round(record.duration_ms))));
      if (Number.isFinite(record.start_time_ms)) {
        const timestamp = node("time", new Date(record.start_time_ms).toLocaleTimeString(language()));
        const date = new Date(record.start_time_ms);
        if (!Number.isNaN(date.getTime())) { timestamp.dateTime = date.toISOString(); timestamp.title = date.toLocaleString(language()); }
        meta.append(timestamp);
      }
      if (record.turn_id !== undefined && record.turn_id !== null) meta.append(node("span", t("turn", record.turn_id)));
      if (record.round_id !== undefined && record.round_id !== null) meta.append(node("span", t("round", record.round_id)));
      summary.append(meta);
      row.append(summary);
      const panel = node("section", undefined, "inspector");
      panel.id = detailId;
      panel.hidden = !selected;
      if (selected) {
        const detail = state.detail;
        const controls = node("div", undefined, "inspector-toolbar");
        ["arguments", "output"].forEach((field) => {
          const tab = button(t(field), `inspect-${field}`, () => inspect(record.id, field, 0));
          tab.setAttribute("aria-pressed", String(detail?.field === field));
          controls.append(tab);
        });
        controls.append(button(t("close"), "close-history", () => action("close-history", {})));
        panel.append(controls);
        if (record.outcome_unknown) panel.append(node("p", t("unknownNotice"), "notice unknown"));
        if (!detail) panel.append(node("p", t("loading"), "hint"));
        else {
          const bytes = new TextEncoder().encode(detail.source).length;
          panel.append(node("p", t("chunk", detail.offset, detail.offset + bytes, detail.total_bytes), "chunk-marker"), node("p", t("selectHint"), "hint"));
          const source = node("pre", detail.source);
          source.dataset.testid = "history-detail-source";
          source.tabIndex = 0;
          source.setAttribute("aria-label", t(detail.field));
          panel.append(source);
          if (detail.omitted) { const marker = node("p", t("omitted"), "notice unknown"); marker.dataset.testid = "history-truncated"; panel.append(marker); }
          if (detail.next_offset !== null && Number.isFinite(detail.next_offset)) {
            panel.append(node("p", t("more"), "chunk-marker"), button(t("nextChunk"), "history-next-chunk", () => inspect(record.id, detail.field, detail.next_offset)));
          }
          if (detail.offset > 0) panel.append(button(t("firstChunk"), "history-first-chunk", () => inspect(record.id, detail.field, 0)));
        }
      }
      row.append(panel);
      list.append(row);
    });
    if (focusKey) {
      const row = Array.from(list.children).find((element) => element.dataset.recordId === focusKey[0]);
      row?.querySelector(`[data-testid="${focusKey[1]}"]`)?.focus({ preventScroll: true });
    }
    if (selection) {
      const row = Array.from(list.children).find((element) => element.dataset.recordId === selection.id);
      const text = row?.querySelector("pre")?.firstChild;
      if (text && text.textContent === selection.text) {
        const range = document.createRange();
        range.setStart(text, Math.min(selection.anchor, selection.focus));
        range.setEnd(text, Math.max(selection.anchor, selection.focus));
        selectedText.removeAllRanges(); selectedText.addRange(range);
      }
    }
  }
  $("clear-history").addEventListener("click", () => action("clear-history", {}));
  $("history-prev").addEventListener("click", () => action("history-page", { page: Math.max(0, state.page - 1) }));
  $("history-next").addEventListener("click", () => action("history-page", { page: state.page + 1 }));
  api.onViewState((next) => {
    if (!next || typeof next !== "object") return;
    state = next;
    if (!Array.isArray(state.records)) state.records = [];
    render();
  });
  render();
})();
