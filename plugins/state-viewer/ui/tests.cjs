const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

// Exercise the authored UI without dependencies or any real credential fixtures.
function surface() {
  function node(attributes = "") {
    const attrs = Object.fromEntries([...attributes.matchAll(/([\w-]+)="([^"]*)"/g)].map(([, key, value]) => [key, value]));
    const classes = new Set((attrs.class || "").split(/\s+/));
    const events = {};
    return {
      id: attrs.id, value: "", textContent: "", innerHTML: "", disabled: /\sdisabled(?:\s|$)/.test(attributes),
      dataset: { key: attrs["data-key"] }, parentElement: null,
      classList: {
        contains: (name) => classes.has(name), add: (name) => classes.add(name), remove: (name) => classes.delete(name),
        toggle(name, on) { if (on) classes.add(name); else classes.delete(name); }
      },
      addEventListener(event, handler) { events[event] = handler; },
      fire(event) { events[event]?.(); },
      appendChild(child) { child.parentElement = this; },
      querySelector() { return this.footer; },
      querySelectorAll(selector) {
        this.buttons ??= [];
        if (this.buttonSource !== this.innerHTML) {
          this.buttonSource = this.innerHTML;
          this.buttons = [...this.innerHTML.matchAll(/<button\b([^>]*)>/g)].map(([, attrs]) => node(attrs));
        }
        return this.buttons.filter((button) => button.classList.contains(selector.slice(1)));
      }
    };
  }
  const html = fs.readFileSync(path.join(__dirname, "index.html"), "utf8");
  const ids = Object.fromEntries([...html.matchAll(/<\w+\b([^>]*\bid="[^"]+"[^>]*)>/g)].map(([, attrs]) => {
    const element = node(attrs);
    return [element.id, element];
  }));
  ids["edit-modal"].footer = node();
  ids["delete-modal"].footer = node();
  const actions = [];
  let update;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "app.js"), "utf8"), {
    document: { getElementById: (id) => ids[id] }, structuredClone,
    crypto: { randomUUID: () => "00000000-0000-4000-8000-000000000001" },
    window: { microcrab: { onViewState: (listener) => { update = listener; }, action: (name, payload) => actions.push({ name, payload }) } }
  });
  const snapshot = (extra = {}) => update({ session_id: "session", has_snapshot: true, witness: { revision: 1 }, ...extra });
  return { ids, actions, update: snapshot, button: (selector, key) => ids["vars-list"].querySelectorAll(selector).find((button) => button.dataset.key === key) };
}

const editable = { kind: "custom", editable: true, deletable: true };

for (const [locale, badge, preview] of [["en", "Secret", "Secret value is not readable"], ["zh-CN", "机密", "机密值不可读取"]]) {
  test(`${locale}: Secret rendering/search never reads its supplied value and stays read-only`, () => {
    const ui = surface();
    const values = { public: "normal visible text" };
    Object.defineProperty(values, "TOKEN", { enumerable: true, get() { throw Error("Secret value must not be accessed"); } });
    ui.update({ locale, values, metadata: { TOKEN: { visibility: "secret", owner: "client" } }, descriptors: { TOKEN: editable, public: editable } });
    const html = ui.ids["vars-list"].innerHTML;
    assert.ok(html.includes(badge));
    assert.ok(html.includes(preview));
    assert.ok(html.includes("normal visible text"));
    assert.equal(ui.button(".op-edit", "TOKEN").disabled, true);
    assert.equal(ui.button(".op-del", "TOKEN").disabled, false);
    ui.button(".op-edit", "TOKEN").fire("click");
    assert.equal(ui.ids["edit-modal"].classList.contains("open"), false);
    ui.ids.search.value = "token";
    ui.ids.search.fire("input");
    assert.ok(ui.ids["vars-list"].innerHTML.includes('data-key="TOKEN"'));
    ui.ids.search.value = "normal";
    ui.ids.search.fire("input");
    assert.equal(ui.ids["vars-list"].innerHTML.includes('data-key="TOKEN"'), false);
    assert.equal(ui.actions.length, 0);
  });
}

test("metadata-only Secret is visible and cannot be overwritten through New Variable", () => {
  const ui = surface();
  ui.update({ locale: "en", values: {}, metadata: { TOKEN: { visibility: "secret" } }, descriptors: { TOKEN: { ...editable, editable: false } } });
  assert.ok(ui.ids["vars-list"].innerHTML.includes('data-key="TOKEN"'));
  assert.ok(ui.ids.summary.textContent.includes("1 read-only"));
  ui.ids["btn-new"].fire("click");
  ui.ids["modal-key"].value = "TOKEN";
  ui.ids["modal-val"].value = "not-a-credential";
  ui.ids["modal-save"].fire("click");
  assert.equal(ui.actions.length, 0);
  assert.match(ui.ids["modal-alert"].textContent, /read-only/);
});

test("an open draft becomes inaccessible when metadata changes to Secret", () => {
  const ui = surface();
  ui.update({ values: { field: "ordinary draft" }, metadata: {}, descriptors: { field: editable } });
  ui.button(".op-edit", "field").fire("click");
  assert.equal(ui.ids["edit-modal"].classList.contains("open"), true);
  ui.update({ values: {}, metadata: { field: { visibility: "secret" } }, descriptors: { field: { ...editable, editable: false } } });
  assert.equal(ui.ids["modal-val"].value, "");
  assert.equal(ui.ids["edit-modal"].classList.contains("open"), false);
  ui.ids["modal-save"].fire("click");
  assert.equal(ui.actions.length, 0);
});

test("Client-owned metadata-only Secret deletion submits only its exact key and captured witness", () => {
  const ui = surface();
  ui.update({ locale: "en", values: {}, metadata: { TOKEN: { visibility: "secret", owner: "client" } }, descriptors: { TOKEN: { ...editable, editable: false } } });
  assert.equal(ui.button(".op-del", "TOKEN").disabled, false);
  assert.equal(ui.button(".op-edit", "TOKEN").disabled, true);
  ui.button(".op-del", "TOKEN").fire("click");
  assert.equal(ui.ids["delete-modal"].classList.contains("open"), true);
  assert.ok(ui.ids["delete-msg"].textContent.includes("TOKEN"));
  ui.ids["delete-confirm"].fire("click");
  assert.equal(ui.actions.length, 1);
  assert.equal(ui.actions[0].name, "delete-field");
  assert.deepEqual(JSON.parse(JSON.stringify(ui.actions[0].payload)), {
    operation_id: "00000000-0000-4000-8000-000000000001", expected: { revision: 1 }, key: "TOKEN"
  });
});

for (const revoked of ["descriptor", "owner"]) {
  test(`Secret deletion rechecks current ${revoked} before submitting without accessing a value`, () => {
    const ui = surface();
    const values = {};
    Object.defineProperty(values, "TOKEN", { enumerable: true, get() { throw Error("Secret value must not be accessed"); } });
    const metadata = { TOKEN: { visibility: "secret", owner: "client" } };
    const descriptors = { TOKEN: { ...editable, editable: false } };
    ui.update({ values, metadata, descriptors });
    ui.button(".op-del", "TOKEN").fire("click");
    ui.update({ values, metadata: revoked === "owner" ? { TOKEN: { visibility: "secret", owner: "agent" } } : metadata, descriptors: revoked === "descriptor" ? { TOKEN: { ...editable, editable: false, deletable: false } } : descriptors });
    assert.equal(ui.button(".op-del", "TOKEN").disabled, true);
    ui.ids["delete-confirm"].fire("click");
    assert.equal(ui.actions.length, 0);
  });
}

test("ordinary fields retain descriptor-gated editing, witness and existing invisible filtering", () => {
  const ui = surface();
  ui.update({ locale: "en", values: { field: "visible", hidden: "internal", locked: "read only" }, metadata: { hidden: { visibility: "invisible" } }, descriptors: { field: editable, locked: { ...editable, editable: false } } });
  assert.equal(ui.ids["vars-list"].innerHTML.includes('data-key="hidden"'), false);
  assert.equal(ui.button(".op-edit", "locked").disabled, true);
  ui.button(".op-edit", "field").fire("click");
  ui.ids["modal-val"].value = '"updated"';
  ui.ids["modal-save"].fire("click");
  assert.equal(ui.actions.length, 1);
  assert.equal(ui.actions[0].name, "save-json");
  assert.equal(ui.actions[0].payload.value, "updated");
  assert.equal(ui.actions[0].payload.expected.revision, 1);
});
