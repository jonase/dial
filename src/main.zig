const std = @import("std");
const Credentials = @import("credentials.zig").Credentials;
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const PluginsManager = @import("plugins-manager.zig").PluginsManager;
const HttpClient = @import("http-client.zig").HttpClient;

const version = "0.0.1";

// Buffer used for prompt inputs
var input_buffer: [1024 * 1024]u8 = undefined;
var input_buffer_fbs = std.io.fixedBufferStream(&input_buffer);

// Scratch memory
var scratch_buffer: [1024 * 1024]u8 = undefined;
pub var scratch_fbs = std.io.fixedBufferStream(&scratch_buffer);

pub fn readUserInput(reader: anytype) ![]const u8 {
    input_buffer_fbs.reset();
    reader.streamUntilDelimiter(input_buffer_fbs.writer(), '\n', input_buffer.len) catch |err| {
        if (err == error.EndOfStream) {
            // Do Nothing
        } else {
            return err;
        }
    };
    return std.mem.trim(u8, input_buffer_fbs.getWritten(), " \n\r\t");
}

fn readUserInputFromEditor(allocator: std.mem.Allocator, config: Config, home_path: []const u8) ![]const u8 {
    const temp_file_path = blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        var prng = std.rand.DefaultPrng.init(seed);
        const random = prng.random();

        std.debug.assert(scratch_fbs.pos == 0);
        defer scratch_fbs.reset();
        try std.fmt.format(scratch_fbs.writer(), "dial-message-{x}", .{random.int(u64)});
        break :blk try std.fs.path.join(allocator, &.{ home_path, ".dial", scratch_fbs.getWritten() });
    };
    defer allocator.free(temp_file_path);

    var editor_command = std.ArrayList([]const u8).init(allocator);
    defer editor_command.deinit();
    try editor_command.appendSlice(config.editor);
    try editor_command.append(temp_file_path);

    var child = std.process.Child.init(editor_command.items, allocator);
    try child.spawn();

    const term = child.wait() catch {
        const command_string = try std.mem.join(allocator, " ", config.editor);
        defer allocator.free(command_string);
        std.log.err("Failed to open editor '{s}'.", .{command_string});
        return error.EditorOpenError;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.warn("Editor exited with code {d}\n", .{code});
                return error.EditorCloseError;
            }

            var temp_file = try std.fs.openFileAbsolute(temp_file_path, .{});
            defer {
                std.os.unlink(temp_file_path) catch {};
                temp_file.close();
            }

            var n = try temp_file.readAll(&input_buffer);
            return std.mem.trim(u8, input_buffer[0..n], " \n\r\t");
        },
        else => {
            std.log.warn("Editor terminated unexpectedly\n", .{});
            return error.EditorError;
        },
    }
}

fn clearHistory(allocator: std.mem.Allocator, message_history: *std.ArrayList(Request.Message)) void {
    for (message_history.items) |message| {
        if (message.content) |content| {
            allocator.free(content);
        }
        if (message.name) |name| {
            allocator.free(name);
        }
    }
    message_history.clearRetainingCapacity();
}

const Command = enum {
    clear,
    editor,
    exit,
    help,
};

const command_map = std.ComptimeStringMap(Command, .{
    .{ ".clear", .clear },
    .{ ".editor", .editor },
    .{ ".e", .editor },
    .{ ".exit", .exit },
    .{ ".help", .help },
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const home_path = std.os.getenv("HOME") orelse {
        return error.MissingHomeEnvVar;
    };

    const credentials = try Credentials.parse(allocator, home_path);
    defer credentials.deinit();

    const config = try Config.parse(allocator, home_path);
    defer config.deinit();

    const std_in = std.io.getStdIn();
    const std_out = std.io.getStdOut();

    var plugins_manager = try PluginsManager.init(allocator, config.plugin_search_paths, config.plugins);
    defer plugins_manager.deinit();

    var message_history = std.ArrayList(Request.Message).init(allocator);
    defer {
        clearHistory(allocator, &message_history);
        message_history.deinit();
    }

    var http_client = try HttpClient.init(allocator, .{
        .credentials = credentials,
        .config = config,
        .out = std_out,
        .in = std_in,
        .plugins_manager = plugins_manager,
        .message_history = &message_history,
        .verbose = false,
    });
    defer http_client.deinit();

    const reader = std_in.reader();
    const writer = std_out.writer();

    try writer.print(
        \\Welcome to dial v{s} ({s})
        \\Type ".help" for more information.
        \\
    , .{ version, config.model });

    done: while (true) {
        _ = try writer.write("user> ");

        var user_input = try readUserInput(reader);

        if (user_input.len == 0) continue;

        const command = blk: {
            if (user_input[0] == '.') {
                const idx = std.mem.indexOf(u8, user_input, " ") orelse user_input.len;
                const command = command_map.get(user_input[0..idx]);

                if (command) |cmd| {
                    user_input = user_input[idx..];
                    break :blk cmd;
                } else {
                    std.log.warn("Unknown command: {s}\n", .{user_input});
                    continue;
                }
            }
            break :blk null;
        };

        if (command) |cmd| {
            switch (cmd) {
                .editor => {
                    user_input = readUserInputFromEditor(allocator, config, home_path) catch |err| {
                        switch (err) {
                            error.EditorOpenError, error.EditorCloseError, error.EditorError => continue,
                            else => return err,
                        }
                    };
                    if (user_input.len == 0) continue;
                },
                .clear => {
                    clearHistory(allocator, &message_history);
                    std.log.info("Cleared message history and starting over", .{});
                    continue;
                },
                .exit => {
                    break :done;
                },
                .help => {
                    _ = try writer.print(
                        \\
                        \\.help         Print this help message
                        \\.exit         Exit the program
                        \\.clear        Clear the message history and start over
                        \\.editor .e    Open an editor for prompt editing
                        \\
                        \\More information on https://github.com/jonase/dial
                        \\
                        \\
                    , .{});
                    continue;
                },
            }
        }

        const user_message = .{
            .role = .user,
            .content = try allocator.dupe(u8, user_input),
        };

        http_client.submit(user_message) catch |err| {
            switch (err) {
                error.CurlPerformError => continue,
                else => return err,
            }
        };
        _ = try writer.write("\n");
    }
}
