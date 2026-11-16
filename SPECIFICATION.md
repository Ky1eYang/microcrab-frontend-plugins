# MicroCrab Frontend Plugins (Zig Edition) 实现规范

## Maintained v0.4.0 adaptation

This section governs the maintained implementation; the original design text
below remains as provenance where it describes visual proposals rather than
verified behavior. The package, State Viewer and MCP Bridge manifest releases are
`0.4.0`. The target restrictions in the following State governance paragraphs apply
to State Viewer; MCP declares Sidebar and SettingPage with the `tool-plugin` world.

### Modular Component builds and MCP Bridge

Every default and selected Zig build emits a validated true WebAssembly Component:
Core compilation stays internal, selected WIT world embedding precedes component
creation, validation and WIT extraction. Actual default optimization is ReleaseSmall;
`-Doptimize` is explicit. Root-only per-plugin registrations own target/world/assets
metadata, with common build-time utilities separate from runtime imports. Only explicit
diagnostic `*-core` targets install Core modules. UI assets are generated in cache.

MCP imports only `net`/`resources` from ABI0.4, with correlated `start-tool` and
`cancel-tool`. Its asynchronous path is Resources → Initialize → Notify ACK → List →
Call; the refreshed catalog, exact host config revision, schema SHA-256 and validated
arguments authorize the final call. Multi-version negotiation, bounded pagination,
256-entry scoped call/cursor caches,32 concurrent operation slots,60KiB durable output,
and16MiB aggregate operation allocations are independent. Server transitions free
previous catalogs. Cancellation permits one best-effort discard notification; it
never retries remote effects or claims certainty for a queued remote call.

Settings owns server administration; Sidebar owns the current resident Session's
observation window only. History is capped at128 records/2MiB serialized retained
history, terminal-first eviction, ten-row pages and4096-byte UTF-8 detail chunks.
Leaving a Session, refresh or history replacement clears it. Clearing display history
does not cancel pending effects. Host-sampled wall/monotonic context times are
observational, never deadline authority. Both authored surfaces consume host theme
tokens. New credentials transiently pass through the password field and one fenced
save action, with raw/decoded/encoded action buffers wiped even on parse failure;
no credential is retained in Vars, projections or history. Saved credentials remain
host-owned and never return to the plugin.

Explicit aggregate installation validates every selected artifact and all target
indexes before pointer changes, locks each destination, preserves unselected entries,
defaults and explicit predecessors, stages immutable bytes then atomically publishes
one index per directory. `--adopt-current` is an explicit authorized publication
policy: verify the current selected packaged bytes/hash before retaining that exact
predecessor. No real artifact digest is hardcoded in source. Atomicity across separate
directories is not claimed. See README for root Cargo and direct Zig commands.

The exact official ABI source is the frontend-owned
`crates/client/plugins/wit/client-plugin.wit`; the Zig workspace copy must be
byte-identical. Only ABI0.4 imports are emitted. Sidebar and ExpandedPage are the
only declared targets (`[0, 1]`). The WIT
enum remains unchanged, including SettingPage; the plugin has no settings surface
or settings-specific branch. Undeclared targets, including SettingPage, intentionally
return native JSON `null` before context processing or State imports. Initialization
and a missing selected Session issue no State imports; declared views without a
Session retain localized conversation-selection information.

The authored layout and interactions consume the host HTML theme bridge: resolved
root `data-theme`, `color-scheme` and `--microcrab-*` CSS variables update in place.
All colors, overlay/shadow and font values derive from host tokens. Chrome, field
names and visibility/persistence badges remain neutral; protected fields and
destructive actions use semantic warning/danger colors. No guest theme preference
or independent dark palette is maintained.

Flat `ctx.session_id` and `ctx.locale` are consumed on every lifecycle call;
owner/server/history/instance changes revoke stale snapshot/request state.
Atomic inspection installs values, metadata, descriptors and witness together.
Descriptor policy fails closed. A draft captures its opening witness; submission
retains the exact UUID, expected witness and change. Queue acknowledgement means
saving, never success. Completions correlate by request ID and operation ID.
Only an applied receipt marks saved. Rejected errors retain drafts; queued or
unknown operations disable duplicate submission and permit read-only observation
of that exact operation. New keys keep visible/persisted scope and the existing
Agent/Client/Runtime editor set; existing sets retain their attributes; deletions
require Client ownership. No role or Session can be selected by action payloads.

`ui/index.html`, `ui/style.css` and `ui/app.js` are the authored build inputs.
`tools/bundle.zig` generates the embedded HTML in the build cache. The two unused
historical tracked bundles were removed after verifying no maintained build references.
`zig build component` builds, embeds and validates without staging browser assets.
`zig build test` runs native State governance, MCP protocol/runtime/cleanup and
aggregate installer tests.
Actual browser acceptance is a separate frontend integration gate.


## 1. 架构总览与设计目标

本项目是 `MicroCrab` 客户端在浏览器端运行的 **Frontend Plugins** 的全新技术栈实现，采用 **Zig** 语言重构原 Rust 实现（`microcrab-frontend/crates/client/plugins/*`），运行于 WebAssembly Component Model 运行时之上。

### 核心设计目标
1. **完全等价的功能契约**：严格遵循 `client-plugin@0.4.0` WIT 规范，保持输入输出语义与原 Rust 插件完全对齐；
2. **纯净的 Freestanding 沙箱**：编译目标为 `wasm32-freestanding`，零外部 libc/WASI 导入（`no automatic WASI adapters`），体积轻量且启动迅速；
3. **现代化的 Webview-HTML 体验**：使用 `webview-html` 模式替代传统的简陋 AST 节点树，呈现高度匹配 MicroCrab 设计语言的微质感深色主题、交互式 JSON 检查树与受控编辑体验；
4. **标准的 Zig 多工程模块化架构**：采用 Zig 0.13.0 标准的 `build.zig` + `build.zig.zon` Monorepo 体系，通用 Canonical ABI/宿主导入能力抽象为 `shared` 模块供各插件复用。

---

## 2. 工程目录结构

```text
microcrab-frontend-plugins/
├── .gitignore
├── SPECIFICATION.md              # 本规范文档
├── build.zig                     # 顶层构建脚本（管理共享模块、插件编译与组件打包）
├── build.zig.zon                 # 顶层包声明文件
├── wit/
│   └── client-plugin.wit         # 官方 WIT 接口定义 (microcrab:client-plugin@0.4.0)
├── shared/                       # 核心通用共享库
│   ├── build.zig                 # shared 模块定义
│   └── src/
│       ├── root.zig              # 模块导出入口
│       ├── abi.zig               # Canonical ABI 规范实现与 cabi_realloc 分配器
│       ├── types.zig             # WIT 数据结构及常量
│       ├── json.zig              # JSON 序列化与解析辅助库
│       └── host.zig              # 宿主导入接口（session-state, storage, net 等）
└── plugins/
    ├── state-viewer/             # 会话状态查看与受控编辑器
    │   ├── build.zig             # 插件构建定义
    │   ├── src/
    │   │   ├── main.zig          # Wasm 导出核心逻辑
    │   │   └── state.zig         # 状态过滤、只读检查与变更生成
    │   └── ui/                   # Webview UI 资源
    │       ├── index.html        # 页面模板
    │       ├── style.css         # 现代微质感深色 CSS
    │       └── app.js            # 响应式交互驱动 (对接 window.microcrab)
    └── mcp-bridge/               # MCP 工具桥接插件 (第二阶段)
        ├── build.zig
        └── src/
            └── main.zig
```

---

## 3. WebAssembly Component Model 互操作规范

### 3.1 编译与目标规范
- **Target**：`wasm32-freestanding`；
- **优化模式**：ReleaseSmall (`-O ReleaseSmall`) 或 ReleaseFast (`-O ReleaseFast`)；
- **内存管理**：
  必须导出符合 Canonical ABI 规范的内存重新分配函数 `cabi_realloc`：
  ```zig
  export fn cabi_realloc(
      old_ptr: ?*anyopaque,
      old_size: usize,
      alignment: usize,
      new_size: usize,
  ) callconv(.C) ?*anyopaque
  ```

### 3.2 导出函数签名（WIT `plugin-exports`）
The maintained wasm32 exports return an `i32` pointer to the result area:

- `manifest() -> i32`: 56-byte record. String pointer/length pairs begin at
  offsets 0, 8 and 16; description option at 24; target pointer/length at 36;
  network-origins option at 44. The target list is the two bytes `[0, 1]`,
  representing Sidebar and ExpandedPage. WIT enum list elements
  occupy one byte; a flattened enum function argument still occupies `i32`.
- `init(ctx_ptr, ctx_len) -> i32`, `on-action(...) -> i32` and
  `on-phase(...) -> i32`: 8-byte string return area `(pointer, byte length)`.
- `render-view(target, vars_ptr, vars_len, ctx_ptr, ctx_len) -> i32`:
  44-byte record with schema-version at 0, mode at 4, content pair at 8,
  vars-patch option at 16, rerender at 28 and error option at 32.
- Each export has a corresponding `cabi_post_*` hook. Owned result bytes remain
  live until the host has lifted the return and invokes that hook. Input strings
  transferred to the guest are freed after the export finishes using them.
- Imported `result<u32,string>` uses a 12-byte return area with a one-byte
  discriminator at offset 0 and payload at offset 4. Padding bytes are never
  interpreted as part of the discriminator.

### 3.3 打包管线（Packaging Pipeline）
1. `zig build-exe` / `zig build-lib` $\rightarrow$ 产出 `module.wasm`；
2. `wasm-tools component embed wit -w state-viewer module.wasm -o embedded.wasm`；
3. `wasm-tools component new embedded.wasm -o plugin.wasm`；
4. 校验产物格式为 `Encoding::Component`。

---

## 4. Webview-HTML UI/UX 现代视觉与交互规范

### 4.1 视觉风格与主题系统（Design Tokens）
界面在沙箱 iframe 内运行，通过内嵌样式精确匹配 MicroCrab 设计语言：
- **背景与表面**：深色层级背景（`#0f1117` 主色、`#161922` 卡片面），辅以微弱的 `1px solid rgba(255, 255, 255, 0.08)` 描边；
- **色彩与状态**：
  - 强调色（Accent）：`#3b82f6`（MicroCrab 经典蓝）；
  - 成功（Success）：`#10b981`；
  - 警告与只读（Warning/Locked）：`#f59e0b`；
  - 危险（Danger）：`#ef4444`；
- **字体规范**：
  - 标题与正文：`system-ui, -apple-system, sans-serif`；
  - 代码与 JSON 键值：`ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace`。

### 4.2 交互模式与数据流
- **状态监听**：页面初始化时调用 `window.microcrab.onViewState(state => updateDOM(state))`；
- **增量响应**：当搜索框变动或展开节点时，优先在本地 DOM 快速响应；
- **受控编辑**：
  - 点击变量项展开属性抽屉，展示只读权限、可见性、持久化属性；
  - 只读字段（例如受宿主/Agent 锁定的字段）展示 🔒 图标并锁定修改；
  - 用户提交编辑时，调用 `window.microcrab.action("save-json", { key, value })` 发起变更。

---

## 5. 验证与测试标准

1. **二进制 Component 验证**：生成的 `.wasm` 必须通过 `wasm-tools validate`；
2. **Worker 加载测试**：放入 `microcrab-frontend/frontend/public/plugins/`，前端 Worker 中的 `inspectComponent` 能够顺利识别并 transpile 成功；
3. **端到端交互验证**：在 MicroCrab UI 中切换会话，State Viewer 能够正常发起 `inspect` 请求，展示状态列表，并通过 `webview-html` 实现搜索与编辑保存。
