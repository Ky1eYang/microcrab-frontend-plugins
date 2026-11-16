(function () {
  "use strict";
  const api = window.microcrab;
  const $ = (id) => document.getElementById(id);
  let state = { locale: "zh-CN", servers: [], health: {}, busy: false };
  let editing = false;
  let deleteId = null;
  let returnFocus = null;
  const dictionaries = {
    "zh-CN": {
      title: "MCP 服务管理", subtitle: "配置工具服务及其访问凭据。", refresh: "刷新配置", add: "添加服务", serverId: "服务 ID", endpoint: "服务地址", endpointHint: "输入完整 HTTP(S) 地址，可包含路径。", authorization: "新授权凭据", credentialHint: "留空保留已有凭据。凭据仅在本次保存时发送，提交后立即清空；已保存的凭据不会显示。", clearAuthorization: "清除已保存凭据", enabledOnSave: "保存后启用", save: "保存配置", cancel: "取消", empty: "尚未配置服务。添加服务后，可在会话中使用其工具。", edit: "编辑", editTitle: "编辑服务", remove: "移除服务", confirmRemove: "确认移除", test: "测试连接", enable: "启用", disable: "停用", enabled: "已启用", disabled: "已停用", reenable: "需要重新授权", authorize: "重新授权并启用", busy: "正在处理…", invalidEndpoint: "请输入完整的 HTTP 或 HTTPS 地址。", conflictingCredential: "新凭据与清除凭据不能同时提交。", unavailable: "无法提交，请重新打开此页面。", checking: "正在检查连接", online: "连接正常", offline: "连接不可用", unchecked: "尚未测试连接", count: (n) => `已配置 ${n} 个服务`, tools: (n) => `${n} 个工具`, checked: (s) => `检查时间：${s}`, origin: (s) => `授权来源：${s}`, deletePrompt: (id) => `移除服务“${id}”？此服务的工具授权将被撤销。`
    },
    en: {
      title: "MCP servers", subtitle: "Manage tool services and their access credentials.", refresh: "Refresh configuration", add: "Add server", serverId: "Server ID", endpoint: "Endpoint URL", endpointHint: "Enter a full HTTP(S) URL, including its path if needed.", authorization: "New authorization credential", credentialHint: "Leave blank to retain the saved credential. Sent only with this save and cleared immediately after submission. Saved credentials are never displayed.", clearAuthorization: "Clear saved credential", enabledOnSave: "Enable on save", save: "Save configuration", cancel: "Cancel", empty: "No servers configured. Add a server to use its tools in a conversation.", edit: "Edit", editTitle: "Edit server", remove: "Remove server", confirmRemove: "Confirm removal", test: "Test connection", enable: "Enable", disable: "Disable", enabled: "Enabled", disabled: "Disabled", reenable: "Reauthorization required", authorize: "Reauthorize and enable", busy: "Working…", invalidEndpoint: "Enter a full HTTP or HTTPS URL.", conflictingCredential: "A new credential and clear credential cannot be submitted together.", unavailable: "Unable to submit. Reopen this page.", checking: "Checking connection", online: "Connected", offline: "Unavailable", unchecked: "Connection not tested", count: (n) => `${n} configured servers`, tools: (n) => `${n} tools`, checked: (s) => `Checked: ${s}`, origin: (s) => `Authorized origin: ${s}`, deletePrompt: (id) => `Remove server “${id}”? Its tool authorizations will be revoked.`
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
    catch { $("settings-error").textContent = t("unavailable"); $("settings-error").hidden = false; }
  }
  function button(label, testid, handler, destructive) {
    const element = node("button", label, destructive ? "destructive" : "");
    element.type = "button";
    element.dataset.testid = testid;
    element.disabled = Boolean(state.busy);
    element.addEventListener("click", handler);
    return element;
  }
  function closeEditor() {
    $("server-authorization").value = "";
    $("server-editor").hidden = true;
    if (returnFocus && returnFocus.isConnected) returnFocus.focus();
    else $("add-server").focus();
  }
  function openEditor(server, trigger) {
    returnFocus = trigger;
    editing = Boolean(server);
    $("server-form").reset();
    $("server-id").value = server ? server.id : "";
    $("server-id").readOnly = editing;
    $("server-endpoint").value = server ? server.endpoint : "";
    $("server-enabled").checked = server ? Boolean(server.enabled) : true;
    $("server-authorization").value = "";
    $("form-error").hidden = true;
    $("editor-title").textContent = t(editing ? "editTitle" : "add");
    $("server-editor").hidden = false;
    $(editing ? "server-endpoint" : "server-id").focus();
  }
  function render() {
    document.documentElement.lang = language();
    document.querySelectorAll("[data-i18n]").forEach((element) => { element.textContent = t(element.dataset.i18n); });
    $("editor-title").textContent = t(editing ? "editTitle" : "add");
    $("settings-status").textContent = state.busy ? t("busy") : (state.status || "");
    $("settings-error").textContent = state.error || "";
    $("settings-error").hidden = !state.error;
    $("configured-count").textContent = t("count", state.configured_count ?? state.servers.length);
    ["refresh-config", "add-server", "save-config", "cancel-edit", "server-id", "server-endpoint", "server-authorization", "clear-authorization", "server-enabled"].forEach((id) => { $(id).disabled = Boolean(state.busy); });
    $("server-authorization").disabled = Boolean(state.busy) || $("clear-authorization").checked;
    const list = $("servers");
    const active = document.activeElement;
    const focusKey = list.contains(active) ? [active.dataset.testid, active.closest("[data-server-id]")?.dataset.serverId] : null;
    list.replaceChildren();
    state.servers.forEach((server) => {
      const row = node("section", undefined, "server");
      row.dataset.serverId = server.id;
      row.dataset.testid = "server-row";
      const heading = node("div", undefined, "server-head");
      heading.append(node("h2", server.id, "server-id"), node("span", t(server.requires_reenable ? "reenable" : server.enabled ? "enabled" : "disabled"), "badge" + (server.requires_reenable ? " warning" : "")));
      row.append(heading, node("p", server.endpoint, "endpoint"), node("p", t("origin", server.origin || ""), "hint"));
      const health = state.health?.[server.id];
      const healthLine = node("p", undefined, "health");
      if (!health) healthLine.textContent = t("unchecked");
      else {
        const statusKey = { pending: "checking", checking: "checking", online: "online", connected: "online", completed: "online", success: "online", healthy: "online", ok: "online", failed: "offline", offline: "offline", error: "offline", unreachable: "offline" }[health.status];
        healthLine.textContent = (statusKey ? t(statusKey) : String(health.status || "")) + (Number.isFinite(health.tool_count) ? " · " + t("tools", health.tool_count) : "");
        if (Number.isFinite(health.checked_at_ms)) healthLine.append(node("span", " · " + t("checked", new Date(health.checked_at_ms).toLocaleString(language()))));
      }
      row.append(healthLine);
      const controls = node("div", undefined, "actions");
      const edit = button(t("edit"), "edit-server", () => openEditor(server, edit));
      controls.append(edit, button(t(server.requires_reenable ? "authorize" : server.enabled ? "disable" : "enable"), "server-toggle", () => action("server-toggle", { id: server.id, enabled: server.requires_reenable || !server.enabled })), button(t("test"), "test-connection", () => action("test-connection", { id: server.id })), button(t("remove"), "remove-server", () => { deleteId = server.id; render(); rowFocus(server.id, "delete-cancel"); }, true));
      row.append(controls);
      if (deleteId === server.id) {
        const confirmation = node("div", undefined, "delete-confirm");
        confirmation.setAttribute("role", "group");
        confirmation.setAttribute("aria-label", t("confirmRemove"));
        confirmation.append(node("p", t("deletePrompt", server.id)));
        const actions = node("div", undefined, "actions");
        actions.append(button(t("cancel"), "delete-cancel", () => { deleteId = null; render(); rowFocus(server.id, "remove-server"); }), button(t("confirmRemove"), "delete-confirm", () => action("remove", { id: server.id }), true));
        confirmation.append(actions);
        row.append(confirmation);
      }
      list.append(row);
    });
    if (focusKey) rowFocus(focusKey[1], focusKey[0]);
    $("settings-empty").hidden = state.servers.length > 0;
  }
  function rowFocus(id, testid) {
    const row = Array.from($("servers").children).find((element) => element.dataset.serverId === id);
    row?.querySelector(`[data-testid="${testid}"]`)?.focus();
  }
  $("add-server").addEventListener("click", () => openEditor(null, $("add-server")));
  $("cancel-edit").addEventListener("click", closeEditor);
  $("refresh-config").addEventListener("click", () => action("refresh-config", {}));
  $("clear-authorization").addEventListener("change", () => {
    $("server-authorization").value = "";
    $("server-authorization").disabled = $("clear-authorization").checked || Boolean(state.busy);
  });
  function saveConfig() {
    if (state.busy || !$('server-form').reportValidity()) return;
    let valid = false;
    try { valid = ["http:", "https:"].includes(new URL($("server-endpoint").value).protocol); } catch { /* Show local validation only. */ }
    if (!valid) {
      $("form-error").textContent = t("invalidEndpoint"); $("form-error").hidden = false; return;
    }
    if ($("clear-authorization").checked && $("server-authorization").value) {
      $("form-error").textContent = t("conflictingCredential"); $("form-error").hidden = false; return;
    }
    // The credential exists only in this input and the single action payload.
    // No promise callback, draft object or diagnostic retains it.
    try {
      api.action("save-config", { id: $("server-id").value, endpoint: $("server-endpoint").value, authorization: $("server-authorization").value, clear_authorization: $("clear-authorization").checked, enabled: $("server-enabled").checked });
    } catch {
      $("form-error").textContent = t("unavailable"); $("form-error").hidden = false;
    } finally {
      $("server-authorization").value = "";
    }
  }
  $("save-config").addEventListener("click", saveConfig);
  $("server-form").addEventListener("submit", (event) => event.preventDefault());
  $("server-form").addEventListener("keydown", (event) => {
    if (event.key === "Enter" && event.target instanceof HTMLInputElement) {
      event.preventDefault();
      saveConfig();
    }
  });
  window.addEventListener("pagehide", () => { $("server-authorization").value = ""; });
  api.onViewState((next) => {
    if (!next || typeof next !== "object") return;
    state = next;
    if (!Array.isArray(state.servers)) state.servers = [];
    if (deleteId && !state.servers.some((server) => server.id === deleteId)) deleteId = null;
    render();
  });
  render();
})();
