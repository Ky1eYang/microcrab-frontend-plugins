//! Deterministic UTF-8 byte scanner. Only the recognized spans are replaced.
const std = @import("std");

pub const max_input_bytes = 8 * 1024;
pub const max_output_bytes = 2 * max_input_bytes;
pub const placeholder = "[REDACTED]";

pub const Result = struct { text: []const u8, count: usize };
pub const ScanError = error{ InputTooLarge, InvalidUtf8, OutputTooLarge, ResidualMatch };

pub fn scan(input: []const u8, buffer: *[max_output_bytes]u8) ScanError!Result {
    if (input.len > max_input_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var out = std.io.fixedBufferStream(buffer);
    const writer = out.writer();
    var cursor: usize = 0;
    var pending: usize = 0;
    var count: usize = 0;
    while (cursor < input.len) {
        if (match(input, cursor)) |span| {
            std.debug.assert(pending <= span.start and cursor <= span.start and span.start < span.end and span.end <= input.len);
            writer.writeAll(input[pending..span.start]) catch return error.OutputTooLarge;
            writer.writeAll(placeholder) catch return error.OutputTooLarge;
            count += 1;
            cursor = span.end;
            pending = cursor;
        } else {
            cursor += 1;
        }
    }
    writer.writeAll(input[pending..]) catch return error.OutputTooLarge;
    const text = out.getWritten();
    // A recognized value must not reappear literally in an unmatched context
    // (for example the same bearer credential pasted without its header). Fail
    // closed rather than guessing how to redact overlaps or placeholder text.
    if (count != 0) {
        cursor = 0;
        while (cursor < input.len) {
            if (match(input, cursor)) |span| {
                if (std.mem.indexOf(u8, text, input[span.start..span.end]) != null) return error.ResidualMatch;
                cursor = span.end;
            } else {
                cursor += 1;
            }
        }
    }
    return .{ .text = text, .count = count };
}

const Span = struct { start: usize, end: usize };
const uri_schemes = [_][]const u8{
    "postgres://", "postgresql://", "mysql://", "mariadb://", "mongodb://", "mongodb+srv://", "redis://", "rediss://",
};
const key_patterns = [_]struct { prefix: []const u8, minimum: usize, maximum: usize, style: enum { token, alnum, aws } }{
    .{ .prefix = "sk-proj-", .minimum = 20, .maximum = max_input_bytes, .style = .token },
    .{ .prefix = "sk-ant-", .minimum = 20, .maximum = max_input_bytes, .style = .token },
    .{ .prefix = "sk-", .minimum = 20, .maximum = max_input_bytes, .style = .token },
    .{ .prefix = "github_pat_", .minimum = 22, .maximum = max_input_bytes, .style = .token },
    .{ .prefix = "ghp_", .minimum = 36, .maximum = 36, .style = .alnum },
    .{ .prefix = "AKIA", .minimum = 16, .maximum = 16, .style = .aws },
    .{ .prefix = "ASIA", .minimum = 16, .maximum = 16, .style = .aws },
};

fn match(input: []const u8, i: usize) ?Span {
    const tail = input[i..];
    if (tail[0] == '-') {
        if (privateKey(tail)) |end| return .{ .start = i, .end = i + end };
    }
    if (i == 0 or (!localByte(input[i - 1]) and input[i - 1] < 128 and input[i - 1] != '@')) {
        if (email(tail)) |end| return .{ .start = i, .end = i + end };
    }
    if (i == 0 or (!tokenByte(input[i - 1]) and input[i - 1] < 128)) {
        if (bearer(tail)) |span| return .{ .start = i + span.start, .end = i + span.end };
        for (uri_schemes) |scheme| {
            if (!startsIgnoreCase(tail, scheme)) continue;
            const end = run(uriByte, tail, scheme.len);
            if (end > scheme.len) return .{ .start = i, .end = i + end };
        }
        for (key_patterns) |key| {
            if (!std.mem.startsWith(u8, tail, key.prefix)) continue;
            const end = run(tokenByte, tail, key.prefix.len);
            const suffix = tail[key.prefix.len..end];
            // The most specific matching prefix owns the token; do not
            // interpret a short sk-ant-/sk-proj- suffix as a generic sk- key.
            if (suffix.len < key.minimum or suffix.len > key.maximum) break;
            for (suffix) |byte| {
                switch (key.style) {
                    .token => {},
                    .alnum => if (!std.ascii.isAlphanumeric(byte)) break,
                    .aws => if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte)) break,
                }
            } else return .{ .start = i, .end = i + end };
            break;
        }
        if (jwt(tail)) |end| return .{ .start = i, .end = i + end };
    }
    return null;
}

fn startsIgnoreCase(tail: []const u8, prefix: []const u8) bool {
    return tail.len >= prefix.len and std.ascii.eqlIgnoreCase(tail[0..prefix.len], prefix);
}

fn run(comptime valid: fn (u8) bool, tail: []const u8, start: usize) usize {
    std.debug.assert(start <= tail.len);
    var i = start;
    while (i < tail.len and valid(tail[i])) : (i += 1) {}
    return i;
}

fn tokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

fn bearerByte(byte: u8) bool {
    return tokenByte(byte) or byte == '.' or byte == '~' or byte == '+' or byte == '/' or byte == '=';
}

fn horizontalSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn bearer(tail: []const u8) ?Span {
    const word = "bearer";
    if (!startsIgnoreCase(tail, word)) return null;
    const start = run(horizontalSpace, tail, word.len);
    if (start == word.len) return null;
    const end = run(bearerByte, tail, start);
    if (end - start < 8) return null;
    // An unsupported colon-delimited value could be a supported URI. Leave its
    // scheme intact so the main scanner can recognize the complete URI.
    if (std.mem.startsWith(u8, tail[end..], "://")) return null;
    return .{ .start = start, .end = end };
}

fn uriByte(byte: u8) bool {
    return byte > 0x20 and byte != 0x7f and switch (byte) {
        '\'', '"', '`', '<', '>' => false,
        else => true,
    };
}

fn jwt(tail: []const u8) ?usize {
    if (!std.mem.startsWith(u8, tail, "eyJ")) return null;
    const header = run(tokenByte, tail, 0);
    if (header < 8 or header == tail.len or tail[header] != '.') return null;
    const claims = run(tokenByte, tail, header + 1);
    if (claims - (header + 1) < 4 or claims == tail.len or tail[claims] != '.') return null;
    const signature = run(tokenByte, tail, claims + 1);
    if (signature - (claims + 1) < 8) return null;
    // Do not partially redact a longer dot-separated token (e.g. compact JWE).
    if (tail.len - signature >= 2 and tail[signature] == '.' and tokenByte(tail[signature + 1])) return null;
    return signature;
}

fn localByte(byte: u8) bool {
    return tokenByte(byte) or byte == '.' or byte == '+' or byte == '%';
}

fn domainByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-';
}

fn email(tail: []const u8) ?usize {
    // Inspect at most the supported local-part size plus the @ delimiter.
    const local = run(localByte, tail[0..@min(65, tail.len)], 0);
    if (local == 0 or local > 64 or local == tail.len or tail[local] != '@') return null;
    if (tail[0] == '.' or tail[local - 1] == '.' or std.mem.indexOf(u8, tail[0..local], "..") != null) return null;
    var end = run(domainByte, tail[0..@min(256, tail.len)], local + 1);
    if (end > 255) return null;
    if (end < tail.len and (tail[end] >= 128 or tail[end] == '@' or tail[end] == '_')) return null;
    if (end > local + 1 and tail[end - 1] == '.') end -= 1;
    if (end > 254) return null;
    var labels = std.mem.splitScalar(u8, tail[local + 1 .. end], '.');
    var total: usize = 0;
    var suffix: []const u8 = "";
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return null;
        total += 1;
        suffix = label;
    }
    if (total < 2 or suffix.len < 2) return null;
    for (suffix) |byte| if (!std.ascii.isAlphabetic(byte)) return null;
    return end;
}

fn privateKey(tail: []const u8) ?usize {
    const begin = "-----BEGIN ";
    const label_suffix = "PRIVATE KEY";
    const dashes = "-----";
    if (!std.mem.startsWith(u8, tail, begin)) return null;
    const start = begin.len;
    const label_end = for (tail[start..@min(tail.len, start + 64 + 1)], start..) |byte, j| {
        if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte) and byte != ' ') break j;
    } else return null;
    const label = tail[start..label_end];
    if (!std.mem.endsWith(u8, label, label_suffix) or (label.len > label_suffix.len and label[label.len - label_suffix.len - 1] != ' ')) return null;
    if (!std.mem.startsWith(u8, tail[label_end..], dashes)) return null;
    const footer_prefix = "-----END ";
    var footer: [footer_prefix.len + 64 + dashes.len]u8 = undefined;
    @memcpy(footer[0..footer_prefix.len], footer_prefix);
    @memcpy(footer[footer_prefix.len..][0..label.len], label);
    const footer_end = footer_prefix.len + label.len;
    @memcpy(footer[footer_end..][0..dashes.len], dashes);
    const body = label_end + dashes.len;
    // For a recognizable opener with no exact footer, redact through EOF rather
    // than returning any truncated private-key body.
    const closing = std.mem.indexOfPos(u8, tail, body, footer[0 .. footer_end + dashes.len]) orelse return tail.len;
    return closing + footer_end + dashes.len;
}
