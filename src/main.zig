const std = @import("std");
const CredentialsParser = @import("credentials-parser.zig").CredentialsParser;
const Credentials = @import("credentials.zig").Credentials;
const ConfigParser = @import("config-parser.zig").ConfigParser;
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const PluginsManager = @import("plugins-manager.zig").PluginsManager;
const HttpClient = @import("http-client.zig").HttpClient;

const version = "0.0.1";

pub fn readUserInput(reader: anytype, user_input: *std.ArrayList(u8)) !void {
    reader.readUntilDelimiterArrayList(user_input, '\n', std.math.maxInt(usize)) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
}

fn readUserInputFromEditor(
    allocator: std.mem.Allocator,
    config: Config,
    home_path: []const u8,
    user_input: *std.ArrayList(u8),
) !void {
    const temp_file_path = blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        var prng = std.rand.DefaultPrng.init(seed);
        const random = prng.random();

        var input_array_list = std.ArrayList(u8).init(allocator);
        defer input_array_list.deinit();
        try std.fmt.format(input_array_list.writer(), "dial-message-{x}", .{random.int(u64)});
        break :blk try std.fs.path.join(allocator, &.{ home_path, ".dial", input_array_list.items });
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

            var reader = temp_file.reader();

            try reader.readAllArrayList(user_input, std.math.maxInt(usize));
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

const Cmd = enum {
    clear,
    editor,
    exit,
    help,
    load,
    save,
};

const command_map = std.ComptimeStringMap(Cmd, .{
    .{ ".clear", .clear },
    .{ ".editor", .editor },
    .{ ".e", .editor },
    .{ ".exit", .exit },
    .{ ".help", .help },
    .{ ".load", .load },
    .{ ".save", .save },
});

const Command = union(Cmd) {
    clear,
    editor,
    exit,
    help,
    load: []const u8,
    save: []const u8,

    fn ensureEndOfCommand(iter: *std.mem.TokenIterator(u8, .scalar), comptime format: []const u8, args: anytype) !void {
        if (iter.peek() != null) {
            std.log.err(format, args);
            return error.InvalidCommand;
        }
    }

    fn parseCommand(user_input: []const u8) error{ InvalidCommand, UnknownCommand }!?Command {
        if (user_input[0] != '.') return null;

        var iter = std.mem.tokenizeScalar(u8, user_input, ' ');

        const idx = std.mem.indexOf(u8, user_input, " ") orelse user_input.len;
        _ = idx;

        if (command_map.get(iter.next().?)) |cmd| {
            switch (cmd) {
                .clear => {
                    try ensureEndOfCommand(&iter, "Usage: .clear", .{});
                    return Command{ .clear = {} };
                },
                .editor => {
                    try ensureEndOfCommand(&iter, "Usage: .editor or .e", .{});
                    return Command{ .editor = {} };
                },
                .exit => {
                    try ensureEndOfCommand(&iter, "Usage: .exit", .{});
                    return Command{ .exit = {} };
                },
                .help => {
                    try ensureEndOfCommand(&iter, "Usage: .help", .{});
                    return Command{ .help = {} };
                },
                .load => {
                    if (iter.next()) |filename| {
                        try ensureEndOfCommand(&iter, "Usage: .load <filename>", .{});
                        return Command{ .load = filename };
                    } else {
                        std.log.err("Usage: .load <filename>", .{});
                        return error.InvalidCommand;
                    }
                },
                .save => {
                    if (iter.next()) |filename| {
                        try ensureEndOfCommand(&iter, "Usage: .save <filename>", .{});
                        return Command{ .save = filename };
                    } else {
                        std.log.err("Usage: .save <filename>", .{});
                        return error.InvalidCommand;
                    }
                },
            }
        } else {
            return error.UnknownCommand;
        }
    }
};

fn trim(string: []const u8) []const u8 {
    return std.mem.trim(u8, string, " \r\n\t");
}

fn isBlank(array_list: *std.ArrayList(u8)) bool {
    return trim(array_list.items).len == 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const home_path = std.os.getenv("HOME") orelse {
        return error.MissingHomeEnvVar;
    };

    var credentials_parser = try CredentialsParser.parse(allocator, home_path);
    defer credentials_parser.deinit();
    const credentials = credentials_parser.credentials;

    var config_parser = try ConfigParser.parse(allocator, home_path);
    defer config_parser.deinit();
    const config = config_parser.config;

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
        .plugins_manager = &plugins_manager,
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

    var user_input = std.ArrayList(u8).init(allocator);
    defer user_input.deinit();

    done: while (true) {
        user_input.clearRetainingCapacity();

        try writer.print("user> ", .{});

        try readUserInput(reader, &user_input);

        if (isBlank(&user_input)) continue;

        const command = Command.parseCommand(user_input.items) catch |err| {
            switch (err) {
                error.UnknownCommand => std.log.warn("Unknown command: {s}", .{user_input.items}),
                error.InvalidCommand => std.log.err("Invalid command: {s}", .{user_input.items}),
            }
            continue;
        };

        if (command) |cmd| {
            switch (cmd) {
                .editor => {
                    user_input.clearRetainingCapacity();
                    readUserInputFromEditor(allocator, config, home_path, &user_input) catch |err| {
                        switch (err) {
                            error.EditorOpenError, error.EditorCloseError, error.EditorError => continue,
                            else => return err,
                        }
                    };
                    if (isBlank(&user_input)) continue;
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
                        \\.help            Print this help message
                        \\.exit            Exit the program
                        \\.clear           Clear the message history and start over
                        \\.editor .e       Open an editor for prompt editing
                        \\.load <filename> Load message history from a file
                        \\.save <filename> Save message history to a file
                        \\
                        \\More information on https://github.com/jonase/dial
                        \\
                        \\
                    , .{});
                    continue;
                },

                .load => |filename| {
                    var file = std.fs.cwd().openFile(filename, .{}) catch |err| switch (err) {
                        error.FileNotFound => {
                            std.log.err("File \"{s}\" not found", .{filename});
                            continue;
                        },
                        else => return err,
                    };
                    defer file.close();

                    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
                    defer allocator.free(file_content);

                    const parsed = try std.json.parseFromSlice([]Request.Message, allocator, file_content, .{});
                    defer parsed.deinit();

                    clearHistory(allocator, &message_history);
                    for (parsed.value) |message| {
                        try message_history.append(Request.Message{
                            .role = message.role,
                            .content = if (message.content) |content| try allocator.dupe(u8, content) else null,
                            .name = if (message.name) |name| try allocator.dupe(u8, name) else null,
                            .function_call = message.function_call,
                        });
                    }

                    std.log.info("Loaded \"{s}\"", .{filename});
                    continue;
                },

                .save => |filename| {
                    var file = std.fs.cwd().createFile(filename, .{ .exclusive = true }) catch |err| {
                        if (err == error.PathAlreadyExists) {
                            std.log.err("File \"{s}\" already exists.", .{filename});
                            continue;
                        }
                        return err;
                    };
                    defer file.close();

                    try std.json.stringify(
                        message_history.items,
                        .{ .whitespace = std.json.StringifyOptions.Whitespace{} },
                        file.writer(),
                    );

                    std.log.info("Saved message history to \"{s}\"", .{filename});

                    continue;
                },
            }
        }

        const user_message = .{
            .role = .user,
            .content = try allocator.dupe(u8, trim(user_input.items)),
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
