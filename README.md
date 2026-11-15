# MicroCrab frontend plugins (Zig)

This workspace builds the maintained State Viewer against
`microcrab:client-plugin@0.4.0` using Zig 0.13.0 and an already installed
`wasm-tools`. Package and manifest release versions are `0.4.0`.

```powershell
zig version
wasm-tools --version
zig build component
zig build test
```

The component output is `zig-out/bin/state_viewer.component.wasm`.
`zig build component` embeds WIT, creates the Component and validates it. It
never installs browser resources. `zig build install-frontend` is a separate,
explicit staging action coordinated with frontend acceptance.

The official WIT owner is
`../microcrab-frontend/crates/client/plugins/wit/client-plugin.wit`.
The workspace copy in `wit/client-plugin.wit` must match it byte for byte.
Actual effect imports are State inspection and governed State writes; the
component has no WASI, network, storage or conversation effect imports.

UI source files are `plugins/state-viewer/ui/index.html`, `style.css` and
`app.js`. The build generates the embedded HTML in the Zig cache using
`tools/bundle.zig`. Historical checked-in `ui/bundle.html` and `src/bundle.html`
are preserved during this adaptation, including pre-existing user edits, but
are no longer build inputs. Edit the three authored source files to change UI.

State Viewer declares Sidebar, ExpandedPage and SettingPage. Settings is a
localized informational view: there are no plugin parameters; users inspect
state in the conversation sidebar or expanded view. It performs no State
imports, with or without a selected Session. Sidebar/expanded inspection is
lazy and requires the current flat `ctx.session_id`. Undeclared targets return
intentional native JSON `null` before State imports.

State updates use `vars_patch: {state: <safe view state>}` with `rerender: false`.
The constant HTML envelope declares `view_state: {"$ref":"state"}`; the initial
render also returns that explicit state patch. The generic frontend projection
resolves this reference on each variable publication without recreating the
iframe or consuming structural-render quota. Ignored events preserve the prior
projection. The complete private variable bag is never sent to the webview.

State inspection installs values, metadata, descriptors and witness atomically.
Existing edits require an affirmative custom-field descriptor; deletion also
requires Client ownership. Edit/delete dialogs capture the opening witness and
submit a fresh browser UUID. Queue IDs are correlated with `event-result`
completions. Only an exact matching `applied` operation receipt closes a draft;
errors retain it, and queued/unknown operations block duplicate submissions.
The Observe action reads the same operation receipt and never replays a write.
New fields retain visible/persisted scope and Agent/Client/Runtime editors.

Native tests cover strict JSON parsing, UUIDs, descriptor governance and
installer index preservation. Browser integration is owned by the frontend
workspace and exercises the actual component through the real runtime.
Build success alone is not browser acceptance or deployment.
