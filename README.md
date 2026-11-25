# MicroCrab Frontend Plugins

This repository builds WebAssembly Component plugins for the MicroCrab browser client.
Each plugin uses a WIT world that declares the host interfaces it can import.

Current examples include:

- [State Viewer](<plugins/state-viewer/>) (`state-viewer`) displays session state and supports edits where the host grants mutation authority.
- [MCP Bridge](<plugins/mcp-bridge/>) (`mcp-bridge`) connects configured MCP servers to MicroCrab's tool interface.
- [Output Translator](<plugins/output-translator/>) (`output-translator`) translates settled conversation text and publishes variants for browser display.
- [Prompt Redactor](<plugins/prompt-redactor/README.md>) (`prompt-redactor`) scans pasted text locally and lets users review and copy a bounded redacted preview.
- [External Speaker Test](<plugins/external-speaker-test/>) (`external-speaker-test`) is an opt-in visual plugin for preparing and explicitly sending an external-speaker inbox message.

## Build

Install Zig 0.13.0 and `wasm-tools` on your `PATH`.

### Aggregate build (repository root)

Run these commands from the plugin repository root.

```powershell
zig build
zig build output-translator
zig build test
```

`zig build`, `zig build component`, and `zig build all` build and validate all bundled components by default (excluding External Speaker Test). Use `-Dplugins=state-viewer,output-translator` to select plugins for an aggregate target. `zig build test` runs native tests for the selected plugins plus the installer tests.

### Standalone build (plugin directory)

Run these commands from any `plugins/<slug>/` directory in a full checkout of
this plugin repository:

```sh
zig build           # Build and validate just this Component
zig build test      # Run just this plugin's native unit tests
zig build component # Explicit equivalent of the default Component build
```

Each plugin declares its own package inputs and local dependencies in
`build.zig.zon`. A copied plugin directory alone is not a complete source tree:
it needs the checkout's shared library, bundler, and WIT mirror. The aggregate
`-Dplugins` selection, installer tests, and browser staging targets remain at
the repository root only.

Both entry points write `zig-out/bin/<stem>.component.wasm` under their own
build root by default. Each plugin's registration sets `<stem>`, and the
default guest optimization is `ReleaseSmall`. Ordinary builds leave browser
asset directories untouched.

### External Speaker Test

External Speaker Test remains opt-in and disabled by default. Build explicitly
with `zig build component -Dplugins=external-speaker-test`, or run `zig build
component` from its package directory. Neither command takes a deployment address.
This fixture is for testing only, not for production. The destination Session
must belong to a Project with External Messaging explicitly enabled. Disabling
External Messaging for that Project suspends inbox ingress and reply observation;
it does not revoke test credentials.

Reply inspection requires a Frontend with generic GET and SSE support on
explicitly approved resource grants and a Server with dialogue replies. Older
POST-only Frontends cannot inspect replies. Keep a test Session open. Authorize
the current Server inbox or an exact external inbox
URL at runtime. Use HTTPS (loopback HTTP is allowed) with the path
`/api/v1/sessions/<session-id>/inbox`. At authorization, the existing Host
stores the test speaker key in browser local storage. It is not returned to the
plugin. **Explicitly revoke the grant after testing and wait for confirmation:**
closing the browser, switching Session, or an interrupted request does not
remove persisted credentials. Use a dedicated disposable key and revoke it at
the issuing server too if local cleanup is uncertain. The POST and cURL
inspection use a key placeholder. After an acknowledged POST includes a
`dialogue_id`, the plugin automatically opens GET on the same exact URL with
`Accept: text/event-stream` and `X-MicroCrab-Dialogue-Id`. Inbound chunks and
terminal state are separate from the POST receipt. No automatic reconnect or
replay of the POST. The Host HTTP deadline applies to this stream; configure a
longer deadline in the plugin manager for slow turns. Cross-origin sends and
reads require target-side CORS.
There is no Webview networking, cookie forwarding, redirect following or
automatic retry. During testing, wait for each displayed result before taking
the next action. If rapid interactions trip the production Host's render rate
limit, reopen the plugin and inspect saved grants before retrying; never assume
that an unacknowledged revoke deleted the key. For native tests run `zig build
external-speaker-test-test` or the package's `zig build test`.

## Stage components for the browser

From the plugin repository root, run an explicit staging target. Relative `-Dinstall-dir` paths are resolved from that root.

```powershell
zig build install-output-translator -Dinstall-dir=../microcrab-frontend/frontend/public/plugins
```

Use `install-frontend` for all selected plugins or `install-<slug>` for one. Without `-Dinstall-dir`, both targets stage to `../microcrab-frontend/frontend/public/plugins` and `../public/plugins`. The installer writes content-addressed components and atomically updates each destination's `current.json`.

If using the MicroCrab superproject, run these commands from its root. The second command stages to the specified directory, relative to the caller's working directory.

```powershell
cargo xtask wasm zig-plugins -p output-translator
cargo xtask wasm zig-plugins -p output-translator --install-dir microcrab-frontend/frontend/public/plugins
```

## Reference

- [Architecture and ABI specification](<SPECIFICATION.md>)
- [Client plugin WIT mirror](<wit/client-plugin.wit>)
- [Output Translator UI contract](<plugins/output-translator/ui/README.md>)
- [Repository development rules](<AGENTS.md>)
