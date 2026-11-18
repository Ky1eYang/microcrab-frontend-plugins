const std = @import("std");
const j = @import("json.zig");
const c = @import("config.zig");
const providers = @import("providers.zig");
const language = @import("language.zig");
pub fn Runtime(comptime Host: type) type {
    return struct {
        const Self = @This();
        const A = std.mem.Allocator;
        pub const max_entries = 128;
        pub const concurrency = 4;
        pub const retained_limit = 256 * 1024;
        fn retainedBytes(self: *Self) usize {
            var n: usize = 0;
            for (self.entries.items) |e| n += e.text.len + e.translation.len + e.id.len + e.history.len + e.role.len;
            return n;
        }
        const Status = enum { vacant, queued, pending, completed, skipped, err, cancelled };
        const Entry = struct { revision: u64 = 0, signature: [32]u8 = undefined, force: bool = false, reason: ?language.Reason = null, blocked: bool = false, age: u64 = 0, id: []const u8 = "", history: []const u8 = "", text: []const u8 = "", role: []const u8 = "", status: Status = .queued, translation: []const u8 = "", failure: []const u8 = "", failure_detail: [512]u8 = undefined, failure_len: usize = 0, duration: f64 = 0, generation: u64 = 0, fresh: bool = true };
        const Task = struct { id: u32, index: usize, generation: u64, revision: u64 = 0, started: f64, timeout_ms: f64, provider: c.Provider };
        fn httpTimeout(ctx: j.Value) f64 {
            const timeout = j.number(j.get(ctx, "host_http_timeout_ms")) orelse return 10000;
            if (!std.math.isFinite(timeout) or timeout < 10000 or timeout > 300000 or @floor(timeout) != timeout) return 10000;
            return timeout;
        }
        a: A,
        config: c.Config,
        entries: std.ArrayList(Entry),
        tasks: [concurrency]?Task = .{null} ** concurrency,
        session: []const u8 = "",
        owner: []const u8 = "",
        server: []const u8 = "",
        history: u64 = 0,
        instance: u64 = 0,
        generation: u64 = 1,
        resources: []const u8 = "[]",
        resource_request: ?u32 = null,
        save_request: ?u32 = null,
        storage_request: ?u32 = null,
        staged_config: ?c.Config = null,
        save_generation: u64 = 0,
        save_started: f64 = 0,
        save_operation: []const u8 = "",
        save_status: []const u8 = "applied",
        saved: bool = true,
        status: []const u8 = "Ready",
        translated: u64 = 0,
        total_ms: f64 = 0,
        test_duration_ms: f64 = 0,
        test_status: []const u8 = "idle",
        test_failure_detail: [128]u8 = undefined,
        age: u64 = 0,
        removed: [max_entries]struct { id: [256]u8 = undefined, len: usize = 0, assistant: bool = true } = undefined,
        removed_count: usize = 0,
        fn nextAge(self: *Self) u64 {
            self.age +|= 1;
            return self.age;
        }
        fn clearRemovals(self: *Self) void {
            self.removed_count = 0;
        }
        fn oldestTerminal(self: *Self, exclude: ?usize) ?usize {
            var found: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (exclude == i or e.status == .vacant or e.status == .queued or e.status == .pending) continue;
                if (found == null or e.age < self.entries.items[found.?].age) found = i;
            }
            return found;
        }
        fn evict(self: *Self, index: usize) !void {
            const e = &self.entries.items[index];
            if (!e.fresh) {
                if (self.removed_count >= max_entries) return error.DecorationRemovalBudgetExceeded;
                @memcpy(self.removed[self.removed_count].id[0..e.id.len], e.id);
                self.removed[self.removed_count].len = e.id.len;
                self.removed[self.removed_count].assistant = std.mem.eql(u8, e.role, "assistant");
                self.removed_count += 1;
            }
            self.freeEntry(e.*);
            e.* = .{ .status = .vacant, .fresh = false };
        }
        fn room(self: *Self, bytes: usize, exclude: ?usize) !bool {
            const replacing = if (exclude) |i| blk: {
                const e = self.entries.items[i];
                break :blk e.text.len + e.translation.len + e.id.len + e.history.len + e.role.len;
            } else 0;
            while (self.retainedBytes() - replacing + bytes > retained_limit) {
                const victim = self.oldestTerminal(exclude) orelse {
                    self.status = "Retained content limit is 256 KiB; pending translations cannot be evicted";
                    return false;
                };
                try self.evict(victim);
            }
            return true;
        }
        fn destination(self: *Self, bytes: usize) !?usize {
            if (!try self.room(bytes, null)) return null;
            for (self.entries.items, 0..) |e, i| {
                if (e.status == .vacant) return i;
            }
            if (self.entries.items.len < max_entries) return self.entries.items.len;
            const victim = self.oldestTerminal(null) orelse {
                self.status = "All 128 cache entries are active; wait for completion before retrying settlement";
                return null;
            };
            try self.evict(victim);
            return victim;
        }
        fn reap(self: *Self, ctx: j.Value) void {
            const now = j.number(j.get(ctx, "host_monotonic_ms")) orelse return;
            if (!std.math.isFinite(now)) return;
            // Each HTTP request keeps its dispatch-time Host deadline plus5s receipt grace.
            for (&self.tasks) |*slot| {
                if (slot.*) |task| {
                    if (now - task.started < task.timeout_ms + 5000) continue;
                    slot.* = null;
                    if (task.generation != self.generation) continue;
                    if (task.index == max_entries) {
                        self.test_status = "error";
                        self.status = "Connection test receipt expired";
                    } else if (task.index < self.entries.items.len) {
                        const e = &self.entries.items[task.index];
                        if (e.status == .pending and e.generation == task.generation and e.revision == task.revision) {
                            e.status = .err;
                            e.failure = "Network receipt expired or its surface was retired";
                        }
                    }
                }
            }
            if ((self.save_request != null or self.storage_request != null) and now - self.save_started >= 15000) {
                self.save_request = null;
                self.storage_request = null;
                if (self.staged_config) |conf| conf.deinit(self.a);
                self.staged_config = null;
                self.save_status = "unknown";
                self.saved = false;
                self.status = "Save receipt expired; stored outcome is unknown. Reload to inspect; do not resubmit.";
            }
        }
        pub fn init(a: A) !Self {
            const config = try (c.Config{}).owned(a);
            errdefer config.deinit(a);
            var entries = std.ArrayList(Entry).init(a);
            errdefer entries.deinit();
            try entries.ensureTotalCapacity(max_entries);
            return .{ .a = a, .config = config, .entries = entries };
        }
        fn freeEntry(self: *Self, e: Entry) void {
            self.a.free(e.id);
            self.a.free(e.history);
            self.a.free(e.text);
            self.a.free(e.role);
            if (e.translation.len > 0) self.a.free(e.translation);
        }
        pub fn deinit(self: *Self) void {
            self.clearRemovals();
            for (self.entries.items) |e| self.freeEntry(e);
            self.entries.deinit();
            self.config.deinit(self.a);
            if (self.staged_config) |conf| conf.deinit(self.a);
            inline for (.{ "session", "owner", "server", "save_operation" }) |f| {
                const value = @field(self, f);
                if (value.len > 0) self.a.free(value);
            }
            if (!std.mem.eql(u8, self.resources, "[]")) self.a.free(self.resources);
        }
        fn active(self: *Self) usize {
            var n: usize = 0;
            for (self.tasks) |task| {
                if (task != null) n += 1;
            }
            return n;
        }
        fn replace(self: *Self, dest: *[]const u8, value: []const u8) !void {
            const next = try self.a.dupe(u8, value);
            if (dest.len > 0) self.a.free(dest.*);
            dest.* = next;
        }
        pub fn context(self: *Self, ctx: j.Value) !void {
            const session = j.text(j.get(ctx, "session_id")) orelse "";
            const owner = j.text(j.get(ctx, "owner_id")) orelse "";
            const server = j.text(j.get(ctx, "server_origin")) orelse "";
            const history = j.uint(j.get(ctx, "history_generation")) orelse 0;
            const instance = j.uint(j.get(ctx, "instance_generation")) orelse 0;
            if (session.len > 256 or owner.len > 256 or server.len > 2048) return error.ContextIdentityLengthLimit;
            if (!std.mem.eql(u8, session, self.session) or !std.mem.eql(u8, owner, self.owner) or !std.mem.eql(u8, server, self.server) or history != self.history or instance != self.instance) {
                self.generation += 1;
                // Host aborts and suppresses receipts from retired Session/history scopes.
                self.tasks = .{null} ** concurrency;
                self.clearRemovals();
                if (self.staged_config != null) self.save_status = "unknown";
                self.test_status = "idle";
                for (self.entries.items) |e| self.freeEntry(e);
                self.entries.clearRetainingCapacity();
                if (self.save_request != null or self.storage_request != null) {
                    self.save_status = "unknown";
                    self.status = "Save scope retired; inspect persisted configuration before saving again";
                }
                self.translated = 0;
                self.total_ms = 0;
                try self.replace(&self.session, session);
                try self.replace(&self.owner, owner);
                try self.replace(&self.server, server);
                self.history = history;
                self.instance = instance;
                if (self.staged_config) |conf| conf.deinit(self.a);
                self.staged_config = null;
                self.save_request = null;
                self.storage_request = null;
                self.resource_request = null;
                self.saved = true;
            }
            self.reap(ctx);
        }
        pub fn initialize(self: *Self, a: A, ctx: j.Value) !void {
            try self.context(ctx);
            if (Host.storage.read("config")) |raw| {
                defer self.a.free(raw);
                const value = j.parse(a, raw) catch {
                    self.status = "Stored configuration JSON is invalid";
                    return;
                };
                const conf = c.Config.parse(value) catch {
                    self.status = "Stored configuration fields are invalid";
                    return;
                };
                const owned = try conf.owned(self.a);
                self.config.deinit(self.a);
                self.config = owned;
            }
            switch (Host.resources.send("resource-list", "{}")) {
                .ok => |id| self.resource_request = id,
                .err => |message| {
                    defer self.a.free(message);
                    self.status = "Resource inventory unavailable";
                },
            }
            // Preserve the actual conversation capability import.
            switch (Host.conversation.send("block-slots", "{\"slots\":[]}")) {
                .ok => {},
                .err => |message| {
                    self.a.free(message);
                    self.status = "Conversation capability unavailable";
                },
            }
        }
        fn invalidate(self: *Self, queue: bool) void {
            self.test_status = "idle";
            self.test_duration_ms = 0;
            self.generation += 1;
            for (self.entries.items) |*e| {
                if (e.status == .vacant) continue;
                if (e.translation.len > 0) self.a.free(e.translation);
                e.translation = "";
                e.failure = "";
                e.force = false;
                e.reason = null;
                e.failure_len = 0;
                e.duration = 0;
                e.generation = self.generation;
                e.status = if (queue and e.text.len > 0 and (!self.config.assistant_only or std.mem.eql(u8, e.role, "assistant"))) .queued else .cancelled;
            }
        }
        fn resource(self: *Self, a: A) !?j.Value {
            const listed = try j.parse(a, self.resources);
            if (listed != .array) return null;
            for (listed.array.items) |r| {
                if (j.is(j.get(r, "id"), @tagName(self.config.provider)) and j.truth(j.get(r, "enabled"))) return r;
            }
            return null;
        }
        pub fn pump(self: *Self, a: A, ctx: j.Value) !void {
            if (self.session.len == 0 or self.staged_config != null) return;
            if (self.resource_request != null and (self.config.provider == .siliconflow or self.config.provider == .custom)) return;
            for (self.entries.items, 0..) |*e, index| {
                if (e.status != .queued) continue;
                if (!e.force) {
                    if (language.decision(self.config, e.text)) |reason| {
                        e.status = .skipped;
                        e.reason = reason;
                        continue;
                    }
                }
                if (self.active() >= concurrency) continue;
                e.force = false;
                const r = try self.resource(a);
                const payload = providers.build(a, self.config, e.text, if (r) |v| j.text(j.get(v, "id")) else null, if (r) |v| j.text(j.get(v, "config_pin")) else null) catch |err| {
                    e.status = .err;
                    e.failure = @errorName(err);
                    continue;
                };
                const raw = try j.stringify(a, payload);
                switch (Host.net.send("http", raw)) {
                    .err => |message| {
                        defer self.a.free(message);
                        e.status = .err;
                        e.failure = "Host rejected network request";
                    },
                    .ok => |id| {
                        for (&self.tasks) |*slot| {
                            if (slot.* == null) {
                                slot.* = .{ .id = id, .index = index, .generation = self.generation, .revision = e.revision, .started = j.number(j.get(ctx, "host_monotonic_ms")) orelse 0, .timeout_ms = httpTimeout(ctx), .provider = self.config.provider };
                                break;
                            }
                        }
                        e.status = .pending;
                        e.generation = self.generation;
                    },
                }
            }
        }
        fn newEntry(self: *Self, b: j.Value, id: []const u8, history: []const u8, text: []const u8, role: []const u8) !Entry {
            var exclude: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.id, id)) exclude = i;
            }
            while (true) {
                return self.entryOnce(b, id, history, text, role) catch |err| {
                    if (err != error.OutOfMemory) return err;
                    const victim = self.oldestTerminal(exclude) orelse return err;
                    try self.evict(victim);
                    continue;
                };
            }
        }
        fn sourceSignature(b: j.Value, text: []const u8) ![32]u8 {
            var signature: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(text, &signature, .{});
            const value = j.get(b, "source_digest");
            if (value != .null) {
                const digest = j.text(value) orelse return error.InvalidSourceDigest;
                if (digest.len != 64) return error.InvalidSourceDigest;
                for (digest) |ch| if (!(ch >= '0' and ch <= '9') and !(ch >= 'a' and ch <= 'f')) return error.InvalidSourceDigest;
                // Use the canonical settled witness when the Host supplies it.
                _ = std.fmt.hexToBytes(&signature, digest) catch return error.InvalidSourceDigest;
            }
            return signature;
        }
        fn entryOnce(self: *Self, b: j.Value, id: []const u8, history: []const u8, text: []const u8, role: []const u8) !Entry {
            const signature = try sourceSignature(b, text);
            const id_owned = try self.a.dupe(u8, id);
            errdefer self.a.free(id_owned);
            const revision = try self.a.dupe(u8, history);
            errdefer self.a.free(revision);
            const source = try self.a.dupe(u8, if (text.len <= providers.input_limit and !j.truth(j.get(b, "text_truncated"))) text else "");
            errdefer self.a.free(source);
            const role_owned = try self.a.dupe(u8, role);
            const revision_id = self.nextAge();
            var e = Entry{ .revision = revision_id, .age = revision_id, .blocked = j.truth(j.get(b, "text_truncated")), .signature = signature, .id = id_owned, .history = revision, .text = source, .role = role_owned, .generation = self.generation };
            if (j.truth(j.get(b, "text_truncated"))) {
                e.status = .err;
                e.failure = "Host text was truncated; translation refused";
                self.status = "Original text truncated by host; translation unavailable";
            } else if (text.len > providers.input_limit) {
                e.status = .err;
                e.failure = "Translation input exceeds 16 KiB";
            } else if (!self.config.auto_translate) e.status = .cancelled;
            return e;
        }
        fn blocks(self: *Self, a: A, payload: j.Value) !void {
            const blocks_value = j.get(payload, "blocks");
            if (blocks_value != .array) return error.SettledBlocksArrayRequired;
            if (blocks_value.array.items.len > 512) return error.SettledBatchExceeds512Blocks;
            for (blocks_value.array.items) |b| {
                if (!j.is(j.get(b, "kind"), "text")) continue;
                const role = j.text(j.get(b, "role")) orelse continue;
                if (!std.mem.eql(u8, role, "assistant") and (self.config.assistant_only or !std.mem.eql(u8, role, "user"))) continue;
                // Host settled payloads omit stream; an explicit non-complete value is rejected.
                const stream = j.get(b, "stream");
                if (stream != .null and !j.is(stream, "complete")) continue;
                const id = j.text(j.get(b, "block_id")) orelse return error.BlockIdentityRequired;
                const history = j.text(j.get(b, "history_revision")) orelse return error.HistoryRevisionRequired;
                const text = j.text(j.get(b, "text")) orelse continue;
                if (id.len == 0 or id.len > 256 or history.len > 256) return error.BlockIdentityLengthLimit;
                var found: ?usize = null;
                for (self.entries.items, 0..) |e, i| {
                    if (std.mem.eql(u8, e.id, id)) {
                        found = i;
                        break;
                    }
                }
                const needed = id.len + history.len + role.len + (if (text.len <= providers.input_limit and !j.truth(j.get(b, "text_truncated"))) text.len else 0);
                if (found) |i| {
                    const e = &self.entries.items[i];
                    const signature = try sourceSignature(b, text);
                    if (std.mem.eql(u8, e.history, history) and std.mem.eql(u8, e.role, role) and std.mem.eql(u8, &e.signature, &signature) and e.blocked == j.truth(j.get(b, "text_truncated"))) {
                        e.age = self.nextAge();
                        continue;
                    }
                    if (!try self.room(needed, i)) continue;
                    // Old HTTP capacity remains occupied until its receipt or captured deadline.
                    var replacement = try self.newEntry(b, id, history, text, role);
                    replacement.fresh = e.fresh;
                    self.freeEntry(e.*);
                    e.* = replacement;
                    continue;
                }
                const index = (try self.destination(needed)) orelse continue;
                const e = try self.newEntry(b, id, history, text, role);
                if (index < self.entries.items.len) self.entries.items[index] = e else self.entries.append(e) catch |err| {
                    self.freeEntry(e);
                    return err;
                };
            }
            _ = a;
        }
        pub fn phase(self: *Self, a: A, name: []const u8, payload: j.Value, ctx: j.Value) !void {
            try self.context(ctx);
            if (std.mem.eql(u8, name, "history-reset")) {
                self.generation += 1;
                // Host aborts and suppresses receipts from retired Session/history scopes.
                self.tasks = .{null} ** concurrency;
                self.clearRemovals();
                if (self.staged_config != null) self.save_status = "unknown";
                self.test_status = "idle";
                for (self.entries.items) |e| self.freeEntry(e);
                self.entries.clearRetainingCapacity();
                if (self.save_request != null or self.storage_request != null) {
                    self.save_status = "unknown";
                    self.status = "Save scope retired; inspect persisted configuration before saving again";
                }
                self.translated = 0;
                self.total_ms = 0;
            }
            if (std.mem.eql(u8, name, "settled-blocks")) try self.blocks(a, payload);
            if (std.mem.eql(u8, name, "event-result")) try self.completion(a, payload, ctx);
            try self.pump(a, ctx);
        }
        fn inventory(self: *Self, a: A, value: j.Value) !void {
            if (value != .array or value.array.items.len > 32) return error.InvalidResourceInventory;
            const raw = if (value.array.items.len == 0) "[]" else try j.stringify(self.a, value);
            if (!std.mem.eql(u8, self.resources, "[]")) self.a.free(self.resources);
            self.resources = raw;
            _ = a;
        }
        fn persist(self: *Self, a: A) !void {
            const conf = self.staged_config orelse return;
            const raw = try j.stringify(a, try conf.value(a));
            switch (Host.storage.write("config", raw)) {
                .ok => |id| {
                    self.storage_request = id;
                    self.status = "Saving preferences";
                },
                .err => |message| {
                    defer self.a.free(message);
                    self.status = "Preference storage rejected Save";
                    self.save_status = "failed";
                    self.saved = false;
                    if (self.staged_config) |v| v.deinit(self.a);
                    self.staged_config = null;
                },
            }
        }
        fn retainTranslation(self: *Self, text: []const u8) ![]const u8 {
            while (true) {
                return self.a.dupe(u8, text) catch |err| {
                    const victim = self.oldestTerminal(null) orelse return err;
                    try self.evict(victim);
                    continue;
                };
            }
        }
        fn completion(self: *Self, a: A, payload: j.Value, ctx: j.Value) !void {
            const id64 = j.uint(j.get(payload, "request_id")) orelse return;
            if (id64 > std.math.maxInt(u32)) return;
            const id: @TypeOf(@as(u32, 0)) = @intCast(id64);
            const ok = j.truth(j.get(payload, "ok"));
            const value = j.get(payload, "value");
            if (self.resource_request == id) {
                self.resource_request = null;
                if (ok) try self.inventory(a, value) else self.status = "Resource inventory failed";
            }
            if (self.save_request == id) {
                self.save_request = null;
                if (ok and self.save_generation == self.generation) {
                    try self.inventory(a, value);
                    self.save_started = j.number(j.get(ctx, "host_monotonic_ms")) orelse self.save_started;
                    try self.persist(a);
                } else {
                    self.status = "Resource Save failed or expired";
                    self.save_status = "failed";
                    self.saved = false;
                    if (self.staged_config) |v| v.deinit(self.a);
                    self.staged_config = null;
                }
            }
            if (self.storage_request == id) {
                self.storage_request = null;
                if (ok and j.truth(j.get(value, "ack")) and self.save_generation == self.generation) {
                    if (self.staged_config) |conf| {
                        self.config.deinit(self.a);
                        self.config = conf;
                        self.staged_config = null;
                        self.saved = true;
                        self.status = "Saved";
                        self.save_status = "applied";
                        self.invalidate(self.config.auto_translate);
                    }
                } else {
                    self.save_status = "unknown";
                    self.status = "Preference Save failed or expired";
                    self.saved = false;
                    if (self.staged_config) |v| v.deinit(self.a);
                    self.staged_config = null;
                }
            }
            for (&self.tasks) |*slot| {
                if (slot.*) |task| {
                    if (task.id != id) continue;
                    slot.* = null;
                    if (task.generation != self.generation) return;
                    if (task.index == max_entries) {
                        self.test_duration_ms = @max(0, (j.number(j.get(ctx, "host_monotonic_ms")) orelse task.started) - task.started);
                        self.test_status = "error";
                        if (!ok) {
                            self.status = "Connection test failed or exceeded host deadline";
                            if (j.text(j.get(payload, "error"))) |detail| {
                                const prefix = "plugin host effect exceeded ";
                                const suffix = "ms deadline";
                                if (detail.len <= self.test_failure_detail.len and std.mem.startsWith(u8, detail, prefix) and std.mem.endsWith(u8, detail, suffix)) {
                                    const digits = detail[prefix.len .. detail.len - suffix.len];
                                    if (digits.len > 0 and std.mem.indexOfNone(u8, digits, "0123456789") == null) {
                                        const timeout = std.fmt.parseInt(u32, digits, 10) catch 0;
                                        if (timeout >= 10000 and timeout <= 300000) {
                                            @memcpy(self.test_failure_detail[0..detail.len], detail);
                                            self.status = self.test_failure_detail[0..detail.len];
                                        }
                                    }
                                }
                            }
                            return;
                        }
                        const code = j.uint(j.get(value, "status")) orelse 0;
                        if (code < 200 or code >= 300) {
                            self.status = "Connection test provider HTTP status rejected";
                            return;
                        }
                        const body = j.text(j.get(value, "body")) orelse return error.HttpResponseBodyMissing;
                        _ = providers.decode(a, task.provider, body) catch |err| {
                            self.status = @errorName(err);
                            return;
                        };
                        self.test_status = "completed";
                        self.status = "Connection test completed";
                        return;
                    }
                    if (task.index >= self.entries.items.len) return;
                    const e = &self.entries.items[task.index];
                    if (e.generation != task.generation or e.revision != task.revision or e.status != .pending) return;
                    e.duration = @max(0, (j.number(j.get(ctx, "host_monotonic_ms")) orelse task.started) - task.started);
                    if (!ok) {
                        e.status = .err;
                        e.failure = "Network failed or exceeded host deadline";
                        if (j.text(j.get(payload, "error"))) |detail| {
                            if (detail.len <= e.failure_detail.len and std.mem.indexOf(u8, detail, "Bearer ") == null and std.mem.indexOf(u8, detail, "authorization") == null) {
                                @memcpy(e.failure_detail[0..detail.len], detail);
                                e.failure_len = detail.len;
                            }
                        }
                        return;
                    }
                    const status = j.uint(j.get(value, "status")) orelse 0;
                    if (status < 200 or status >= 300) {
                        e.status = .err;
                        e.failure = if (status == 401 or status == 403) "Provider authorization rejected" else if (status == 429) "Provider rate limit" else "Provider HTTP status rejected";
                        return;
                    }
                    const body = j.text(j.get(value, "body")) orelse {
                        e.status = .err;
                        e.failure = "HTTP response body missing";
                        return;
                    };
                    const translation = providers.decode(a, task.provider, body) catch |err| {
                        e.status = .err;
                        e.failure = @errorName(err);
                        return;
                    };
                    if (std.mem.eql(u8, translation, e.text)) {
                        e.status = .skipped;
                        e.reason = .unchanged;
                        e.age = self.nextAge();
                        return;
                    }
                    if (!try self.room(translation.len, null)) {
                        e.status = .err;
                        e.failure = "Retained translation content exceeds 256 KiB";
                        return;
                    }
                    e.translation = self.retainTranslation(translation) catch {
                        e.status = .err;
                        e.failure = "Aggregate allocation budget exhausted";
                        return;
                    };
                    e.status = .completed;
                    e.age = self.nextAge();
                    self.translated += 1;
                    self.total_ms += e.duration;
                    return;
                }
            }
        }
        pub fn rejectSave(self: *Self, operation: []const u8) !void {
            if (std.mem.eql(u8, self.save_status, "unknown")) return;
            if (operation.len == 0 or operation.len > 128) return;
            if (self.save_request != null or self.storage_request != null) return;
            try self.replace(&self.save_operation, operation);
            self.save_status = "failed";
            self.saved = false;
        }
        pub fn action(self: *Self, a: A, name: []const u8, payload: j.Value, ctx: j.Value) !void {
            try self.context(ctx);
            if (!j.truth(j.get(ctx, "user_action"))) return error.ExplicitOwnerActionRequired;
            const surface = j.get(ctx, "surface");
            const target = j.get(surface, "target");
            if ((self.save_request != null or self.storage_request != null) and !std.mem.eql(u8, name, "settings.save")) return error.SaveAlreadyPending;
            if (std.mem.eql(u8, name, "settings.save")) {
                if (std.mem.eql(u8, self.save_status, "unknown")) return error.SaveOutcomeUnknownReloadToInspect;
                if (!j.is(target, "setting-page")) return error.SettingsSurfaceRequired;
                if (self.save_request != null or self.storage_request != null) return error.SaveAlreadyPending;
                const operation = j.text(j.get(payload, "operation_id")) orelse return error.SaveOperationIdentityRequired;
                if (operation.len == 0 or operation.len > 128) return error.SaveOperationIdentityLengthLimit;
                const conf = try c.Config.parse(j.get(payload, "config"));
                try self.replace(&self.save_operation, operation);
                self.save_status = "pending";
                errdefer {
                    self.save_status = "failed";
                    if (self.staged_config) |staged| staged.deinit(self.a);
                    self.staged_config = null;
                }
                self.staged_config = try conf.owned(self.a);
                self.saved = false;
                self.invalidate(false);
                self.save_generation = self.generation;
                self.save_started = j.number(j.get(ctx, "host_monotonic_ms")) orelse 0;
                if (conf.provider == .siliconflow or conf.provider == .custom) {
                    var resource_config = j.object(a);
                    try j.set(&resource_config, "id", j.string(@tagName(conf.provider)));
                    const endpoint = if (conf.provider == .siliconflow) "https://api.siliconflow.cn/v1/chat/completions" else j.text(j.get(payload, "endpoint")) orelse return error.CustomEndpointRequired;
                    if (endpoint.len > 2048 or !(std.mem.startsWith(u8, endpoint, "https://") or std.mem.startsWith(u8, endpoint, "http://"))) return error.AbsoluteHttpEndpointRequired;
                    try j.set(&resource_config, "endpoint", j.string(endpoint));
                    try j.set(&resource_config, "enabled", .{ .bool = true });
                    try j.set(&resource_config, "authorization", j.get(payload, "authorization"));
                    try j.set(&resource_config, "clear_authorization", .{ .bool = j.truth(j.get(payload, "clear_authorization")) });
                    switch (Host.resources.send("resource-configure", try j.stringify(a, resource_config))) {
                        .ok => |id| {
                            self.save_request = id;
                            self.status = "Saving exact endpoint grant";
                        },
                        .err => |message| {
                            self.a.free(message);
                            return error.ResourceSaveRejected;
                        },
                    }
                } else try self.persist(a);
            } else if (std.mem.eql(u8, name, "control")) {
                if (!j.is(target, "sidebar")) return error.SidebarSurfaceRequired;
                if (self.save_request != null or self.storage_request != null) return error.SaveAlreadyPending;
                const conf = try (try c.Config.parse(payload)).owned(self.a);
                self.config.deinit(self.a);
                self.config = conf;
                self.saved = false;
                self.invalidate(conf.auto_translate);
                self.status = "Session controls updated; Save settings to persist";
            } else if (std.mem.eql(u8, name, "cache.clear")) {
                if (!j.is(target, "sidebar")) return error.SidebarSurfaceRequired;
                self.invalidate(false);
                self.translated = 0;
                self.total_ms = 0;
                self.status = "Session translations cleared; retry a block to translate again";
            } else if ((std.mem.eql(u8, name, "block.retry") or std.mem.eql(u8, name, "block.force"))) {
                if (!j.is(target, "block-slot")) return error.BlockSurfaceRequired;
                const id = j.text(j.get(surface, "block_id")) orelse return error.BlockIdentityRequired;
                if (!j.is(j.get(payload, "block_id"), id)) return error.BlockIdentityMismatch;
                for (self.entries.items) |*e| {
                    if (std.mem.eql(u8, e.id, id)) {
                        if (self.config.assistant_only and !std.mem.eql(u8, e.role, "assistant")) return error.AssistantOnlyControlEnabled;
                        if (e.status == .queued or e.status == .pending) return error.TranslationAlreadyPending;
                        if (e.text.len == 0) return error.OriginalTextUnavailable;
                        if (e.translation.len > 0) self.a.free(e.translation);
                        e.translation = "";
                        e.failure = "";
                        e.failure_len = 0;
                        e.status = .queued;
                        e.force = std.mem.eql(u8, name, "block.force");
                        e.reason = null;
                        e.generation = self.generation;
                    }
                }
            } else if (std.mem.eql(u8, name, "test")) {
                if (!j.is(target, "setting-page")) return error.SettingsSurfaceRequired;
                if (self.active() >= concurrency) return error.TranslationConcurrencyLimit;
                if (self.save_request != null or self.storage_request != null) return error.SaveAlreadyPending;
                const r = try self.resource(a);
                const request = try providers.build(a, self.config, "Hello, world.", if (r) |v| j.text(j.get(v, "id")) else null, if (r) |v| j.text(j.get(v, "config_pin")) else null);
                switch (Host.net.send("http", try j.stringify(a, request))) {
                    .err => |message| {
                        self.a.free(message);
                        return error.ConnectionTestDispatchRejected;
                    },
                    .ok => |id| {
                        for (&self.tasks) |*slot| {
                            if (slot.* == null) {
                                slot.* = .{ .id = id, .index = max_entries, .generation = self.generation, .started = j.number(j.get(ctx, "host_monotonic_ms")) orelse 0, .timeout_ms = httpTimeout(ctx), .provider = self.config.provider };
                                break;
                            }
                        }
                    },
                }
                self.test_status = "pending";
                self.status = "Testing saved provider";
            } else return error.UnknownTranslatorAction;
            try self.pump(a, ctx);
        }
        fn variantValue(self: *Self, a: A, e: *const Entry, locale: []const u8) !j.Value {
            var v = j.object(a);
            try j.set(&v, "block_id", j.string(e.id));
            try j.set(&v, "variant_id", j.string("translation"));
            try j.set(&v, "source_digest", j.string(try std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(&e.signature)})));
            try j.set(&v, "history_revision", j.string(e.history));
            try j.set(&v, "label", j.string(if (std.mem.startsWith(u8, locale, "en")) "Translation" else "译文"));
            try j.set(&v, "status", j.string(switch (e.status) {
                .queued, .pending => "pending",
                .completed => "completed",
                .skipped => "skipped",
                .err => "error",
                .vacant, .cancelled => "cancelled",
            }));
            try j.set(&v, "text", j.string(if (e.status == .completed) e.translation else ""));
            try j.set(&v, "default_display", j.string(@tagName(self.config.display_mode)));
            if (e.reason) |reason| try j.set(&v, "reason", j.string(@tagName(reason)));
            if (e.status == .err) try j.set(&v, "error", j.string(if (e.failure_len > 0) e.failure_detail[0..e.failure_len] else e.failure));
            try j.set(&v, "retry_action", j.string("block.retry"));
            try j.set(&v, "force_action", j.string("block.force"));
            return v;
        }
        fn userValue(self: *Self, a: A, e: *const Entry, locale: []const u8) !j.Value {
            if (e.status == .vacant or !std.mem.eql(u8, e.role, "user")) return .null;
            var v = j.object(a);
            try j.set(&v, "block_id", j.string(e.id));
            try j.set(&v, "locale", j.string(locale));
            try j.set(&v, "status", j.string(switch (e.status) {
                .queued, .pending => "pending",
                .completed => "completed",
                .skipped => "skipped",
                .err => "error",
                .vacant, .cancelled => "cancelled",
            }));
            try j.set(&v, "translation", j.string(if (e.status == .completed) e.translation else ""));
            try j.set(&v, "error", j.string(if (e.failure_len > 0) e.failure_detail[0..e.failure_len] else e.failure));
            try j.set(&v, "duration_ms", .{ .float = e.duration });
            try j.set(&v, "provider", j.string(@tagName(self.config.provider)));
            try j.set(&v, "source", j.string(self.config.source));
            try j.set(&v, "target", j.string(self.config.target));
            return v;
        }
        pub fn published(self: *Self) void {
            for (self.entries.items) |*e| {
                if (e.blocked and std.mem.eql(u8, e.role, "assistant")) continue;
                e.fresh = false;
            }
            self.clearRemovals();
        }
        pub fn result(self: *Self, a: A, ctx: j.Value, block_html: []const u8, publish: bool) !j.Value {
            _ = block_html;
            const locale = j.text(j.get(ctx, "locale")) orelse "zh-CN";
            var projection = j.object(a);
            try j.set(&projection, "locale", j.string(locale));
            try j.set(&projection, "config", try self.config.value(a));
            try j.set(&projection, "resources", try j.parse(a, self.resources));
            try j.set(&projection, "status", j.string(self.status));
            try j.set(&projection, "saved", .{ .bool = self.saved });
            var save = j.object(a);
            try j.set(&save, "operation_id", j.string(self.save_operation));
            try j.set(&save, "status", j.string(self.save_status));
            try j.set(&save, "error", j.string(if (std.mem.eql(u8, self.save_status, "failed") or std.mem.eql(u8, self.save_status, "unknown")) self.status else ""));
            try j.set(&projection, "save", save);
            try j.set(&projection, "pending", .{ .bool = self.save_request != null or self.storage_request != null });
            var stats = j.object(a);
            try j.set(&stats, "translated", .{ .integer = @intCast(self.translated) });
            try j.set(&stats, "average_ms", .{ .float = if (self.translated > 0) self.total_ms / @as(f64, @floatFromInt(self.translated)) else 0 });
            try j.set(&projection, "stats", stats);
            var connection_test = j.object(a);
            try j.set(&connection_test, "status", j.string(self.test_status));
            try j.set(&connection_test, "duration_ms", .{ .float = self.test_duration_ms });
            try j.set(&projection, "test", connection_test);
            var users = j.array(a);
            var has_users = false;
            for (self.entries.items) |*e| {
                const value = try self.userValue(a, e, locale);
                if (value != .null) has_users = true;
                try users.array.append(value);
            }
            var variants = j.array(a);
            var slots = j.array(a);
            var deferred = j.array(a);
            if (publish) for (self.entries.items) |*e| {
                if (e.status == .vacant) continue;
                if (std.mem.eql(u8, e.role, "assistant")) {
                    // Truncated source has no certified replacement authority.
                    if (e.blocked) continue;
                    try variants.array.append(try self.variantValue(a, e, locale));
                } else {
                    var slot = j.object(a);
                    try j.set(&slot, "slot_id", j.string("translation"));
                    try j.set(&slot, "block_id", j.string(e.id));
                    try j.set(&slot, "placement", j.string("after"));
                    if (!e.fresh) continue;
                    if (slots.array.items.len < 64) try slots.array.append(slot) else try deferred.array.append(slot);
                }
            };
            var patch = j.object(a);
            try j.set(&patch, "settings", projection);
            try j.set(&patch, "sidebar", projection);
            // Optional legacy user cards alone retain the old HTML projection.
            if (has_users) try j.set(&patch, "user_blocks", users);
            var out = j.object(a);
            try j.set(&out, "schema_version", .{ .integer = 1 });
            try j.set(&out, "vars_patch", patch);
            try j.set(&out, "rerender", .{ .bool = false });
            if (publish and self.removed_count > 0) {
                var removals = j.array(a);
                var slot_removals = j.array(a);
                for (self.removed[0..self.removed_count]) |*removal| {
                    var item = j.object(a);
                    try j.set(&item, "block_id", j.string(removal.id[0..removal.len]));
                    try j.set(&item, if (removal.assistant) "variant_id" else "slot_id", j.string("translation"));
                    if (removal.assistant) try removals.array.append(item) else try slot_removals.array.append(item);
                }
                if (removals.array.items.len > 0) try j.set(&out, "remove_block_variants", removals);
                if (slot_removals.array.items.len > 0) try j.set(&out, "remove_block_slots", slot_removals);
            }
            if (publish) try j.set(&out, "block_variants", variants);
            if (slots.array.items.len > 0) try j.set(&out, "block_slots", slots);
            if (deferred.array.items.len > 0) {
                var effect = j.object(a);
                try j.set(&effect, "kind", j.string("block-slots"));
                var payload = j.object(a);
                try j.set(&payload, "slots", deferred);
                try j.set(&effect, "payload", payload);
                var effects = j.array(a);
                try effects.array.append(effect);
                try j.set(&out, "effects", effects);
            }
            return out;
        }
    };
}
