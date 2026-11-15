(function () {
  let state = {
    values: {},
    metadata: {},
    loading: false,
    has_snapshot: false,
    search: "",
    show_invisible: false,
    error: "",
    locale: "zh-CN"
  };

  const isZh = () => !String(state.locale || "").toLowerCase().startsWith("en");

  const i18n = {
    searchPlaceholder: () => isZh() ? "搜索字段名或值..." : "Search key or value...",
    fieldsCount: (total, ro) => isZh() ? `共 ${total} 个字段 (${ro} 个只读)` : `${total} fields (${ro} read-only)`,
    loading: () => isZh() ? "正在读取会话状态..." : "Loading state...",
    empty: () => isZh() ? "当前会话暂无状态数据" : "No state fields found",
    showInvisible: () => isZh() ? "显示隐藏字段" : "Show hidden fields",
    hideInvisible: () => isZh() ? "隐藏内部字段" : "Hide hidden fields",
    refresh: () => isZh() ? "刷新" : "Refresh",
    newField: () => isZh() ? "+ 新建变量" : "+ New Variable",
    readOnly: () => isZh() ? "只读受保护" : "Read Only",
    edit: () => isZh() ? "编辑" : "Edit",
    delete: () => isZh() ? "删除" : "Delete",
    save: () => isZh() ? "保存变更" : "Save Changes",
    cancel: () => isZh() ? "取消" : "Cancel",
    invalidJson: () => isZh() ? "无效的 JSON 格式" : "Invalid JSON syntax",
    cannotEditReadOnly: () => isZh() ? "此字段受只读保护，不可修改" : "This field is read-only protected"
  };

  // DOM elements
  const el = {
    search: document.getElementById("search"),
    summary: document.getElementById("summary"),
    btnInvisible: document.getElementById("btn-invisible"),
    btnRefresh: document.getElementById("btn-refresh"),
    btnNew: document.getElementById("btn-new"),
    list: document.getElementById("vars-list"),
    modal: document.getElementById("edit-modal"),
    modalTitle: document.getElementById("modal-title"),
    modalKey: document.getElementById("modal-key"),
    modalVal: document.getElementById("modal-val"),
    modalAlert: document.getElementById("modal-alert"),
    btnModalSave: document.getElementById("modal-save"),
    btnModalCancel: document.getElementById("modal-cancel")
  };

  let activeEditKey = null;
  let isCreatingNew = false;

  function isReadOnly(key) {
    const meta = state.metadata ? state.metadata[key] : null;
    if (!meta) return false;
    if (Array.isArray(meta.editors)) {
      return !meta.editors.includes("client");
    }
    return false;
  }

  function render() {
    el.search.placeholder = i18n.searchPlaceholder();
    el.btnNew.textContent = i18n.newField();
    el.btnInvisible.classList.toggle("active", Boolean(state.show_invisible));
    el.btnInvisible.title = state.show_invisible ? i18n.hideInvisible() : i18n.showInvisible();

    if (state.loading && !state.has_snapshot) {
      el.list.innerHTML = `<div style="text-align:center;padding:24px;color:var(--text-sub);">${i18n.loading()}</div>`;
      el.summary.textContent = "";
      return;
    }

    const keys = Object.keys(state.values || {}).sort();
    const query = (el.search.value || "").trim().toLowerCase();

    let eligible = 0;
    let readOnlyCount = 0;

    const matchedKeys = keys.filter(k => {
      const meta = state.metadata ? state.metadata[k] : null;
      const isInvisible = meta && meta.visibility === "invisible";
      if (isInvisible && !state.show_invisible) return false;

      eligible++;
      if (isReadOnly(k)) readOnlyCount++;

      if (!query) return true;
      const valStr = JSON.stringify(state.values[k] || "").toLowerCase();
      return k.toLowerCase().includes(query) || valStr.includes(query);
    });

    el.summary.textContent = i18n.fieldsCount(eligible, readOnlyCount);

    if (matchedKeys.length === 0) {
      el.list.innerHTML = `<div style="text-align:center;padding:32px;color:var(--text-sub);">${i18n.empty()}</div>`;
      return;
    }

    let html = "";
    for (const key of matchedKeys) {
      const val = state.values[key];
      const meta = state.metadata ? state.metadata[key] : {};
      const ro = isReadOnly(key);
      const valFormatted = typeof val === "object" ? JSON.stringify(val, null, 2) : String(val);
      const type = Array.isArray(val) ? "array" : typeof val;

      const isInvisible = meta.visibility === "invisible";
      const isPersisted = meta.persistence === "persisted";

      html += `
        <div class="var-card" data-key="${escapeHtml(key)}">
          <div class="card-header">
            <div class="card-title">
              <span>${escapeHtml(key)}</span>
              <span style="font-size:10px;color:var(--text-sub);">(${type})</span>
            </div>
            <div class="card-badges">
              ${isInvisible ? `<span class="badge badge-invisible">Invisible</span>` : `<span class="badge badge-visible">Visible</span>`}
              ${isPersisted ? `<span class="badge badge-persisted">Persisted</span>` : ""}
              ${ro ? `<span class="badge badge-locked">🔒 ${i18n.readOnly()}</span>` : ""}
            </div>
          </div>
          <div class="val-preview">${escapeHtml(valFormatted)}</div>
          <div class="card-footer">
            <div style="font-size:11px;color:var(--text-sub);">
              ${ro ? "只读保护不可删除" : "Client-owned"}
            </div>
            <div class="card-ops">
              ${!ro ? `<button class="btn btn-sm op-edit" data-key="${escapeHtml(key)}">${i18n.edit()}</button>` : ""}
              ${!ro ? `<button class="btn btn-sm op-del" data-key="${escapeHtml(key)}" style="color:var(--badge-red);">${i18n.delete()}</button>` : ""}
            </div>
          </div>
        </div>
      `;
    }

    el.list.innerHTML = html;

    // Attach buttons
    el.list.querySelectorAll(".op-edit").forEach(btn => {
      btn.addEventListener("click", () => openEditModal(btn.dataset.key, false));
    });
    el.list.querySelectorAll(".op-del").forEach(btn => {
      btn.addEventListener("click", () => deleteKey(btn.dataset.key));
    });
  }

  function openEditModal(key, isNew) {
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
      el.modalTitle.textContent = `${i18n.edit()}: ${key}`;
      el.modalKey.value = key;
      el.modalKey.disabled = true;
      const val = state.values[key];
      el.modalVal.value = JSON.stringify(val, null, 2);

      if (isReadOnly(key)) {
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
      el.modalAlert.textContent = "变量名不可为空";
      return;
    }

    let parsedVal;
    try {
      parsedVal = JSON.parse(el.modalVal.value);
    } catch {
      // 允许普通字符串免写双引号
      parsedVal = el.modalVal.value;
    }

    if (window.microcrab && window.microcrab.action) {
      window.microcrab.action("save-json", {
        key: key,
        value: parsedVal,
        is_new: isCreatingNew
      });
    }

    closeEditModal();
  }

  function deleteKey(key) {
    if (confirm(`确认删除变量 "${key}" 吗？`)) {
      if (window.microcrab && window.microcrab.action) {
        window.microcrab.action("delete-field", { key: key });
      }
    }
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

  // microcrab state listener
  if (window.microcrab && window.microcrab.onViewState) {
    window.microcrab.onViewState((next) => {
      if (next && typeof next === "object") {
        state = { ...state, ...next };
        render();
      }
    });
  } else {
    // Dev mock
    render();
  }
})();
