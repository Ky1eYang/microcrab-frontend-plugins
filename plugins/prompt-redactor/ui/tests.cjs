// Offline integration test: run the actual Zig core ABI and bundled UI using a
// synthetic DOM/bridge. No production clipboard, browser session, or installation.
const { readFileSync } = require("node:fs");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { webcrypto } = require("node:crypto");
const { join } = require("node:path");

async function run() {
  const filename = join(__dirname, "../../../zig-out/diagnostics/prompt_redactor.core.wasm");
  const module = new WebAssembly.Module(readFileSync(filename));
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const api = new WebAssembly.Instance(module).exports;
  const bytes = () => new Uint8Array(api.memory.buffer);
  const word = (pointer, index) => new DataView(api.memory.buffer).getUint32(pointer + index * 4, true);
  const read = (pointer, len) => new TextDecoder().decode(bytes().subarray(pointer, pointer + len));
  function arg(text) {
    const encoded = new TextEncoder().encode(text);
    const ptr = api.cabi_realloc(0, 0, 1, encoded.length);
    bytes().set(encoded, ptr);
    return [ptr, encoded.length];
  }
  function stringCall(name, ...args) {
    const pointer = api[name](...args);
    const value = JSON.parse(read(word(pointer, 0), word(pointer, 1)));
    api[`cabi_post_${name}`](pointer);
    return value;
  }
  const ctx = {
    schema_version: 1, session_id: "demo-session", instance_generation: 1,
    history_generation: 2, surface_generation: 3, host_monotonic_ms: 10,
    target_visible: true, surface: { target: "sidebar", surface_id: "demo-sidebar" },
    user_action: true,
  };
  function render(target = 0, context = ctx) {
    const pointer = api["render-view"](target, ...arg("{}"), ...arg(JSON.stringify(context)));
    assert.equal(word(pointer, 0), 1);
    assert.equal(word(pointer, 4), 0, "no vars patch");
    assert.equal(word(pointer, 8), 0, "no diagnostic");
    const output = {
      mode: word(pointer, 1), content: JSON.parse(read(word(pointer, 2), word(pointer, 3))),
    };
    api["cabi_post_render-view"](pointer);
    return output;
  }
  function action(payload) {
    return stringCall("on-action", ...arg("scan-preview"), ...arg(JSON.stringify(payload)), ...arg("{}"), ...arg(JSON.stringify(ctx)));
  }
  const manifest = api.manifest();
  assert.equal(read(word(manifest, 0), word(manifest, 1)), "microcrab.prompt-redactor");
  assert.deepEqual([...bytes().subarray(word(manifest, 9), word(manifest, 9) + word(manifest, 10))], [0, 1]);
  assert.equal(word(manifest, 11), 0, "no network origins");
  api.cabi_post_manifest(manifest);
  assert.deepEqual(stringCall("init", ...arg(JSON.stringify(ctx))), { schema_version: 1 });
  assert.deepEqual(render(4), { mode: 0, content: null });
  const initial = render();
  assert.equal(initial.mode, 1);
  assert.equal(initial.content.view_state, null);
  assert.equal(render(1, { ...ctx, surface: { target: "expanded-page", surface_id: "demo-expanded" } }).mode, 1);

  function element() {
    const callbacks = {};
    return {
      value: "", textContent: "", disabled: false, hidden: true,
      addEventListener: (name, callback) => { callbacks[name] = callback; },
      fire: (name) => callbacks[name](), focus() {},
    };
  }
  const elements = Object.fromEntries(["source", "scan", "clear", "copy", "status", "result", "preview"].map((id) => [id, element()]));
  elements.scan.disabled = elements.copy.disabled = true;
  let notify;
  let response;
  let nextTimer = 0;
  const timers = new Map();
  const copied = [];
  let clipboardFails = false;
  const window = {
    microcrab: {
      onViewState(callback) { notify = callback; },
      action(name, payload) {
        assert.equal(name, "scan-preview");
        response = action(payload);
      },
      async copyText(text) { if (clipboardFails) throw Error("broker denied"); copied.push(text); },
    },
    addEventListener() {},
    setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
  };
  const script = initial.content.html.match(/<script>([\s\S]+)<\/script>/)[1];
  vm.runInNewContext(script, { window, document: { getElementById: (id) => elements[id] }, crypto: webcrypto, TextEncoder });
  const { source, scan, clear, copy, status, preview } = elements;
  notify(null);
  const start = (text) => {
    source.value = text;
    source.fire("input");
    scan.fire("click");
  };
  start("Hello <b>demo@example.invalid</b>");
  assert.equal(source.value, "");
  assert.deepEqual(response, { schema_version: 1, rerender: true });
  assert.equal(render(0, { ...ctx, surface_generation: 4 }).content.view_state, null);
  const state = render().content.view_state;
  assert.equal(state.text, "Hello <b>[REDACTED]</b>");
  assert.equal(render().content.view_state, null, "guest projection is one-shot");
  notify({ ...state, id: "stale" });
  assert.equal(copy.disabled, true);
  notify(state);
  assert.equal(preview.textContent, state.text);
  assert.match(status.textContent, /some secrets may remain/);
  assert.deepEqual(copied, []);
  await copy.fire("click");
  assert.deepEqual(copied, [state.text]);
  clipboardFails = true;
  await copy.fire("click");
  assert.match(status.textContent, /Nothing was retried/);
  assert.equal(copied.length, 1);
  clear.fire("click");
  notify(state);
  assert.equal(preview.textContent, "");
  assert.equal(copy.disabled, true);

  start("no supported pattern");
  const noMatch = render().content.view_state;
  assert.equal(noMatch.text, null);
  notify(noMatch);
  assert.match(status.textContent, /No preview was produced/);
  start("Bearer DEMO-token/+= then DEMO-token/+=");
  const rejected = render().content.view_state;
  assert.equal(rejected.status, "rejected");
  assert.equal(rejected.text, null);
  notify(rejected);
  assert.equal(copy.disabled, true);
  start("another@example.invalid");
  assert.equal(render(0, { ...ctx, host_monotonic_ms: 3010 }).content.view_state, null);
  [...timers.values()][0]();
  assert.match(status.textContent, /result unavailable/);
  response = undefined;
  start("界".repeat(3000));
  assert.equal(response, undefined);
  assert.match(status.textContent, /exceeds the 8 KiB scan limit/);
  console.log("Prompt Redactor guest ABI and authored UI checks passed");
}

run().catch((error) => { console.error(error); process.exitCode = 1; });
