//! WIT type definitions and constants for microcrab:client-plugin@0.4.0

pub const ViewTarget = enum(u8) {
    sidebar = 0,
    expanded_page = 1,
    session_tab = 2,
    block_slot = 3,
    setting_page = 4,

    pub fn fromString(str: []const u8) ?ViewTarget {
        if (std.mem.eql(u8, str, "sidebar")) return .sidebar;
        if (std.mem.eql(u8, str, "expanded-page")) return .expanded_page;
        if (std.mem.eql(u8, str, "session-tab")) return .session_tab;
        if (std.mem.eql(u8, str, "block-slot")) return .block_slot;
        if (std.mem.eql(u8, str, "setting-page")) return .setting_page;
        return null;
    }

    pub fn toString(self: ViewTarget) []const u8 {
        return switch (self) {
            .sidebar => "sidebar",
            .expanded_page => "expanded-page",
            .session_tab => "session-tab",
            .block_slot => "block-slot",
            .setting_page => "setting-page",
        };
    }
};

pub const RenderMode = enum(u32) {
    native_json = 0,
    webview_html = 1,
};

pub const PluginManifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    targets: []const ViewTarget,
    network_origins: ?[]const []const u8 = null,
};

pub const ViewOutput = struct {
    schema_version: u32 = 1,
    mode: RenderMode,
    content: []const u8,
    vars_patch: ?[]const u8 = null,
    rerender: bool = false,
    error_msg: ?[]const u8 = null,
};

const std = @import("std");
