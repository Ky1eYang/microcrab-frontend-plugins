# MicroCrab Frontend Plugins

This repository builds WebAssembly Component plugins for the MicroCrab browser client.
Each plugin uses a WIT world that declares the host interfaces it can import.

Current examples include:

- [State Viewer](<plugins/state-viewer/>) (`state-viewer`) displays session state and supports edits where the host grants mutation authority.
- [MCP Bridge](<plugins/mcp-bridge/>) (`mcp-bridge`) connects configured MCP servers to MicroCrab's tool interface.
- [Output Translator](<plugins/output-translator/>) (`output-translator`) translates settled conversation text and publishes variants for browser display.

## Build

Install Zig 0.13.0 and `wasm-tools` on your `PATH`. Run these commands from the plugin repository root.

```powershell
zig build
zig build output-translator
zig build test
```

`zig build`, `zig build component`, and `zig build all` build and validate all registered components by default. Use `-Dplugins=state-viewer,output-translator` to select plugins for an aggregate target. `zig build test` runs native tests for the selected plugins plus the installer tests.

Builds write components to `zig-out/bin/<stem>.component.wasm` by default, where each plugin's build definition sets `<stem>`. The default guest optimization is `ReleaseSmall`. Ordinary builds leave browser asset directories untouched.

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
