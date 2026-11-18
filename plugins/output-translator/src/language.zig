const std = @import("std");
const c = @import("config.zig");
pub const Reason = enum { same_language, no_prose, unchanged };

// This is a local confidence gate, not general language identification. Unknown
// text must still reach the provider. Work stays bounded by the source ceiling.
pub fn decision(config: c.Config, text: []const u8) ?Reason {
    var buffer: [16 * 1024]u8 = undefined;
    const prose = extract(text, &buffer);
    const evidence = inspect(prose);
    if (evidence.letters == 0) return .no_prose;
    if (!config.skip_same_language) return null;
    if (!std.mem.eql(u8, config.source, "auto")) {
        return if (std.mem.eql(u8, config.source, config.target)) .same_language else null;
    }
    if (hasHtml(text)) return null;
    const detected = evidence.language(prose) orelse return null;
    return if (std.mem.eql(u8, detected, config.target)) .same_language else null;
}
fn hasHtml(text: []const u8) bool {
    for (text, 0..) |ch, i| {
        if (ch != '<' or i + 1 >= text.len) continue;
        const next = text[i + 1];
        if ((std.ascii.isAlphabetic(next) or next == '!' or next == '/') and std.mem.indexOfScalar(u8, text[i + 1 ..], '>') != null) return true;
    }
    return false;
}
fn extract(text: []const u8, buffer: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    var fence: u8 = 0;
    var fence_len: usize = 0;
    var line_start = true;
    while (i < text.len and n < buffer.len) {
        if (line_start) {
            var start = i;
            while (start < text.len and (text[start] == ' ' or text[start] == '\t')) : (start += 1) {}
            var end = start;
            if (start - i <= 3 and start < text.len and (text[start] == '`' or text[start] == '~')) {
                while (end < text.len and text[end] == text[start]) : (end += 1) {}
                var suffix = end;
                while (suffix < text.len and (text[suffix] == ' ' or text[suffix] == '\t' or text[suffix] == '\r')) : (suffix += 1) {}
                const closes = suffix == text.len or text[suffix] == '\n';
                if (end - start >= 3 and (fence == 0 or (closes and (fence == text[start] and end - start >= fence_len)))) {
                    if (fence == 0) {
                        fence = text[start];
                        fence_len = end - start;
                    } else fence = 0;
                    while (i < text.len and text[i] != '\n') : (i += 1) {}
                    if (i < text.len) i += 1;
                    buffer[n] = ' ';
                    n += 1;
                    continue;
                }
            }
            line_start = false;
        }
        if (text[i] == '\n') {
            line_start = true;
            if (fence == 0) {
                buffer[n] = ' ';
                n += 1;
            }
            i += 1;
            continue;
        }
        if (fence != 0) {
            i += 1;
            continue;
        }
        if (text[i] == '`') {
            const start = i;
            while (i < text.len and text[i] == '`') : (i += 1) {}
            const run = i - start;
            var slashes: usize = 0;
            var before = start;
            while (before > 0 and text[before - 1] == '\\') {
                slashes += 1;
                before -= 1;
            }
            if (slashes % 2 == 0) {
                var closing = i;
                while (closing < text.len) {
                    if (text[closing] != '`') {
                        closing += 1;
                        continue;
                    }
                    const candidate = closing;
                    while (closing < text.len and text[closing] == '`') : (closing += 1) {}
                    if (closing - candidate == run) {
                        i = closing;
                        break;
                    }
                }
            }
            // An unmatched or escaped opener is literal Markdown, not code.
            buffer[n] = ' ';
            n += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://") or std.mem.startsWith(u8, text[i..], "www.")) {
            while (i < text.len and !std.ascii.isWhitespace(text[i]) and text[i] != '>' and text[i] < 128) : (i += 1) {}
            buffer[n] = ' ';
            n += 1;
            continue;
        }
        if (text[i] == ']' and i + 1 < text.len and text[i + 1] == '(') {
            i += 2;
            var depth: usize = 1;
            while (i < text.len and depth > 0) : (i += 1) {
                if (text[i] == '(') depth += 1 else if (text[i] == ')') depth -= 1;
            }
            buffer[n] = ' ';
            n += 1;
            continue;
        }
        const ch = text[i];
        buffer[n] = if (std.ascii.isAlphanumeric(ch) or ch >= 128 or ch == '.' or ch == '!' or ch == '?') ch else ' ';
        n += 1;
        i += 1;
    }
    return buffer[0..n];
}
const Evidence = struct {
    letters: usize = 0,
    latin: usize = 0,
    han: usize = 0,
    kana: usize = 0,
    hangul: usize = 0,
    cyrillic: usize = 0,
    arabic: usize = 0,
    simplified: u64 = 0,
    traditional: u64 = 0,
    fn language(e: Evidence, prose: []const u8) ?[]const u8 {
        if (e.letters < 16) return null;
        if (e.kana >= 8 and (e.kana + e.han) * 100 >= e.letters * 90) return "ja";
        if (e.hangul >= 16 and e.hangul * 100 >= e.letters * 90) return "ko";
        if (e.cyrillic >= 24 and e.cyrillic * 100 >= e.letters * 95) {
            // Ukrainian/Belarusian/Serbian are not Russian evidence.
            var it = std.unicode.Utf8View.init(prose) catch return null;
            var points = it.iterator();
            while (points.nextCodepoint()) |cp| if ((cp >= 0x400 and cp <= 0x40f and cp != 0x401) or (cp >= 0x450 and cp <= 0x45f and cp != 0x451) or cp > 0x45f and cp <= 0x52f) return null;
            return if (russianEvidence(prose)) "ru" else null;
        }
        if (e.arabic >= 24 and e.arabic * 100 >= e.letters * 95 and arabicEvidence(prose)) return "ar";
        if (e.han >= 20 and e.latin > 0) {
            for (prose, 0..) |ch, i| {
                if ((ch == '.' or ch == '!' or ch == '?') and i > 0 and std.ascii.isAlphabetic(prose[i - 1])) return null;
            }
        }
        if (e.han >= 20 and e.kana == 0 and e.hangul == 0 and e.han * 100 >= e.letters * 85) {
            if (@popCount(e.simplified) >= 2 and e.traditional == 0) return "zh-CN";
            if (@popCount(e.traditional) >= 2 and e.simplified == 0) return "zh-TW";
            return null;
        }
        if (e.latin * 100 >= e.letters * 95) return latinLanguage(prose);
        return null;
    }
};
fn neutral(cp: u21) bool {
    return cp == 0x00a0 or cp == 0x1680 or cp == 0x3000 or
        (cp >= 0x2000 and cp <= 0x206f) or
        cp == 0x3001 or cp == 0x3002 or
        (cp >= 0x3008 and cp <= 0x3011) or
        (cp >= 0x3014 and cp <= 0x301f) or
        (cp >= 0xff01 and cp <= 0xff20) or
        (cp >= 0xff3b and cp <= 0xff40) or
        (cp >= 0xff5b and cp <= 0xff65);
}
fn inspect(prose: []const u8) Evidence {
    var e = Evidence{};
    const view = std.unicode.Utf8View.init(prose) catch return .{ .letters = 1 };
    var it = view.iterator();
    const simplified = "这为个们来时会说对从与无后发里网络译语简体设置应启关数显处理传请据过还进种将并实让长学习";
    const traditional = "這為個們來時會說對從與無後發裡網絡譯語簡體設置應啟關數顯處理傳請據過還進種將並實讓長學習";
    while (it.nextCodepoint()) |cp| {
        // Proven punctuation/spacing is neutral evidence. Keep unclassified
        // Unicode letters (including fullwidth Latin and halfwidth Kana) unknown.
        if (neutral(cp)) continue;
        if ((cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or (cp >= 0xc0 and cp <= 0x24f)) {
            e.latin += 1;
            e.letters += 1;
        } else if ((cp >= 0x3400 and cp <= 0x9fff) or (cp >= 0x20000 and cp <= 0x3134f)) {
            e.han += 1;
            e.letters += 1;
            var s = (std.unicode.Utf8View.initComptime(simplified)).iterator();
            var t = (std.unicode.Utf8View.initComptime(traditional)).iterator();
            var index: u6 = 0;
            while (s.nextCodepoint()) |sc| : (index += 1) {
                const tc = t.nextCodepoint().?;
                if (sc != tc and cp == sc) e.simplified |= @as(u64, 1) << index;
                if (sc != tc and cp == tc) e.traditional |= @as(u64, 1) << index;
            }
        } else if (cp >= 0x3040 and cp <= 0x30ff) {
            e.kana += 1;
            e.letters += 1;
        } else if (cp >= 0xac00 and cp <= 0xd7af) {
            e.hangul += 1;
            e.letters += 1;
        } else if (cp >= 0x400 and cp <= 0x52f) {
            e.cyrillic += 1;
            e.letters += 1;
        } else if ((cp >= 0x620 and cp <= 0x64a) or (cp >= 0x66e and cp <= 0x6d3)) {
            e.arabic += 1;
            e.letters += 1;
        } else if (cp >= 128) {
            // Absence of prose requires proof. Unclassified Unicode (including
            // fullwidth letters and halfwidth Kana) is unknown, never no_prose.
            e.letters += 1;
        }
    }
    return e;
}
fn wordHits(prose: []const u8, words: []const []const u8) struct { hits: usize, distinct: usize, total: usize } {
    var tokens = std.mem.tokenizeScalar(u8, prose, ' ');
    var hits: usize = 0;
    var total: usize = 0;
    var seen: u64 = 0;
    while (tokens.next()) |token| {
        total += 1;
        for (words, 0..) |word, i| {
            if (std.ascii.eqlIgnoreCase(token, word)) {
                hits += 1;
                seen |= @as(u64, 1) << @as(u6, @intCast(i));
                break;
            }
        }
    }
    return .{ .hits = hits, .distinct = @popCount(seen), .total = total };
}
fn russianEvidence(prose: []const u8) bool {
    const hits = wordHits(prose, &.{ "и", "в", "не", "на", "что", "это", "для", "как", "из", "по", "с", "к", "но" });
    const distinctive = wordHits(prose, &.{ "это", "для", "что", "как", "который", "которые", "этот", "эти", "или", "чтобы" });
    return hits.total >= 8 and hits.distinct >= 3 and hits.hits >= 4 and distinctive.distinct >= 2;
}
fn arabicEvidence(prose: []const u8) bool {
    const hits = wordHits(prose, &.{ "في", "من", "على", "إلى", "هذا", "هذه", "التي", "الذي", "أن", "لا", "مع" });
    return hits.total >= 8 and hits.distinct >= 3 and hits.hits >= 4;
}
fn latinLanguage(prose: []const u8) ?[]const u8 {
    const languages = [_][]const u8{ "en", "fr", "de", "es", "pt", "it" };
    const sets = [_][]const []const u8{
        &.{ "the", "is", "are", "and", "with", "this", "that", "for", "from", "you", "your", "not", "will", "can", "has", "have", "to", "of", "in", "it" },
        &.{ "le", "la", "les", "des", "une", "est", "sont", "dans", "pour", "avec", "vous", "nous", "que", "qui", "pas", "sur", "et", "du" },
        &.{ "der", "die", "das", "den", "dem", "und", "ist", "sind", "mit", "für", "nicht", "eine", "einen", "auch", "wird", "werden", "auf", "zu" },
        &.{ "el", "los", "las", "una", "que", "del", "por", "para", "con", "es", "son", "está", "como", "pero", "sin", "sus", "este", "esta" },
        &.{ "os", "as", "uma", "que", "dos", "das", "para", "com", "não", "são", "está", "como", "mas", "sem", "seus", "este", "esta", "é" },
        &.{ "il", "lo", "gli", "una", "che", "del", "per", "con", "sono", "è", "non", "come", "ma", "senza", "questo", "questa", "della", "nel" },
    };
    var winner: ?[]const u8 = null;
    var score: usize = 0;
    var second: usize = 0;
    var credible: usize = 0;
    for (sets, languages) |set, language| {
        const hits = wordHits(prose, set);
        if (hits.distinct >= 3 and hits.hits >= 3) credible += 1;
        const value = if (hits.total >= 12 and hits.distinct >= 4 and hits.hits >= 6 and hits.hits * 100 >= hits.total * 40) hits.hits else 0;
        if (value > score) {
            second = score;
            score = value;
            winner = language;
        } else second = @max(second, value);
    }
    return if (credible == 1 and score >= second + 3) winner else null;
}
