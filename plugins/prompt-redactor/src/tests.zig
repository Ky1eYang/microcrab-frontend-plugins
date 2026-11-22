const std = @import("std");
const scanner = @import("scanner.zig");

fn expectScan(input: []const u8, expected: []const u8, count: usize) !void {
    var buffer: [scanner.max_output_bytes]u8 = undefined;
    const result = try scanner.scan(input, &buffer);
    try std.testing.expectEqualStrings(expected, result.text);
    try std.testing.expectEqual(count, result.count);
}

test "synthetic key families and their exact span boundaries" {
    try expectScan(
        "API=sk-AbCdEfGhIjKlMnOpQrSt; sk-proj-AbCdEfGhIjKlMnOpQrSt sk-ant-AbCdEfGhIjKlMnOpQrSt " ++
            "ghp_abcdefghijklmnopqrstuvwxyz1234567890 github_pat_abcdefghijklmnopqrstuv " ++
            "(AKIAEXAMPLEDEMO00000) ASIAEXAMPLEDEMO00000!",
        "API=[REDACTED]; [REDACTED] [REDACTED] [REDACTED] [REDACTED] ([REDACTED]) [REDACTED]!",
        7,
    );
    const misses = "xsk-AbCdEfGhIjKlMnOpQrSt SK-AbCdEfGhIjKlMnOpQrSt sk-ant-AbCdEfGhIjKlMnOp ghp_short AKIAEXAMPLEDEMO00000A AKIAexampledemo00000";
    try expectScan(misses, misses, 0);
}

test "Bearer header, JWT shape, and inclusive URI precedence" {
    try expectScan(
        "Authorization: bEaReR\t DEMO-token/+=\r\neyJDEMO1.e30A.SYNTHETIC! TOKEN=\"PostgreSQL://a:s@m.invalid/db?q=demo#frag\"",
        "Authorization: bEaReR\t [REDACTED]\r\n[REDACTED]! TOKEN=\"[REDACTED]\"",
        3,
    );
    try expectScan("Bearer mongodb+srv://demo.invalid/x redis://localhost:6379", "Bearer [REDACTED] [REDACTED]", 2);
    const misses = "Bearer abc eyJDEMO1.e30A.SYNTHETIC.more.parts eyJshort.a.b https://demo.invalid/";
    try expectScan(misses, misses, 0);
}

test "complete and incomplete private-key blocks" {
    try expectScan(
        "before\n-----BEGIN OPENSSH PRIVATE KEY-----\r\nnot-a-real-key\r\n-----END OPENSSH PRIVATE KEY-----\nafter\n" ++
            "-----BEGIN PRIVATE KEY-----\nnot-real\n-----END OTHER PRIVATE KEY-----\ntruncated",
        "before\n[REDACTED]\nafter\n[REDACTED]",
        2,
    );
    const public = "-----BEGIN PUBLIC KEY-----\nexample\n-----END PUBLIC KEY-----";
    try expectScan(public, public, 0);
}

test "email subset and unchanged Unicode and markup" {
    try expectScan(
        "你好 <b>one+demo@sample.invalid</b> Two.Test@demo.example. sk-AbCdEfGhIjKlMnOpQrSt@demo.invalid",
        "你好 <b>[REDACTED]</b> [REDACTED]. [REDACTED]",
        3,
    );
    const unsupported = "二tester@sample.invalid user@local user@sample.二 no..match@example.invalid +1 202 555 0112";
    try expectScan(unsupported, unsupported, 0);
}

test "hard limits, UTF-8 validation and max input without truncation" {
    var buffer: [scanner.max_output_bytes]u8 = undefined;
    const oversized = "a" ** (scanner.max_input_bytes + 1);
    try std.testing.expectError(error.InputTooLarge, scanner.scan(oversized, &buffer));
    try std.testing.expectError(error.InvalidUtf8, scanner.scan(&.{ 0xc0, 0x80 }, &buffer));
    try expectScan(oversized[1..], oversized[1..], 0);
    try expectScan("", "", 0);
    try expectScan("a@b.cd " ** 1170, "[REDACTED] " ** 1170, 1170);
}

test "a literal repeat of a recognized Bearer value fails closed" {
    var buffer: [scanner.max_output_bytes]u8 = undefined;
    try std.testing.expectError(error.ResidualMatch, scanner.scan("Bearer DEMO-token/+= then DEMO-token/+=", &buffer));
    try expectScan("Bearer DEMO-token/+= then Bearer DEMO-token/+=", "Bearer [REDACTED] then Bearer [REDACTED]", 2);
}

const preview = @import("preview.zig");
const nonce = "0123456789abcdef0123456789abcdef";
const mount: preview.Context = .{
    .schema_version = 1,
    .session_id = "synthetic-session",
    .instance_generation = 7,
    .history_generation = 9,
    .surface_generation = 12,
    .target_visible = true,
    .surface = .{ .surface_id = "test-sidebar", .target = "sidebar" },
    .user_action = true,
    .host_monotonic_ms = 1000,
};

test "pending preview allows only the exact visible mount and expires" {
    var pending: preview.Pending = .{};
    const request: preview.Request = .{ .id = nonce, .text = "contact demo@example.invalid" };
    var other = mount;
    other.user_action = false;
    try std.testing.expect(!pending.prepare(other, request));
    try std.testing.expect(pending.prepare(mount, request));
    try std.testing.expect(!pending.prepare(mount, .{ .id = "invalid", .text = request.text }));
    try std.testing.expect(pending.get(mount, .expanded_page) == null);
    other.surface.surface_id = "different-sidebar";
    try std.testing.expect(pending.get(other, .sidebar) == null);
    other = mount;
    other.surface_generation += 1;
    try std.testing.expect(pending.get(other, .sidebar) == null);
    other = mount;
    other.target_visible = false;
    try std.testing.expect(pending.get(other, .sidebar) == null);
    other = mount;
    other.session_id = null;
    try std.testing.expect(pending.get(other, .sidebar) == null);
    other = mount;
    other.history_generation += 1;
    try std.testing.expect(pending.get(other, .sidebar) == null);
    const view = pending.get(mount, .sidebar) orelse return error.ExpectedPreview;
    try std.testing.expectEqualStrings(nonce, view.id);
    try std.testing.expectEqualStrings("contact [REDACTED]", view.text.?);
    other = mount;
    other.host_monotonic_ms += preview.ttl_ms;
    try std.testing.expect(pending.get(other, .sidebar) == null);
    try std.testing.expect(pending.entry == null);
}

test "zero-match and invalid previews never expose original text" {
    var pending: preview.Pending = .{};
    try std.testing.expect(pending.prepare(mount, .{ .id = nonce, .text = "no supported pattern" }));
    const unmatched = pending.get(mount, .sidebar).?;
    try std.testing.expect(unmatched.status == .no_matches and unmatched.text == null and unmatched.count == 0);
    try std.testing.expect(pending.prepare(mount, .{ .id = nonce, .text = "a" ** (scanner.max_input_bytes + 1) }));
    const rejected = pending.get(mount, .sidebar).?;
    try std.testing.expect(rejected.status == .rejected and rejected.text == null);
    pending.clear();
    try std.testing.expect(pending.get(mount, .sidebar) == null);
}
