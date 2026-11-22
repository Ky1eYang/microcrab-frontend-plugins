const std = @import("std");

pub const message_limit = 8192;
pub const token_min = 43;
pub const token_limit = 128;
pub const receipt_limit = 1024;
pub const endpoint_limit = 460;
const path_prefix = "/api/v1/sessions/";
const bearer_placeholder = "Bearer <EXTERNAL_SPEAKER_TOKEN>";
const origin_rules = @import("origin.zig");

pub fn validEndpoint(endpoint: []const u8) bool {
    if (endpoint.len > endpoint_limit) return false;
    const at = std.mem.indexOf(u8, endpoint, path_prefix) orelse return false;
    if (!origin_rules.valid(endpoint[0..at])) return false;
    const path = endpoint[at + path_prefix.len ..];
    const suffix = "/inbox";
    return std.mem.endsWith(u8, path, suffix) and validSession(path[0 .. path.len - suffix.len]);
}

pub const Headers = struct {
    @"Content-Type": []const u8 = "application/json",
    @"Idempotency-Key": []const u8,
};
pub const Inspection = struct {
    url: []const u8,
    method: []const u8 = "POST",
    headers: struct {
        Authorization: []const u8 = bearer_placeholder,
        @"Content-Type": []const u8 = "application/json",
        @"Idempotency-Key": []const u8,
    },
    body: []const u8,
};

pub fn validSession(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |byte| if (!identifierByte(byte)) return false;
    return true;
}

pub fn validToken(token: []const u8) bool {
    if (token.len < token_min or token.len > token_limit) return false;
    for (token) |byte| if (!identifierByte(byte)) return false;
    return true;
}

pub fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

pub fn validOperation(id: []const u8) bool {
    if (id.len != 36 or id[14] != '4' or std.mem.indexOfScalar(u8, "89ab", id[19]) == null) return false;
    for (id, 0..) |byte, offset| {
        switch (offset) {
            8, 13, 18, 23 => if (byte != '-') return false,
            else => if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false,
        }
    }
    return true;
}

pub fn validMessage(message: []const u8) bool {
    if (message.len == 0 or message.len > message_limit) return false;
    const view = std.unicode.Utf8View.init(message) catch return false;
    var it = view.iterator();
    // At most one codepoint per byte, and the input was validated above.
    for (0..message.len) |_| {
        const c = it.nextCodepoint() orelse return false;
        switch (c) { // Rust str::trim's Unicode White_Space property.
            0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => {},
            else => return true,
        }
    }
    return false;
}

pub const Request = struct {
    url: []const u8,
    operation: []const u8,
    body: []const u8,
    external: bool = false,

    pub fn forEndpoint(a: std.mem.Allocator, endpoint: []const u8, operation: []const u8, message: []const u8) !Request {
        if (!validEndpoint(endpoint)) return error.InvalidEndpoint;
        if (!validOperation(operation)) return error.InvalidOperation;
        if (!validMessage(message)) return error.InvalidMessage;
        return .{
            .url = try a.dupe(u8, endpoint),
            .operation = operation,
            .body = try std.json.stringifyAlloc(a, .{ .body = message }, .{}),
            .external = true,
        };
    }

    pub fn inspection(self: Request) Inspection {
        return .{ .url = self.url, .headers = .{
            .@"Idempotency-Key" = self.operation,
        }, .body = self.body };
    }

    pub fn prepare(a: std.mem.Allocator, origin: []const u8, session: []const u8, operation: []const u8, message: []const u8) !Request {
        if (!origin_rules.valid(origin)) return error.InvalidEndpoint;
        if (!validSession(session)) return error.InvalidSession;
        var url_buffer: [endpoint_limit]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}" ++ path_prefix ++ "{s}/inbox", .{ origin, session });
        var prepared = try forEndpoint(a, url, operation, message);
        prepared.external = false;
        return prepared;
    }

    /// The Host owns Authorization; it verifies this URL and configuration pin.
    pub fn json(self: Request, a: std.mem.Allocator, grant_id: []const u8, pin: []const u8) ![]u8 {
        return std.json.stringifyAlloc(a, .{
            .resource = grant_id,
            .config_pin = pin,
            .url = self.url,
            .method = "POST",
            .headers = Headers{ .@"Idempotency-Key" = self.operation },
            .body = self.body,
        }, .{});
    }

    pub fn subscribe(a: std.mem.Allocator, url: []const u8, grant_id: []const u8, pin: []const u8, id: []const u8) ![]u8 {
        return std.json.stringifyAlloc(a, .{
            .resource = grant_id,
            .config_pin = pin,
            .url = url,
            .method = "GET",
            .response_mode = "sse",
            .headers = .{ .Accept = "text/event-stream", .@"X-MicroCrab-Dialogue-Id" = id },
        }, .{});
    }

    pub fn preview(self: Request, a: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(a);
        errdefer output.deinit();
        const writer = output.writer();
        // -q must be first: ignore curlrc, which can enable redirects, cookies, etc.
        try writer.writeAll("curl -q --proto '=https,http' --globoff --request POST --header '" ++ "Authorization: " ++ bearer_placeholder ++ "' --header 'Content-Type: application/json' --header 'Idempotency-Key: ");
        try writer.writeAll(self.operation);
        try writer.writeAll("' --data-binary ");
        try shellQuote(writer, self.body);
        try writer.writeAll(" --url ");
        try shellQuote(writer, self.url);
        return output.toOwnedSlice();
    }
};

fn shellQuote(writer: anytype, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') try writer.writeAll("'\\''") else try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

const JsonNumber = struct {
    value: []const u8,
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !JsonNumber {
        return switch (try source.nextAllocMax(a, .alloc_if_needed, options.max_value_len.?)) {
            .number, .allocated_number => |value| .{ .value = value },
            else => error.UnexpectedToken,
        };
    }
};

pub const Receipt = struct {
    status: enum { queued, consumed },
    ordinal: u64,
    dialogue_id: ?[8]u8,
};

pub fn validDialogueId(id: []const u8) bool {
    if (id.len != 8) return false;
    for (id) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

pub fn receipt(a: std.mem.Allocator, status: u16, operation: []const u8, body: []const u8) !Receipt {
    if ((status != 200 and status != 202) or body.len > receipt_limit) return error.InvalidReceipt;
    const Wire = struct {
        operation_id: []const u8,
        ordinal: JsonNumber,
        status: []const u8,
        dialogue_id: ?[]const u8 = null,
    };
    const decoded = try std.json.parseFromSlice(Wire, a, body, .{});
    defer decoded.deinit();
    const value = decoded.value;
    if (!std.mem.eql(u8, operation, value.operation_id)) return error.InvalidReceipt;
    const expected = if (status == 202) "queued" else "consumed";
    if (!std.mem.eql(u8, expected, value.status)) return error.InvalidReceipt;
    const digits = value.ordinal.value;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidReceipt;
    const ordinal = try std.fmt.parseInt(u64, digits, 10);
    if (ordinal == 0) return error.InvalidReceipt;
    const dialogue = if (value.dialogue_id) |id| blk: {
        if (!validDialogueId(id)) return error.InvalidReceipt;
        break :blk id[0..8].*;
    } else null;
    return .{ .ordinal = ordinal, .status = if (status == 202) .queued else .consumed, .dialogue_id = dialogue };
}
