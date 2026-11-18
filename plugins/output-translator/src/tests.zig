const std = @import("std");
const j = @import("json.zig");
const p = @import("providers.zig");
const c = @import("config.zig");
const Result = @import("shared").host.ResultU32;
const Mock = struct {
    var next: u32 = 0;
    var http: usize = 0;
    var stored: usize = 0;
    var grants: usize = 0;
    var reject_storage = false;
    var reject_http = false;
    var reject_resources = false;
    var reject_conversation = false;
    fn rejected() Result {
        return .{ .err = std.testing.allocator.dupe(u8, "Host rejected request") catch unreachable };
    }
    pub const storage = struct {
        pub fn read(_: []const u8) ?[]const u8 {
            return null;
        }
        pub fn write(_: []const u8, _: []const u8) Result {
            Mock.stored += 1;
            if (Mock.reject_storage) return Mock.rejected();
            Mock.next += 1;
            return .{ .ok = Mock.next };
        }
    };
    pub const resources = struct {
        pub fn send(kind: []const u8, _: []const u8) Result {
            if (std.mem.eql(u8, kind, "resource-configure")) Mock.grants += 1;
            if (Mock.reject_resources) return Mock.rejected();
            Mock.next += 1;
            return .{ .ok = Mock.next };
        }
    };
    pub const net = struct {
        pub fn send(_: []const u8, _: []const u8) Result {
            Mock.http += 1;
            if (Mock.reject_http) return Mock.rejected();
            Mock.next += 1;
            return .{ .ok = Mock.next };
        }
    };
    pub const conversation = struct {
        pub fn send(_: []const u8, _: []const u8) Result {
            if (Mock.reject_conversation) return Mock.rejected();
            Mock.next += 1;
            return .{ .ok = Mock.next };
        }
    };
};
const Engine = @import("runtime.zig").Runtime(Mock);
fn context(a: std.mem.Allocator) !j.Value {
    return j.parse(a, "{\"session_id\":\"s\",\"owner_id\":\"o\",\"server_origin\":\"https://host\",\"instance_generation\":1,\"history_generation\":1,\"host_monotonic_ms\":100,\"user_action\":true,\"surface\":{\"target\":\"sidebar\"}}");
}
fn block(a: std.mem.Allocator, id: usize, kind: []const u8, role: []const u8) !j.Value {
    return j.parse(a, try std.fmt.allocPrint(a, "{{\"blocks\":[{{\"block_id\":\"b{d}\",\"history_revision\":\"r\",\"kind\":\"{s}\",\"role\":\"{s}\",\"text\":\"hello\"}}]}}", .{ id, kind, role }));
}
fn complete(a: std.mem.Allocator, id: u32, body: []const u8) !j.Value {
    var out = j.object(a);
    try j.set(&out, "request_id", .{ .integer = id });
    try j.set(&out, "ok", .{ .bool = true });
    var v = j.object(a);
    try j.set(&v, "status", .{ .integer = 200 });
    try j.set(&v, "body", j.string(body));
    try j.set(&out, "value", v);
    return out;
}
test "provider encoded URLs and strict bounded parsers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try p.build(a, .{}, "a &中?", null, null);
    try std.testing.expect(std.mem.indexOf(u8, j.text(j.get(request, "url")).?, "q=a%20%26%E4%B8%AD%3F") != null);
    try std.testing.expectEqualStrings("你好世界", try p.decode(a, .google, "[[[\"你好\",\"hello\"],[\"世界\",\"world\"]],null,\"en\"]"));
    try std.testing.expectEqualStrings("hi", try p.decode(a, .mymemory, "{\"responseStatus\":200,\"responseData\":{\"translatedText\":\"hi\"}}"));
    try std.testing.expectError(error.DuplicateField, p.decode(a, .mymemory, "{\"responseStatus\":200,\"responseStatus\":500}"));
    try std.testing.expectEqualStrings("result", try p.decode(a, .custom, "{\"choices\":[{\"message\":{\"content\":\"result\"}}]}"));
    var cfg = c.Config{ .provider = .mymemory };
    try std.testing.expectError(error.MyMemoryCannotDetectLanguage, p.build(a, cfg, "123", null, null));
    try std.testing.expectEqualStrings("ja", try p.detect("漢字かな"));
    try std.testing.expectEqualStrings("ko", try p.detect("한국어"));
    cfg.source = "en";
    const overlong = try a.alloc(u8, 501);
    @memset(overlong, 'a');
    try std.testing.expectError(error.MyMemoryInputExceeds500Bytes, p.build(a, cfg, overlong, null, null));
}
test "settled assistant text only, four concurrent, correlated completion and stale fences" {
    Mock.next = 0;
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try block(a, 100, "reasoning", "assistant"), ctx);
    try e.phase(a, "settled-blocks", try block(a, 101, "text", "user"), ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    for (0..6) |i| try e.phase(a, "settled-blocks", try block(a, i, "text", "assistant"), ctx);
    try std.testing.expectEqual(@as(usize, 4), Mock.http);
    const task = e.tasks[0].?;
    try e.phase(a, "event-result", try complete(a, task.id, "[[[\"译文\"]]]"), ctx);
    try std.testing.expectEqualStrings("译文", e.entries.items[0].translation);
    try std.testing.expectEqual(@as(usize, 5), Mock.http);
    const stale = e.tasks[1].?.id;
    try e.action(a, "cache.clear", j.object(a), ctx);
    try e.phase(a, "event-result", try complete(a, stale, "[[[\"stale\"]]]"), ctx);
    try std.testing.expectEqualStrings("", e.entries.items[1].translation);
    try j.set(&ctx, "session_id", j.string("other"));
    try e.phase(a, "event-result", try complete(a, e.tasks[0].?.id, "[[[\"wrong session\"]]]"), ctx);
    try std.testing.expectEqual(@as(usize, 0), e.entries.items.len);
}
test "128 session cap and host-truncated text never dispatched" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    for (0..129) |i| try e.phase(a, "settled-blocks", try block(a, i, "text", "assistant"), ctx);
    try std.testing.expectEqual(@as(usize, 128), e.entries.items.len);
    try std.testing.expectEqual(@as(usize, 4), Mock.http);
}
test "settings Save requires exact storage ACK and projects no credentials" {
    Mock.stored = 0;
    Mock.grants = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    var payload = j.object(a);
    try j.set(&payload, "operation_id", j.string("save-1"));
    var cfg = try e.config.value(a);
    try j.set(&cfg, "provider", j.string("custom"));
    try j.set(&payload, "config", cfg);
    try j.set(&payload, "endpoint", j.string("https://example.test/v1/chat/completions"));
    try j.set(&payload, "authorization", j.string("Bearer secret-never-project"));
    try e.action(a, "settings.save", payload, ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.grants);
    try std.testing.expectEqual(@as(usize, 0), Mock.stored);
    try std.testing.expect(!e.saved);
    const grant = e.save_request.?;
    var response = j.object(a);
    try j.set(&response, "request_id", .{ .integer = grant });
    try j.set(&response, "ok", .{ .bool = true });
    try j.set(&response, "value", try j.parse(a, "[{\"id\":\"custom\",\"endpoint\":\"https://example.test/v1/chat/completions\",\"config_pin\":\"pin\",\"enabled\":true}]"));
    try e.phase(a, "event-result", response, ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.stored);
    try std.testing.expect(!e.saved);
    const storage_id = e.storage_request.?;
    try j.set(&response, "request_id", .{ .integer = storage_id + 1000 });
    try j.set(&response, "value", try j.parse(a, "{\"ack\":true}"));
    try e.phase(a, "event-result", response, ctx);
    try std.testing.expect(!e.saved);
    try j.set(&response, "request_id", .{ .integer = storage_id });
    try e.phase(a, "event-result", response, ctx);
    try std.testing.expect(e.saved);
    try std.testing.expectEqual(c.Provider.custom, e.config.provider);
    try std.testing.expectEqualStrings("applied", e.save_status);
    const output = try j.stringify(a, try e.result(a, ctx, "ignored", true));
    try std.testing.expect(std.mem.indexOf(u8, output, "secret-never-project") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "save-1") != null);
}
test "configuration rejects secrets and POST payload delegates exact resource pin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = try (c.Config{}).value(a);
    try j.set(&cfg, "api_key", j.string("forbidden"));
    try std.testing.expectError(error.UnknownConfigurationField, c.Config.parse(cfg));
    const request = try p.build(a, .{ .provider = .siliconflow }, "hello", "siliconflow", "exact-pin");
    try std.testing.expect(j.is(j.get(request, "resource"), "siliconflow"));
    try std.testing.expect(j.is(j.get(request, "config_pin"), "exact-pin"));
    try std.testing.expect(j.get(request, "url") == .null);
    try std.testing.expect(j.get(j.get(request, "headers"), "Authorization") == .null);
    const body = try j.parse(a, j.text(j.get(request, "body")).?);
    try std.testing.expect(!j.truth(j.get(body, "stream")));
    try std.testing.expectError(error.SaveResourceGrantFirst, p.build(a, .{ .provider = .custom }, "hello", null, null));
}
test "truncated input cannot be retried and repeated settlement is cached" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    var truncated = try block(a, 1, "text", "assistant");
    try j.set(&truncated.object.getPtr("blocks").?.array.items[0], "text_truncated", .{ .bool = true });
    try e.phase(a, "settled-blocks", truncated, ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b1\"}"));
    try std.testing.expectError(error.OriginalTextUnavailable, e.action(a, "block.retry", try j.parse(a, "{\"block_id\":\"b1\"}"), ctx));
    const good = try block(a, 2, "text", "assistant");
    try e.phase(a, "settled-blocks", good, ctx);
    const id = e.tasks[0].?.id;
    try e.phase(a, "event-result", try complete(a, id, "[[[\"ok\"]]]"), ctx);
    try e.phase(a, "settled-blocks", good, ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
}
test "history replacement preserves slot indexes and rejects prior task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try block(a, 1, "text", "assistant"), ctx);
    const old = e.tasks[0].?.id;
    try e.phase(a, "settled-blocks", try block(a, 2, "text", "assistant"), ctx);
    var changed = try block(a, 1, "text", "assistant");
    try j.set(&changed.object.getPtr("blocks").?.array.items[0], "text", j.string("new content"));
    try e.phase(a, "settled-blocks", changed, ctx);
    try std.testing.expectEqualStrings("b1", e.entries.items[0].id);
    try std.testing.expectEqualStrings("b2", e.entries.items[1].id);
    try e.phase(a, "event-result", try complete(a, old, "[[[\"stale\"]]]"), ctx);
    try std.testing.expectEqualStrings("", e.entries.items[0].translation);
}
test "orphaned surface effects expire conservatively without mutation replay" {
    Mock.http = 0;
    Mock.stored = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try block(a, 1, "text", "assistant"), ctx);
    const old = e.tasks[0].?.id;
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15099 });
    try e.context(ctx);
    try std.testing.expect(e.tasks[0] != null);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15100 });
    try e.context(ctx);
    try std.testing.expect(e.tasks[0] == null);
    try e.phase(a, "event-result", try complete(a, old, "[[[\"late\"]]]"), ctx);
    try std.testing.expectEqualStrings("", e.entries.items[0].translation);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    var payload = j.object(a);
    try j.set(&payload, "operation_id", j.string("orphan-save"));
    try j.set(&payload, "config", try e.config.value(a));
    try e.action(a, "settings.save", payload, ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.stored);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 30100 });
    try e.context(ctx);
    try std.testing.expectEqualStrings("unknown", e.save_status);
    try std.testing.expectError(error.SaveOutcomeUnknownReloadToInspect, e.action(a, "settings.save", payload, ctx));
    try std.testing.expectEqual(@as(usize, 1), Mock.stored);
}
test "connection test uses actual whole request duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    try e.action(a, "test", j.object(a), ctx);
    const id = e.tasks[0].?.id;
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 475 });
    try e.phase(a, "event-result", try complete(a, id, "[[[\"你好\"]]]"), ctx);
    try std.testing.expectEqualStrings("completed", e.test_status);
    try std.testing.expectEqual(@as(f64, 375), e.test_duration_ms);
    try std.testing.expectEqual(@as(usize, 0), e.entries.items.len);
}
test "LRU evicts terminal entries and emits exact removals without consuming them on render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try block(a, 0, "text", "assistant"), ctx);
    const pending = e.tasks[0].?.id;
    e.config.auto_translate = false;
    for (1..128) |i| try e.phase(a, "settled-blocks", try block(a, i, "text", "assistant"), ctx);
    const first = try e.result(a, ctx, "", true);
    try std.testing.expectEqual(@as(usize, 128), j.get(first, "block_variants").array.items.len);
    try std.testing.expect(j.get(first, "effects") == .null);
    e.published();
    try e.phase(a, "settled-blocks", try block(a, 128, "text", "assistant"), ctx);
    try std.testing.expectEqualStrings("b0", e.entries.items[0].id);
    try std.testing.expectEqualStrings("b128", e.entries.items[1].id);
    try std.testing.expectEqual(pending, e.tasks[0].?.id);
    try std.testing.expectEqual(@as(usize, 128), e.entries.items.len);
    _ = try e.result(a, ctx, "", false);
    try std.testing.expectEqual(@as(usize, 1), e.removed_count);
    const output = try e.result(a, ctx, "", true);
    const removed = j.get(output, "remove_block_variants");
    try std.testing.expectEqual(@as(usize, 1), removed.array.items.len);
    try std.testing.expect(j.is(j.get(removed.array.items[0], "block_id"), "b1"));
    try std.testing.expect(j.is(j.get(removed.array.items[0], "variant_id"), "translation"));
    try std.testing.expect(e.entries.items[1].fresh);
    e.published();
    try std.testing.expectEqual(@as(usize, 0), e.removed_count);
    try std.testing.expect(!e.entries.items[1].fresh);
}
test "LRU reclaims terminal content at aggregate retained budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    e.config.auto_translate = false;
    const text = try a.alloc(u8, 16 * 1024);
    @memset(text, 'a');
    for (0..24) |i| {
        var item = try block(a, i, "text", "assistant");
        try j.set(&item.object.getPtr("blocks").?.array.items[0], "text", j.string(text));
        try e.phase(a, "settled-blocks", item, ctx);
    }
    var bytes: usize = 0;
    var latest = false;
    for (e.entries.items) |entry| {
        bytes += entry.text.len + entry.translation.len + entry.id.len + entry.history.len + entry.role.len;
        if (std.mem.eql(u8, entry.id, "b23")) latest = true;
    }
    try std.testing.expect(bytes <= Engine.retained_limit);
    try std.testing.expect(latest);
    try std.testing.expect(e.entries.items.len <= 128);
}
test {
    _ = @import("budget.zig");
}

fn textBlock(a: std.mem.Allocator, id: usize, text: []const u8) !j.Value {
    var value = try block(a, id, "text", "assistant");
    try j.set(&value.object.getPtr("blocks").?.array.items[0], "text", j.string(text));
    return value;
}
test "conservative language evidence including code mixed unknown and scripts" {
    const gate = @import("language.zig");
    const same: ?gate.Reason = .same_language;
    const none: ?gate.Reason = null;
    try std.testing.expectEqual(same, gate.decision(.{ .source = "en", .target = "en" }, "Short"));
    try std.testing.expectEqual(none, gate.decision(.{ .source = "zh-CN", .target = "zh-TW" }, "这是中文"));
    try std.testing.expectEqual(none, gate.decision(.{ .source = "zh-TW", .target = "zh-CN" }, "這是中文"));
    try std.testing.expectEqual(none, gate.decision(.{ .target = "en" }, "API HTTP JSON Markdown configuration response transport"));
    try std.testing.expectEqual(none, gate.decision(.{ .target = "en" }, "Hello world"));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "en" }, "This is the text that you can use with the system and it will preserve your data."));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "fr" }, "Les données sont dans le système et vous pouvez les utiliser avec une méthode pour les documents."));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "de" }, "Die Daten sind für das System und werden mit der Methode auf die neue Datei übertragen."));
    try std.testing.expectEqual(none, gate.decision(.{ .target = "en" }, "This is the text that you can use with the system. 这是另一种语言的完整说明，需要继续提供翻译而不是直接跳过。"));
    const technical = "这个接口会保留请求数据，并将网络返回内容转换为显示文本。API 的代码和链接应当保持原样，不需要重新处理。";
    try std.testing.expectEqual(same, gate.decision(.{}, technical));
    try std.testing.expectEqual(none, gate.decision(.{ .target = "zh-TW" }, technical));
    try std.testing.expectEqual(none, gate.decision(.{ .skip_same_language = false }, technical));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "zh-TW" }, "這個介面會保留請求資料，並將網絡返回內容轉換為顯示文字。程式碼和連結應當保持原樣，不需要重新處理。"));
    try std.testing.expectEqual(none, gate.decision(.{ .target = "zh-TW" }, "天地玄黃宇宙洪荒日月盈昃辰宿列張寒冬暑往秋收冬藏"));
    try std.testing.expectEqual(none, gate.decision(.{}, "简短中文"));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "ja" }, "これは日本語の説明です。設定を保存してから、この文章を確認してください。"));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "ko" }, "이 문장은 한국어로 작성된 설명입니다 설정을 저장하고 내용을 확인해 주세요"));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "ru" }, "Это текст для системы и для пользователя который работает в ней но не изменяет данные"));
    try std.testing.expectEqual(same, gate.decision(.{ .target = "ar" }, "هذا النص في النظام من أجل المستخدم الذي يعمل على البيانات مع هذه المعلومات التي لا تتغير"));
    try std.testing.expectEqual(none, gate.decision(.{ .target = "ru" }, "Це український текст і він містить інші літери для перевірки мови"));
    try std.testing.expectEqual(@as(?gate.Reason, .no_prose), gate.decision(.{}, "```zig\nconst text = \"English and 中文\";\n```\n`const api = fetch(url)`\nhttps://example.test/the/is/english\n123 + 456"));
    try std.testing.expectEqual(@as(?gate.Reason, .no_prose), gate.decision(.{}, "~~~js\nconst x = 'hello';\n~~~\n[123](https://example.test/path)"));
    try std.testing.expectEqual(none, gate.decision(.{}, "Uncertain prose\n```zig\nconst x = 1;\n```"));
}
test "skip before HTTP force one invocation unchanged and reset" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    const text = "这个接口会保留请求数据，并将网络返回内容转换为显示文本。API 的代码和链接应当保持原样，不需要重新处理。";
    const payload = try textBlock(a, 1, text);
    try e.phase(a, "settled-blocks", payload, ctx);
    try e.phase(a, "settled-blocks", payload, ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    var result = try e.result(a, ctx, "", true);
    try std.testing.expect(j.is(j.get(j.get(result, "block_variants").array.items[0], "status"), "skipped"));
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b1\"}"));
    const action = try j.parse(a, "{\"block_id\":\"b1\"}");
    try e.action(a, "block.retry", action, ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try e.action(a, "block.force", action, ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
    try std.testing.expect(!e.entries.items[0].force);
    const body = try std.json.stringifyAlloc(a, .{.{.{text}}}, .{});
    try e.phase(a, "event-result", try complete(a, e.tasks[0].?.id, body), ctx);
    try std.testing.expectEqual(@as(u64, 0), e.translated);
    try std.testing.expectEqualStrings("", e.entries.items[0].translation);
    try std.testing.expectEqual(@import("language.zig").Reason.unchanged, e.entries.items[0].reason.?);
    try e.action(a, "block.retry", action, ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
    try e.action(a, "block.force", action, ctx);
    try e.phase(a, "event-result", try complete(a, e.tasks[0].?.id, "[[[\"different translation\"]]]"), ctx);
    try std.testing.expectEqual(@as(u64, 1), e.translated);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"sidebar\"}"));
    try e.action(a, "cache.clear", j.object(a), ctx);
    try std.testing.expect(!e.entries.items[0].force);
    try e.action(a, "control", try e.config.value(a), ctx);
    try std.testing.expectEqual(@as(usize, 2), Mock.http);
    result = try e.result(a, ctx, "", true);
    try std.testing.expect(j.is(j.get(j.get(result, "block_variants").array.items[0], "reason"), "same_language"));
}
test "exact variant contract defaults digest and user compatibility without assistant projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    var old = try e.config.value(a);
    _ = old.object.swapRemove("display_mode");
    _ = old.object.swapRemove("skip_same_language");
    const conf = try c.Config.parse(old);
    try std.testing.expectEqual(c.DisplayMode.@"inline", conf.display_mode);
    try std.testing.expect(conf.skip_same_language);
    try j.set(&old, "prompt", j.string("My exact custom prompt"));
    try std.testing.expectEqualStrings("My exact custom prompt", (try c.Config.parse(old)).prompt);
    try j.set(&old, "display_mode", j.string("invalid"));
    try std.testing.expectError(error.InvalidDisplayMode, c.Config.parse(old));
    try e.phase(a, "settled-blocks", try textBlock(a, 1, "hello"), ctx);
    var result = try e.result(a, ctx, "unused", true);
    const v = j.get(result, "block_variants").array.items[0];
    try std.testing.expectEqual(@as(usize, 10), v.object.count());
    try std.testing.expect(j.is(j.get(v, "source_digest"), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"));
    try std.testing.expect(j.is(j.get(v, "history_revision"), "r"));
    try std.testing.expect(j.is(j.get(v, "text"), ""));
    try std.testing.expect(j.is(j.get(v, "default_display"), "inline"));
    try std.testing.expect(j.is(j.get(v, "retry_action"), "block.retry"));
    try std.testing.expect(j.is(j.get(v, "force_action"), "block.force"));
    try std.testing.expect(j.get(result, "block_slots") == .null);
    try std.testing.expect(j.get(j.get(result, "vars_patch"), "blocks") == .null);
    try std.testing.expect(j.get(j.get(result, "vars_patch"), "user_blocks") == .null);
    e.config.display_mode = .after;
    e.config.assistant_only = false;
    try e.phase(a, "settled-blocks", try block(a, 2, "text", "user"), ctx);
    try e.phase(a, "event-result", try complete(a, e.tasks[1].?.id, "[[[\"user translation\"]]]"), ctx);
    result = try e.result(a, ctx, "unused", true);
    try std.testing.expectEqual(@as(usize, 1), j.get(result, "block_variants").array.items.len);
    try std.testing.expect(j.is(j.get(j.get(result, "block_variants").array.items[0], "default_display"), "after"));
    try std.testing.expectEqual(@as(usize, 1), j.get(result, "block_slots").array.items.len);
    const users = j.get(j.get(result, "vars_patch"), "user_blocks").array.items;
    try std.testing.expect(users[0] == .null);
    try std.testing.expect(j.is(j.get(users[1], "translation"), "user translation"));
    e.published();
    result = try e.result(a, ctx, "unused", true);
    try std.testing.expect(j.get(result, "block_slots") == .null);
}
test "force cannot bypass source ceilings and MyMemory 500 bytes" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    const oversized = try a.alloc(u8, p.input_limit + 1);
    @memset(oversized, 'a');
    try e.phase(a, "settled-blocks", try textBlock(a, 1, oversized), ctx);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b1\"}"));
    try std.testing.expectError(error.OriginalTextUnavailable, e.action(a, "block.force", try j.parse(a, "{\"block_id\":\"b1\"}"), ctx));
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    e.config.provider = .mymemory;
    const text = try a.alloc(u8, 501);
    @memset(text, 'a');
    try e.phase(a, "settled-blocks", try textBlock(a, 2, text), ctx);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b2\"}"));
    try e.action(a, "block.force", try j.parse(a, "{\"block_id\":\"b2\"}"), ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try std.testing.expectEqualStrings("MyMemoryInputExceeds500Bytes", e.entries.items[1].failure);
}

test "no prose skips before HTTP and ambiguous text remains eligible" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try textBlock(a, 1, "```zig\nconst x = 42;\n```\n`hello world`\n12345"), ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try std.testing.expectEqual(@import("language.zig").Reason.no_prose, e.entries.items[0].reason.?);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b1\"}"));
    try e.action(a, "block.force", try j.parse(a, "{\"block_id\":\"b1\"}"), ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
    for (2..5) |i| try e.phase(a, "settled-blocks", try textBlock(a, i, "unknown short API text"), ctx);
    try std.testing.expectEqual(@as(usize, 4), Mock.http);
    // The confidence gate still runs even while all HTTP positions are occupied.
    try e.phase(a, "settled-blocks", try textBlock(a, 5, "12345"), ctx);
    try std.testing.expectEqual(@import("language.zig").Reason.no_prose, e.entries.items[4].reason.?);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b5\"}"));
    try e.action(a, "block.force", try j.parse(a, "{\"block_id\":\"b5\"}"), ctx);
    try std.testing.expect(e.entries.items[4].force);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"sidebar\"}"));
    try e.action(a, "control", try e.config.value(a), ctx);
    try std.testing.expect(!e.entries.items[4].force);
    try std.testing.expectEqual(@import("language.zig").Reason.no_prose, e.entries.items[4].reason.?);
}
test "provider output remains bounded at 32 KiB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try a.alloc(u8, 32 * 1024 + 1);
    @memset(text, 'x');
    const body = try std.json.stringifyAlloc(a, .{.{.{text}}}, .{});
    try std.testing.expectError(error.TranslationOutputExceeds32KiB, p.decode(a, .google, body));
}

test "mixed Latin languages stay unknown and MyMemory manual equality can dispatch" {
    const gate = @import("language.zig");
    try std.testing.expectEqual(@as(?gate.Reason, null), gate.decision(.{ .target = "en" }, "This is the text that you can use with the system and it will preserve your data. Les données sont dans le système et vous pouvez les utiliser avec une méthode pour les documents."));
    try std.testing.expectEqual(@as(?gate.Reason, null), gate.decision(.{ .target = "ru" }, "Това е текст в системата и на потребителя с данни но не променя нищо"));
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    e.config.provider = .mymemory;
    try e.phase(a, "settled-blocks", try textBlock(a, 1, "这个接口会保留请求数据，并将网络返回内容转换为显示文本，不需要重新处理。"), ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b1\"}"));
    try e.action(a, "block.force", try j.parse(a, "{\"block_id\":\"b1\"}"), ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
}

test "host truncation emits no uncertified variant or retirement and digest spelling is strict" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    var payload = try textBlock(a, 1, "truncated preview");
    const b = &payload.object.getPtr("blocks").?.array.items[0];
    try j.set(b, "text_truncated", .{ .bool = true });
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try j.set(b, "source_digest", j.string(digest));
    try e.phase(a, "settled-blocks", payload, ctx);
    const result = try e.result(a, ctx, "", true);
    try std.testing.expectEqual(@as(usize, 0), j.get(result, "block_variants").array.items.len);
    try std.testing.expectEqualStrings("Original text truncated by host; translation unavailable", e.status);
    e.published();
    try std.testing.expect(e.entries.items[0].fresh);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try j.set(b, "source_digest", j.string("0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expectError(error.InvalidSourceDigest, e.phase(a, "settled-blocks", payload, ctx));
}

test "literal backticks adjacent URL prose and unclassified Unicode stay eligible" {
    const gate = @import("language.zig");
    const unknown: ?gate.Reason = null;
    for ([_][]const u8{ "`Please translate this sentence into Chinese.", "\\`Please translate this sentence into Chinese.", "https://example.com。请把这段话翻译成英文。", "Ｈｅｌｌｏ，ｗｏｒｌｄ！", "ｺﾝﾆﾁﾊ" }) |text| {
        try std.testing.expectEqual(unknown, gate.decision(.{ .target = "en" }, text));
        Mock.http = 0;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var e = try Engine.init(std.testing.allocator);
        defer e.deinit();
        const ctx = try context(a);
        try e.initialize(a, ctx);
        try e.phase(a, "settled-blocks", try textBlock(a, 1, text), ctx);
        try std.testing.expectEqual(@as(usize, 1), Mock.http);
    }
}

test "invalid fences HTML attributes and foreign clauses do not cause skips" {
    const gate = @import("language.zig");
    try std.testing.expectEqual(@as(?gate.Reason, null), gate.decision(.{}, "    ```\nPlease translate this sentence into Chinese."));
    try std.testing.expectEqual(@as(?gate.Reason, null), gate.decision(.{ .target = "en" }, "<div title=\"the is are and with this that for from you your not\">Bonjour</div>"));
    try std.testing.expectEqual(@as(?gate.Reason, null), gate.decision(.{}, "这个接口会保留请求数据，并将网络返回内容转换为显示文本，不需要重新处理。Stop."));
    try std.testing.expectEqual(@as(?gate.Reason, .no_prose), gate.decision(.{}, "```zig\n```not-a-close\nconst x = 1;\n```"));
}

test "Chinese API prose excludes proven punctuation without weakening unknown Unicode" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    const source = "这个设置会将网络请求处理为完整的消息，并且保留原来的内容。我们应该先检查传入的数据，然后再进行翻译和显示，让所有用户都能够了解当前处理结果。API HTTP";
    try e.phase(a, "settled-blocks", try textBlock(a, 1, source), ctx);
    try std.testing.expectEqual(@as(usize, 0), Mock.http);
    try std.testing.expectEqual(@import("language.zig").Reason.same_language, e.entries.items[0].reason.?);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"block-slot\",\"block_id\":\"b1\"}"));
    try e.action(a, "block.force", try j.parse(a, "{\"block_id\":\"b1\"}"), ctx);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
    const unknown: ?@import("language.zig").Reason = null;
    try std.testing.expectEqual(unknown, @import("language.zig").decision(.{}, "Ｈｅｌｌｏ，ｗｏｒｌｄ！"));
    try std.testing.expectEqual(unknown, @import("language.zig").decision(.{}, "ｺﾝﾆﾁﾊ"));
}

test "authored settings and sidebar expose ordered compatible display controls" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "settings", "sidebar" }) |surface| {
        const path = try std.fmt.allocPrint(a, "plugins/output-translator/ui/{s}/index.html", .{surface});
        defer a.free(path);
        const html = try std.fs.cwd().readFileAlloc(a, path, 64 * 1024);
        defer a.free(html);
        const auto = std.mem.indexOf(u8, html, "id=\"auto_translate\"") orelse return error.MissingAutoControl;
        const display = std.mem.indexOf(u8, html, "id=\"display_mode\"") orelse return error.MissingDisplayControl;
        const assistant = std.mem.indexOf(u8, html, "id=\"assistant_only\"") orelse return error.MissingAssistantControl;
        try std.testing.expect(auto < display and display < assistant);
        try std.testing.expect(std.mem.indexOf(u8, html, "默认译文位置") == null);
        try std.testing.expect(std.mem.indexOf(u8, html, "data-i18n=\"display\">显示格式") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "value=\"inline\" data-i18n=\"inline\">译文") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "value=\"after\" data-i18n=\"after\">原文+译文") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "aria-describedby=\"assistant-hint\"") != null);
        if (std.mem.eql(u8, surface, "settings")) {
            try std.testing.expect(std.mem.indexOf(u8, html, "id=\"model\" data-field=\"model\" type=\"text\" maxlength=\"256\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, html, "datalist") == null);
            try std.testing.expect(std.mem.indexOf(u8, html, " list=") == null);
        }
    }
}

test "model defaults freeform saved values and byte bounds remain compatible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = try (c.Config{}).value(a);
    _ = cfg.object.swapRemove("model");
    try std.testing.expectEqualStrings("tencent/Hunyuan-MT-7B", (try c.Config.parse(cfg)).model);
    try std.testing.expect((try c.Config.parse(cfg)).assistant_only);
    const model = "自定义 model / : @ < > & \" 🚀";
    try j.set(&cfg, "model", j.string(model));
    for ([_][]const u8{ "siliconflow", "custom", "google", "siliconflow" }) |provider| {
        try j.set(&cfg, "provider", j.string(provider));
        const roundtrip = try j.parse(a, try j.stringify(a, try (try c.Config.parse(cfg)).value(a)));
        try std.testing.expectEqualStrings(model, (try c.Config.parse(roundtrip)).model);
    }
    const limit = try a.alloc(u8, 257);
    @memset(limit, 'a');
    try j.set(&cfg, "model", j.string(limit[0..256]));
    try std.testing.expectEqual(@as(usize, 256), (try c.Config.parse(cfg)).model.len);
    try j.set(&cfg, "model", j.string(limit));
    try std.testing.expectError(error.ModelLengthLimit, c.Config.parse(cfg));
    try j.set(&cfg, "model", j.string(""));
    try std.testing.expectError(error.ModelLengthLimit, c.Config.parse(cfg));
}

test "HTTP capacity keeps dispatch timeout through preference and config changes" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 120000 });
    try e.initialize(a, ctx);
    for (0..5) |i| try e.phase(a, "settled-blocks", try block(a, i, "text", "assistant"), ctx);
    const original_id = e.tasks[0].?.id;
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 20100 });
    try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 10000 });
    var config = try e.config.value(a);
    try j.set(&config, "target", j.string("de"));
    try e.action(a, "control", config, ctx);
    try std.testing.expectEqual(@as(usize, 4), Mock.http);
    try std.testing.expectEqual(@as(f64, 120000), e.tasks[0].?.timeout_ms);
    try std.testing.expect(e.tasks[0].?.generation != e.generation);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 125099 });
    try e.phase(a, "idle", j.object(a), ctx);
    try std.testing.expectEqual(@as(usize, 4), Mock.http);
    try std.testing.expectEqual(original_id, e.tasks[0].?.id);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 125100 });
    try e.phase(a, "idle", j.object(a), ctx);
    try std.testing.expectEqual(@as(usize, 8), Mock.http);
    try std.testing.expect(e.tasks[0].?.id != original_id);
    try std.testing.expectEqual(@as(f64, 10000), e.tasks[0].?.timeout_ms);
    try e.phase(a, "event-result", try complete(a, original_id, "[[[\"stale\"]]]"), ctx);
    try std.testing.expectEqualStrings("", e.entries.items[0].translation);
    try std.testing.expectEqual(@as(usize, 8), Mock.http);
}

test "default HTTP request expires at original15s despite a later longer preference" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try block(a, 1, "text", "assistant"), ctx);
    const original_id = e.tasks[0].?.id;
    try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 300000 });
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15099 });
    try e.context(ctx);
    try std.testing.expect(e.tasks[0] != null);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15100 });
    try e.phase(a, "idle", j.object(a), ctx);
    try std.testing.expect(e.tasks[0] == null);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
    try e.phase(a, "event-result", try complete(a, original_id, "[[[\"late\"]]]"), ctx);
    try std.testing.expectEqualStrings("", e.entries.items[0].translation);
}

test "connection test snapshots120s HTTP deadline and can complete after20s" {
    Mock.http = 0;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 120000 });
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    try e.initialize(a, ctx);
    try e.action(a, "test", j.object(a), ctx);
    const id = e.tasks[0].?.id;
    try std.testing.expectEqual(@as(f64, 120000), e.tasks[0].?.timeout_ms);
    try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 10000 });
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 20100 });
    try e.phase(a, "idle", j.object(a), ctx);
    try std.testing.expectEqualStrings("pending", e.test_status);
    try std.testing.expectEqual(@as(usize, 1), Mock.http);
    try e.phase(a, "event-result", try complete(a, id, "[[[\"你好\"]]]"), ctx);
    try std.testing.expectEqualStrings("completed", e.test_status);
    try std.testing.expectEqual(@as(f64, 20000), e.test_duration_ms);
}

test "trusted HTTP timeout validates integer bounds and preserves nonHTTP Save15s" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inputs = [_]j.Value{ .null, .{ .bool = true }, j.string("120000"), .{ .integer = 9999 }, .{ .integer = 300001 }, .{ .float = 10000.5 }, .{ .float = std.math.nan(f64) }, .{ .float = std.math.inf(f64) }, .{ .integer = 10000 }, .{ .integer = 120000 }, .{ .integer = 300000 } };
    for (inputs, 0..) |input, i| {
        var e = try Engine.init(std.testing.allocator);
        defer e.deinit();
        var ctx = try context(a);
        try j.set(&ctx, "host_http_timeout_ms", input);
        try e.initialize(a, ctx);
        try e.phase(a, "settled-blocks", try block(a, 1, "text", "assistant"), ctx);
        try std.testing.expectEqual(if (i < 8) @as(f64, 10000) else j.number(input).?, e.tasks[0].?.timeout_ms);
    }
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 120000 });
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    try e.initialize(a, ctx);
    var payload = j.object(a);
    try j.set(&payload, "operation_id", j.string("save-long-http"));
    try j.set(&payload, "config", try e.config.value(a));
    try e.action(a, "settings.save", payload, ctx);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15100 });
    try e.context(ctx);
    try std.testing.expectEqualStrings("unknown", e.save_status);
    try std.testing.expectError(error.SaveOutcomeUnknownReloadToInspect, e.action(a, "settings.save", payload, ctx));
}

test "connection timeout keeps recognized Host cause and never echoes arbitrary error bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const timeout_message = "plugin host effect exceeded 120000ms deadline";
    for ([_][]const u8{ timeout_message, "Bearer private-token", "plugin host effect exceeded Bearer secretms deadline", "plugin host effect exceeded 1ms deadline", "plugin host effect exceeded 120000ms deadline secret" }, 0..) |detail, i| {
        var e = try Engine.init(std.testing.allocator);
        defer e.deinit();
        var ctx = try context(a);
        try j.set(&ctx, "host_http_timeout_ms", .{ .integer = 120000 });
        try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
        try e.initialize(a, ctx);
        try e.action(a, "test", j.object(a), ctx);
        var response = j.object(a);
        try j.set(&response, "request_id", .{ .integer = e.tasks[0].?.id });
        try j.set(&response, "ok", .{ .bool = false });
        try j.set(&response, "error", j.string(detail));
        try e.phase(a, "event-result", response, ctx);
        try std.testing.expectEqualStrings("error", e.test_status);
        try std.testing.expectEqualStrings(if (i == 0) timeout_message else "Connection test failed or exceeded host deadline", e.status);
    }
}

test "source replacement preserves peer translations pending work and Save generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    const ctx = try context(a);
    try e.initialize(a, ctx);
    for (0..3) |i| try e.phase(a, "settled-blocks", try block(a, i, "text", "assistant"), ctx);
    const stale = e.tasks[0].?.id;
    const peer = e.tasks[1].?.id;
    const done = e.tasks[2].?.id;
    try e.phase(a, "event-result", try complete(a, done, "[[[\"peer translation\"]]]"), ctx);
    const generation = e.generation;
    try e.phase(a, "settled-blocks", try textBlock(a, 0, "updated source"), ctx);
    const replacement = e.tasks[2].?.id;
    try std.testing.expectEqual(generation, e.generation);
    try std.testing.expectEqualStrings("peer translation", e.entries.items[2].translation);
    try std.testing.expectEqual(peer, e.tasks[1].?.id);
    try e.phase(a, "event-result", try complete(a, stale, "[[[\"stale translation\"]]]"), ctx);
    try std.testing.expectEqualStrings("", e.entries.items[0].translation);
    try e.phase(a, "event-result", try complete(a, peer, "[[[\"pending peer\"]]]"), ctx);
    try std.testing.expectEqualStrings("pending peer", e.entries.items[1].translation);
    try e.phase(a, "event-result", try complete(a, replacement, "[[[\"new translation\"]]]"), ctx);
    try std.testing.expectEqualStrings("new translation", e.entries.items[0].translation);
}

test "old source timeout cannot fail the newer pending source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try textBlock(a, 0, "old source"), ctx);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 1000 });
    try e.phase(a, "settled-blocks", try textBlock(a, 0, "new source"), ctx);
    const next = e.tasks[1].?.id;
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15100 });
    try e.context(ctx);
    try std.testing.expect(e.tasks[0] == null);
    try e.phase(a, "event-result", try complete(a, next, "[[[\"new result\"]]]"), ctx);
    try std.testing.expectEqualStrings("new result", e.entries.items[0].translation);
}

test "source update during Save preserves exact storage acknowledgment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try textBlock(a, 0, "old source"), ctx);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    const save = try j.parse(a, "{\"operation_id\":\"save-source-change\"}");
    var payload = save;
    try j.set(&payload, "config", try e.config.value(a));
    try e.action(a, "settings.save", payload, ctx);
    const id = e.storage_request.?;
    try e.phase(a, "settled-blocks", try textBlock(a, 0, "new source"), ctx);
    var receipt = try j.parse(a, "{\"ok\":true,\"value\":{\"ack\":true}}");
    try j.set(&receipt, "request_id", .{ .integer = id });
    try e.phase(a, "event-result", receipt, ctx);
    try std.testing.expect(e.saved);
    try std.testing.expectEqualStrings("applied", e.save_status);
}

test "Save dispatch failures settle and unknown rejection cannot erase original receipt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    try e.initialize(a, ctx);
    var payload = try j.parse(a, "{\"operation_id\":\"save-rejected\"}");
    try j.set(&payload, "config", try e.config.value(a));
    Mock.reject_storage = true;
    defer Mock.reject_storage = false;
    try e.action(a, "settings.save", payload, ctx);
    try std.testing.expectEqualStrings("failed", e.save_status);
    try std.testing.expect(e.staged_config == null);
    Mock.reject_storage = false;
    try e.action(a, "settings.save", payload, ctx);
    try j.set(&ctx, "host_monotonic_ms", .{ .integer = 15100 });
    try e.context(ctx);
    try e.rejectSave("another-operation");
    try std.testing.expectEqualStrings("unknown", e.save_status);
    try std.testing.expectEqualStrings("save-rejected", e.save_operation);
    try std.testing.expectError(error.SaveOutcomeUnknownReloadToInspect, e.action(a, "settings.save", payload, ctx));
}

test "Host dispatch rejections release every owned error buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try Engine.init(std.testing.allocator);
    defer e.deinit();
    var ctx = try context(a);
    Mock.reject_resources = true;
    Mock.reject_conversation = true;
    Mock.reject_http = true;
    defer {
        Mock.reject_resources = false;
        Mock.reject_conversation = false;
        Mock.reject_http = false;
    }
    try e.initialize(a, ctx);
    try e.phase(a, "settled-blocks", try textBlock(a, 0, "eligible text"), ctx);
    try j.set(&ctx, "surface", try j.parse(a, "{\"target\":\"setting-page\"}"));
    try std.testing.expectError(error.ConnectionTestDispatchRejected, e.action(a, "test", j.object(a), ctx));
    var config = try e.config.value(a);
    try j.set(&config, "provider", j.string("custom"));
    var payload = try j.parse(a, "{\"operation_id\":\"rejected-grant\",\"endpoint\":\"https://example.test\"}");
    try j.set(&payload, "config", config);
    try std.testing.expectError(error.ResourceSaveRejected, e.action(a, "settings.save", payload, ctx));
}
