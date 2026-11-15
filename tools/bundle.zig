const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try std.process.argsAlloc(alloc);
    if (args.len != 5) return error.ExpectedTemplateCssJsOutput;
    const html = try std.fs.cwd().readFileAlloc(alloc, args[1], 1024 * 1024);
    const css = try std.fs.cwd().readFileAlloc(alloc, args[2], 1024 * 1024);
    const js = try std.fs.cwd().readFileAlloc(alloc, args[3], 1024 * 1024);
    const styled = try std.mem.replaceOwned(u8, alloc, html, "/* CSS will be embedded here */", css);
    const bundled = try std.mem.replaceOwned(u8, alloc, styled, "/* JS will be embedded here */", js);
    const file = try std.fs.cwd().createFile(args[4], .{});
    defer file.close();
    try file.writeAll(bundled);
}
