(function () {
  let state = {
    values: {}, metadata: {}, descriptors: {}, loading: false,
    has_snapshot: false, search: "", show_invisible: false,
    error: "", locale: "zh-CN", mutation_status: "idle"
  };

  const isZh = () => !String(state.locale || "").toLowerCase().startsWith("en");

  const i18n = {
    searchPlaceholder: () => isZh() ? "搜索字段名或值..." : "Search key or value...",
    fieldsCount: (total, ro) => isZh() ? `共 ${total} 个字段 (${ro} 个只读)` : `${total} fields (${ro} read-only)`,
    loading: () => isZh() ? "正在读取会话状态..." : "Loading state...",
    empty: () => isZh() ? "当前会话暂无状态数据" : "No state data in current session",
    noMatches: (q) => isZh() ? `未找到匹配 "${q}" 的变量` : `No variables match "${q}"`,
    clearSearch: () => isZh() ? "清空筛选" : "Clear Filter",
    showInvisible: () => isZh() ? "显示隐藏字段" : "Show hidden fields",
    hideInvisible: () => isZh() ? "隐藏内部字段" : "Hide hidden fields",
    refresh: () => isZh() ? "刷新" : "Refresh",
    newField: () => isZh() ? "+ 新建变量" : "+ New Variable",
    readOnly: () => isZh() ? "只读受保护" : "Read Only",
    secret: () => isZh() ? "机密" : "Secret",
    secretValue: () => isZh() ? "机密值不可读取" : "Secret value is not readable",
    editTitle: (can) => can ? (isZh() ? "编辑此变量" : "Edit variable") : (isZh() ? "此变量受保护，无编辑权限 (缺少 client 授权)" : "Protected variable (missing client edit permission)"),
    deleteTitle: (can) => can ? (isZh() ? "删除此变量" : "Delete variable") : (isZh() ? "此变量非客户端所有 (Owner 不是 client)，无法删除" : "Variable not owned by client (cannot delete)"),
    save: () => isZh() ? "保存变更" : "Save Changes",
    cancel: () => isZh() ? "取消" : "Cancel",
    confirmDeletePrompt: (key) => isZh() ? `确定要从会话状态中删除变量 "${key}" 吗？此操作无法撤销。` : `Are you sure you want to delete variable "${key}"? This cannot be undone.`,
    invalidJson: () => isZh() ? "无效的 JSON 格式" : "Invalid JSON syntax",
    cannotEditReadOnly: () => isZh() ? "此字段受只读保护，不可修改" : "This field is read-only protected"
  };

  const ICONS = {
    edit: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path></svg>`,
    trash: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg>`
  };

  // DOM elements
  const el = {
    search: document.getElementById("search"),
    summary: document.getElementById("summary"),
    btnInvisible: document.getElementById("btn-invisible"),
    btnRefresh: document.getElementById("btn-refresh"),
    btnNew: document.getElementById("btn-new"),
    list: document.getElementById("vars-list"),
    // Edit Modal
    modal: document.getElementById("edit-modal"),
    modalTitle: document.getElementById("modal-title"),
    modalKey: document.getElementById("modal-key"),
    modalVal: document.getElementById("modal-val"),
    modalAlert: document.getElementById("modal-alert"),
    btnModalSave: document.getElementById("modal-save"),
    btnModalCancel: document.getElementById("modal-cancel"),
    // Delete Modal
    deleteModal: document.getElementById("delete-modal"),
    deleteMsg: document.getElementById("delete-msg"),
    btnDeleteConfirm: document.getElementById("delete-confirm"),
    btnDeleteCancel: document.getElementById("delete-cancel")
  };

  let activeEditKey = null;
  let isCreatingNew = false;
  let pendingDeleteKey = null;
  let capturedWitness = null;
  let capturedSession = null;
  let submittedOperation = null;
  const busy = () => ["pending", "saving", "queued", "unknown"].includes(state.mutation_status);

  function isSecret(key) {
    return state.metadata?.[key]?.visibility === "secret";
  }

  function canEdit(key) {
    return !isSecret(key) && state.descriptors?.[key]?.kind === "custom" && state.descriptors[key].editable === true;
  }

  function canDelete(key) {
    return state.descriptors?.[key]?.kind === "custom" && state.descriptors[key].deletable === true && state.metadata?.[key]?.owner === "client";
  }

  // Keep in parity with the native State inspector. The authoritative snapshot
  // and edit/CAS input below remain exact; only these certified paths vary.
  function projectStateValue(key, value) {
    const kind = state.descriptors?.[key]?.kind;
    const slots = [];
    const add = (row, field, composite = false) => {
      if (!row || typeof row !== "object" || !Object.hasOwn(row, field) || typeof row[field] !== "string") return;
      const match = (composite ? /^(agent-init:[1-9]\d{0,19}:[1-9]\d{0,19}:)([0-9a-f]{64})(?![\s\S])/i : /^()([0-9a-f]{64})(?![\s\S])/i).exec(row[field]);
      if (match) slots.push({ row, field, exact: row[field], prefix: match[1], hex: match[2].toLowerCase() });
    };
    if (key === "references" && kind === "reference" && Array.isArray(value)) {
      for (const row of value) add(row, "content_digest");
    } else if (key === "agent_init" && kind === "framework") {
      add(value, "component");
      if (Array.isArray(value?.cache_points)) for (const row of value.cache_points) {
        add(row, "version");
        add(row, "call_id", true);
      }
    } else if (key === "executions" && kind === "framework" && Array.isArray(value)) {
      for (const row of value) if (row?.subject?.kind === "agent_init") {
        add(row.subject, "component");
        add(row, "call_id", true);
      }
    }
    if (!slots.length) return value;
    const peers = new Map();
    for (const slot of slots) peers.set(slot.exact, slot);
    const ordered = [...peers.keys()].sort();
    const counts = new Map();
    for (const {prefix, hex} of peers.values()) for (const length of [16, 20, 24]) {
      const stem = prefix + hex.slice(0, length);
      counts.set(stem, (counts.get(stem) || 0) + 1);
    }
    const ranks = new Map();
    const labels = new Map();
    for (const exact of ordered) {
      const {prefix, hex} = peers.get(exact);
      const stems = [16, 20, 24].map(length => prefix + hex.slice(0, length));
      const stem = stems.find(candidate => counts.get(candidate) === 1) || stems[2];
      let suffix = "";
      if (counts.get(stem) > 1) {
        const ordinal = (ranks.get(stem) || 0) + 1;
        ranks.set(stem, ordinal);
        suffix = `~${ordinal.toString(36)}`;
      }
      labels.set(exact, `${stem}…${suffix}`);
    }
    const patches = new Map();
    for (const {row, field, exact} of slots) {
      const patch = patches.get(row) || {};
      patch[field] = labels.get(exact);
      patches.set(row, patch);
    }
    const project = row => patches.has(row) ? { ...row, ...patches.get(row) } : row;
    if (key === "references") return value.map(project);
    if (key === "agent_init") return Array.isArray(value.cache_points)
      ? { ...project(value), cache_points: value.cache_points.map(project) }
      : project(value);
    return value.map(row => row?.subject?.kind === "agent_init"
      ? { ...project(row), subject: project(row.subject) }
      : row);
  }

  const exactKeys = new Set();
  function render() {
    const status = document.getElementById("operation-status");
    const observe = document.getElementById("observe-operation");
    const activeModal = el.modal.classList.contains("open") ? el.modal : el.deleteModal.classList.contains("open") ? el.deleteModal : null;
    const observeContainer = activeModal ? activeModal.querySelector(".modal-footer") : document.getElementById("operation-controls");
    if (observe.parentElement !== observeContainer) observeContainer.appendChild(observe);
    status.textContent = state.mutation_error || state.error || (busy() ? (isZh() ? "变更状态：" : "Change status: ") + state.mutation_status : "");
    observe.disabled = Boolean(state.mutation_observing);
    observe.hidden = !["unknown", "queued"].includes(state.mutation_status);
    observe.textContent = isZh() ? "查询此操作结果" : "Observe this operation";
    el.btnNew.disabled = busy() || !state.has_snapshot;
    el.btnModalSave.disabled = busy() || (!isCreatingNew && activeEditKey !== null && !canEdit(activeEditKey));
    el.btnDeleteConfirm.disabled = busy();
    el.btnModalCancel.disabled = busy();
    el.btnDeleteCancel.disabled = busy();
    if (el.modal.classList.contains("open")) el.modalAlert.textContent = state.mutation_error || state.error || "";
    if (el.deleteModal.classList.contains("open")) el.deleteMsg.textContent = state.mutation_error || state.error || i18n.confirmDeletePrompt(pendingDeleteKey);
    el.btnRefresh.title = i18n.refresh();
    el.search.placeholder = i18n.searchPlaceholder();
    el.btnNew.textContent = i18n.newField();
    el.btnInvisible.classList.toggle("active", Boolean(state.show_invisible));
    el.btnInvisible.title = state.show_invisible ? i18n.hideInvisible() : i18n.showInvisible();

    const allKeys = [...new Set([
      ...Object.keys(state.values || {}),
      ...Object.keys(state.metadata || {}).filter(isSecret)
    ])].sort();

    // 1. If currently loading and no snapshot exists yet
    if (state.loading && !state.has_snapshot && allKeys.length === 0) {
      el.list.innerHTML = `<div style="text-align:center;padding:24px;color:var(--text-sub);">${i18n.loading()}</div>`;
      el.summary.textContent = "";
      return;
    }

    // 2. Count visible vs invisible eligible keys
    let eligible = 0;
    let readOnlyCount = 0;
    const query = (el.search.value || "").trim().toLowerCase();

    for (const k of allKeys) {
      const meta = state.metadata ? state.metadata[k] : null;
      const isInvisible = meta && meta.visibility === "invisible";
      if (isInvisible && !state.show_invisible) continue;
      eligible++;
      if (!canEdit(k)) readOnlyCount++;
    }

    el.summary.textContent = i18n.fieldsCount(eligible, readOnlyCount);

    // 3. If there are truly zero fields in the session
    if (eligible === 0) {
      el.list.innerHTML = `<div style="text-align:center;padding:32px;color:var(--text-sub);">${i18n.empty()}</div>`;
      return;
    }

    const displayValues = new Map();
    for (const key of allKeys) {
      if (isSecret(key) || (state.metadata?.[key]?.visibility === "invisible" && !state.show_invisible)) continue;
      displayValues.set(key, projectStateValue(key, state.values[key]));
    }
    // 4. Filter by search query
    const matchedKeys = allKeys.filter(k => {
      const meta = state.metadata ? state.metadata[k] : null;
      const isInvisible = meta && meta.visibility === "invisible";
      if (isInvisible && !state.show_invisible) return false;

      if (!query) return true;
      if (isSecret(k)) return k.toLowerCase().includes(query);
      const display = JSON.stringify(displayValues.get(k) ?? "").toLowerCase();
      const exact = displayValues.get(k) === state.values[k] ? display : JSON.stringify(state.values[k]).toLowerCase();
      return k.toLowerCase().includes(query) || display.includes(query) || exact.includes(query);
    });

    // 5. If search query yielded no matches (Differentiate from empty session!)
    if (matchedKeys.length === 0) {
      el.list.innerHTML = `
        <div class="search-empty-box">
          <p>${i18n.noMatches(escapeHtml(query))}</p>
          <button id="btn-clear-search" class="btn btn-sm">${i18n.clearSearch()}</button>
        </div>
      `;
      const btnClear = document.getElementById("btn-clear-search");
      if (btnClear) {
        btnClear.addEventListener("click", () => {
          el.search.value = "";
          render();
        });
      }
      return;
    }

    let html = "";
    for (const key of matchedKeys) {
      const secret = isSecret(key);
      const val = secret ? undefined : state.values[key];
      const meta = (state.metadata && state.metadata[key]) || {};
      const editable = canEdit(key);
      const deletable = canDelete(key);

      const displayVal = displayValues.get(key);
      const hasExact = !secret && displayVal !== val;
      const showExact = hasExact && exactKeys.has(key);
      const shown = showExact ? val : displayVal;
      const valFormatted = secret ? i18n.secretValue() : typeof shown === "object" ? JSON.stringify(shown, null, 2) : String(shown);
      const type = secret ? i18n.secret() : Array.isArray(val) ? "array" : typeof val;

      const isInvisible = Boolean(meta.visibility === "invisible");
      const isPersisted = Boolean(meta.persistence === "persisted");

      const editTitle = i18n.editTitle(editable);
      const deleteTitle = i18n.deleteTitle(deletable);

      html += `
        <div class="var-card" data-key="${escapeHtml(key)}">
          <div class="card-header">
            <div class="card-title">
              <span>${escapeHtml(key)}</span>
              <span style="font-size:10px;color:var(--text-sub);">(${type})</span>
            </div>
            <div class="card-badges">
              ${secret ? `<span class="badge badge-invisible">${i18n.secret()}</span>` : isInvisible ? `<span class="badge badge-invisible">Invisible</span>` : `<span class="badge badge-visible">Visible</span>`}
              ${isPersisted ? `<span class="badge badge-persisted">Persisted</span>` : ""}
              ${!editable ? `<span class="badge badge-locked">🔒 ${i18n.readOnly()}</span>` : ""}
            </div>
          </div>
          <div class="val-preview">${escapeHtml(valFormatted)}</div>
          ${hasExact ? `<button type="button" class="btn btn-sm exact-state" data-key="${escapeHtml(key)}" aria-pressed="${showExact}">${showExact ? (isZh() ? "显示简洁视图" : "Show compact view") : (isZh() ? "显示精确证据" : "Show exact evidence")}</button>` : ""}
          <div class="card-footer">
            <div style="font-size:11px;color:var(--text-sub);">
              ${!deletable ? (isZh() ? "受保护 (非 Client 所有)" : "Protected") : "Client-owned"}
            </div>
            <div class="action-buttons">
              <button 
                class="btn-icon op-edit" 
                data-key="${escapeHtml(key)}" 
                title="${editTitle}"
                ${!editable ? "disabled" : ""}
              >
                ${ICONS.edit}
              </button>
              <button 
                class="btn-icon btn-icon-danger op-del" 
                data-key="${escapeHtml(key)}" 
                title="${deleteTitle}"
                ${!deletable ? "disabled" : ""}
              >
                ${ICONS.trash}
              </button>
            </div>
          </div>
        </div>
      `;
    }

    el.list.innerHTML = html;

    el.list.querySelectorAll(".exact-state").forEach(btn => {
      btn.addEventListener("click", () => {
        const key = btn.dataset.key;
        if (isSecret(key)) return;
        if (exactKeys.has(key)) exactKeys.delete(key);
        else exactKeys.add(key);
        render();
        Array.from(el.list.querySelectorAll(".exact-state")).find(next => next.dataset.key === key)?.focus();
      });
    });
    // Attach buttons with disabled guards
    el.list.querySelectorAll(".op-edit").forEach(btn => {
      btn.addEventListener("click", () => {
        if (btn.disabled) return;
        openEditModal(btn.dataset.key, false);
      });
    });
    el.list.querySelectorAll(".op-del").forEach(btn => {
      btn.addEventListener("click", () => {
        if (btn.disabled) return;
        openDeleteModal(btn.dataset.key);
      });
    });
  }

  function openEditModal(key, isNew) {
    if (busy() || !state.has_snapshot || (!isNew && !canEdit(key))) return;
    capturedWitness = structuredClone(state.witness);
    capturedSession = state.session_id;
    submittedOperation = null;
    isCreatingNew = isNew;
    activeEditKey = key;
    el.modalAlert.textContent = "";

    if (isNew) {
      el.modalTitle.textContent = i18n.newField();
      el.modalKey.value = "";
      el.modalKey.disabled = false;
      el.modalVal.value = "{\n  \"example\": true\n}";
      el.btnModalSave.disabled = false;
    } else {
      el.modalTitle.textContent = `${isZh() ? "编辑" : "Edit"}: ${key}`;
      el.modalKey.value = key;
      el.modalKey.disabled = true;
      const val = state.values[key];
      el.modalVal.value = JSON.stringify(val, null, 2);

      if (!canEdit(key)) {
        el.modalAlert.textContent = i18n.cannotEditReadOnly();
        el.btnModalSave.disabled = true;
      } else {
        el.btnModalSave.disabled = false;
      }
    }

    el.modal.classList.add("open");
  }

  function closeEditModal() {
    el.modal.classList.remove("open");
  }

  function saveModal() {
    const key = el.modalKey.value.trim();
    if (!key) {
      el.modalAlert.textContent = isZh() ? "变量名不可为空" : "Variable name cannot be empty";
      return;
    }
    if (isSecret(key) || (!isCreatingNew && !canEdit(activeEditKey))) {
      el.modalAlert.textContent = i18n.cannotEditReadOnly();
      return;
    }

    let parsedVal;
    try {
      parsedVal = JSON.parse(el.modalVal.value);
    } catch {
      parsedVal = el.modalVal.value;
    }

    if (busy() || capturedSession !== state.session_id) return;
    if (!capturedWitness || typeof crypto?.randomUUID !== "function") {
      el.modalAlert.textContent = isZh() ? "缺少状态版本或安全操作标识；请重新打开编辑器。" : "Missing state witness or secure operation identity; reopen the editor.";
      return;
    }
    if (!window.microcrab?.action) return;
    submittedOperation = crypto.randomUUID();
    state.mutation_status = "saving";
    window.microcrab.action("save-json", {
      operation_id: submittedOperation,
      expected: capturedWitness,
      key,
      value: parsedVal,
      is_new: isCreatingNew
    });
    render();
  }

  // Custom Inline Delete Modal
  function openDeleteModal(key) {
    if (busy() || !canDelete(key)) return;
    capturedWitness = structuredClone(state.witness);
    capturedSession = state.session_id;
    submittedOperation = null;
    pendingDeleteKey = key;
    el.deleteMsg.textContent = i18n.confirmDeletePrompt(key);
    el.deleteModal.classList.add("open");
  }

  function closeDeleteModal() {
    pendingDeleteKey = null;
    el.deleteModal.classList.remove("open");
  }

  function confirmDelete() {
    if (busy() || capturedSession !== state.session_id || !pendingDeleteKey || !canDelete(pendingDeleteKey)) return;
    if (!capturedWitness || typeof crypto?.randomUUID !== "function" || !window.microcrab?.action) return;
    submittedOperation = crypto.randomUUID();
    state.mutation_status = "saving";
    window.microcrab.action("delete-field", {
      operation_id: submittedOperation,
      expected: capturedWitness,
      key: pendingDeleteKey
    });
    render();
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  // Events
  el.search.addEventListener("input", render);
  el.btnInvisible.addEventListener("click", () => {
    if (window.microcrab && window.microcrab.action) {
      window.microcrab.action("toggle-invisible", {});
    }
  });
  el.btnRefresh.addEventListener("click", () => {
    if (window.microcrab && window.microcrab.action) {
      window.microcrab.action("refresh", {});
    }
  });
  el.btnNew.addEventListener("click", () => openEditModal("", true));
  el.btnModalCancel.addEventListener("click", closeEditModal);
  el.btnModalSave.addEventListener("click", saveModal);

  el.btnDeleteCancel.addEventListener("click", closeDeleteModal);
  el.btnDeleteConfirm.addEventListener("click", confirmDelete);

  document.getElementById("observe-operation").addEventListener("click", () => {
    if (!state.mutation_observing && window.microcrab?.action) {
      window.microcrab.action("observe-operation", {});
    }
  });

  // microcrab state listener
  if (window.microcrab && window.microcrab.onViewState) {
    window.microcrab.onViewState((next) => {
      if (next && typeof next === "object") {
        const previousSession = state.session_id;
        if (next.values !== undefined || previousSession !== next.session_id) exactKeys.clear();
        state = { ...state, ...next };
        if (activeEditKey !== null && isSecret(activeEditKey)) {
          el.modalVal.value = "";
          closeEditModal();
        }
        if (previousSession && previousSession !== state.session_id) {
          closeEditModal();
          closeDeleteModal();
          submittedOperation = null;
        }
        if (submittedOperation && state.mutation_operation_id === submittedOperation && state.mutation_status === "saved") {
          closeEditModal();
          closeDeleteModal();
          submittedOperation = null;
        }
        render();
      }
    });
  }

  // Initial render
  render();
})();
