# MicroCrab frontend plugins (Zig)

This root-only modular workspace builds State Viewer and MCP Bridge against
`microcrab:client-plugin@0.4.0`, using Zig 0.13.0 and an already installed
`wasm-tools`. Package and plugin manifest release versions are `0.4.0`.
Plugin `build.zig` files export registration declarations for the root Build;
they are not standalone package entrypoints.

```powershell
zig build                         # all validated WIT Components
zig build component               # same selection
zig build all                     # same selection
zig build state-viewer            # one validated Component
zig build mcp-bridge               # one validated Component
zig build -Doptimize=ReleaseSafe   # default is ReleaseSmall
zig build test                    # native plugin and installer tests
zig build installer-test
zig build state-viewer-test
zig build mcp-bridge-test
```

`-Dplugins=state-viewer,mcp-bridge` restricts aggregate default/all/component/test
and install-frontend selection (default both). Empty/unknown names fail; duplicate
slugs are deduplicated. Individual plugin targets remain available independently.
The outer canonical entry is `cargo xtask wasm zig-plugins -p state-viewer -p
mcp-bridge`; it delegates one Zig invocation and requires explicit `--install-dir`
for publication. The outer `wasm plugins` scope remains a Rust fixture compatibility
path and must not be used as routine maintained-plugin publication.

Guest compilation is always `wasm32-freestanding`, without automatic WASI
adapters. Native bundler, installer and tests use the host target and Debug.
`-Doptimize` overrides the guest optimization mode; `--release=fast|safe|small`
is also supported when no explicit `-Doptimize` is supplied.

Default and targeted outputs are `zig-out/bin/state_viewer.component.wasm` and
`zig-out/bin/mcp_bridge.component.wasm`. Every Component embeds its declared WIT
world, is componentized, validated, and checked by Component WIT extraction
before installation into `zig-out`. Core/embedded intermediates stay in the Zig
cache. Explicit `state-viewer-core` and `mcp-bridge-core` diagnostics install
Core modules under `zig-out/diagnostics/`; these are not distribution artifacts.
No normal build stages browser resources or downloads missing tools.

The official WIT owner is
`../microcrab-frontend/crates/client/plugins/wit/client-plugin.wit`.
The workspace copy in `wit/client-plugin.wit` must match it byte for byte.
State Viewer uses world `state-viewer`, importing State inspection and governed
State writes. MCP Bridge uses world `tool-plugin`, importing `net` and
`resources` and exporting correlated tool start/cancel operations.

UI assets are authored as `index.html`, `style.css`, and `app.js` per surface.
The build generates embedded HTML in the cache with `tools/bundle.zig` and
injects a generated `ui_assets` module: State Viewer uses `html`; MCP Bridge
uses `settings_html` and `sidebar_html`, sourced from its `ui/settings` and
`ui/sidebar` directories. Historical checked-in bundles were removed because
maintained builds consume only these authored inputs. UI follows the host theme bridge.

State Viewer declares Sidebar and ExpandedPage only. Undeclared targets,
including SettingPage, return intentional native JSON `null` before context or
State effects. Inspection is lazy and requires the current flat
`ctx.session_id`; missing-Session views retain localized selection information.
State updates use `vars_patch: {state: <safe view state>}` and `rerender: false`,
with `view_state: {"$ref":"state"}` as the explicit HTML projection.
The complete private variable bag is never delivered to the webview.

Browser staging is explicit:

```powershell
zig build install-frontend       # aggregate selected updates for both plugins
zig build install-state-viewer   # selected update for State Viewer
zig build install-mcp-bridge     # selected update for MCP Bridge
```

Each command invokes one aggregate installer for both
`../microcrab-frontend/frontend/public/plugins` and `../public/plugins` by default.
An explicit `-Dinstall-dir=PATH` replaces both defaults with that single destination;
relative direct Zig paths resolve from this repository root. The outer Cargo entry
passes a caller-absolute destination. `-Dplugins=...` chooses the aggregate selected
updates; explicit install-state-viewer/install-mcp-bridge remain targeted updates.
The installer validates every selected Component before pointer publication,
locks each destination from index read through publication, verifies existing
immutable bytes, writes selected immutable `id/sha256/plugin.wasm` files, and
atomically replaces each `current.json`. Unselected entries, explicit defaults,
and predecessor chains are preserved. Only a missing index creates an empty
schema-version-1 index; malformed/unreadable indexes fail without replacement.
Indexes have at most 64 plugins and predecessor lists at most 16 hashes.
Release versions remain guest manifest metadata, separate from index version 1.

These staging targets explicitly pass `--adopt-current`: the current selected
packaged artifact is read, hash-checked and Component-validated before its digest
is added to the predecessor chain when bytes change. No artifact hash is
hardcoded. Existing predecessors are retained and deduplicated on adoption;
a full chain fails rather than evicting authority. Browser-local installed bytes
are never inferred as predecessors. Existing browser preferences, tombstones,
and effect reauthorization remain governed by the frontend runtime.

Direct installer usage accepts repeated `--plugin <id> <component> <true|false>`
and `--destination <directory>` groups. Adoption is disabled unless
`--adopt-current` is explicitly supplied. `.microcrab-install.lock` files are
persistent coordination files; a competing installer fails immediately with
`WouldBlock`. All writers must respect this lock: do not run the separate Rust
publisher concurrently. All destinations are prepared before pointers change,
but publication is atomic per destination, not across destinations. A later
commit failure reports how many destinations were already published. Unreferenced
immutable files can remain after a failed transaction.

State governance/parser and installer tests run natively. Actual browser
integration is owned by the frontend workspace and exercises the emitted
Components in the real runtime. Build success is not browser acceptance or
deployment.
