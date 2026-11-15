const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: install <component.wasm> <frontend_public_plugins_dir>\n", .{});
        return error.InvalidArgs;
    }

    const component_path = args[1];
    const plugins_dir = args[2];

    const bytes = try std.fs.cwd().readFileAlloc(allocator, component_path, 32 * 1024 * 1024);
    defer allocator.free(bytes);

    var sha256 = std.crypto.hash.sha2.Sha256.init(.{});
    sha256.update(bytes);
    var hash_bytes: [32]u8 = undefined;
    sha256.final(&hash_bytes);
    const hash_hex = std.fmt.bytesToHex(hash_bytes, .lower);

    // plugins/microcrab.state-viewer/<hash>/plugin.wasm
    var target_dir_buf: [512]u8 = undefined;
    const target_dir = try std.fmt.bufPrint(&target_dir_buf, "{s}/microcrab.state-viewer/{s}", .{ plugins_dir, hash_hex });

    try std.fs.cwd().makePath(target_dir);

    var target_file_buf: [512]u8 = undefined;
    const target_file = try std.fmt.bufPrint(&target_file_buf, "{s}/plugin.wasm", .{target_dir});

    try std.fs.cwd().writeFile(.{ .sub_path = target_file, .data = bytes });
    std.debug.print("Installed plugin: {s}\n", .{target_file});
    std.debug.print("SHA-256: {s}\n", .{hash_hex});

    // Update current.json
    var current_json_path_buf: [512]u8 = undefined;
    const current_json_path = try std.fmt.bufPrint(&current_json_path_buf, "{s}/current.json", .{plugins_dir});

    const current_json_bytes = std.fs.cwd().readFileAlloc(allocator, current_json_path, 1024 * 1024) catch null;
    defer if (current_json_bytes) |b| allocator.free(b);

    if (current_json_bytes) |json_text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.getPtr("plugins")) |plugins_val| {
                if (plugins_val.* == .array) {
                    for (plugins_val.array.items) |*item| {
                        if (item.* == .object) {
                            if (item.object.get("id")) |id_val| {
                                if (id_val == .string and std.mem.eql(u8, id_val.string, "microcrab.state-viewer")) {
                                    var file_path_buf: [256]u8 = undefined;
                                    const file_rel = try std.fmt.bufPrint(&file_path_buf, "microcrab.state-viewer/{s}/plugin.wasm", .{hash_hex});
                                    try item.object.put("file", .{ .string = try allocator.dupe(u8, file_rel) });
                                    try item.object.put("sha256", .{ .string = try allocator.dupe(u8, &hash_hex) });
                                }
                            }
                        }
                    }
                }
            }
        }

        var out_list = std.ArrayList(u8).init(allocator);
        defer out_list.deinit();
        try std.json.stringify(parsed.value, .{ .whitespace = .indent_2 }, out_list.writer());
        try std.fs.cwd().writeFile(.{ .sub_path = current_json_path, .data = out_list.items });
        std.debug.print("Updated current.json pointer\n", .{});
    }
}
