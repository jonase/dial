const std = @import("std");

fn parseString(value: std.json.Value) ![]const u8 {
    switch (value) {
        else => return error.ConfigParseError,
        .string => |string| return string,
    }
}

fn parseStringArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    switch (value) {
        else => return error.ConfigParseError,
        .array => |array| {
            var array_list = std.ArrayList([]const u8).init(allocator);
            defer array_list.deinit();

            for (array.items) |item| {
                const str = try parseString(item);
                try array_list.append(str);
            }

            return array_list.toOwnedSlice();
        },
    }
}

fn parseBoolean(value: std.json.Value) !bool {
    switch (value) {
        else => return error.ConfigParseError,
        .bool => |b| return b,
    }
}

const default_model = "gpt-3.5-turbo-0613";
const default_editor = [_][]const u8{"vi"};
const default_plugins = [_]Config.Plugin{};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    model: []const u8 = default_model,
    editor: []const []const u8 = &default_editor,
    plugin_search_paths: []const []const u8,
    plugins: []const Plugin = &default_plugins,

    pub const Plugin = struct {
        name: []const u8,
        args: std.json.Value,
        enabled: bool = true,
        auto_confirm: bool = false,

        fn fromJson(value: std.json.Value) !Plugin {
            switch (value) {
                else => return error.ConfigParseError,
                .object => |object| {
                    const name = try parseString(object.get("name") orelse return error.ConfigParseError);

                    const args = object.get("args") orelse std.json.Value{ .null = {} };

                    const enabled = blk: {
                        if (object.get("enabled")) |val| {
                            break :blk try parseBoolean(val);
                        } else {
                            break :blk true;
                        }
                    };

                    const auto_confirm = blk: {
                        if (object.get("auto_confirm")) |val| {
                            break :blk try parseBoolean(val);
                        } else {
                            break :blk false;
                        }
                    };

                    return .{
                        .name = name,
                        .args = args,
                        .enabled = enabled,
                        .auto_confirm = auto_confirm,
                    };
                },
            }
        }
    };

    pub fn parse(allocator: std.mem.Allocator, home_path: []const u8) !Config {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const file_path = try std.fs.path.join(
            arena_allocator,
            &.{ home_path, ".dial/config.json" },
        );

        const default_plugin_search_paths = blk: {
            const default_plugin_search_path = try std.fs.path.join(
                arena_allocator,
                &.{ home_path, ".dial/plugins" },
            );
            var default_plugin_search_paths = try arena_allocator.alloc([]const u8, 1);
            default_plugin_search_paths[0] = default_plugin_search_path;
            break :blk default_plugin_search_paths;
        };

        const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return Config{
                    .arena = arena,
                    .plugin_search_paths = default_plugin_search_paths,
                },
                else => return err,
            }
        };
        defer file.close();

        const json_string = try file.readToEndAlloc(arena_allocator, std.math.maxInt(usize));

        const parsed = try std.json.parseFromSlice(std.json.Value, arena_allocator, json_string, .{});

        switch (parsed.value) {
            else => return error.ConfigParseError,
            .object => |object| {
                const model = blk: {
                    if (object.get("model")) |value| {
                        break :blk try parseString(value);
                    } else {
                        break :blk default_model;
                    }
                };
                const editor = blk: {
                    if (object.get("editor")) |value| {
                        break :blk try parseStringArray(arena_allocator, value);
                    } else {
                        break :blk &default_editor;
                    }
                };

                const plugin_search_paths = blk: {
                    if (object.get("plugin_search_paths")) |value| {
                        const plugin_search_paths = try parseStringArray(arena_allocator, value);
                        // Add default search path
                        var array_list = std.ArrayList([]const u8).init(arena_allocator);
                        try array_list.appendSlice(plugin_search_paths);
                        try array_list.appendSlice(default_plugin_search_paths);
                        break :blk try array_list.toOwnedSlice();
                    } else {
                        break :blk default_plugin_search_paths;
                    }
                };

                const plugins = blk: {
                    if (object.get("plugins")) |value| {
                        switch (value) {
                            else => return error.ConfigParseError,
                            .array => |array| {
                                var array_list = std.ArrayList(Plugin).init(arena_allocator);
                                defer array_list.deinit();

                                for (array.items) |item| {
                                    try array_list.append(try Plugin.fromJson(item));
                                }

                                break :blk try array_list.toOwnedSlice();
                            },
                        }
                    } else {
                        break :blk &default_plugins;
                    }
                };

                return .{
                    .arena = arena,
                    .model = model,
                    .editor = editor,
                    .plugin_search_paths = plugin_search_paths,
                    .plugins = plugins,
                };
            },
        }
    }

    pub fn deinit(config: Config) void {
        config.arena.deinit();
    }
};
