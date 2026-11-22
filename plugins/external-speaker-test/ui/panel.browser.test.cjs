// Run from the plugin repository root with its sibling Frontend dependencies available:
// NODE_PATH=../microcrab-frontend/frontend/node_modules CHROME_BIN="$(command -v google-chrome)" \
//   node --test plugins/external-speaker-test/ui/panel.browser.test.cjs
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test, before, after } = require("node:test");
const { chromium } = require("playwright");

const fromUi = (file) => readFileSync(join(__dirname, file), "utf8");
const html = fromUi("index.html")
  .replace("/* CSS will be embedded here */", () => fromUi("style.css"))
  .replace("/* JS will be embedded here */", () => fromUi("app.js"));
const mock = `<script>
  window.actions = [];
  window.copies = [];
  window.microcrab = {
    onViewState(subscriber) { window.project = subscriber; },
    action(name, payload) {
      if (window.failSend) throw Error("channel closed");
      actions.push({ name, payload: structuredClone(payload) });
    },
    async copyText(text) {
      copies.push(text);
      if (window.deferCopy) await new Promise((resolve) => { window.finishCopy = resolve; });
    },
  };
</script>`;
const origin = "https://connected-test.example:8443";
const selected = { origin, session: "test_session", host_credentials: true };
const connectedUrl = `${origin}/api/v1/sessions/${selected.session}/inbox`;
const connected = { endpoint: connectedUrl, name: "Connected test inbox", enabled: true };
const secret = "a".repeat(43);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
let browser;
before(async () => {
  browser = await chromium.launch({ executablePath: process.env.CHROME_BIN });
});
after(async () => { await browser?.close(); });

async function usingPage(fn, settings = {}) {
  const page = await browser.newPage(settings);
  try {
    // Playwright's locale override may not reach an opaque-origin srcdoc.
    // Inject the same browser preference into the guest when selecting a locale.
    const locale = settings.locale ? `<script>Object.defineProperty(navigator, "language", {get: () => ${JSON.stringify(settings.locale)}});</script>` : "";
    // Match the Host's nested guest markup and restrictive action policy.
    const guest = `<!doctype html><html><head>
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; form-action 'none'">
      ${locale}${mock}</head><body>${html}</body></html>`;
    const embedded = guest.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
    await page.setContent(`<style>body{margin:0}iframe{border:0;width:100vw;height:99vh}</style>
      <iframe sandbox="allow-scripts" srcdoc="${embedded}"></iframe>`);
    const iframe = await page.locator("iframe").elementHandle();
    const frame = await iframe.contentFrame();
    await frame.waitForFunction(() => typeof window.project === "function");
    await fn(frame, page);
  } finally {
    await page.close();
  }
}
const project = (page, value = {}) => page.evaluate((value) => window.project(value), value);
const actions = (page) => page.evaluate(() => window.actions);
const active = (page) => page.evaluate(() => document.activeElement.id);
const result = (page) => page.locator("#result").getAttribute("data-kind");
const locator = (page, id) => page.locator(`#${id}`);
const value = (page, id) => locator(page, id).inputValue();
const fill = (page, id, input) => locator(page, id).fill(input);
const click = (page, id) => locator(page, id).click();
const expand = (page) => page.locator("#advanced > summary").click();
const compose = (page, message = "Test inbox message") => fill(page, "message", message);
const acknowledge = (page, state, connections, actionId) => project(page, {
  ...state, connections, connection_action_id: actionId, connection_status: "ready",
});
async function loadGrants(page, state = selected, connections = [connected], listId = 1) {
  await project(page, { ...state, connections });
  assert.deepEqual((await actions(page)).at(-1), { name: "list", payload: { action_id: listId } });
  await acknowledge(page, state, connections, listId);
}
const sends = async (page) => (await actions(page)).filter(({ name }) => name === "send");

test("read-only destination; accessible custom errors, UTF-8 count, and focus", async () => usingPage(async (page) => {
  assert.equal(await locator(page, "send").isDisabled(), true);
  await project(page, { ...selected, host_credentials: undefined, connections: [connected] });
  assert.equal(await locator(page, "send").isDisabled(), true);
  assert.deepEqual(await actions(page), []);
  await loadGrants(page);
  assert.equal(await locator(page, "origin").textContent(), origin);
  assert.equal(await locator(page, "session").textContent(), selected.session);
  assert.equal(await page.locator(".page-header :is(input[type=url], input[name=origin], input[name=server])").count(), 0);
  assert.equal(await locator(page, "advanced").getAttribute("open"), null);
  assert.equal(await page.getByLabel("Message (required)").count(), 1);
  assert.equal(await locator(page, "message").getAttribute("aria-invalid"), "false");
  await click(page, "send");
  assert.equal(await active(page), "message");
  assert.equal(await locator(page, "message").getAttribute("aria-describedby"), "message-help message-error");
  await fill(page, "message", "中".repeat(2731));
  assert.equal(await locator(page, "length").textContent(), "8193 / 8192 bytes");
  await click(page, "send");
  assert.equal(await active(page), "message");
  await fill(page, "message", "\u0085\u3000");
  await click(page, "send");
  assert.equal(await active(page), "message");
  await fill(page, "message", "你好");
  assert.equal(await locator(page, "length").textContent(), "6 / 8192 bytes");
  assert.equal(await locator(page, "message").getAttribute("aria-describedby"), "message-help");
  await expand(page);
  await fill(page, "operation", "bad-id");
  await expand(page);
  await click(page, "send");
  assert.equal(await active(page), "operation");
  assert.equal(await locator(page, "operation-error").isVisible(), true);
  assert.deepEqual(await sends(page), []);
}));

test("preview and clipboard never dispatch send or include the typed key", async () => usingPage(async (page) => {
  await loadGrants(page, selected, []);
  await compose(page, "Draft 'quoted'\nbody");
  await fill(page, "token", secret);
  assert.equal(await locator(page, "send").isDisabled(), true);
  await expand(page);
  const initialOperation = await value(page, "operation");
  assert.match(initialOperation, uuid);
  await click(page, "new-key");
  const operation = await value(page, "operation");
  assert.match(operation, uuid);
  assert.notEqual(operation, initialOperation);
  await click(page, "preview");
  assert.deepEqual((await actions(page)).at(-1), { name: "preview", payload: { session: selected.session, message: "Draft 'quoted'\nbody", operation, action_id: 2 } });
  assert.equal(await value(page, "token"), secret);
  const command = "curl -q --header 'Authorization: Bearer <EXTERNAL_SPEAKER_TOKEN>'";
  await project(page, { ...selected, action_id: 2, status: "preview", preview: command, preview_operation: operation });
  assert.equal(await value(page, "curl"), command);
  await click(page, "copy");
  assert.match(await locator(page, "copy-status").textContent(), /placeholder/);
  assert.deepEqual(await page.evaluate(() => window.copies), [command]);
  await fill(page, "message", "Edited");
  assert.equal(await locator(page, "command").isVisible(), false);
  assert.equal(await value(page, "curl"), "");
  assert.equal(await result(page), "idle");
}));

test("reply projection displays incremental chunks, rejects a stale action, and waits for terminal", async () => usingPage(async (page) => {
  await loadGrants(page);
  await compose(page);
  await click(page, "send");
  const operation = await value(page, "operation");
  const preview = "curl -q --header 'Authorization: Bearer <EXTERNAL_SPEAKER_TOKEN>'";
  const state = { ...selected, action_id: 2, status: "queued", operation, ordinal: "1", http_status: 202, preview };
  await project(page, { ...state, reply: { dialogue_id: "0123abcd", status: "waiting", chunks: [] } });
  assert.equal(await locator(page, "reply-stream").isVisible(), true);
  assert.equal(await locator(page, "next-send").getAttribute("aria-disabled"), "true");
  await project(page, { ...state, action_id: 1, reply: { dialogue_id: "87654321", status: "completed", chunks: [] } });
  assert.match(await locator(page, "reply-status").textContent(), /0123abcd/);
  const chunks = [{ index: 0, message: "<b>literal reply</b>" }];
  await project(page, { ...state, reply: { dialogue_id: "0123abcd", status: "consumed", chunks } });
  assert.equal(await locator(page, "reply-chunks").textContent(), "<b>literal reply</b>");
  await expand(page);
  const previewButton = locator(page, "preview");
  assert.equal(await previewButton.getAttribute("aria-disabled"), "true");
  const beforePreview = await actions(page);
  await previewButton.press("Enter");
  await previewButton.click({ force: true });
  assert.deepEqual(await actions(page), beforePreview);
  assert.equal(await value(page, "curl"), preview);
  await project(page, { ...state, reply: { dialogue_id: "0123abcd", status: "completed", chunks } });
  assert.equal(await locator(page, "next-send").getAttribute("aria-disabled"), "false");
  assert.equal((await sends(page)).length, 1);
}));

test("only a trusted submit sends; pending, queued, consumed and rejected have explicit receipts", async () => usingPage(async (page) => {
  await loadGrants(page);
  await compose(page);
  const operation = await value(page, "operation");
  await page.evaluate(() => {
    const button = document.getElementById("send");
    button.click();
    button.form.requestSubmit(button);
  });
  assert.deepEqual(await sends(page), []);
  await click(page, "send");
  assert.equal(await active(page), "send");
  assert.deepEqual(await sends(page), [{ name: "send", payload: { session: selected.session, message: "Test inbox message", operation, action_id: 2 } }]);
  assert.equal(await value(page, "token"), "");
  assert.equal(await result(page), "submitting");
  await locator(page, "send").press("Enter");
  assert.equal((await sends(page)).length, 1);
  await project(page, { ...selected, action_id: 2, status: "pending", operation });
  assert.equal(await result(page), "pending");
  await project(page, { ...selected, action_id: 2, status: "queued", operation, ordinal: "18446744073709551615", http_status: 202 });
  assert.equal(await result(page), "queued");
  assert.equal(await locator(page, "receipt-operation").textContent(), operation);
  assert.equal(await locator(page, "receipt-ordinal").textContent(), "18446744073709551615");
  assert.equal(await locator(page, "receipt-http").textContent(), "202");
  assert.equal(await active(page), "send");

  for (const [actionId, status, httpStatus] of [[3, "consumed", 200], [4, "rejected", 403]]) {
    await click(page, "next-send");
    assert.equal(await active(page), "message");
    assert.equal(await value(page, "message"), "");
    assert.notEqual(await value(page, "operation"), operation);
    await compose(page);
    await locator(page, "send").press("Enter");
    await project(page, { ...selected, action_id: actionId, status, operation: await value(page, "operation"), http_status: httpStatus });
    assert.equal(await result(page), status);
    assert.equal(await locator(page, "receipt-http").textContent(), String(httpStatus));
  }
  assert.equal((await sends(page)).length, 3);
}));

test("unknown outcome is explicit, fenced, and never retried; a timed-out send can settle late", async () => usingPage(async (page, host) => {
  await host.clock.install();
  await loadGrants(page);
  await compose(page);
  const operation = await value(page, "operation");
  await click(page, "send");
  await project(page, { ...selected, action_id: 2, status: "pending", operation });
  await host.clock.fastForward(310_001);
  assert.equal(await result(page), "outcome_unknown");
  assert.match(await locator(page, "result").textContent(), /Check the Session.+No automatic retry/);
  assert.equal(await locator(page, "send").getAttribute("aria-disabled"), "true");
  await locator(page, "send").press("Enter");
  assert.equal((await sends(page)).length, 1);
  await click(page, "next-send");
  assert.notEqual(await value(page, "operation"), operation);
  assert.equal(await value(page, "token"), "");
  await project(page, { ...selected, action_id: 2, status: "consumed", operation, ordinal: "10", http_status: 200 });
  assert.equal(await result(page), "consumed");
  assert.equal(await locator(page, "send").getAttribute("aria-disabled"), "false");
  assert.equal((await sends(page)).length, 1);
  await compose(page);
  await page.evaluate(() => { window.failSend = true; });
  await click(page, "send");
  assert.equal(await result(page), "outcome_unknown");
  assert.equal(await value(page, "token"), "");
}));

test("origin and Session changes retire draft, stale receipts and clipboard feedback", async () => usingPage(async (page) => {
  await loadGrants(page);
  await compose(page);
  await click(page, "send");
  const other = { ...selected, session: "other_session" };
  await loadGrants(page, other, [], 3);
  await compose(page, "New scope");
  await expand(page);
  await click(page, "preview");
  const operation = await value(page, "operation");
  await project(page, { ...other, action_id: 2, status: "queued", ordinal: "8", http_status: 202 });
  assert.equal(await result(page), "idle");
  await project(page, { ...other, action_id: 4, status: "preview", preview: "curl command", preview_operation: operation });
  await page.evaluate(() => { window.deferCopy = true; });
  await click(page, "copy");
  await project(page, { ...other, origin: "https://other.example" });
  await page.evaluate(() => window.finishCopy());
  for (const id of ["message", "token", "curl"]) assert.equal(await value(page, id), "");
  assert.equal(await locator(page, "copy-status").textContent(), "");
  assert.equal(await result(page), "idle");
  assert.equal((await actions(page)).filter(({ name }) => name !== "list").length, 2);
  for (const issue of ["wrong_origin", "unsupported_origin", "no_session"]) {
    await project(page, { ...selected, session: issue === "no_session" ? null : selected.session, issue });
    assert.equal(await locator(page, "send").isDisabled(), true);
    assert.match(await locator(page, "availability").textContent(), issue === "no_session" ? /Open an active Session/ : /unsupported/);
  }
  await loadGrants(page, selected, [], 6);
  await compose(page);
  await fill(page, "token", secret);
  await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
  assert.equal(await value(page, "token"), "");
  assert.equal(await value(page, "message"), "");
  await project(page, selected);
  assert.equal(await locator(page, "send").isDisabled(), true);
}));

test("Host theme changes keep the draft and keyboard focus; forced colors retain an outline", async () => usingPage(async (page, host) => {
  await loadGrants(page);
  await compose(page);
  await locator(page, "message").focus();
  const applyTheme = (scheme, ink) => page.evaluate(({ scheme, ink }) => {
    document.documentElement.dataset.theme = scheme;
    document.documentElement.style.setProperty("--microcrab-text", ink);
  }, { scheme, ink });
  const color = () => page.locator("main").evaluate((el) => getComputedStyle(el).color);
  await applyTheme("light", "rgb(14, 18, 24)");
  assert.equal(await color(), "rgb(14, 18, 24)");
  await applyTheme("dark", "rgb(240, 242, 250)");
  assert.equal(await color(), "rgb(240, 242, 250)");
  assert.equal(await value(page, "message"), "Test inbox message");
  assert.equal(await active(page), "message");
  await host.emulateMedia({ forcedColors: "active" });
  await page.waitForFunction(() => matchMedia("(forced-colors: active)").matches);
  await locator(page, "message").press("Tab");
  assert.equal(await active(page), "send");
  assert.equal(await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle), "solid");
  assert.deepEqual(await sends(page), []);
}));

test("zh-CN at 390px and English at 1440px fit without horizontal scroll", async () => {
  for (const [width, locale, lang, title] of [[390, "zh-CN", "zh-CN", "外部发言者测试"], [1440, "en-US", "en", "External Speaker Test"]]) {
    await usingPage(async (page) => {
      await loadGrants(page, { ...selected, origin: `https://${"subdomain.".repeat(16)}example:3443`, session: "s".repeat(128) }, []);
      await expand(page);
      await fill(page, "message", "中".repeat(2500));
      assert.equal(await page.title(), title);
      assert.equal(await page.locator("html").getAttribute("lang"), lang);
      const dimensions = await page.evaluate(() => ({
        scroll: document.documentElement.scrollWidth,
        client: document.documentElement.clientWidth,
        compose: document.querySelector(".compose").getBoundingClientRect().top,
        receipt: document.querySelector(".receipt").getBoundingClientRect().top,
      }));
      assert.equal(dimensions.scroll, dimensions.client);
      assert.equal(dimensions.receipt === dimensions.compose, width === 1440);
    }, { locale, viewport: { width, height: 900 } });
  }
});

const externalUrl = "https://speaker.example:9443/api/v1/sessions/remote_session/inbox";
const external = { endpoint: externalUrl, name: "Remote test inbox", enabled: true };
const withConnections = (connections, extra = {}) => ({ ...selected, connections, ...extra });

test("add, authorize, select, revoke and remove exact endpoints through the Host", async () => usingPage(async (page) => {
  await project(page, withConnections([]));
  assert.deepEqual(await actions(page), [{ name: "list", payload: { action_id: 1 } }]);
  await project(page, withConnections([], { connection_action_id: 1, connection_status: "ready" }));
  await compose(page, "Live draft");
  await fill(page, "token", secret);
  await click(page, "add-connection-summary");
  await fill(page, "connection-name", external.name);
  for (const blocked of [
    "http://speaker.example/api/v1/sessions/target/inbox",
    `${externalUrl}?token=abc`, `${externalUrl}#`, `${externalUrl}/`,
    "https://name@speaker.example/api/v1/sessions/target/inbox",
    "https://speaker.example:443/api/v1/sessions/target/inbox",
  ]) {
    await fill(page, "endpoint", blocked);
    await click(page, "add-connection");
    assert.equal(await active(page), "endpoint");
    assert.equal(await locator(page, "endpoint").getAttribute("aria-invalid"), "true");
  }
  await fill(page, "endpoint", externalUrl);
  await click(page, "add-connection");
  assert.equal(await active(page), "destination");
  assert.equal(await value(page, "destination"), externalUrl);
  assert.equal(await value(page, "token"), "");
  assert.equal(await value(page, "message"), "");
  assert.equal(await locator(page, "send").isDisabled(), true);
  assert.equal((await actions(page)).length, 1);
  await page.evaluate(() => document.getElementById("authorize").click());
  assert.equal((await actions(page)).length, 1);
  await click(page, "authorize");
  assert.equal(await active(page), "token");
  assert.match(await locator(page, "token-error").textContent(), /43–128/);
  await fill(page, "token", secret);
  await click(page, "authorize");
  assert.equal(await value(page, "token"), "");
  assert.deepEqual((await actions(page)).at(-1), { name: "authorize", payload: { endpoint: externalUrl, name: external.name, token: secret, action_id: 2 } });
  await project(page, withConnections([], { connection_action_id: 2, connection_status: "pending" }));
  assert.equal(await locator(page, "send").isDisabled(), true);
  await project(page, withConnections([external], { connection_action_id: 2, connection_status: "ready" }));
  assert.equal(await locator(page, "send").isDisabled(), false);
  await compose(page, "External draft");
  await click(page, "revoke");
  assert.deepEqual((await actions(page)).at(-1), { name: "revoke", payload: { endpoint: externalUrl, action_id: 3 } });
  await project(page, withConnections([], { connection_action_id: 3, connection_status: "ready" }));
  assert.equal(await value(page, "token"), "");
  assert.equal(await locator(page, "send").isDisabled(), true);
  await click(page, "remove-connection");
  assert.equal(await value(page, "destination"), "");
  assert.equal(await locator(page, "send").isDisabled(), true);
  assert.equal(await page.locator("#destination option").count(), 1);
  assert.equal((await actions(page)).length, 3);
}));

test("external POST keeps the local Session fence and renders HTTP receipts as text", async () => usingPage(async (page) => {
  await project(page, withConnections([external], { connection_action_id: 4, connection_status: "ready" }));
  await project(page, withConnections([external], { connection_action_id: 5, connection_status: "ready" }));
  assert.equal(await value(page, "destination"), "");
  await locator(page, "destination").press("ArrowDown");
  await compose(page, "External draft");
  await expand(page);
  const operation = await value(page, "operation");
  const body = JSON.stringify({ body: "External draft" });
  const request = { url: externalUrl, method: "POST", headers: { Authorization: "Bearer SHOULD_NOT_RENDER", "Idempotency-Key": operation }, body };
  const preview = "curl -q --header 'Authorization: Bearer <EXTERNAL_SPEAKER_TOKEN>'";
  const projected = { endpoint: externalUrl, request, preview, preview_operation: operation };
  await click(page, "preview");
  assert.deepEqual((await actions(page)).at(-1), { name: "preview", payload: { session: selected.session, endpoint: externalUrl, operation, message: "External draft", action_id: 6 } });
  await project(page, withConnections([external], { ...projected, action_id: 6, status: "preview" }));
  await page.locator("#request-details > summary").click();
  assert.equal(await locator(page, "request-line").textContent(), `POST ${externalUrl}`);
  assert.match(await locator(page, "request-headers").textContent(), /Bearer <EXTERNAL_SPEAKER_TOKEN>/);
  assert.doesNotMatch(await locator(page, "request-headers").textContent(), /SHOULD_NOT_RENDER/);
  assert.equal(await locator(page, "request-body").textContent(), body);
  assert.equal(await value(page, "curl"), preview);
  await click(page, "send");
  assert.deepEqual((await actions(page)).at(-1), { name: "send", payload: { session: selected.session, endpoint: externalUrl, operation, message: "External draft", action_id: 7 } });
  assert.equal(await value(page, "token"), "");
  const response = { status: 403, truncated: true, headers: [{ name: "content-type", value: "text/html" }], body: "<img src=x onerror=alert(1)>" };
  await project(page, withConnections([external], { ...projected, endpoint: `${externalUrl}2`, action_id: 7, status: "rejected", response }));
  assert.equal(await result(page), "submitting");
  await project(page, withConnections([external], { ...projected, action_id: 7, status: "rejected", response }));
  await page.locator("#response-details > summary").click();
  assert.equal(await locator(page, "response-status").textContent(), "HTTP status: 403");
  assert.equal(await locator(page, "response-truncated").isVisible(), true);
  assert.equal(await locator(page, "response-body").textContent(), response.body);
  assert.equal(await page.locator("#response-body img").count(), 0);
  await locator(page, "destination").press("ArrowUp");
  assert.equal(await locator(page, "response-details").isVisible(), false);
  assert.equal(await locator(page, "response-body").textContent(), "");
  assert.equal(await value(page, "curl"), "");
}));

test("uncertain removal never retries or sends and scope changes retire external state", async () => usingPage(async (page, host) => {
  await host.clock.install();
  const loopback = { endpoint: "http://[::1]:9443/api/v1/sessions/loopback/inbox", name: "Loopback inbox", enabled: false };
  await project(page, withConnections([loopback]));
  await project(page, withConnections([loopback], { connection_action_id: 1, connection_status: "ready" }));
  await locator(page, "destination").press("ArrowDown");
  assert.equal(await value(page, "destination"), loopback.endpoint);
  assert.equal(await locator(page, "send").isDisabled(), true);
  assert.equal(await locator(page, "authorize").isVisible(), true);
  assert.equal(await locator(page, "revoke").isVisible(), true);
  await click(page, "remove-connection");
  assert.deepEqual((await actions(page)).at(-1), { name: "revoke", payload: { endpoint: loopback.endpoint, action_id: 2 } });
  await host.clock.fastForward(15_001);
  assert.match(await locator(page, "connection-status").textContent(), /may still be saved/);
  assert.equal((await actions(page)).length, 2);
  assert.equal(await locator(page, "send").isDisabled(), true);
  assert.equal(await locator(page, "remove-connection").isDisabled(), true);
  await click(page, "refresh-connections");
  assert.deepEqual((await actions(page)).at(-1), { name: "list", payload: { action_id: 3 } });
  await project(page, withConnections([], { connection_action_id: 3, connection_status: "ready" }));
  assert.equal(await value(page, "token"), "");
  assert.equal(await locator(page, "send").isDisabled(), true);
  await project(page, { ...selected, session: "another_local_session", connections: [] });
  assert.equal(await value(page, "destination"), "");
  assert.equal(await value(page, "message"), "");
  assert.equal(await page.locator("#destination option").count(), 1);
  assert.equal((await actions(page)).at(-1).name, "list");
}));


test("connected Host saves only on trusted valid authorization; completion and pagehide never clear it", async () => usingPage(async (page) => {
  await loadGrants(page, selected, []);
  assert.equal(await value(page, "destination"), "");
  assert.equal(await locator(page, "connection-endpoint").textContent(), connectedUrl);
  assert.match(await locator(page, "credential-advisory").textContent(), /local storage.+does not remove it.+wait for Host confirmation/);
  await compose(page);
  assert.equal(await locator(page, "send").isDisabled(), true);
  await fill(page, "token", "short");
  await click(page, "authorize");
  assert.equal(await active(page), "token");
  assert.equal((await actions(page)).length, 1);
  await fill(page, "token", secret);
  await page.evaluate(() => document.getElementById("authorize").click());
  assert.equal((await actions(page)).length, 1);
  await click(page, "authorize");
  assert.deepEqual((await actions(page)).at(-1), { name: "authorize", payload: {
    action_id: 2, endpoint: connectedUrl, name: "Connected Server · Active Session", token: secret,
  } });
  assert.equal(await value(page, "token"), "");
  assert.equal(await locator(page, "send").isDisabled(), true);
  await acknowledge(page, selected, [connected], 123);
  assert.equal(await locator(page, "send").isDisabled(), true);
  await acknowledge(page, selected, [connected], 2);
  assert.equal(await locator(page, "revoke").isVisible(), true);
  assert.equal(await locator(page, "token").isVisible(), false);
  assert.equal(await page.locator("#destination option").count(), 1);
  const operation = await value(page, "operation");
  await click(page, "send");
  assert.deepEqual(await sends(page), [{ name: "send", payload: {
    action_id: 124, session: selected.session, operation, message: "Test inbox message",
  } }]);
  await project(page, { ...selected, action_id: 124, status: "queued", operation, http_status: 202 });
  assert.equal(await locator(page, "revoke").isDisabled(), false);
  assert.equal((await actions(page)).length, 3);
  await page.evaluate(() => document.getElementById("revoke").click());
  assert.equal((await actions(page)).length, 3);
  await click(page, "revoke");
  assert.deepEqual((await actions(page)).at(-1), { name: "revoke", payload: { action_id: 125, endpoint: connectedUrl } });
  await project(page, { ...selected, connections: [], connection_action_id: 125, connection_status: "pending" });
  assert.doesNotMatch(await locator(page, "connection-status").textContent(), /confirmed removal/);
  await acknowledge(page, selected, [], 125);
  assert.match(await locator(page, "connection-status").textContent(), /confirmed removal.*saved key/);
  assert.equal(await locator(page, "send").isDisabled(), true);
  assert.equal(await locator(page, "token").isVisible(), true);
  await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
  assert.equal((await actions(page)).length, 4);
}));

test("every saved grant is visible for cleanup, including disabled rows", async () => usingPage(async (page) => {
  const all = Array.from({ length: 31 }, (_, i) => ({
    endpoint: `https://many.example/api/v1/sessions/test_${i}/inbox`, name: `Test ${i}`, enabled: false,
  }));
  const disabledConnected = { ...connected, enabled: false };
  await loadGrants(page, selected, [...all, disabledConnected]);
  assert.equal(await page.locator("#destination option").count(), 32);
  assert.equal(await locator(page, "revoke").isVisible(), true);
  await locator(page, "destination").press("End");
  assert.equal(await value(page, "destination"), all.at(-1).endpoint);
  assert.equal(await locator(page, "revoke").isVisible(), true);
}));
