const std = @import("std");

const plugin_id = "microcrab.state-viewer";
const max_component_bytes = 16 * 1024 * 1024;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len != 3) {
        std.debug.print("Usage: install <component.wasm> <frontend_public_plugins_dir>\n", .{});
        return error.InvalidArgs;
    }
    const bytes = try std.fs.cwd().readFileAlloc(allocator, args[1], max_component_bytes);
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &.{ 0, 97, 115, 109, 13, 0, 1, 0 }))
        return error.ExpectedValidatedComponent;

    var hash_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash_bytes, .{});
    const hash_hex = std.fmt.bytesToHex(hash_bytes, .lower);
    var directory = try std.fs.cwd().makeOpenPath(args[2], .{});
    defer directory.close();
    // Only absence creates an index. Malformed or unreadable state is never replaced.
    const current = directory.readFileAlloc(allocator, "current.json", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const updated = try updateIndex(allocator, current, &hash_hex);
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}/plugin.wasm", .{ plugin_id, hash_hex });
    if (directory.readFileAlloc(allocator, relative, max_component_bytes)) |existing| {
        if (!std.mem.eql(u8, existing, bytes)) return error.ImmutableArtifactConflict;
    } else |err| switch (err) {
        error.FileNotFound => {
            var artifact = try directory.atomicFile(relative, .{ .make_path = true });
            defer artifact.deinit();
            try artifact.file.writeAll(bytes);
            try artifact.file.sync();
            try artifact.finish();
        },
        else => return err,
    }
    var index = try directory.atomicFile("current.json", .{});
    defer index.deinit();
    try index.file.writeAll(updated);
    try index.file.sync();
    try index.finish();
    std.debug.print("Installed {s} ABI 0.4.0: {s}\n", .{ plugin_id, hash_hex });
}

fn updateIndex(allocator: std.mem.Allocator, current: ?[]const u8, digest: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, current orelse "{\"version\":1,\"plugins\":[]}", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPluginIndex;
    const version = parsed.value.object.get("version") orelse return error.InvalidPluginIndex;
    if (version != .integer or version.integer != 1) return error.UnsupportedPluginIndex;
    const plugins = parsed.value.object.getPtr("plugins") orelse return error.InvalidPluginIndex;
    if (plugins.* != .array) return error.InvalidPluginIndex;
    var selected: ?*std.json.Value = null;
    for (plugins.array.items) |*entry| {
        if (entry.* != .object) return error.InvalidPluginEntry;
        const id = entry.object.get("id") orelse return error.InvalidPluginEntry;
        if (id != .string) return error.InvalidPluginEntry;
        if (std.mem.eql(u8, id.string, plugin_id)) {
            if (selected != null) return error.DuplicatePluginIdentity;
            selected = entry;
        }
    }
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}/plugin.wasm", .{ plugin_id, digest });
    if (selected) |entry| {
        try entry.object.put("file", .{ .string = relative });
        try entry.object.put("sha256", .{ .string = digest });
        // Preserve explicit defaults and predecessor declarations. A previously
        // staged same-ID artifact is not automatically an authorized predecessor.
    } else {
        var entry = std.json.ObjectMap.init(allocator);
        try entry.put("id", .{ .string = plugin_id });
        try entry.put("file", .{ .string = relative });
        try entry.put("sha256", .{ .string = digest });
        try entry.put("default_enabled", .{ .bool = true });
        try plugins.array.append(.{ .object = entry });
    }
    var output = std.ArrayList(u8).init(allocator);
    try std.json.stringify(parsed.value, .{ .whitespace = .indent_2 }, output.writer());
    return output.toOwnedSlice();
}

test "index installation creates missing entry and preserves unrelated exact choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const created = try updateIndex(allocator, null, digest);
    var first = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer first.deinit();
    try std.testing.expectEqualStrings(plugin_id, first.value.object.get("plugins").?.array.items[0].object.get("id").?.string);
    const source = "{\"version\":1,\"plugins\":[{\"id\":\"custom\",\"file\":\"custom.wasm\",\"sha256\":\"keep\",\"default_enabled\":false},{\"id\":\"microcrab.state-viewer\",\"file\":\"old\",\"sha256\":\"old\",\"default_enabled\":false,\"supersedes\":[\"explicit\"]}]}";
    const result = try updateIndex(allocator, source, digest);
    var next = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer next.deinit();
    const entries = next.value.object.get("plugins").?.array.items;
    try std.testing.expectEqualStrings("keep", entries[0].object.get("sha256").?.string);
    try std.testing.expect(!entries[1].object.get("default_enabled").?.bool);
    try std.testing.expectEqualStrings("explicit", entries[1].object.get("supersedes").?.array.items[0].string);
    try std.testing.expectEqualStrings(digest, entries[1].object.get("sha256").?.string);
}

test "invalid and duplicate indexes fail without replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidPluginIndex, updateIndex(allocator, "[]", "hash"));
    try std.testing.expectError(error.UnsupportedPluginIndex, updateIndex(allocator, "{\"version\":2,\"plugins\":[]}", "hash"));
    try std.testing.expectError(error.DuplicatePluginIdentity, updateIndex(allocator, "{\"version\":1,\"plugins\":[{\"id\":\"microcrab.state-viewer\"},{\"id\":\"microcrab.state-viewer\"}]}", "hash"));
}
