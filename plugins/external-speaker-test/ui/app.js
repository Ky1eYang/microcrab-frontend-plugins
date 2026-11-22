(() => {
  "use strict";
  const copy = {
    en: {
      title: "External Speaker Test",
      replyTitle: "Dialogue reply", replyStatus: { waiting: "Connecting to reply stream", queued: "Queued", consumed: "Awaiting reply", completed: "Completed", cancelled: "Cancelled", interrupted: "Interrupted", unavailable: "Reply stream ended without confirmation" }, noReply: "This turn ended without an explicit reply.", replyTruncated: "Only the first 8 KiB of reply text is shown.",
      connections: "Inbox connections", destination: "Inbox destination", liveDestination: "Connected Server · Active Session",
      destinationHelp: "Use the connected Server’s active Session or select a different inbox. Each inbox needs its own exact authorization. Sending elsewhere does not change the active Session.",
      newConnection: "Add an external connection", connectionName: "Connection name (required)", connectionNameHelp: "A label of up to 80 UTF-8 bytes.",
      endpoint: "Exact inbox URL (required)", endpointHelp: "Use HTTPS or loopback HTTP, ending in /api/v1/sessions/<id>/inbox, with no credentials, query, or fragment.",
      addConnection: "Add connection", authorize: "Authorize this inbox", revoke: "Revoke and clear saved key", removeConnection: "Remove connection",
      removeAuthorized: "Revoke and remove connection", refreshConnections: "Refresh authorizations",
      invalidName: "Enter a connection name of 1–80 UTF-8 bytes without control characters.",
      invalidEndpoint: "Enter the exact canonical inbox URL. Use lowercase scheme and host, and omit the default port.",
      tooManyConnections: "The connection list is full (32). Remove a connection before adding another.",
      authorizedOption: "Authorized", unauthorizedOption: "Not authorized", connectionAdded: "Connection added to this panel. Authorize it before sending.", connectionSelected: "Connection selected.",
      connectionPending: "Checking authorizations with the Host…", connectionFailed: "The Host did not confirm this change. The key may still be saved. Refresh authorizations before trying again.",
      connectionsReady: "Authorizations refreshed.", connectionAuthorized: "This exact inbox is authorized.",
      connectionRevoked: "The Host confirmed removal of this inbox authorization and its saved key from this browser.", connectionRemoved: "Connection removed.", removedWithKey: "The Host confirmed removal of the saved key. The connection was removed.",
      needsAuthorization: "Authorize this exact inbox with a test speaker key before sending.",
      requestDetails: "HTTP request", requestHeaders: "Request headers (redacted)", requestBody: "Request body",
      responseDetails: "HTTP response", truncated: "The Host truncated this response body.", responseHeaders: "Response headers", responseBody: "Response body",
      intro: "Send a message as an external speaker to the active Session or an authorized external inbox.",
      warning: "This can add a real message to the Session. Use a test Session and a test speaker key.",
      server: "Connected Server", session: "Active Session", compose: "Compose message", inboxRequest: "Inbox request",
      message: "Message (required)", messageHelp: "1–8192 UTF-8 bytes; not just whitespace.",
      bytes: (n) => `${n} / 8192 bytes`,
      token: "External speaker key (required)", tokenHelp: "Use a test key issued for the external speaker, not your login token. This field clears when you submit authorization. HTTP request previews and cURL show only a placeholder.",
      credentialAdvisory: "For this test, the Host saves the key in this browser’s local storage. Sending, navigating away, closing the tab, or a crash does not remove it. When finished, select Revoke and clear saved key for each inbox and wait for Host confirmation. This does not revoke the key on the issuing Server.",
      credentialUnsupported: "This panel requires a Host that supports saved test credentials.",
      disabledOption: "Saved key · authorization disabled",
      send: "Send to Session inbox", nextSend: "Compose a new message", advanced: "Advanced: request ID and cURL",
      operation: "Request ID (Idempotency-Key)", operationHelp: "A lowercase UUIDv4 is generated for each new message. You can replace it here.", newKey: "New UUID",
      preview: "Generate cURL", previewHelp: "Preview only. Uses the current message and request ID, with a key placeholder. Running the command yourself can send the message.",
      curl: "cURL command (POSIX shell)", copy: "Copy cURL", copied: "cURL copied; contains only a key placeholder.",
      copyUnavailable: "Clipboard unavailable. Select and copy the command manually.", copyTooLarge: "Command exceeds the clipboard limit. Select and copy it manually.",
      previewing: "Preparing cURL…", previewReady: "cURL is ready. No message was sent by the preview.",
      previewFailed: "Could not prepare cURL. No message was sent by the preview.",
      receipt: "Latest send receipt", receiptOperation: "Request ID", ordinal: "Inbox ordinal", http: "HTTP status",
      waiting: "Waiting for the connected Server and active Session…", noSession: "Open an active Session to send a test message.",
      unsupported: "The connected Server endpoint is unavailable or unsupported for this test.",
      sendHelp: "Check the last receipt before composing a new message.",
      unknownHelp: "Check the Session first. Composing a new message does not resend the previous one.",
      invalidMessage: "Enter a message of 1–8192 UTF-8 bytes with at least one non-whitespace character.",
      invalidToken: "Enter a speaker key with 43–128 letters, digits, hyphens, or underscores.",
      invalidOperation: "Enter a lowercase UUIDv4 or select New UUID.",
      usedOperation: "This request ID was already submitted. Check its outcome and use a new UUID for a new message.",
      idle: ["No message sent", "The result of sending to this Session will appear here."],
      submitting: ["Sending", "Waiting for the Server to confirm the request…"],
      pending: ["Waiting for receipt", "The request is in progress. Do not send it again."],
      queued: ["Queued", "The Server queued the message in the Session inbox. It has not confirmed consumption."],
      consumed: ["Consumed", "The Server reports that the Session consumed the message."],
      rejected: ["Rejected", "The Server rejected the inbox request."],
      outcome_unknown: ["Outcome unknown", "The message may have been accepted. Check the Session before sending again. No automatic retry will occur."],
      notSent: ["Not sent", "Review the highlighted field and try again only when ready."],
      unavailable: ["Could not prepare the request", "No send was confirmed. Check that the Server and Session are still active."],
    },
    "zh-CN": {
      title: "外部发言者测试",
      replyTitle: "对话回复", replyStatus: { waiting: "正在连接回复流", queued: "已入队", consumed: "正在等待回复", completed: "已完成", cancelled: "已取消", interrupted: "已中断", unavailable: "回复流结束，未确认终态" }, noReply: "本轮结束，未收到显式回复。", replyTruncated: "仅显示回复正文的前 8 KiB。",
      connections: "收件箱连接", destination: "收件箱目标", liveDestination: "已连接的服务器 · 当前会话",
      destinationHelp: "可使用已连接服务器上的当前会话，也可选择其他收件箱。每个收件箱都需要单独授权。向其他收件箱发送不会切换当前会话。",
      newConnection: "添加外部连接", connectionName: "连接名称（必填）", connectionNameHelp: "标签最长为 80 个 UTF-8 字节。",
      endpoint: "准确的收件箱 URL（必填）", endpointHelp: "使用 HTTPS 或环回地址的 HTTP，路径以 /api/v1/sessions/<id>/inbox 结尾，不得包含凭据、查询参数或片段。",
      addConnection: "添加连接", authorize: "授权此收件箱", revoke: "撤销授权并清除已保存密钥", removeConnection: "移除连接",
      removeAuthorized: "撤销授权并移除连接", refreshConnections: "刷新授权列表",
      invalidName: "请输入 1–80 个 UTF-8 字节且不含控制字符的连接名称。",
      invalidEndpoint: "请输入规范的完整收件箱 URL。协议和主机名须为小写，并省略默认端口。",
      tooManyConnections: "连接列表已满（32 个）。请先移除一个再添加。",
      authorizedOption: "已授权", unauthorizedOption: "未授权", connectionAdded: "连接已添加到此面板。请先授权再发送。", connectionSelected: "已选择连接。",
      connectionPending: "正在向宿主查询授权…", connectionFailed: "宿主未确认此变更，密钥可能仍保存在浏览器中。请先刷新授权列表再重试。",
      connectionsReady: "授权列表已刷新。", connectionAuthorized: "此收件箱已获得授权。",
      connectionRevoked: "宿主已确认从此浏览器移除该收件箱授权及其保存的密钥。", connectionRemoved: "连接已移除。", removedWithKey: "宿主已确认清除保存的密钥。连接已移除。",
      needsAuthorization: "请先使用测试发言者密钥授权此收件箱，再发送。",
      requestDetails: "HTTP 请求", requestHeaders: "请求头（已脱敏）", requestBody: "请求正文",
      responseDetails: "HTTP 响应", truncated: "宿主已截断响应正文。", responseHeaders: "响应头", responseBody: "响应正文",
      intro: "以外部发言者身份向当前会话或已授权的外部收件箱发送消息。",
      warning: "此操作可能向会话添加真实消息。请使用测试会话和测试发言者密钥。",
      server: "已连接的服务器", session: "当前会话", compose: "撰写消息", inboxRequest: "收件箱请求",
      message: "消息（必填）", messageHelp: "1–8192 个 UTF-8 字节，不能只有空白字符。",
      bytes: (n) => `${n} / 8192 字节`,
      token: "外部发言者密钥（必填）", tokenHelp: "请使用为外部发言者签发的测试密钥，而非登录凭据。提交授权申请时会清空此输入框。HTTP 请求预览和 cURL 仅显示占位符。",
      credentialAdvisory: "在此测试中，宿主会将密钥保存到此浏览器的本地存储。发送消息、离开页面、关闭标签页或发生崩溃都不会清除密钥。测试结束后，请对每个收件箱选择「撤销授权并清除已保存密钥」，并等待宿主确认。这不会在签发密钥的服务器上撤销该密钥。",
      credentialUnsupported: "此面板需要支持保存测试密钥的宿主。",
      disabledOption: "已保存密钥 · 授权已停用",
      send: "发送到会话收件箱", nextSend: "撰写新消息", advanced: "高级：请求 ID 和 cURL",
      operation: "请求 ID（Idempotency-Key）", operationHelp: "每条新消息都会生成一个小写 UUIDv4。你可以在此替换它。", newKey: "生成新 UUID",
      preview: "生成 cURL", previewHelp: "仅预览。命令包含当前消息、请求 ID 和密钥占位符。自行运行该命令可能发送消息。",
      curl: "cURL 命令（POSIX shell）", copy: "复制 cURL", copied: "已复制 cURL，其中只有密钥占位符。",
      copyUnavailable: "无法使用剪贴板。请选择命令并手动复制。", copyTooLarge: "命令超出剪贴板大小限制。请选择命令并手动复制。",
      previewing: "正在生成 cURL…", previewReady: "cURL 已生成。预览未发送消息。", previewFailed: "无法生成 cURL。预览未发送消息。",
      receipt: "最近一次发送回执", receiptOperation: "请求 ID", ordinal: "收件箱序号", http: "HTTP 状态码",
      waiting: "正在等待已连接的服务器和当前会话…", noSession: "请打开一个会话以发送测试消息。",
      unsupported: "此测试无法使用当前连接的服务器端点。",
      sendHelp: "撰写新消息前，请先查看上次发送的回执。", unknownHelp: "请先检查会话。撰写新消息不会重发上一条消息。",
      invalidMessage: "请输入 1–8192 个 UTF-8 字节且不全为空白的消息。",
      invalidToken: "请输入 43–128 个英文字母、数字、连字符或下划线组成的发言者密钥。",
      invalidOperation: "请输入小写 UUIDv4，或选择生成新 UUID。",
      usedOperation: "此请求 ID 已提交过。请先检查发送结果，再使用新的 UUID 发送新消息。",
      idle: ["尚未发送", "发送到此会话的结果将显示在这里。"],
      submitting: ["正在发送", "正在等待服务器确认请求…"],
      pending: ["正在等待回执", "请求正在处理，请勿再次发送。"],
      queued: ["已入队", "服务器已将消息放入会话收件箱，尚未确认会话已处理。"],
      consumed: ["已处理", "服务器确认会话已处理此消息。"],
      rejected: ["已拒绝", "服务器拒绝了收件箱请求。"],
      outcome_unknown: ["结果未知", "消息可能已被接收。再次发送前请先检查会话。系统不会自动重试。"],
      notSent: ["未发送", "请检查标出的字段，准备好后再发送。"],
      unavailable: ["无法准备请求", "未确认发送。请检查服务器和会话是否仍可用。"],
    },
  };
  const language = /^zh(?:-|$)/i.test(navigator.language) ? "zh-CN" : "en";
  const t = copy[language];
  document.documentElement.lang = language;
  document.title = t.title;
  for (const element of document.querySelectorAll("[data-copy]")) element.textContent = t[element.dataset.copy];

  const api = window.microcrab;
  const $ = (id) => document.getElementById(id);
  const { message, token, operation, advanced, fields, send } = Object.fromEntries(
    ["message", "token", "operation", "advanced", "fields", "send"].map((id) => [id, $(id)]),
  );
  const bytes = new TextEncoder();
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const bearer = /^[A-Za-z0-9_-]{43,128}(?![\s\S])/u;
  const validation = { invalid_message: message, invalid_operation: operation, operation_already_used: operation };
  const settled = new Set(["queued", "consumed", "rejected", "outcome_unknown"]);
  // Frontend permits HTTP timeouts up to 300s. If even the Host projection is
  // lost, end the UI wait without replaying; a matching late receipt can still settle it.
  const sendWait = 310_000;
  const previewWait = 15_000;
  let scope = null, sequence = 0, awaiting = null, timer, retired = false;
  let receipt = null, preview = "", previewRevision = 0, sendNeedsNewDraft = false, lastAttempt = "";
  let inspectedRequest = null, inspectedResponse = null;
  let reply = null;
  let replyContent = "";
  const draftBusy = () => Boolean(awaiting) || Boolean(reply && ["waiting", "queued", "consumed"].includes(reply.status));
  function readReply(next) {
    const value = next.reply;
    if (receipt?.id !== next.action_id || (next.endpoint || "") !== endpoint ||
        !value || !/^[0-9a-f]{8}$/.test(value.dialogue_id) || !Object.hasOwn(t.replyStatus, value.status) ||
        !Array.isArray(value.chunks) || value.chunks.length > 64 ||
        value.chunks.some((chunk, index) => chunk.index !== index || typeof chunk.message !== "string")) return;
    reply = value;
  }
  function renderReply() {
    $("reply-stream").hidden = !reply;
    $("reply-truncated").hidden = reply?.truncated !== true;
    setText($("reply-status"), reply ? `${reply.dialogue_id} · ${t.replyStatus[reply.status]}${reply.reason === "no_reply_invoked" ? ` — ${t.noReply}` : ""}` : "");
    const messages = reply?.chunks.map((chunk) => chunk.message) || [];
    const encoded = JSON.stringify(messages);
    if (encoded === replyContent) return;
    replyContent = encoded;
    $("reply-chunks").replaceChildren(...messages.map((message) => {
      const item = document.createElement("li");
      item.textContent = message;
      return item;
    }));
  }
  const nameInput = $("connection-name"), endpointInput = $("endpoint"), destination = $("destination");
  const connectionLimit = 32, nameLimit = 80;
  const drafts = new Map();
  let grants = new Map(), endpoint = "", connectionOptions = "", supportsConnections = false;
  let connectionWait = null, connectionTimer, connectionUncertain = false, listStarted = false;
  let connectionFeedback = "";

  function validEndpoint(value) {
    if (value.length > 460 || !/^https?:\/\/[!-~]+\/api\/v1\/sessions\/[A-Za-z0-9_-]{1,128}\/inbox$/.test(value)) return false;
    try {
      const url = new URL(value);
      const loopback = url.hostname === "localhost" || url.hostname === "[::1]" || /^127\.(?:\d+\.){2}\d+$/.test(url.hostname);
      const host = url.hostname;
      const validHost = host.startsWith("[") || (host.length <= 253 && host.split(".").every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)));
      return value === `${url.origin}${url.pathname}` && url.origin.length <= 300 && url.port !== "0" && validHost &&
        /^\/api\/v1\/sessions\/[A-Za-z0-9_-]{1,128}\/inbox$/.test(url.pathname) && (url.protocol === "https:" || loopback);
    } catch {
      return false;
    }
  }

  function connectedEndpoint() {
    if (!scopeAvailable()) return "";
    const url = `${scope.origin}/api/v1/sessions/${scope.session}/inbox`;
    return validEndpoint(url) ? url : "";
  }

  function destinationEndpoint() {
    return endpoint || connectedEndpoint();
  }

  function authorized(url) {
    return grants.get(url)?.enabled === true;
  }

  function validName(value) {
    return Boolean(value) && bytes.encode(value).length <= nameLimit && !/\p{Cc}/u.test(value);
  }

  function readConnections(connections) {
    return new Map(connections.slice(0, connectionLimit)
      .filter((item) => item && typeof item.endpoint === "string" && validEndpoint(item.endpoint) &&
        typeof item.name === "string" && validName(item.name) && typeof item.enabled === "boolean")
      .map(({ endpoint, name, enabled }) => [endpoint, { name, enabled }]));
  }

  function headersText(headers) {
    if (!headers || typeof headers !== "object") return "";
    const entries = Array.isArray(headers) ? headers.map((item) => [item?.name, item?.value]) : Object.entries(headers);
    return entries.filter(([key, value]) => typeof key === "string" && typeof value === "string")
      .map(([key, value]) => `${key}: ${/^(?:proxy-)?authorization$/i.test(key) ? "Bearer <EXTERNAL_SPEAKER_TOKEN>"
        : /^(?:set-)?cookie$/i.test(key) ? "<REDACTED>" : value}`).join("\n");
  }

  function readInspection(next, includeResponse) {
    const { request, response } = next;
    if (request && request.method === "POST" && validEndpoint(typeof request.url === "string" ? request.url : "") &&
        request.url === destinationEndpoint() && typeof request.body === "string") {
      inspectedRequest = { line: `POST ${request.url}`, headers: headersText(request.headers), body: request.body };
    }
    if (typeof next.preview === "string" && next.preview) preview = next.preview;
    if (includeResponse && inspectedRequest && response && Number.isInteger(response.status) && typeof response.body === "string") {
      inspectedResponse = { line: `${t.http}: ${response.status}`, headers: headersText(response.headers), body: response.body, truncated: response.truncated === true };
    }
  }

  function setText(element, value) {
    if (element.textContent !== value) element.textContent = value;
  }

  function makeUuid() {
    const value = crypto.getRandomValues(new Uint8Array(16));
    value[6] = (value[6] & 0x0f) | 0x40;
    value[8] = (value[8] & 0x3f) | 0x80;
    const hex = Array.from(value, (n) => n.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  function errorFor(field) {
    if (field === message) return !/\P{White_Space}/u.test(message.value) || bytes.encode(message.value).length > 8192 ? t.invalidMessage : "";
    if (field === token) return bearer.test(token.value) ? "" : t.invalidToken;
    if (!uuid.test(operation.value)) return t.invalidOperation;
    return operation.value === lastAttempt ? t.usedOperation : "";
  }

  function setError(field, error) {
    const output = $(`${field.id}-error`);
    field.setAttribute("aria-invalid", String(Boolean(error)));
    field.setAttribute("aria-describedby", `${field.id}-help${error ? ` ${output.id}` : ""}`);
    output.hidden = !error;
    setText(output, error);
  }

  function focusError(field) {
    if (field === operation) advanced.open = true;
    field.focus();
  }

  function clearPreview() {
    preview = "";
    previewRevision++;
    setText($("preview-status"), "");
    setText($("copy-status"), "");
  }

  function isCopyable(value) {
    if (!value || bytes.encode(value).length > 48 * 1024) return false;
    const envelope = JSON.stringify({ type: "clipboard-write", id: Number.MAX_SAFE_INTEGER, text: value });
    return bytes.encode(envelope).length <= 64 * 1024;
  }

  function scopeAvailable() {
    return Boolean(!retired && scope?.session && scope.origin && !scope.issue);
  }

  function grantLabel(url) {
    return authorized(url) ? t.authorizedOption : grants.has(url) ? t.disabledOption : t.unauthorizedOption;
  }

  function render() {
    const target = destinationEndpoint();
    const targetAuthorized = authorized(target);
    setText($("origin"), scope?.origin || "—");
    $("connections").hidden = !supportsConnections;
    if (supportsConnections) {
      const connected = connectedEndpoint();
      const entries = [["", connected ? `${t.liveDestination} · ${grantLabel(connected)}` : t.liveDestination],
        ...Array.from(drafts, ([url, name]) => [url, `${name} · ${grantLabel(url)}`]).filter(([url]) => url !== connected)];
      const options = JSON.stringify(entries);
      if (connectionOptions !== options) {
        destination.replaceChildren(...entries.map(([value, label]) => {
          const option = document.createElement("option");
          option.value = value;
          option.textContent = label;
          return option;
        }));
        connectionOptions = options;
      }
      destination.value = endpoint;
      const canEdit = !connectionWait && !awaiting && scopeAvailable();
      destination.disabled = !canEdit;
      $("connection-endpoint").hidden = !target;
      setText($("connection-endpoint"), target);
      $("credential-entry").hidden = !target || targetAuthorized;
      token.readOnly = !canEdit || connectionUncertain;
      $("authorize").hidden = !target || targetAuthorized;
      $("revoke").hidden = !target || !grants.has(target);
      $("remove-connection").hidden = !endpoint;
      setText($("remove-connection"), grants.has(target) ? t.removeAuthorized : t.removeConnection);
      for (const id of ["authorize", "revoke", "remove-connection"]) $(id).setAttribute("aria-disabled", String(!canEdit || connectionUncertain));
      $("refresh-connections").setAttribute("aria-disabled", String(!canEdit));
      $("add-connection").disabled = !canEdit;
      setText($("connection-status"), connectionWait ? t.connectionPending : connectionUncertain ? t.connectionFailed : connectionFeedback);
    }
    setText($("session"), scope?.session || "—");
    const available = supportsConnections && Boolean(target) && !connectionWait && !connectionUncertain;
    fields.disabled = !available || (Boolean(endpoint) && !targetAuthorized);
    setText($("availability"), !scope ? t.waiting
      : scope.issue === "wrong_origin" || scope.issue === "unsupported_origin" ? t.unsupported
      : !scope.session || scope.issue === "no_session" ? t.noSession
      : scope.issue || !scope.origin || !target ? t.unsupported
      : !supportsConnections ? t.credentialUnsupported
      : connectionUncertain ? t.connectionFailed
      : !targetAuthorized && !connectionWait ? t.needsAuthorization : "");
    const busy = draftBusy();
    renderReply();
    const locked = busy || sendNeedsNewDraft;
    // Keep the initiating button focusable while the view updates asynchronously.
    // The event guards below enforce the same lock on UI mutations.
    send.setAttribute("aria-disabled", String(locked || !targetAuthorized));
    send.setAttribute("aria-describedby", sendNeedsNewDraft ? "send-help result" : !targetAuthorized ? "availability result" : "result");
    $("preview").setAttribute("aria-disabled", String(busy));
    $("next-send").hidden = !sendNeedsNewDraft;
    $("next-send").setAttribute("aria-disabled", String(busy));
    $("send-help").hidden = !sendNeedsNewDraft;
    setText($("send-help"), receipt?.status === "outcome_unknown" ? t.unknownHelp : t.sendHelp);
    message.readOnly = operation.readOnly = busy || sendNeedsNewDraft;
    $("new-key").disabled = busy || sendNeedsNewDraft;
    setText($("length"), t.bytes(bytes.encode(message.value).length));
    $("command").hidden = !preview;
    if ($("curl").value !== preview) $("curl").value = preview;
    $("copy").disabled = !isCopyable(preview);

    const kind = receipt?.status || "idle";
    $("request-details").hidden = !inspectedRequest;
    $("response-details").hidden = !inspectedResponse;
    $("response-truncated").hidden = !inspectedResponse?.truncated;
    setText($("request-line"), inspectedRequest?.line || "");
    setText($("request-headers"), inspectedRequest?.headers || "");
    setText($("request-body"), inspectedRequest?.body || "");
    setText($("response-status"), inspectedResponse?.line || "");
    setText($("response-headers"), inspectedResponse?.headers || "");
    setText($("response-body"), inspectedResponse?.body || "");
    const [title, description] = t[kind];
    $("result").dataset.kind = kind;
    setText($("result-label"), title);
    setText($("result-description"), description);
    const rows = { operation: receipt?.operation, ordinal: receipt?.ordinal, http: receipt?.http };
    $("receipt-meta").hidden = !Object.values(rows).some(Boolean);
    for (const [key, value] of Object.entries(rows)) {
      $(`receipt-${key}-row`).hidden = !value;
      setText($(`receipt-${key}`), value ? String(value) : "");
    }
  }

  function clearWait() {
    clearTimeout(timer);
    awaiting = null;
  }

  function readReceipt(next, ticket) {
    const rawStatus = next.status;
    const status = settled.has(rawStatus) || rawStatus === "pending" ? rawStatus
      : Object.hasOwn(validation, rawStatus) ? "notSent" : rawStatus === "unavailable" ? "unavailable" : "outcome_unknown";
    const op = ticket?.operation || next.operation;
    // Runtime projects the ordinal as a decimal string. Do not round large IDs.
    const ordinal = (status === "queued" || status === "consumed") && (typeof next.ordinal === "string" || Number.isSafeInteger(next.ordinal)) ? next.ordinal : null;
    const http = Number.isInteger(next.http_status) ? next.http_status : null;
    const operationId = typeof op === "string" && uuid.test(op) ? op : null;
    receipt = { status, id: ticket?.id ?? next.action_id, operation: operationId, ordinal, http };
    sendNeedsNewDraft = settled.has(status);
    if ((sendNeedsNewDraft || status === "pending") && operationId) lastAttempt = operationId;
    if (ticket && Object.hasOwn(validation, rawStatus)) {
      const field = validation[rawStatus];
      setError(field, rawStatus === "operation_already_used" ? t.usedOperation
        : field === operation ? t.invalidOperation : t.invalidMessage);
    }
  }

  function transmit(event, sending) {
    event.preventDefault();
    if (!event.isTrusted || fields.disabled || draftBusy() || (sending && (sendNeedsNewDraft || !authorized(destinationEndpoint())))) return;
    const checks = [message, operation];
    let first;
    setText($("validation-status"), "");
    for (const field of checks) {
      // cURL preview may inspect the last sent UUID, but cannot submit it.
      const error = !sending && field === operation ? (uuid.test(field.value) ? "" : t.invalidOperation) : errorFor(field);
      setError(field, error);
      if (error && !first) first = field;
    }
    if (first) {
      focusError(first);
      return;
    }
    if (sequence >= 0xffffffff) {
      if (sending) receipt = { status: "unavailable" };
      else setText($("preview-status"), t.previewFailed);
      render();
      return;
    }
    const ticket = { id: ++sequence, operation: operation.value, sending };
    awaiting = ticket;
    const payload = { session: scope.session, message: message.value, operation: ticket.operation, action_id: ticket.id };
    if (endpoint) payload.endpoint = endpoint;
    clearPreview();
    inspectedRequest = inspectedResponse = null;
    if (sending) receipt = { status: "submitting", id: ticket.id, operation: ticket.operation };
    else setText($("preview-status"), t.previewing);
    const lost = () => {
      if (awaiting !== ticket) return;
      clearWait();
      if (sending) readReceipt({ status: "outcome_unknown" }, ticket);
      else setText($("preview-status"), t.previewFailed);
      render();
    };
    timer = setTimeout(lost, sending ? sendWait : previewWait);
    try {
      api.action(sending ? "send" : "preview", payload);
    } catch {
      lost();
    }
    render();
  }

  function resetDraft() {
    clearWait();
    reply = receipt = inspectedRequest = inspectedResponse = null;
    sendNeedsNewDraft = false;
    lastAttempt = "";
    message.value = token.value = "";
    operation.value = scope?.session && scope.origin && !scope.issue ? makeUuid() : "";
    advanced.open = $("request-details").open = $("response-details").open = false;
    clearPreview();
    for (const field of [message, token, operation]) setError(field, "");
    setText($("validation-status"), "");
  }

  function selectEndpoint(nextEndpoint) {
    if (endpoint === nextEndpoint) return;
    endpoint = nextEndpoint;
    resetDraft();
  }

  $("add-connection-form").addEventListener("submit", (event) => event.preventDefault());
  $("add-connection").addEventListener("click", (event) => {
    event.preventDefault();
    if (!event.isTrusted || connectionWait || awaiting || !scopeAvailable()) return;
    const name = nameInput.value.trim();
    const url = endpointInput.value;
    const nameError = validName(name) ? "" : t.invalidName;
    const endpointError = validEndpoint(url) ? "" : t.invalidEndpoint;
    setError(nameInput, nameError);
    setError(endpointInput, endpointError);
    if (nameError || endpointError) return (nameError ? nameInput : endpointInput).focus();
    if (drafts.size >= connectionLimit && !drafts.has(url)) {
      connectionFeedback = t.tooManyConnections;
      render();
      return;
    }
    if (!drafts.has(url)) drafts.set(url, name);
    selectEndpoint(url === connectedEndpoint() ? "" : url);
    nameInput.value = endpointInput.value = "";
    $("add-connection-panel").open = false;
    connectionFeedback = grants.has(url) ? t.connectionSelected : t.connectionAdded;
    render();
    destination.focus();
  });
  for (const field of [nameInput, endpointInput]) {
    field.addEventListener("input", () => {
      if (field.getAttribute("aria-invalid") !== "true") return;
      if (field === nameInput ? validName(field.value.trim()) : validEndpoint(field.value)) setError(field, "");
    });
  }
  destination.addEventListener("change", (event) => {
    if (!event.isTrusted || awaiting || connectionWait || retired) return;
    selectEndpoint(destination.value);
    connectionFeedback = "";
    render();
  });
  $("refresh-connections").addEventListener("click", (event) => {
    if (event.isTrusted) connectionAction("list");
  });
  $("authorize").addEventListener("click", (event) => {
    const target = destinationEndpoint();
    if (event.isTrusted && target && !authorized(target)) {
      connectionAction("authorize", { endpoint: target, name: endpoint ? drafts.get(target) : t.liveDestination });
    }
  });
  $("revoke").addEventListener("click", (event) => {
    const target = destinationEndpoint();
    if (event.isTrusted && target && grants.has(target)) connectionAction("revoke", { endpoint: target });
  });
  $("remove-connection").addEventListener("click", (event) => {
    if (!event.isTrusted || !endpoint || awaiting || connectionWait || connectionUncertain || retired) return;
    if (grants.has(endpoint)) {
      connectionAction("revoke", { endpoint }, true);
    } else {
      drafts.delete(endpoint);
      selectEndpoint("");
      connectionFeedback = t.connectionRemoved;
      render();
      destination.focus();
    }
  });

  function clearConnectionWait() {
    clearTimeout(connectionTimer);
    connectionWait = null;
  }

  function connectionAction(action, payload = {}, remove = false) {
    if (!supportsConnections || !scopeAvailable() || connectionWait || awaiting || !api || sequence >= 0xffffffff || (connectionUncertain && action !== "list")) return;
    if (action === "authorize") {
      const error = errorFor(token);
      setError(token, error);
      if (error) return focusError(token);
    }
    const ticket = { id: ++sequence, action, endpoint: payload.endpoint, remove };
    connectionWait = ticket;
    const lost = () => {
      if (connectionWait !== ticket) return;
      clearConnectionWait();
      connectionUncertain = true;
      render();
    };
    connectionTimer = setTimeout(lost, action === "authorize" ? 65_000 : previewWait);
    const envelope = { ...payload, action_id: ticket.id };
    if (action === "authorize") {
      envelope.token = token.value;
      token.value = "";
    }
    try {
      api.action(action, envelope);
    } catch {
      lost();
    } finally {
      delete envelope.token;
    }
    render();
  }

  // The Host sandbox has no allow-forms. Handle the submit button's trusted
  // activation (including keyboard), not the sandbox-blocked native submit.
  // requestSubmit() can generate a trusted submit event, but must never send.
  send.addEventListener("click", (event) => transmit(event, true));
  $("request").addEventListener("submit", (event) => event.preventDefault());
  $("preview").addEventListener("click", (event) => transmit(event, false));
  $("new-key").addEventListener("click", () => {
    if (fields.disabled || draftBusy() || sendNeedsNewDraft) return;
    operation.value = makeUuid();
    setError(operation, "");
    clearPreview();
    render();
  });
  $("next-send").addEventListener("click", () => {
    if (fields.disabled || draftBusy() || !sendNeedsNewDraft) return;
    sendNeedsNewDraft = false;
    message.value = token.value = "";
    operation.value = makeUuid();
    clearPreview();
    for (const field of [message, token, operation]) setError(field, "");
    render();
    message.focus();
  });
  for (const field of [message, token, operation]) {
    field.addEventListener("input", () => {
      if (field.getAttribute("aria-invalid") === "true" && !errorFor(field)) setError(field, "");
      setText($("validation-status"), "");
      if (field !== token) clearPreview();
      render();
    });
    field.addEventListener("blur", () => {
      // Moving focus from the key to Authorize must not move the button under a
      // pointer click. That action validates the key instead of validating on blur.
      if (field === token) return;
      // Announce other new blur errors once, without interrupting typing.
      if (field.readOnly || !field.value || field.getAttribute("aria-invalid") === "true") return;
      const error = errorFor(field);
      if (!error) return;
      setError(field, error);
      setText($("validation-status"), error);
    });
  }
  window.addEventListener("pagehide", () => {
    // The Host closes its channel permanently on pagehide, including bfcache.
    retired = true;
    scope = null;
    resetDraft();
    clearConnectionWait();
    drafts.clear();
    grants.clear();
    endpoint = "";
    nameInput.value = endpointInput.value = "";
    supportsConnections = false;
    render();
  }, { once: true });
  $("copy").addEventListener("click", async (event) => {
    if (!event.isTrusted || !preview || $("copy").disabled) return;
    const revision = previewRevision;
    try {
      await api.copyText(preview);
      if (revision === previewRevision) setText($("copy-status"), t.copied);
    } catch {
      if (revision === previewRevision) setText($("copy-status"), t.copyUnavailable);
    }
  });

  render();
  api?.onViewState((next) => {
    if (retired || !next || typeof next !== "object") return;
    const origin = typeof next.origin === "string" ? next.origin : null;
    const session = typeof next.session === "string" ? next.session : null;
    const issue = next.issue || null;
    const hostCredentials = next.host_credentials === true;
    const changed = !scope || scope.session !== session || scope.origin !== origin || scope.issue !== issue || supportsConnections !== hostCredentials;
    supportsConnections = hostCredentials;
    if (changed) {
      scope = { origin, session, issue };
      clearConnectionWait();
      drafts.clear();
      grants.clear();
      endpoint = "";
      listStarted = connectionUncertain = false;
      connectionFeedback = "";
      nameInput.value = endpointInput.value = "";
      $("add-connection-panel").open = false;
      for (const field of [nameInput, endpointInput]) setError(field, "");
      resetDraft();
    }
    if (Number.isInteger(next.connection_action_id)) sequence = Math.max(sequence, next.connection_action_id);
    let focusDestination = false;
    const projectedGrants = supportsConnections && Array.isArray(next.connections) ? readConnections(next.connections) : null;
    const validInventory = projectedGrants !== null && projectedGrants.size === next.connections.length;
    if (validInventory) {
      const previousGrants = grants;
      grants = projectedGrants;
      const localDrafts = [...drafts];
      drafts.clear();
      for (const [url, { name }] of grants) drafts.set(url, name);
      for (const [url, name] of localDrafts) {
        if (drafts.size < connectionLimit || drafts.has(url)) drafts.set(url, name);
      }
      if (endpoint && !drafts.has(endpoint)) selectEndpoint("");
      const target = destinationEndpoint();
      if (authorized(target) || (previousGrants.get(target)?.enabled && !authorized(target))) {
        token.value = "";
        setError(token, "");
      }
      if (previousGrants.get(target)?.enabled && !authorized(target)) {
        token.value = "";
        clearPreview();
        inspectedRequest = inspectedResponse = null;
      }
    }
    if (connectionWait && next.connection_action_id === connectionWait.id && ["ready", "unavailable"].includes(next.connection_status)) {
      const { action, endpoint: target, remove } = connectionWait;
      clearConnectionWait();
      connectionUncertain = next.connection_status !== "ready" || !validInventory
        || (action === "authorize" && !authorized(target)) || (action === "revoke" && grants.has(target));
      if (!connectionUncertain) {
        connectionFeedback = action === "list" ? t.connectionsReady : action === "authorize" ? t.connectionAuthorized : t.connectionRevoked;
        focusDestination = [$("authorize"), $("revoke"), $("remove-connection")].includes(document.activeElement);
        if (remove) {
          drafts.delete(target);
          selectEndpoint("");
          connectionFeedback = t.removedWithKey;
        }
      }
    }
    if (changed) {
      if (session && origin && !issue) {
        if (Number.isInteger(next.action_id)) sequence = Math.max(sequence, next.action_id);
        if (typeof next.endpoint === "string" && authorized(next.endpoint) && next.endpoint !== connectedEndpoint()) endpoint = next.endpoint;
        if ((next.endpoint || "") === endpoint && (settled.has(next.status) || next.status === "pending")) {
          readReceipt(next);
          readInspection(next, true);
          if (receipt.operation) operation.value = receipt.operation;
          if (next.status === "pending") {
            const ticket = { id: next.action_id, operation: operation.value, sending: true };
            awaiting = ticket;
            timer = setTimeout(() => {
              if (awaiting !== ticket) return;
              clearWait();
              readReceipt({ status: "outcome_unknown" }, ticket);
              render();
            }, sendWait);
          }
        }
      }
    } else if (awaiting && awaiting.id === next.action_id && ((next.endpoint || "") === endpoint
        || (!next.endpoint && (next.status === "unavailable" || Object.hasOwn(validation, next.status))))) {
      const ticket = awaiting;
      if (ticket.sending) {
        if (next.status !== "pending") clearWait();
        readReceipt(next, ticket);
        readInspection(next, true);
      } else {
        clearWait();
        if (next.status === "preview" && next.preview_operation === ticket.operation && typeof next.preview === "string") {
          readInspection(next, false);
          setText($("preview-status"), t.previewReady);
          if (!isCopyable(preview)) setText($("copy-status"), t.copyTooLarge);
        } else {
          setText($("preview-status"), t.previewFailed);
          if (next.status === "invalid_message") setError(message, t.invalidMessage);
          if (next.status === "invalid_operation") setError(operation, t.invalidOperation);
        }
      }
    } else if (receipt?.status === "outcome_unknown" && receipt.id === next.action_id && (next.endpoint || "") === endpoint && settled.has(next.status)) {
      // Preserve a late receipt for the same send, without re-locking a new draft.
      const previousGate = sendNeedsNewDraft;
      readReceipt(next, { id: receipt.id, operation: receipt.operation });
      sendNeedsNewDraft = previousGate;
      readInspection(next, true);
    }
    readReply(next);
    if (supportsConnections && !listStarted && !awaiting && scopeAvailable()) {
      listStarted = true;
      connectionAction("list");
    }
    render();
    if (focusDestination) destination.focus();
  });
})();
