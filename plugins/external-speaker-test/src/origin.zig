//! Validate the trusted runtime origin for display and safe cURL preview.
pub const max_len = 300;
const std = @import("std");

pub fn valid(origin: []const u8) bool {
    if (origin.len > max_len) return false;
    const secure = std.mem.startsWith(u8, origin, "https://");
    const prefix = if (secure) @as(usize, 8) else if (std.mem.startsWith(u8, origin, "http://")) @as(usize, 7) else return false;
    const authority = origin[prefix..];
    if (authority.len == 0) return false;
    const end = if (authority[0] == '[')
        (std.mem.indexOfScalar(u8, authority, ']') orelse return false) + 1
    else
        std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..end];
    if (authority.len > end) {
        if (authority[end] != ':') return false;
        const port = canonicalDecimal(u16, authority[end + 1 ..]) orelse return false;
        if (port == 0 or port == @as(u16, if (secure) 443 else 80)) return false;
    }
    if (host.len == 0) return false;
    if (host[0] == '[') {
        if (!secure) return std.mem.eql(u8, host, "[::1]");
        return canonicalIpv6(host[1 .. host.len - 1]);
    }
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (canonicalIpv4(host)) return secure or std.mem.startsWith(u8, host, "127.");
    return secure and canonicalDns(host);
}

fn canonicalDecimal(comptime T: type, text: []const u8) ?T {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

fn canonicalIpv4(host: []const u8) bool {
    var parts = std.mem.splitScalar(u8, host, '.');
    for (0..4) |_| {
        const part = parts.next() orelse return false;
        if (canonicalDecimal(u8, part) == null) return false;
    }
    return parts.next() == null;
}

fn canonicalDns(host: []const u8) bool {
    if (host.len > 253) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    var last: []const u8 = "";
    // A valid label consumes at least one byte plus its separating dot.
    for (0..127) |_| {
        const label = labels.next() orelse break;
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
        last = label;
    }
    if (last.len == 0 or labels.next() != null) return false;
    // Browser URL parsing treats a decimal/hex last label as legacy IPv4.
    for (last) |byte| if (!std.ascii.isDigit(byte)) break else {} else return false;
    if (std.mem.startsWith(u8, last, "0x")) {
        for (last[2..]) |byte| if (!std.ascii.isHex(byte)) break else {} else return false;
    }
    return true;
}

fn canonicalIpv6(host: []const u8) bool {
    if (host.len > 39) return false;
    for (host) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f') or byte == ':')) return false;
    var words = [_]u16{0} ** 8;
    if (std.mem.indexOf(u8, host, "::")) |at| {
        var tail: [8]u16 = undefined;
        const head_count = ipv6Words(host[0..at], &words) orelse return false;
        const tail_count = ipv6Words(host[at + 2 ..], &tail) orelse return false;
        if (head_count + tail_count >= words.len) return false;
        @memcpy(words[words.len - tail_count ..], tail[0..tail_count]);
    } else if ((ipv6Words(host, &words) orelse return false) != words.len) return false;
    // WHATWG form compresses only the first longest run of at least two zeroes.
    var start: usize = 0;
    var length: usize = 0;
    var run: usize = 0;
    for (words, 0..) |word, i| {
        run = if (word == 0) run + 1 else 0;
        if (run >= 2 and run > length) {
            start = i + 1 - run;
            length = run;
        }
    }
    var buffer: [39]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();
    for (words, 0..) |word, i| {
        if (length > 0 and i >= start and i < start + length) {
            if (i == start) writer.writeAll("::") catch unreachable;
            continue;
        }
        if (i != 0 and (length == 0 or i != start + length)) writer.writeByte(':') catch unreachable;
        writer.print("{x}", .{word}) catch unreachable;
    }
    return std.mem.eql(u8, host, stream.getWritten());
}

fn ipv6Words(host: []const u8, words: *[8]u16) ?usize {
    if (host.len == 0) return 0;
    var parts = std.mem.splitScalar(u8, host, ':');
    for (words, 0..) |*word, index| {
        const part = parts.next() orelse return index;
        if (part.len == 0 or part.len > 4) return null;
        word.* = std.fmt.parseInt(u16, part, 16) catch return null;
    }
    return if (parts.next() == null) words.len else null;
}
