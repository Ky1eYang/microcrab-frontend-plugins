# Output Translator UI Interface

Each authored surface uses the native bundler's `index.html`, `style.css`, and
`app.js` markers; generated HTML is not checked in.

## Host bridge

Use the existing ACK-fenced `window.microcrab.action(name, payload)` and
`onViewState(listener)`. Theme tokens are the host's `--microcrab-*` projection;
no business projection contains theme data. Ordinary view-state updates preserve
form elements, dirty fields, focus, disclosure and block collapse state.

`copyText(text): Promise<void>` is an optional generic host API, invoked directly
inside the Copy click handler. Only fulfillment reports success. Missing API or
rejection offers selectable raw text and a concrete localized explanation.
No async browser clipboard, legacy clipboard bypass, external script, network,
raw HTML rendering, rich engine, or image loading is used.

## Projections

Settings and sidebar:

```text
{locale, config:{provider,source,target,model,temperature,prompt,
 auto_translate,assistant_only,display_mode,skip_same_language},
 resources:[{id,endpoint,enabled,config_pin,requires_reenable}],
 status:string,saved:boolean,pending:boolean,
 stats:{translated:number,average_ms:number},
 test:{status:'idle'|'pending'|'completed'|'error',duration_ms:number},
 save:{operation_id:string,status:'pending'|'applied'|'failed'|'unknown',error:string}}
```

Provider IDs: `google`, `mymemory`, `siliconflow`, `custom`. Paid/custom readiness
requires resource ID equal to provider, `enabled:true`, and no `requires_reenable`.
Saved credentials are never projected or stored in browser storage. The input is
masked and transient, cleared after each Save attempt and on page exit. Draft key
material is also cleared on provider changes. Settings accept only HTTP(S)
endpoint URLs without embedded credentials.

Optional legacy user card only (`assistant_only=false`):

```text
{locale,block_id,status:'pending'|'completed'|'skipped'|'error'|'cancelled',
 translation:string,error:string,provider,source,target,duration_ms:number}
```

Duration is actual total duration; no TTFT or locally fabricated timing. Passive
Markdown supports headings, paragraphs, code, emphasis, lists, quotes and rules
using DOM text nodes only. Unsupported syntax remains text. Block content is
bounded by the runtime's 32 KiB result quota; the parser additionally bounds its
formatted block count and falls back to literal text for the remainder.

## Actions

```text
settings.save {operation_id,config:<FULL Config>,endpoint,authorization,
               clear_authorization:boolean}
control       <FULL Config>
cache.clear   {}
block.retry   {block_id}
block.force   {block_id}
test          {}
```

`authorization` is a full HTTP authorization header value; a bare input token is
prefixed with `Bearer `. It exists only in the transient input and one Save
payload, never Config. Test uses saved configuration and never transports draft
credentials. Sidebar Apply sends its complete draft; Swap applies immediately.
Block retry and retranslate share `block.retry`; skipped cards use `block.force`.

Each explicit Save generates one operation ID. Only `save.operation_id` matching
that operation with `status:'applied'` clears the draft. Failed receipts preserve
non-secret drafts and expose errors. Unknown outcomes preserve the operation and
block duplicate Save; no implicit replay occurs. Initial/default applied receipts
and unrelated projections cannot acknowledge a Save. Pending settings inputs are
disabled until a matching terminal receipt.

Chinese is the default. `locale` starting with `en` selects the English dictionary.
Run `node --test plugins/output-translator/ui/tests.cjs` from the repository root
for authored-script checks of field order, localization, full-save receipts and
custom model preservation. Native `zig build output-translator-test` from the
repository root, or `zig build test` from the Output Translator package directory,
also checks actual HTML content and configuration compatibility.

## Canonical assistant variants

Assistant text uses only the Host variant presentation, never the legacy HTML block
parser or a second Vars translation projection. Each `block_variants` item has exact
required fields `{block_id,variant_id:'translation',source_digest,history_revision,
label,status,text,default_display,retry_action:'block.retry',force_action:'block.force'}`.
`source_digest` is 64 lower-case hexadecimal SHA-256 of exact UTF-8 settled text,
matching the canonical Host digest. `history_revision` retains the exact Entry revision.
Status is `pending|completed|skipped|error|cancelled`; only completed has nonempty text.
Optional `reason` is `same_language|no_prose|unchanged`; optional `error` preserves the
concrete safe diagnostic. Retirement sends `remove_block_variants:[{block_id,
variant_id:'translation'}]` for known published assistant entries only. User cards
retain their existing metadata-only after slots and exact `remove_block_slots`.

Both Settings and Sidebar place Auto translate, Display format, then Assistant
responses only in that order. Display format offers Translation (`inline`, default)
and Original + translation (`after`); these are the values stored in configuration.
Settings also saves these behavior flags through the existing full-config ACK flow.
`skip_same_language` defaults to true. Old saved configurations receive the display
and skip defaults. Host owns Original/Translation/Both and Copy current Markdown.

Assistant responses only defaults to true. Turning it off also translates completed
user text into the existing after-card; it does not replace user input, resend a
message or mutate history. Tools and reasoning remain excluded in either mode.
Both surfaces include this explanation in Chinese and English.

The model is a plain freeform text input, without a select, list or datalist. New
configuration defaults to `tencent/Hunyuan-MT-7B`; saved custom model names remain
exact across provider changes and saves. Valid UTF-8 names may contain arbitrary
characters within the existing nonempty 256-byte configuration bound. The HTML
length bound is an editing aid; guest validation remains authoritative.

Skipped assistant results have no visible translation card; the Host status bar
retains explicit force. The same certified block-slot action descriptor routes
`block.retry` and `block.force`. Force bypasses one invocation's local decision,
never original-input truncation/size or provider limits. Cache/config invalidation
clears a queued force flag. No skip or unchanged result increases translated count.
