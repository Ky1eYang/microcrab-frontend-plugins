const std = @import("std");
const max_component_bytes = 16 * 1024 * 1024;
const max_index_bytes = 1024 * 1024;
const Plugin = struct { id: []const u8, path: []const u8, default_enabled: bool, bytes: []const u8 = "", digest: []const u8 = "" };
const Destination = struct { path: []const u8, directory: std.fs.Dir, lock: std.fs.File, updated: []const u8 };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    try run(a, args);
}

fn run(a: std.mem.Allocator, args: []const []const u8) !void {
    var plugins = std.ArrayList(Plugin).init(a);
    var paths = std.ArrayList([]const u8).init(a);
    var adopt_current = false;
    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--adopt-current")) {
            adopt_current = true;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--plugin") and i + 3 < args.len) {
            const enabled = args[i + 3];
            if (!std.mem.eql(u8, enabled, "true") and !std.mem.eql(u8, enabled, "false")) return error.InvalidDefaultEnabled;
            try plugins.append(.{ .id = args[i + 1], .path = args[i + 2], .default_enabled = std.mem.eql(u8, enabled, "true") });
            i += 4;
        } else if (std.mem.eql(u8, args[i], "--destination") and i + 1 < args.len) {
            try paths.append(args[i + 1]);
            i += 2;
        } else {
            std.debug.print("Usage: install_plugins [--adopt-current] --plugin <id> <component.wasm> <true|false> ... --destination <plugins_dir> ...\n", .{});
            return error.InvalidArgs;
        }
    }
    if (plugins.items.len == 0 or plugins.items.len > 64 or paths.items.len == 0) return error.InvalidSelection;
    std.mem.sort(Plugin, plugins.items, {}, struct {
        fn less(_: void, x: Plugin, y: Plugin) bool {
            return std.mem.lessThan(u8, x.id, y.id);
        }
    }.less);
    for (plugins.items, 0..) |*plugin, n| {
        if (!validId(plugin.id)) return error.InvalidPluginIdentity;
        if (n > 0 and std.mem.eql(u8, plugins.items[n - 1].id, plugin.id)) return error.DuplicatePluginIdentity;
        plugin.bytes = try std.fs.cwd().readFileAlloc(a, plugin.path, max_component_bytes);
        try validateComponent(plugin.path, plugin.bytes);
        plugin.digest = try digestBytes(a, plugin.bytes);
    }
    for (paths.items) |*path| {
        try std.fs.cwd().makePath(path.*);
        path.* = try std.fs.cwd().realpathAlloc(a, path.*);
    }
    // Every participating installer acquires locks in canonical order, without waiting.
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var destinations = std.ArrayList(Destination).init(a);
    defer for (destinations.items) |*destination| {
        destination.lock.close();
        destination.directory.close();
    };
    for (paths.items, 0..) |path, n| {
        if (n > 0 and std.ascii.eqlIgnoreCase(paths.items[n - 1], path)) return error.DuplicateDestination;
        var directory = try std.fs.cwd().openDir(path, .{});
        errdefer directory.close();
        // Keep this file: unlinking it creates multiple lock identities.
        const lock = try directory.createFile(".microcrab-install.lock", .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        errdefer lock.close();
        const current = directory.readFileAlloc(a, "current.json", max_index_bytes) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const updated = try updateIndex(a, current, plugins.items, if (adopt_current) directory else null);
        try destinations.append(.{ .path = path, .directory = directory, .lock = lock, .updated = updated });
    }
    // Every index and selected artifact is validated before any pointer changes.
    for (destinations.items) |destination| {
        for (plugins.items) |plugin| try installImmutable(destination.directory, plugin);
    }
    var published: usize = 0;
    for (destinations.items) |destination| {
        publishIndex(destination.directory, destination.updated) catch |err| {
            std.debug.print("Index publication failed for {s}: {s}; {d}/{d} destinations already published. Atomic per destination, not across destinations.\n", .{ destination.path, @errorName(err), published, destinations.items.len });
            return err;
        };
        published += 1;
        std.debug.print("Published {d} selected plugin updates: {s}/current.json\n", .{ plugins.items.len, destination.path });
    }
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id, 0..) |c, i| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c)) continue;
        if (i > 0 and (c == '.' or c == '_' or c == '-')) continue;
        return false;
    }
    return true;
}
fn validDigest(digest: []const u8) bool {
    if (digest.len != 64) return false;
    for (digest) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn digestBytes(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn validateComponent(path: []const u8, bytes: []const u8) !void {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &.{ 0, 97, 115, 109, 13, 0, 1, 0 })) return error.ExpectedComponent;
    var child = std.process.Child.init(&.{ "wasm-tools", "validate", path }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    switch (try child.spawnAndWait()) {
        .Exited => |code| if (code != 0) return error.ComponentValidationFailed,
        else => return error.ComponentValidatorInterrupted,
    }
}
fn validateIndex(a: std.mem.Allocator, value: std.json.Value) !void {
    if (value != .object) return error.InvalidPluginIndex;
    const version = value.object.get("version") orelse return error.InvalidPluginIndex;
    if (version != .integer or version.integer != 1) return error.UnsupportedPluginIndex;
    const plugins = value.object.get("plugins") orelse return error.InvalidPluginIndex;
    if (plugins != .array or plugins.array.items.len > 64) return error.InvalidPluginCount;
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    for (plugins.array.items) |entry| {
        if (entry != .object) return error.InvalidPluginEntry;
        const id = entry.object.get("id") orelse return error.InvalidPluginEntry;
        const digest = entry.object.get("sha256") orelse return error.InvalidPluginEntry;
        const file = entry.object.get("file") orelse return error.InvalidPluginEntry;
        const enabled = entry.object.get("default_enabled") orelse return error.InvalidPluginEntry;
        if (id != .string or !validId(id.string)) return error.InvalidPluginIdentity;
        if (digest != .string or !validDigest(digest.string)) return error.InvalidPluginDigest;
        if (enabled != .bool) return error.InvalidDefaultEnabled;
        const expected = try std.fmt.allocPrint(a, "{s}/{s}/plugin.wasm", .{ id.string, digest.string });
        defer a.free(expected);
        if (file != .string or !std.mem.eql(u8, file.string, expected)) return error.InvalidPluginPath;
        if ((try seen.getOrPut(id.string)).found_existing) return error.DuplicatePluginIdentity;
        if (entry.object.get("supersedes")) |predecessors| {
            if (predecessors != .array or predecessors.array.items.len > 16) return error.InvalidPredecessors;
            for (predecessors.array.items) |hash| if (hash != .string or !validDigest(hash.string)) return error.InvalidPredecessors;
        }
    }
}
fn updateIndex(a: std.mem.Allocator, current: ?[]const u8, plugins: []const Plugin, adopt_directory: ?std.fs.Dir) ![]const u8 {
    var parsed = try std.json.parseFromSlice(@import("shared").json.UniqueValue(true), a, current orelse "{\"version\":1,\"plugins\":[]}", .{ .allocate = .alloc_always, .max_value_len = max_index_bytes });
    defer parsed.deinit();
    try validateIndex(a, parsed.value.value);
    const entries = parsed.value.value.object.getPtr("plugins").?;
    for (plugins) |plugin| {
        var selected: ?*std.json.Value = null;
        for (entries.array.items) |*entry| {
            if (std.mem.eql(u8, entry.object.get("id").?.string, plugin.id)) selected = entry;
        }
        const relative = try std.fmt.allocPrint(a, "{s}/{s}/plugin.wasm", .{ plugin.id, plugin.digest });
        if (selected) |entry| {
            const previous = entry.object.get("sha256").?.string;
            if (adopt_directory) |directory| {
                // Adoption is limited to the exact packaged pointer, never browser-local installs.
                const previous_file = entry.object.get("file").?.string;
                const bytes = try directory.readFileAlloc(a, previous_file, max_component_bytes);
                if (!std.mem.eql(u8, try digestBytes(a, bytes), previous)) return error.PredecessorDigestMismatch;
                try validateComponent(try directory.realpathAlloc(a, previous_file), bytes);
                if (!std.mem.eql(u8, previous, plugin.digest)) try adoptPredecessor(a, entry, previous);
            }
            try entry.object.put("file", .{ .string = relative });
            try entry.object.put("sha256", .{ .string = plugin.digest });
        } else {
            var entry = std.json.ObjectMap.init(a);
            try entry.put("id", .{ .string = plugin.id });
            try entry.put("file", .{ .string = relative });
            try entry.put("sha256", .{ .string = plugin.digest });
            try entry.put("default_enabled", .{ .bool = plugin.default_enabled });
            try entries.array.append(.{ .object = entry });
        }
    }
    try validateIndex(a, parsed.value.value);
    var output = std.ArrayList(u8).init(a);
    errdefer output.deinit();
    try std.json.stringify(parsed.value.value, .{ .whitespace = .indent_2 }, output.writer());
    if (output.items.len > max_index_bytes) return error.PluginIndexTooLarge;
    return output.toOwnedSlice();
}
fn adoptPredecessor(a: std.mem.Allocator, entry: *std.json.Value, digest: []const u8) !void {
    if (entry.object.getPtr("supersedes")) |predecessors| {
        for (predecessors.array.items) |hash| if (std.mem.eql(u8, hash.string, digest)) return;
        if (predecessors.array.items.len >= 16) return error.PredecessorLimitReached;
        try predecessors.array.insert(0, .{ .string = digest });
    } else {
        var predecessors = std.ArrayList(std.json.Value).init(a);
        try predecessors.append(.{ .string = digest });
        try entry.object.put("supersedes", .{ .array = predecessors });
    }
}
fn installImmutable(directory: std.fs.Dir, plugin: Plugin) !void {
    const a = std.heap.page_allocator;
    const relative = try std.fmt.allocPrint(a, "{s}/{s}/plugin.wasm", .{ plugin.id, plugin.digest });
    defer a.free(relative);
    if (directory.readFileAlloc(a, relative, max_component_bytes)) |existing| {
        defer a.free(existing);
        if (!std.mem.eql(u8, existing, plugin.bytes)) return error.ImmutableArtifactConflict;
    } else |err| switch (err) {
        error.FileNotFound => {
            var artifact = try directory.atomicFile(relative, .{ .make_path = true });
            defer artifact.deinit();
            try artifact.file.writeAll(plugin.bytes);
            try artifact.file.sync();
            try artifact.finish();
        },
        else => return err,
    }
}
fn publishIndex(directory: std.fs.Dir, updated: []const u8) !void {
    var index = try directory.atomicFile("current.json", .{});
    defer index.deinit();
    try index.file.writeAll(updated);
    try index.file.sync();
    try index.finish();
}

const test_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
test "aggregate selected updates preserve unrelated records and explicit choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try std.fmt.allocPrint(a, "{{\"version\":1,\"plugins\":[{{\"id\":\"custom\",\"file\":\"custom/{s}/plugin.wasm\",\"sha256\":\"{s}\",\"default_enabled\":false}},{{\"id\":\"microcrab.state-viewer\",\"file\":\"microcrab.state-viewer/{s}/plugin.wasm\",\"sha256\":\"{s}\",\"default_enabled\":false,\"supersedes\":[\"{s}\"]}}]}}", .{ test_digest, test_digest, test_digest, test_digest, test_digest });
    const result = try updateIndex(a, source, &.{
        .{ .id = "microcrab.state-viewer", .path = "", .default_enabled = true, .digest = test_digest },
        .{ .id = "microcrab.mcp-bridge", .path = "", .default_enabled = true, .digest = test_digest },
    }, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    const entries = parsed.value.object.get("plugins").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(!entries[0].object.get("default_enabled").?.bool);
    try std.testing.expect(!entries[1].object.get("default_enabled").?.bool);
    try std.testing.expectEqualStrings(test_digest, entries[1].object.get("supersedes").?.array.items[0].string);
    try std.testing.expect(entries[2].object.get("default_enabled").?.bool);
}
test "invalid indexes and selected overflow fail before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidPluginIndex, updateIndex(a, "[]", &.{}, null));
    try std.testing.expectError(error.DuplicateField, updateIndex(a, "{\"version\":2,\"version\":1,\"plugins\":[]}", &.{}, null));
    try std.testing.expectError(error.DuplicateField, updateIndex(a, "{\"version\":1,\"plugins\":[],\"extra\":{\"id\":1,\"\\u0069d\":2}}", &.{}, null));
    try std.testing.expectError(error.UnsupportedPluginIndex, updateIndex(a, "{\"version\":2,\"plugins\":[]}", &.{}, null));
    try std.testing.expectError(error.InvalidPluginEntry, updateIndex(a, "{\"version\":1,\"plugins\":[{\"id\":\"bad\"}]}", &.{}, null));
    var selected: [65]Plugin = undefined;
    for (&selected, 0..) |*plugin, n| plugin.* = .{ .id = try std.fmt.allocPrint(a, "plugin-{d}", .{n}), .path = "", .default_enabled = false, .digest = test_digest };
    try std.testing.expectError(error.InvalidPluginCount, updateIndex(a, null, &selected, null));
}
test "predecessors deduplicate and never silently evict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = std.json.Value{ .object = std.json.ObjectMap.init(a) };
    try adoptPredecessor(a, &entry, test_digest);
    try adoptPredecessor(a, &entry, test_digest);
    try std.testing.expectEqual(@as(usize, 1), entry.object.get("supersedes").?.array.items.len);
    for (1..16) |n| try adoptPredecessor(a, &entry, try std.fmt.allocPrint(a, "{x:0>64}", .{n}));
    try std.testing.expectError(error.PredecessorLimitReached, adoptPredecessor(a, &entry, try std.fmt.allocPrint(a, "{x:0>64}", .{@as(u32, 99)})));
}
test "Core bytes cannot enter Component installation" {
    try std.testing.expectError(error.ExpectedComponent, validateComponent("unused", &.{ 0, 97, 115, 109, 1, 0, 0, 0 }));
}
test "adoption verifies actual packaged bytes and retains their dynamic digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // Empty Component is structurally valid; production artifacts carry their selected WIT world.
    const bytes = &[_]u8{ 0, 97, 115, 109, 13, 0, 1, 0 };
    const digest = try digestBytes(a, bytes);
    const plugin = Plugin{ .id = "test.plugin", .path = "", .default_enabled = false, .bytes = bytes, .digest = digest };
    try installImmutable(temporary.dir, plugin);
    const previous = try updateIndex(a, null, &.{plugin}, null);
    const selected = Plugin{ .id = plugin.id, .path = "", .default_enabled = true, .digest = test_digest };
    const updated = try updateIndex(a, previous, &.{selected}, temporary.dir);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, updated, .{});
    const entry = parsed.value.object.get("plugins").?.array.items[0];
    try std.testing.expectEqualStrings(digest, entry.object.get("supersedes").?.array.items[0].string);
    try std.testing.expect(!entry.object.get("default_enabled").?.bool);
    const relative = try std.fmt.allocPrint(a, "{s}/{s}/plugin.wasm", .{ plugin.id, digest });
    try temporary.dir.writeFile(.{ .sub_path = relative, .data = "corrupted" });
    try std.testing.expectError(error.PredecessorDigestMismatch, updateIndex(a, previous, &.{selected}, temporary.dir));
}
test "destination lock rejects a concurrent writer" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const flags = std.fs.File.CreateFlags{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true };
    const first = try temporary.dir.createFile(".microcrab-install.lock", flags);
    defer first.close();
    try std.testing.expectError(error.WouldBlock, temporary.dir.createFile(".microcrab-install.lock", flags));
}
test "aggregate transaction preflights every destination before changing pointers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(a, ".");
    const source = try std.fs.path.join(a, &.{ root, "component.wasm" });
    const first = try std.fs.path.join(a, &.{ root, "a" });
    const second = try std.fs.path.join(a, &.{ root, "b" });
    try temporary.dir.writeFile(.{ .sub_path = "component.wasm", .data = &.{ 0, 97, 115, 109, 13, 0, 1, 0 } });
    const args = &[_][]const u8{ "installer", "--adopt-current", "--plugin", "test.one", source, "false", "--plugin", "test.two", source, "true", "--destination", second, "--destination", first };
    try run(a, args);
    const original = try temporary.dir.readFileAlloc(a, "a/current.json", max_index_bytes);
    try std.testing.expectEqualStrings(original, try temporary.dir.readFileAlloc(a, "b/current.json", max_index_bytes));
    // A changed valid Component must not advance destination a when b is malformed.
    try temporary.dir.writeFile(.{ .sub_path = "component.wasm", .data = &.{ 0, 97, 115, 109, 13, 0, 1, 0, 0, 2, 1, 'a' } });
    try temporary.dir.writeFile(.{ .sub_path = "b/current.json", .data = "[]" });
    try std.testing.expectError(error.InvalidPluginIndex, run(a, args));
    try std.testing.expectEqualStrings(original, try temporary.dir.readFileAlloc(a, "a/current.json", max_index_bytes));
    // Once repaired, both pointers advance together through the aggregate path.
    try temporary.dir.writeFile(.{ .sub_path = "b/current.json", .data = original });
    try run(a, args);
    const updated = try temporary.dir.readFileAlloc(a, "a/current.json", max_index_bytes);
    try std.testing.expect(!std.mem.eql(u8, original, updated));
    try std.testing.expectEqualStrings(updated, try temporary.dir.readFileAlloc(a, "b/current.json", max_index_bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, updated, .{});
    for (parsed.value.object.get("plugins").?.array.items) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.object.get("supersedes").?.array.items.len);
    }
}
