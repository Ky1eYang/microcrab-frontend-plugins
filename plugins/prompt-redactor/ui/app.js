(() => {
  "use strict";
  const bridge = window.microcrab;
  const source = document.getElementById("source");
  const scan = document.getElementById("scan");
  const clear = document.getElementById("clear");
  const copy = document.getElementById("copy");
  const status = document.getElementById("status");
  const panel = document.getElementById("result");
  const preview = document.getElementById("preview");
  const encoder = new TextEncoder();
  const maxInput = 8192;
  const maxOutput = 16384;
  let connected = false;
  let waiting = null;
  let timer = null;
  let copying = false;
  let revision = 0;

  function clearPreview() {
    if (timer !== null) window.clearTimeout(timer);
    timer = null;
    waiting = null;
    revision += 1;
    preview.textContent = "";
    panel.hidden = true;
    copy.disabled = true;
  }

  function syncScan() {
    scan.disabled = !connected || waiting !== null || !source.value;
  }

  source.addEventListener("input", () => {
    // Editing while a scan is pending does not make its old result copyable.
    clearPreview();
    status.textContent = "";
    syncScan();
  });

  clear.addEventListener("click", () => {
    source.value = "";
    clearPreview();
    status.textContent = "Cleared.";
    source.focus();
    syncScan();
  });

  window.addEventListener("pagehide", () => {
    source.value = "";
    clearPreview();
  }, { once: true });

  if (typeof bridge?.onViewState !== "function" || typeof bridge?.action !== "function") {
    status.textContent = "The local scan bridge is unavailable.";
    return;
  }

  bridge.onViewState((state) => {
    connected = true;
    if (!waiting || !state || state.id !== waiting) {
      syncScan();
      return;
    }
    clearPreview();
    if (state.status === "ready" && Number.isSafeInteger(state.count) && state.count > 0 &&
        typeof state.text === "string" && state.text.length <= maxOutput &&
        encoder.encode(state.text).length <= maxOutput) {
      preview.textContent = state.text;
      panel.hidden = false;
      copy.disabled = copying || typeof bridge.copyText !== "function";
      status.textContent = `Redacted ${state.count} matching span${state.count === 1 ? "" : "s"}. Review the entire preview; some secrets may remain.` +
        (typeof bridge.copyText === "function" ? "" : " Clipboard bridge unavailable.");
    } else if (state.status === "no_matches") {
      status.textContent = "No supported patterns found. This does not mean the input was safe. No preview was produced.";
    } else {
      status.textContent = "Could not produce a redacted preview.";
    }
    syncScan();
  });

  scan.addEventListener("click", () => {
    if (scan.disabled) return;
    clearPreview();
    if (source.value.length > maxInput || encoder.encode(source.value).length > maxInput) {
      status.textContent = "Text exceeds the 8 KiB scan limit. Shorten it and try again.";
      return;
    }
    // A fresh document nonce makes retained/stale Host view state ineligible.
    const id = Array.from(crypto.getRandomValues(new Uint8Array(16)), (byte) => byte.toString(16).padStart(2, "0")).join("");
    waiting = id;
    status.textContent = "Scanning…";
    timer = window.setTimeout(() => {
      clearPreview();
      status.textContent = "Scan result unavailable. Nothing was copied.";
      syncScan();
    }, 5000);
    try {
      bridge.action("scan-preview", { id, text: source.value });
    } catch {
      clearPreview();
      status.textContent = "Local scan request failed.";
    } finally {
      source.value = "";
      syncScan();
    }
  });

  copy.addEventListener("click", async () => {
    if (copy.disabled || copying || panel.hidden) return;
    const copiedRevision = revision;
    copying = true;
    copy.disabled = true;
    try {
      await bridge.copyText(preview.textContent);
      if (revision === copiedRevision) status.textContent = "Copied the reviewed preview.";
    } catch {
      if (revision === copiedRevision) status.textContent = "Clipboard write failed. Nothing was retried.";
    } finally {
      copying = false;
      copy.disabled = panel.hidden;
    }
  });
})();
