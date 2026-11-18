const std = @import("std");
const j = @import("json.zig");
const cfg = @import("config.zig");
pub const Config = cfg.Config;
pub const Provider = cfg.Provider;
pub const input_limit = 16 * 1024;
pub const output_limit = 32 * 1024;
pub fn encode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try out.append(c) else try out.writer().print("%{X:0>2}", .{c});
    }
    return out.toOwnedSlice();
}
pub fn detect(s: []const u8) ![]const u8 {
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    var cjk = false;
    var latin = false;
    var kana = false;
    var hangul = false;
    while (it.nextCodepoint()) |c| {
        if (c >= 0x3040 and c <= 0x30ff) kana = true;
        if (c >= 0xac00 and c <= 0xd7af) hangul = true;
        if (c >= 0x4e00 and c <= 0x9fff) cjk = true;
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) latin = true;
    }
    if (kana) return "ja";
    if (hangul) return "ko";
    if (cjk) return "zh-CN";
    if (latin) return "en";
    return error.MyMemoryCannotDetectLanguage;
}
pub fn build(a: std.mem.Allocator, c: Config, text: []const u8, resource: ?[]const u8, pin: ?[]const u8) !j.Value {
    if (text.len == 0) return error.EmptyTranslationInput;
    if (text.len > input_limit) return error.TranslationInputExceeds16KiB;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var p = j.object(a);
    if (c.provider == .google or c.provider == .mymemory) {
        var url: []const u8 = undefined;
        if (c.provider == .google) url = try std.fmt.allocPrint(a, "https://translate.googleapis.com/translate_a/single?client=gtx&sl={s}&tl={s}&dt=t&q={s}", .{ try encode(a, c.source), try encode(a, c.target), try encode(a, text) }) else {
            if (text.len > 500) return error.MyMemoryInputExceeds500Bytes;
            const source = if (std.mem.eql(u8, c.source, "auto")) try detect(text) else c.source;
            url = try std.fmt.allocPrint(a, "https://api.mymemory.translated.net/get?q={s}&langpair={s}%7C{s}", .{ try encode(a, text), try encode(a, source), try encode(a, c.target) });
        }
        try j.set(&p, "url", j.string(url));
        try j.set(&p, "method", j.string("GET"));
    } else {
        try j.set(&p, "resource", j.string(resource orelse return error.SaveResourceGrantFirst));
        try j.set(&p, "config_pin", j.string(pin orelse return error.ResourceConfigurationUnavailable));
        try j.set(&p, "method", j.string("POST"));
        var headers = j.object(a);
        try j.set(&headers, "Content-Type", j.string("application/json"));
        try j.set(&p, "headers", headers);
        const prompt = try std.mem.replaceOwned(u8, a, c.prompt, "{targetLang}", c.target);
        var body = j.object(a);
        try j.set(&body, "model", j.string(c.model));
        try j.set(&body, "temperature", .{ .float = c.temperature });
        try j.set(&body, "stream", .{ .bool = false });
        var messages = j.array(a);
        var system = j.object(a);
        try j.set(&system, "role", j.string("system"));
        try j.set(&system, "content", j.string(prompt));
        try messages.array.append(system);
        var user = j.object(a);
        try j.set(&user, "role", j.string("user"));
        try j.set(&user, "content", j.string(text));
        try messages.array.append(user);
        try j.set(&body, "messages", messages);
        try j.set(&p, "body", j.string(try j.stringify(a, body)));
    }
    return p;
}
pub fn decode(a: std.mem.Allocator, provider: Provider, source: []const u8) ![]const u8 {
    if (source.len > 128 * 1024) return error.ProviderResponseExceeds128KiB;
    const v = try j.parse(a, source);
    var result: []const u8 = undefined;
    switch (provider) {
        .google => {
            if (v != .array or v.array.items.len == 0) return error.InvalidGoogleResponse;
            const segments = v.array.items[0];
            if (segments != .array) return error.InvalidGoogleSegments;
            var out = std.ArrayList(u8).init(a);
            for (segments.array.items) |seg| {
                if (seg != .array or seg.array.items.len == 0) return error.InvalidGoogleSegment;
                const t = j.text(seg.array.items[0]) orelse return error.InvalidGoogleSegmentText;
                if (out.items.len + t.len > output_limit) return error.TranslationOutputExceeds32KiB;
                try out.appendSlice(t);
            }
            result = try out.toOwnedSlice();
        },
        .mymemory => {
            if (j.uint(j.get(v, "responseStatus")) != 200) return error.MyMemoryProviderRejectedRequest;
            result = j.text(j.get(j.get(v, "responseData"), "translatedText")) orelse return error.InvalidMyMemoryResponse;
        },
        .siliconflow, .custom => {
            const choices = j.get(v, "choices");
            if (choices != .array or choices.array.items.len == 0) return error.InvalidCompletionChoices;
            result = j.text(j.get(j.get(choices.array.items[0], "message"), "content")) orelse return error.InvalidCompletionContent;
        },
    }
    if (result.len == 0) return error.EmptyProviderTranslation;
    if (result.len > output_limit) return error.TranslationOutputExceeds32KiB;
    if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidUtf8;
    return result;
}
