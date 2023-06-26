const std = @import("std");
const Config = @import("config.zig").Config;

pub const ConfigParser = struct {
    allocator: std.mem.Allocator,
    parsed: ?std.json.Parsed(Config),
    source: ?[]const u8,
    default_plugin_search_path: []const u8,
    config: Config,

    pub fn parse(allocator: std.mem.Allocator, home_path: []const u8) !ConfigParser {
        const default_plugin_search_path = try std.fs.path.join(allocator, &.{ home_path, ".dial/plugins" });
        errdefer allocator.free(default_plugin_search_path);

        const path = try std.fs.path.join(allocator, &.{ home_path, ".dial/config.json" });
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    var plugin_seach_paths = try allocator.alloc([]const u8, 1);
                    plugin_seach_paths[0] = default_plugin_search_path;

                    return ConfigParser{
                        .allocator = allocator,
                        .parsed = null,
                        .source = null,
                        .default_plugin_search_path = default_plugin_search_path,
                        .config = Config{ .plugin_search_paths = plugin_seach_paths },
                    };
                },
                else => return err,
            }
        };
        defer file.close();

        const source = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

        var parsed = try std.json.parseFromSlice(Config, allocator, source, .{});
        errdefer parsed.deinit();

        var config = parsed.value;

        var array_list = std.ArrayList([]const u8).init(allocator);
        defer array_list.deinit();

        try array_list.appendSlice(config.plugin_search_paths);
        try array_list.append(default_plugin_search_path);

        config.plugin_search_paths = try array_list.toOwnedSlice();

        return ConfigParser{
            .allocator = allocator,
            .parsed = parsed,
            .source = source,
            .default_plugin_search_path = default_plugin_search_path,
            .config = config,
        };
    }

    pub fn deinit(config_parser: *ConfigParser) void {
        config_parser.allocator.free(config_parser.default_plugin_search_path);
        config_parser.allocator.free(config_parser.config.plugin_search_paths);
        if (config_parser.source) |source| {
            config_parser.allocator.free(source);
        }
        if (config_parser.parsed) |parsed| {
            parsed.deinit();
        }
    }
};
