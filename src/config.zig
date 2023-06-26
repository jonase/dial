const std = @import("std");

pub const Config = struct {
    model: []const u8 = "gpt-3.5-turbo-0613",
    editor: []const []const u8 = &[_][]const u8{"vi"},
    plugin_search_paths: []const []const u8 = &[_][]const u8{},
    plugins: []const Plugin = &.{},

    pub const Plugin = struct {
        name: []const u8,
        args: std.json.Value = std.json.Value{ .null = {} },
        enabled: bool = true,
        auto_confirm: bool = false,
    };
};
