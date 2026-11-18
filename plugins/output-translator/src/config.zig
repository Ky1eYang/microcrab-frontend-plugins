const std = @import("std");
const j = @import("json.zig");
pub const DisplayMode = enum { @"inline", after };
pub const Provider = enum { google, mymemory, siliconflow, custom };
pub const Config = struct {
    provider: Provider = .google,
    source: []const u8 = "auto",
    target: []const u8 = "zh-CN",
    model: []const u8 = "tencent/Hunyuan-MT-7B",
    temperature: f64 = 0.3,
    prompt: []const u8 = "You are a professional translation engine. Translate into {targetLang}. Preserve Markdown structure and formatting exactly. Keep fenced code blocks, inline code, URLs and link destinations byte-for-byte unchanged; translate only prose and retain terminology. Output only the translation.",
    auto_translate: bool = true,
    assistant_only: bool = true,
    display_mode: DisplayMode = .@"inline",
    skip_same_language: bool = true,
    pub fn parse(v: j.Value) !Config {
        if (v != .object) return error.ConfigurationMustBeObject;
        var c = Config{};
        const p = j.text(j.get(v, "provider")) orelse return error.ProviderRequired;
        c.provider = std.meta.stringToEnum(Provider, p) orelse return error.UnsupportedProvider;
        c.source = j.text(j.get(v, "source")) orelse return error.SourceLanguageRequired;
        c.target = j.text(j.get(v, "target")) orelse return error.TargetLanguageRequired;
        if (!language(c.source, true) or !language(c.target, false)) return error.UnsupportedLanguage;
        c.model = j.text(j.get(v, "model")) orelse c.model;
        if (c.model.len == 0 or c.model.len > 256) return error.ModelLengthLimit;
        c.prompt = j.text(j.get(v, "prompt")) orelse c.prompt;
        if (c.prompt.len == 0 or c.prompt.len > 2048) return error.PromptLengthLimit;
        c.temperature = j.number(j.get(v, "temperature")) orelse c.temperature;
        if (!std.math.isFinite(c.temperature) or c.temperature < 0 or c.temperature > 1.5) return error.TemperatureRange;
        if (j.get(v, "auto_translate") != .bool or j.get(v, "assistant_only") != .bool) return error.AutomationFlagsRequired;
        c.auto_translate = j.truth(j.get(v, "auto_translate"));
        c.assistant_only = j.truth(j.get(v, "assistant_only"));
        if (j.get(v, "display_mode") != .null) {
            c.display_mode = std.meta.stringToEnum(DisplayMode, j.text(j.get(v, "display_mode")) orelse return error.InvalidDisplayMode) orelse return error.InvalidDisplayMode;
        }
        if (j.get(v, "skip_same_language") != .null) {
            if (j.get(v, "skip_same_language") != .bool) return error.InvalidSkipSameLanguage;
            c.skip_same_language = j.truth(j.get(v, "skip_same_language"));
        }
        var it = v.object.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            var known = false;
            inline for (.{ "provider", "source", "target", "model", "temperature", "prompt", "auto_translate", "assistant_only", "display_mode", "skip_same_language" }) |f| {
                if (std.mem.eql(u8, k, f)) known = true;
            }
            if (!known) return error.UnknownConfigurationField;
        }
        return c;
    }
    pub fn owned(c: Config, a: std.mem.Allocator) !Config {
        var out = c;
        out.source = try a.dupe(u8, c.source);
        errdefer a.free(out.source);
        out.target = try a.dupe(u8, c.target);
        errdefer a.free(out.target);
        out.model = try a.dupe(u8, c.model);
        errdefer a.free(out.model);
        out.prompt = try a.dupe(u8, c.prompt);
        return out;
    }
    pub fn deinit(c: Config, a: std.mem.Allocator) void {
        a.free(c.source);
        a.free(c.target);
        a.free(c.model);
        a.free(c.prompt);
    }
    pub fn value(c: Config, a: std.mem.Allocator) !j.Value {
        const bytes = try std.json.stringifyAlloc(a, c, .{});
        return j.parse(a, bytes);
    }
};
pub fn language(s: []const u8, auto: bool) bool {
    if (auto and std.mem.eql(u8, s, "auto")) return true;
    for ([_][]const u8{ "en", "zh-CN", "zh-TW", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "ar" }) |l| if (std.mem.eql(u8, l, s)) return true;
    return false;
}
