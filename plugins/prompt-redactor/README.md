# Prompt Redactor

Prompt Redactor is an opt-in sidebar and expanded-page plugin. Paste text, click
**Scan and clear input**, review the full preview, then choose **Copy reviewed
preview**. Nothing is applied to the session or submitted to a model. If no
supported pattern matches, it returns a status rather than echoing the input.

This scanner can miss secrets. Do not assume a scan makes text safe to share.

## Local data flow

- The existing sandboxed webview action bridge sends the input through local
  browser host and worker memory to the Zig component. The textarea is cleared
  after the attempt; the browser does not send text on keystrokes. The guest
  wipes its action payload and parsing scratch after use. Browser DOM, message,
  and JavaScript string copies are outside its control; this is not a guarantee of
  plaintext memory erasure.
- The `fixture` Component has no runtime imports, host-origin grants, model tool,
  session read/write, storage, or networking. Callback results carry only an
  acknowledgement or rerender flag. No plugin variables are read or patched.
- The guest keeps one pending projection scoped to the initiating session, target,
  surface identity, and instance/history/mount generations. It is consumed by the
  first matching render, replaced by a new valid scan, or rejected after 3 s on a
  subsequent callback with a host monotonic time sample. There is no guest timer.
  The webview displays results only for its own pending request ID. The host may
  retain the projected preview in its per-surface in-memory view cache until a
  subsequent render or surface retirement. Clear disables copy, drops the local
  preview and its pending request ID, and ignores late results; it does not wipe
  browser copies or the system clipboard.
- Recognized values are not included in the preview. If a value still occurs
  literally after replacement (for example as an unlabelled second occurrence of
  the same Bearer credential), the plugin rejects the whole preview rather than
  emitting it. Unrecognized values can still appear in the preview.
- Copy uses the existing browser clipboard broker only after an explicit click
  and passes only the displayed preview. The system clipboard is outside the
  plugin’s control. Copy failures do not trigger retries.

## Detection rules

The independently authored scanner was not ported from the absent third-party
reference. It scans at most 8,192 bytes of valid UTF-8 and replaces entire matched
spans (except the `Bearer` label and whitespace) with literal `[REDACTED]`. This is
ordinary text, not a session variable reference. It rejects oversize or invalid
input instead of truncating it and caps its caller-owned output at 16,384 bytes.
It uses no heap allocation, regex, decoding of token contents, or network
verification. Unmatched content is copied unchanged; a result will still contain
any sensitive values these rules miss.

| Family | Recognized shape and common false positives |
| --- | --- |
| Key prefixes | Case-sensitive `sk-proj-`, `sk-ant-`, `sk-` with at least 20 ASCII letters, digits, `_`, or `-`; `github_pat_` with at least 22 such characters; `ghp_` with exactly 36 ASCII alphanumeric characters; `AKIA`/`ASIA` with exactly 16 uppercase ASCII letters/digits. These shapes include synthetic identifiers and example keys; AWS access-key IDs are identifiers, not the associated secret keys. |
| Bearer credentials | Case-insensitive `Bearer` followed by ASCII spaces/tabs and at least eight characters from `[A-Za-z0-9._~+/=-]`; starts a token at an ASCII boundary. This also masks prose and examples that look like bearer tokens. If the run is followed immediately by `://`, it skips the Bearer rule so the URI rule can inspect the scheme. |
| Signed JWT-like text | An unpadded three-segment ASCII base64url-like string with `eyJ` at the start of the first segment; segment lengths are at least 8, 4, and 8. It checks the shape, not JSON, encoding validity, claims, or signatures. Longer dot-delimited tokens are not recognized by this rule. |
| Database URIs | Case-insensitive `postgres://`, `postgresql://`, `mysql://`, `mariadb://`, `mongodb://`, `mongodb+srv://`, `redis://`, `rediss://` plus a nonempty run up to ASCII whitespace/control, quote, backtick, or angle bracket. Masks credential-free/local URIs as well, and can consume adjacent punctuation or Unicode until one of those delimiters. |
| Private-key blocks | Exact uppercase `-----BEGIN …PRIVATE KEY-----` marker with an uppercase ASCII letters/digits/spaces label of at most 64 bytes and matching `-----END …PRIVATE KEY-----`. No parsing of the body. A recognized opener without an exact footer masks through end of input, including unrelated text. |
| Email-shaped text | An ASCII local part of 1–64 characters (`[A-Za-z0-9._%+-]`, no edge or consecutive dots), `@`, and a dotted ASCII domain with 1–63-byte alphanumeric/hyphen labels (no edge hyphens) and final alphabetic label of at least two letters. Address length is at most 254 bytes; a single trailing period is left outside the match. Examples and public addresses are also masked. |

The rules do not cover arbitrary passwords, provider formats not listed above,
obfuscated/multiline credentials outside recognized private-key blocks, alternate
encodings, phone numbers, names, addresses, internationalized email addresses, or
all JWTs. Token matching generally requires an ASCII left boundary; punctuation
may affect what is recognized. These are text heuristics, not validators. No
claim is made about complete secret detection or plaintext memory erasure.

## Local verification (no staging)

From the plugin repository root with Zig 0.13.0, `wasm-tools`, and Node on `PATH`:

```sh
zig build test component -Dplugins=prompt-redactor
zig build prompt-redactor-core
node plugins/prompt-redactor/ui/tests.cjs
```

From this plugin's directory in the same checkout, `zig build test component`
verifies just this plugin, without running the aggregate installer tests.

The UI test runs the actual guest core ABI and bundled JavaScript against a mock
DOM and bridge. It does not verify real browser clipboard permissions or staging.
