const std = @import("std");
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Plugin = @import("plugin.zig").Plugin;

pub const PluginsManager = struct {
    plugins: []Plugin,
    allocator: std.mem.Allocator,
    functions: []const Request.Function,
    function_map: std.StringHashMap(Plugin),

    pub fn init(
        allocator: std.mem.Allocator,
        plugin_search_paths: []const []const u8,
        plugins_config: []const Config.Plugin,
    ) !PluginsManager {
        var plugins = blk: {
            var array_list = std.ArrayList(Plugin).init(allocator);
            defer array_list.deinit();
            for (plugins_config) |plugin_config| {
                if (plugin_config.enabled) {
                    const plugin = try Plugin.init(
                        allocator,
                        plugin_search_paths,
                        plugin_config,
                    );
                    try array_list.append(plugin);
                }
            }

            break :blk try array_list.toOwnedSlice();
        };

        var functions_array_list = std.ArrayList(Request.Function).init(allocator);
        defer functions_array_list.deinit();
        var function_map = std.StringHashMap(Plugin).init(allocator);

        for (plugins) |plugin| {
            if (plugin.functions) |functions| {
                try functions_array_list.appendSlice(functions);
                for (functions) |function| {
                    try function_map.putNoClobber(function.name, plugin);
                }
            }
        }

        return .{
            .allocator = allocator,
            .plugins = plugins,
            .functions = try functions_array_list.toOwnedSlice(),
            .function_map = function_map,
        };
    }

    pub fn deinit(plugin_manager: *PluginsManager) void {
        plugin_manager.allocator.free(plugin_manager.functions);
        plugin_manager.function_map.deinit();
        for (plugin_manager.plugins) |*plugin| {
            plugin.deinit();
        }
        plugin_manager.allocator.free(plugin_manager.plugins);
    }
};
