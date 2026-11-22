# AGENTS.md

Operational and development rules for `microcrab-frontend-plugins`.
Product setup and build entries are in [README.md](README.md); comprehensive
architecture, ABI layouts, and runtime boundaries are in [SPECIFICATION.md](SPECIFICATION.md).

## Working scope and authority

- Communicate with the user in the user's language; write agent prompts, plans, and work records in English.
- `microcrab-frontend-plugins` owns maintained Zig-based WebAssembly Component plugins
  for the MicroCrab browser client.
- The canonical WIT interface definition is owned by Frontend at:
  `microcrab-frontend/crates/client/plugins/wit/client-plugin.wit`.
  The local copy at `wit/client-plugin.wit` is an ABI mirror and MUST remain
  byte-for-byte identical to the canonical owner. Never modify local WIT without
  prior frontend authorization and corresponding host runtime updates.
- All plugins are generic, extensible participants in the client plugin ecosystem.
  New plugins can be added at any time; never assume or hardcode a fixed inventory or
  static count of plugins in build logic, documentation, or specifications.
- Follow the established lifecycle stages: inspect, discuss, confirm, implement, verify.
  Obtain user confirmation before introducing new architectural boundaries, altering
  WIT worlds, or staging artifacts into frontend runtime directories.
- Staging and deployment targets (`install-frontend`, `install-<slug>`) are explicit
  publication actions. Do not run staging tasks during routine inspection or builds.

## Repository architecture and conventions

- **Toolchain**: Zig 0.13.0 (`wasm32-freestanding` target for guest Components,
  native host for bundler, installer, and unit tests) and `wasm-tools`.
- **Modular Monorepo**:
  - `build.zig`: Root orchestrator. Aggregates plugin registrations, exposes `-Dplugins=...`
    and `-Dinstall-dir=...`, and manages component build, test, and install steps.
  - `shared/`: Local Zig package for the common guest library (`shared.abi`, `shared.host`,
    `shared.json`, `shared.types`) and common build helpers.
  - `plugins/<slug>/`: Plugin package containing `build.zig.zon`, `build.zig`, `src/`, and UI
    assets where applicable. Each manifest declares local `shared`, `tools`, and `wit`
    dependencies. Standalone commands work in a full checkout, not in a detached directory.
  - `tools/`: Build and installation host tools (`bundle.zig` for asset bundling,
    `install.zig` for atomic immutable installation). Staging is a root-only build operation.
  - `wit/`: The one client-plugin WIT mirror used by both build entries.
- **Plugin Registration Contract**:
  - Each plugin's `build.zig` provides a thin standalone `build` entry and a single `register`
    function used by both entries. The caller supplies the package path so the registration
    can identify its source and UI inputs relative to its own directory.
  - Plugin definitions declare slug, stem, canonical ID, WIT world, guest and native-test
    entrypoints, UI surfaces, and any opt-out from default enablement. Preserve explicit
    configuration requirements; do not add deployment defaults.

## Coding guidelines and TigerStyle idioms

Adhere strictly to TigerStyle principles: **Safety > Performance > Developer Experience**.

1. **Memory management and allocation**:
   - Guest compilation is strictly `wasm32-freestanding` with NO external libc and NO
     automatic WASI imports.
   - Use explicit allocators (`std.heap.wasm_allocator`, scoped arena allocators, or
     custom bounded wiping allocators). Never rely on implicit global heap state.
   - Adhere to the Canonical ABI export contract: provide `cabi_realloc` and corresponding
     `cabi_post_*` cleanup hooks to ensure host-passed strings and guest-allocated return
     buffers are freed predictably without leaks.
   - For sensitive credentials (e.g., API keys, auth headers), allocate with wiping
     wrappers and execute `std.crypto.utils.secureZero` immediately after use.
2. **Control flow and assertions**:
   - Use simple, bounded, explicit control flow. Recursion is forbidden unless provably bounded.
   - State assertions positively: assert entry arguments and preconditions.
   - Pair assertions: assert on both sides of state transitions (before writing and after reading).
   - Assert both the positive and negative spaces; verify compile-time constraints with `comptime assert`.
3. **Bounded resources**:
   - All loops, queues, and caches MUST have a fixed, compile-time or configured upper bound.
     Unbounded `while` loops without explicit bounds checks are strictly prohibited.
   - Enforce explicit live allocation quotas, payload size limits, and invocation timeouts.
4. **Error handling**:
   - Handle all errors explicitly. Never discard error returns with `_ = ...`.
   - Propagate fallible calls using `try` or catch blocks.
   - Reserve `@trap()` or `@panic()` exclusively for provably unreachable invariant violations.
5. **Structs and pointer stability**:
   - Large structures must be initialized in-place via out-pointers to avoid stack overflows
     and intermediate copies.

## Plugin boundaries and security

- **Minimal privilege**: Every plugin MUST declare and use the narrowest WIT world
  sufficient for its operational requirements (e.g., `state-viewer`, `tool-plugin`,
  `output-translator`, `fixture`, or `client-plugin`). Never request ambient capabilities
  (`net`, `resources`, `storage`, `session-state-write`) unless functionally required.
- **Secret variables governance**:
  - Client-side plugins MUST respect Secret variable boundaries.
  - Secret variables are strictly read-only and write-masked in UI views: plugins may display
    the variable key and metadata, but MUST NEVER attempt to inspect, infer, search, echo,
    or persist the secret value.
  - Secret values MUST NOT be written to plugin storage, resident browser history, or logs.
  - Plugins must never leak secret tokens or resolved credentials across uncertified endpoints.
- **Undeclared target safety**:
  - A plugin must strictly respect its declared `targets` in `manifest()`.
  - Invocations for undeclared targets (e.g., SettingPage for a visual-only sidebar plugin)
    MUST immediately return native JSON `null` before performing any context parsing,
    network requests, or state imports.

## UI construction scheme

- **Webview-HTML mode**:
  - Each UI surface directory configured in the plugin registration contains `index.html`, `style.css`, and `app.js`.
  - Author assets against the native theme bridge: consume `--microcrab-*` CSS variables
    and observe root `data-theme` changes. Do not bundle private dark/light palettes.
  - Each surface is bundled at build time via `tools/bundle.zig` into self-contained
    HTML strings embedded in `ui_assets.zig`. No runtime network fetching of UI assets is permitted.
- **Bidirectional communication bridge**:
  - Sandboxed iframes communicate exclusively via `window.microcrab`:
    - Listen for state updates via `window.microcrab.onViewState(callback)`.
    - Dispatch user actions via `window.microcrab.action(name, payload)`.
- **Safe projections**:
  - Never deliver the entire private session variable bag to webviews.
  - When using a variable reference, use `vars_patch: {state: <safe view state>}` with `view_state: {"$ref": "state"}` to project
    only necessary, filtered, and sanitized display states.

## Verification, testing, and release gates

- **Local verification**:
  - At the repository root, run `zig build test` for selected configured plugins and the
    installer; run `zig build component` (or `zig build <slug>`) for validated Components.
  - From the affected plugin directories, verify `zig build`, `zig build test`, and
    `zig build component` against the same checkout inputs. Native tests run with the
    plugin directory as their working directory from either entry point.
  - Ensure generated Components pass `wasm-tools validate` and WIT interface extraction.
    Test configuration-gated plugins both with and without their required inputs.
- **Integration with superproject**:
  - Root build and verification is orchestrated via Cargo:
    `cargo xtask wasm zig-plugins -p <slug>`. Adding `--install-dir <dir>` stages artifacts and resolves a relative path from the caller working directory.
  - Submodule commits must be recorded cleanly before updating root superproject pins.
  - Staging to frontend public directories must be atomic and locked via `.microcrab-install.lock`.
