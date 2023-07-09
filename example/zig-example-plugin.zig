// A simple example plugin in zig that can list and read local files
const std = @import("std");
const c = @cImport({
    @cInclude("dial-plugin.h");
});

const ReadFileArguments = struct {
    filename: []const u8,
};

const ListFilesArguments = struct {
    foldername: []const u8 = ".",
};

const Plugin = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    const schema =
        \\
        \\[
        \\  {
        \\    "name": "read_file",
        \\    "description": "Returns the text content of a file",
        \\    "parameters": {
        \\      "type": "object",
        \\      "properties": {
        \\        "filename": {
        \\          "type": "string",
        \\          "description": "The name of the file e.g. README.md"
        \\        }
        \\      },
        \\      "required": ["filename"]
        \\    }
        \\  },
        \\  {
        \\    "name": "list_files",
        \\    "description": "List files in a directory (relative to current working directory)",
        \\    "parameters": {
        \\      "type": "object",
        \\      "properties": {
        \\        "foldername": {
        \\          "type": "string",
        \\          "description": "the name of the folder to list files in. Relative to the current working directory. Leave empty to get the current directory"
        \\        }
        \\      }
        \\    }
        \\  }
        \\]
        \\
    ;

    fn cast(handle: *anyopaque) *Plugin {
        return @ptrCast(@alignCast(handle));
    }

    fn init() std.mem.Allocator.Error!*Plugin {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        const plugin = try allocator.create(Plugin);

        plugin.* = .{
            .gpa = gpa,
        };

        return plugin;
    }

    fn deinit(plugin: *Plugin) void {
        var gpa = plugin.gpa;
        const allocator = gpa.allocator();
        allocator.destroy(plugin);
        _ = gpa.deinit();
    }

    fn readFile(plugin: *Plugin, args_string: []const u8) ![]u8 {
        const allocator = plugin.gpa.allocator();
        const parsed = std.json.parseFromSlice(ReadFileArguments, allocator, args_string, .{}) catch {
            return error.InvokeError;
        };
        defer parsed.deinit();

        const file = std.fs.cwd().openFile(parsed.value.filename, .{}) catch {
            return error.InvokeError;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 4 * 1024) catch {
            return error.InvokeError;
        };

        return content;
    }

    fn listFiles(plugin: *Plugin, args_string: []const u8) ![]u8 {
        const allocator = plugin.gpa.allocator();
        const parsed = std.json.parseFromSlice(ListFilesArguments, allocator, args_string, .{}) catch {
            return error.InvokeError;
        };

        var dir = try std.fs.cwd().openIterableDir(parsed.value.foldername, .{});
        defer dir.close();

        var iter = dir.iterate();

        var array_list = std.ArrayList(u8).init(allocator);
        defer array_list.deinit();

        while (try iter.next()) |item| {
            try array_list.appendSlice(item.name);
            if (item.kind == .directory) {
                try array_list.append('/');
            }
            try array_list.append('\n');
        }

        return array_list.toOwnedSlice();
    }

    fn invoke(plugin: *Plugin, fn_name: []const u8, args_string: []const u8) ![]u8 {
        if (std.mem.eql(u8, fn_name, "read_file")) {
            return plugin.readFile(args_string);
        } else if (std.mem.eql(u8, fn_name, "list_files")) {
            return plugin.listFiles(args_string);
        } else {
            return error.InvokeError;
        }
    }

    fn freeResult(plugin: *Plugin, result: []const u8) void {
        const allocator = plugin.gpa.allocator();
        allocator.free(result);
    }
};

export fn dial_plugin_init(
    args_len: usize,
    args: [*]const u8,
    handle: **anyopaque,
) c_int {
    _ = args;
    _ = args_len;
    handle.* = Plugin.init() catch {
        return c.DIAL_PLUGIN_ERROR_OUT_OF_MEMORY;
    };

    return c.DIAL_PLUGIN_SUCCESS;
}

export fn dial_plugin_deinit(handle: *anyopaque) void {
    Plugin.cast(handle).deinit();
}

export fn dial_plugin_schema(
    handle: *anyopaque,
    schema_len: *usize,
    schema: *[*]const u8,
) c_int {
    _ = handle;
    schema_len.* = Plugin.schema.len;
    schema.* = Plugin.schema.ptr;
    return c.DIAL_PLUGIN_SUCCESS;
}

export fn dial_plugin_invoke(
    handle: *anyopaque,
    fn_name_len: usize,
    fn_name: [*]const u8,
    args_len: usize,
    args: [*]const u8,
    result_len: *usize,
    result: *[*]const u8,
) c_int {
    const res = Plugin.cast(handle).invoke(
        fn_name[0..fn_name_len],
        args[0..args_len],
    ) catch {
        return c.DIAL_PLUGIN_ERROR_UNKNOWN;
    };

    result_len.* = res.len;
    result.* = res.ptr;

    return c.DIAL_PLUGIN_SUCCESS;
}

export fn dial_plugin_free_result(
    handle: *anyopaque,
    result_len: usize,
    result: [*]const u8,
) void {
    Plugin.cast(handle).freeResult(result[0..result_len]);
}
