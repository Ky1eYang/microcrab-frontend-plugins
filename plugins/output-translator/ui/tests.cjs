const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

// Exercise authored scripts and their actual control attributes without browser dependencies.
function surface(name, saved = {}, locale = "zh-CN") {
  const directory = path.join(__dirname, name);
  const html = fs.readFileSync(path.join(directory, "index.html"), "utf8");
  const nodes = [...html.matchAll(/<(\w+)\b([^>]*)>/g)].map(([, tag, attrs]) => {
    const attributes = Object.fromEntries([...attrs.matchAll(/([\w-]+)="([^"]*)"/g)].map(([, key, value]) => [key, value]));
    const events = {};
    return {
      tag, attributes, id: attributes.id, type: attributes.type || "", value: "", checked: false, disabled: false,
      dataset: { ...(attributes["data-field"] ? { field: attributes["data-field"] } : {}), ...(attributes["data-i18n"] ? { i18n: attributes["data-i18n"] } : {}) },
      addEventListener(event, handler) { events[event] = handler; },
      fire(event) { events[event]?.({ preventDefault() {} }); },
      replaceChildren(...children) { this.children = children; }, reportValidity() { return true; }
    };
  });
  const ids = Object.fromEntries(nodes.filter((node) => node.id).map((node) => [node.id, node]));
  const actions = [];
  let onViewState;
  const document = {
    documentElement: {}, getElementById: (id) => ids[id], createElement: () => ({}),
    querySelectorAll: (selector) => nodes.filter((node) => selector.split(",").some((part) => part.startsWith("#") ? node.id === part.slice(1) : part === "[data-field]" ? node.dataset.field : node.dataset.i18n))
  };
  vm.runInNewContext(fs.readFileSync(path.join(directory, "app.js"), "utf8"), {
    document, window: { microcrab: { action: (name, payload) => actions.push({ name, payload }), onViewState: (listener) => { onViewState = listener; } }, addEventListener() {} }, URL
  });
  const config = { provider: "siliconflow", source: "auto", target: "zh-CN", model: "tencent/Hunyuan-MT-7B", temperature: 0.3, prompt: "Keep my prompt", auto_translate: true, assistant_only: true, display_mode: "inline", skip_same_language: true, ...saved };
  const update = (extra = {}) => onViewState({ config, locale, resources: [{ id: "siliconflow", endpoint: "https://api.siliconflow.cn/v1/chat/completions", enabled: true }], ...extra });
  update();
  return { ids, nodes, actions, config, update };
}

for (const name of ["settings", "sidebar"]) {
  test(`${name}: auto, display and assistant controls retain compatible values in both locales`, () => {
    const ui = surface(name, { display_mode: "after", assistant_only: false });
    const controls = ui.nodes.filter((node) => ["auto_translate", "display_mode", "assistant_only"].includes(node.id));
    assert.deepEqual(controls.map((node) => node.id), ["auto_translate", "display_mode", "assistant_only"]);
    assert.equal(ui.ids.display_mode.value, "after");
    assert.equal(ui.ids.assistant_only.checked, false);
    assert.deepEqual(ui.nodes.filter((node) => node.dataset.i18n === "display").map((node) => node.textContent), ["显示格式"]);
    ui.update({ locale: "en" });
    assert.deepEqual(ui.nodes.filter((node) => node.dataset.i18n === "display").map((node) => node.textContent), ["Display format"]);
    assert.match(ui.ids["assistant-hint"].textContent, /completed user text/);
    assert.match(ui.ids["assistant-hint"].textContent, /Tools and reasoning remain excluded/);
  });
}

test("settings: saved custom model and prompt survive provider changes and full ACK-correlated save", () => {
  const customModel = '自定义 model / : @ < > & " 🚀';
  const ui = surface("settings", { model: customModel, display_mode: "after" });
  assert.equal(ui.ids.model.tag, "input");
  assert.equal(ui.ids.model.type, "text");
  assert.equal(ui.ids.model.attributes.list, undefined);
  assert.equal(ui.nodes.some((node) => node.tag === "datalist"), false);
  ui.ids.provider.value = "custom"; ui.ids.provider.fire("input");
  assert.equal(ui.ids.model.value, customModel);
  ui.ids.provider.value = "siliconflow"; ui.ids.provider.fire("input");
  assert.equal(ui.ids.model.value, customModel);
  ui.ids.auto_translate.checked = false; ui.ids.auto_translate.fire("input");
  ui.ids.assistant_only.checked = false; ui.ids.assistant_only.fire("input");
  ui.ids["save"].fire("click");
  const { name, payload } = ui.actions[0];
  assert.equal(name, "settings.save");
  assert.deepEqual(JSON.parse(JSON.stringify(payload.config)), { ...ui.config, auto_translate: false, assistant_only: false });
  assert.equal(payload.authorization, "");
  assert.equal(ui.ids.save.disabled, true);
  ui.update({ save: { operation_id: "unrelated", status: "applied" } });
  assert.equal(ui.ids.save.disabled, true);
  ui.update({ save: { operation_id: payload.operation_id, status: "unknown" } });
  ui.ids.save.fire("click"); assert.equal(ui.actions.length, 1);
  ui.update({ config: payload.config, save: { operation_id: payload.operation_id, status: "applied" } });
  assert.equal(ui.ids.save.disabled, false);
  assert.equal(ui.ids.model.value, customModel);
});

test("settings: arbitrary edited model remains exact through view updates and Save", () => {
  const ui = surface("settings");
  assert.equal(ui.ids.model.value, "tencent/Hunyuan-MT-7B");
  const model = "任意/模型 + punctuation:!@#$%^&*() 🚀";
  ui.ids.model.value = model; ui.ids.model.fire("input");
  ui.update();
  assert.equal(ui.ids.model.value, model);
  ui.ids.save.fire("click");
  assert.equal(ui.actions[0].payload.config.model, model);
});

test("sidebar: Apply preserves custom model and full saved config", () => {
  const ui = surface("sidebar", { model: "saved/custom:any-模型", display_mode: "after" });
  ui.ids.auto_translate.checked = false; ui.ids.auto_translate.fire("change");
  ui.ids.apply.fire("click");
  assert.equal(ui.actions[0].name, "control");
  assert.deepEqual(JSON.parse(JSON.stringify(ui.actions[0].payload)), { ...ui.config, auto_translate: false });
});

test("sidebar: all supported languages remain selectable through locale changes Apply and Swap", () => {
  const supported = ["en", "zh-CN", "zh-TW", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "ar"];
  for (const language of supported) {
    const ui = surface("sidebar", { source: language, target: language });
    for (const locale of ["zh-CN", "en"]) {
      ui.update({ locale });
      for (const id of ["source", "target"]) {
        assert.ok(ui.ids[id].children.some((option) => option.value === language), `${id} offers ${language} in ${locale}`);
        assert.equal(ui.ids[id].value, language);
      }
    }
    ui.ids.apply.fire("click");
    assert.equal(ui.actions[0].payload.source, language);
    assert.equal(ui.actions[0].payload.target, language);
    ui.ids.target.value = language === "en" ? "zh-CN" : "en";
    ui.ids.target.fire("change");
    ui.ids.swap.fire("click");
    assert.equal(ui.actions[1].payload.source, language === "en" ? "zh-CN" : "en");
    assert.equal(ui.actions[1].payload.target, language);
  }
});
