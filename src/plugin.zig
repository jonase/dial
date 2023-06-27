const std = @import("std");
const root = @import("root");
const Config = @import("./config.zig").Config;
const Request = @import("./request.zig").Request;
const c = @cImport({
    @cInclude("dial-plugin.h");
});

pub const Plugin = struct {
    allocator: std.mem.Allocator,

    library: std.DynLib,

    deinit_fn: *const DeinitFn,
    init_fn: *const InitFn,
    schema_fn: *const SchemaFn,
    invoke_fn: *const InvokeFn,
    free_result_fn: *const FreeResultFn,

    auto_confirm: bool,
    handle: *anyopaque,
    parsed: std.json.Parsed([]const Request.Function),

    const InitFn = fn (
        args_len: usize,
        args: [*]const u8,
        handle: **anyopaque,
    ) callconv(.C) c_int;

    const DeinitFn = fn (
        handle: *anyopaque,
    ) callconv(.C) void;

    const SchemaFn = fn (
        handle: *anyopaque,
        schema_len: *usize,
        schema: *[*]const u8,
    ) callconv(.C) c_int;

    const InvokeFn = fn (
        handle: *anyopaque,
        fn_name_len: usize,
        fn_name: [*]const u8,
        args_len: usize,
        args: [*]const u8,
        result_len: *usize,
        result: *[*]const u8,
    ) callconv(.C) c_int;

    const FreeResultFn = fn (
        handle: *anyopaque,
        result_len: usize,
        result: [*]const u8,
    ) callconv(.C) void;

    pub fn init(
        allocator: std.mem.Allocator,
        search_paths: []const []const u8,
        plugin_config: Config.Plugin,
    ) !Plugin {
        var library = try loadLibrary(allocator, search_paths, plugin_config.name);
        errdefer library.close();

        const init_fn = library.lookup(*InitFn, "dial_plugin_init") orelse return error.SymbolNotFound;
        const deinit_fn = library.lookup(*DeinitFn, "dial_plugin_deinit") orelse return error.SymbolNotFound;
        const schema_fn = library.lookup(*SchemaFn, "dial_plugin_schema") orelse return error.SymbolNotFound;
        const invoke_fn = library.lookup(*InvokeFn, "dial_plugin_invoke") orelse return error.SymbolNotFound;
        const free_result_fn = library.lookup(*FreeResultFn, "dial_plugin_free_result") orelse return error.SymbolNotFound;

        const handle = blk: {
            std.debug.assert(root.scratch_fbs.pos == 0);
            defer root.scratch_fbs.reset();
            try std.json.stringify(plugin_config.args, .{}, root.scratch_fbs.writer());
            const args_str = root.scratch_fbs.getWritten();
            var handle: *anyopaque = undefined;
            if (init_fn(args_str.len, args_str.ptr, &handle) != 0) {
                return error.PluginInitError;
            }
            break :blk handle;
        };
        errdefer deinit_fn(handle);

        var schema_str_len: usize = 0;
        var schema_str: [*]const u8 = undefined;
        if (schema_fn(handle, &schema_str_len, &schema_str) != 0) {
            return error.PluginSchemaError;
        }

        var parsed = try std.json.parseFromSlice(
            []const Request.Function,
            allocator,
            schema_str[0..schema_str_len],
            .{},
        );

        return Plugin{
            .library = library,
            .allocator = allocator,
            .auto_confirm = plugin_config.auto_confirm,
            .handle = handle,
            .parsed = parsed,

            .init_fn = init_fn,
            .deinit_fn = deinit_fn,
            .schema_fn = schema_fn,
            .invoke_fn = invoke_fn,
            .free_result_fn = free_result_fn,
        };
    }

    pub fn deinit(plugin: *Plugin) void {
        plugin.parsed.deinit();
        plugin.deinit_fn(plugin.handle);
        plugin.library.close();
    }

    pub fn invoke(plugin: Plugin, fn_name: []const u8, args: []const u8) ![]const u8 {
        var result_len: usize = 0;
        var result: [*]const u8 = undefined;

        if (plugin.invoke_fn(
            plugin.handle,
            fn_name.len,
            fn_name.ptr,
            args.len,
            args.ptr,
            &result_len,
            &result,
        ) != 0) {
            return error.PluginInvokeError;
        }

        return result[0..result_len];
    }

    pub fn freeResult(plugin: Plugin, result: []const u8) void {
        plugin.free_result_fn(plugin.handle, result.len, result.ptr);
    }

    fn loadLibrary(allocator: std.mem.Allocator, search_paths: []const []const u8, library_name: []const u8) !std.DynLib {
        const full_library_names = blk: {
            var array_list = std.ArrayList([]const u8).init(allocator);
            defer array_list.deinit();
            try array_list.append(try std.mem.concat(allocator, u8, &.{ "lib", library_name, ".dylib" }));
            try array_list.append(try std.mem.concat(allocator, u8, &.{ library_name, ".dll" }));
            try array_list.append(try std.mem.concat(allocator, u8, &.{ "lib", library_name, ".so" }));
            break :blk try array_list.toOwnedSlice();
        };
        defer {
            for (full_library_names) |full_library_name| {
                allocator.free(full_library_name);
            }
            allocator.free(full_library_names);
        }

        for (search_paths) |search_path| {
            for (full_library_names) |lib_name| {
                const path = try std.fs.path.joinZ(allocator, &.{ search_path, lib_name });
                defer allocator.free(path);
                const library = std.DynLib.open(path) catch |err| {
                    switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    }
                };

                return library;
            }
        }
        std.log.err("Failed to load plugin {s}", .{library_name});
        return error.FailedToLoadLibraryError;
    }
};
