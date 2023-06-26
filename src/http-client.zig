const std = @import("std");
const root = @import("root");
const c = @import("c.zig");
const Credentials = @import("credentials.zig").Credentials;
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const PluginsManager = @import("plugins-manager.zig").PluginsManager;

// Used for serializing message history, so should be large enough for 32k tokens.
var message_buffer: [4 * 1024 * 1024]u8 = undefined;
var message_buffer_fbs = std.io.fixedBufferStream(&message_buffer);

var curl_error_buffer: [c.CURL_ERROR_SIZE]u8 = undefined;

const TextPrinter = struct {
    out: std.fs.File,

    idx: usize,
    col: usize,

    fn init(out: std.fs.File) !TextPrinter {
        return .{
            .out = out,
            .idx = 0,
            .col = 0,
        };
    }

    fn deinit(self: *TextPrinter) void {
        _ = self;
    }

    // Implements very simple word-wrapping
    fn print(self: *TextPrinter, all_text: []const u8) !void {
        const writer = self.out.writer();

        var text = all_text[self.idx..];

        while (std.mem.indexOfAny(u8, text, " \n")) |i| {
            switch (text[i]) {
                ' ' => {
                    if (self.col + i > 80) {
                        try writer.writeByte('\n');
                        self.col = 0;
                    }
                    _ = try writer.write(text[0 .. i + 1]);
                    self.col += i + 1;
                    self.idx += i + 1;
                },
                '\n' => {
                    _ = try writer.write(text[0 .. i + 1]);
                    self.col = 0;
                    self.idx += i + 1;
                },
                else => unreachable,
            }
            text = text[i + 1 ..];
        }
    }

    fn flush(self: *TextPrinter, all_text: []const u8) !void {
        const writer = self.out.writer();

        var text = all_text[self.idx..];

        _ = try writer.write(text);
        self.idx += text.len;
        self.col += text.len;
    }
};

const ResponseHandler = struct {
    arena: *std.heap.ArenaAllocator,

    text_printer: TextPrinter,

    content: ?[]const u8,
    content_buffer: std.ArrayList(u8),

    function_call: ?Request.FunctionCall,
    function_call_arguments_buffer: std.ArrayList(u8),

    fn init(http_client: *HttpClient) !ResponseHandler {
        const allocator = http_client.response_handler_arena.allocator();
        const text_printer = try TextPrinter.init(http_client.out);
        return .{
            .arena = &http_client.response_handler_arena,
            .text_printer = text_printer,
            .content = null,
            .content_buffer = std.ArrayList(u8).init(allocator),
            .function_call = null,
            .function_call_arguments_buffer = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(response_handler: *ResponseHandler) void {
        _ = response_handler.arena.reset(.{ .retain_capacity = {} });
    }

    const MessageOrFunctionCall = union(enum) {
        message: Request.Message,
        function_call: Request.FunctionCall,
    };

    fn getMessageOrFunctionCall(response_handler: *ResponseHandler, allocator: std.mem.Allocator) !?MessageOrFunctionCall {
        if (response_handler.content) |content| {
            const assistant_message = .{
                .role = .assistant,
                .content = try allocator.dupe(u8, content),
            };
            return .{ .message = assistant_message };
        }

        if (response_handler.function_call) |function_call| {
            return .{ .function_call = function_call };
        }

        return null;
    }

    fn handleResponse(response_handler: *ResponseHandler, response: Response) !void {
        if (response.choices.len > 0) {
            const choice = response.choices[0];
            const delta = choice.delta;

            // Content handling
            if (delta.content) |content_token| {
                try response_handler.content_buffer.appendSlice(content_token);
                try response_handler.text_printer.print(response_handler.content_buffer.items);
            }

            // Function call handling
            if (delta.function_call) |function_call| {
                if (function_call.name) |name| {
                    response_handler.function_call = .{
                        .name = name,
                        .arguments = null,
                    };
                }

                if (function_call.arguments) |arguments_token| {
                    try response_handler.function_call_arguments_buffer.appendSlice(arguments_token);
                }
            }

            if (choice.finish_reason) |finish_reason| {
                if (std.mem.eql(u8, finish_reason, "stop")) {
                    try response_handler.text_printer.flush(response_handler.content_buffer.items);
                    response_handler.content = try response_handler.content_buffer.toOwnedSlice();
                } else if (std.mem.eql(u8, finish_reason, "function_call")) {
                    if (response_handler.function_call) |*function_call| {
                        function_call.arguments = try response_handler.function_call_arguments_buffer.toOwnedSlice();
                    }
                }
            }
        }
    }

    const ResponseError = struct {
        @"error": struct {
            message: []const u8,
            type: []const u8,
            param: ?[]const u8,
            code: ?i64,
        },
    };

    fn handleSseEvent(
        data: *anyopaque,
        size: c_uint,
        nmemb: c_uint,
        opaque_user_data: *anyopaque,
    ) callconv(.C) c_uint {
        var response_handler = @ptrCast(*ResponseHandler, @alignCast(@alignOf(ResponseHandler), opaque_user_data));

        var message = @ptrCast([*]u8, @alignCast(@alignOf(u8), data))[0 .. nmemb * size];

        var iter = std.mem.splitSequence(u8, message, "\n");

        while (iter.next()) |chunk| {
            if (std.mem.eql(u8, chunk, "")) {
                continue;
            }
            if (std.mem.eql(u8, chunk, "data: [DONE]")) {
                break;
            }
            const allocator = response_handler.arena.allocator();

            if (chunk.len < 6 or !std.mem.eql(u8, chunk[0..6], "data: ")) {
                const parsed = std.json.parseFromSlice(ResponseError, allocator, message, .{}) catch {
                    std.log.err("Failed to parse '{s}'", .{message});
                    return c.CURL_WRITEFUNC_ERROR;
                };
                defer parsed.deinit();
                std.log.err("{s}", .{parsed.value.@"error".message});
                return c.CURL_WRITEFUNC_ERROR;
            }

            const json_string = chunk[6..];

            const parsed = std.json.parseFromSlice(Response, allocator, json_string, .{}) catch {
                const parsed = std.json.parseFromSlice(ResponseError, allocator, json_string, .{}) catch {
                    std.log.err("Failed to parse '{s}'", .{json_string});
                    return c.CURL_WRITEFUNC_ERROR;
                };
                defer parsed.deinit();
                std.log.err("{s}", .{parsed.value.@"error".message});
                return c.CURL_WRITEFUNC_ERROR;
            };

            response_handler.handleResponse(parsed.value) catch {
                return c.CURL_WRITEFUNC_ERROR;
            };
        }

        return nmemb * size;
    }
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    response_handler_arena: std.heap.ArenaAllocator,
    out: std.fs.File,
    in: std.fs.File,
    config: Config,
    curl: *c.CURL,
    headers: *c.curl_slist,
    message_history: *std.ArrayList(Request.Message),
    plugins_manager: PluginsManager,

    const HttpClientOptions = struct {
        credentials: Credentials,
        config: Config,
        message_history: *std.ArrayList(Request.Message),
        plugins_manager: PluginsManager,
        out: std.fs.File,
        in: std.fs.File,
        verbose: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, opts: HttpClientOptions) !HttpClient {
        if (c.curl_global_init(c.CURL_GLOBAL_ALL) != c.CURLE_OK) {
            return error.CurlInitError;
        }

        var curl = c.curl_easy_init() orelse return error.CurlInitError;

        if (opts.verbose) {
            if (c.curl_easy_setopt(curl, c.CURLOPT_VERBOSE, @as(i64, 1)) != c.CURLE_OK) {
                return error.CurlSetoptError;
            }
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_ERRORBUFFER, &curl_error_buffer) != c.CURLE_OK) {
            return error.CurlSetoptError;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_URL, "https://api.openai.com/v1/chat/completions") != c.CURLE_OK) {
            return error.CurlSetoptError;
        }
        if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(i64, 1)) != c.CURLE_OK) {
            return error.CurlSetoptError;
        }

        var headers: ?*c.curl_slist = null;

        {
            headers = c.curl_slist_append(headers, "Content-Type: application/json");

            const auth_header = try std.mem.concatWithSentinel(
                allocator,
                u8,
                &.{ "Authorization: Bearer ", opts.credentials.openai_api_key },
                0,
            );
            defer allocator.free(auth_header);
            headers = c.curl_slist_append(headers, auth_header);

            if (opts.credentials.openai_organization_id) |openai_organization_id| {
                const org_header = try std.mem.concatWithSentinel(
                    allocator,
                    u8,
                    &.{ "OpenAI-Organization: ", openai_organization_id },
                    0,
                );
                defer allocator.free(org_header);
                headers = c.curl_slist_append(headers, org_header);
            }

            if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, headers) != c.CURLE_OK) {
                return error.CurlSetoptError;
            }
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, ResponseHandler.handleSseEvent) != c.CURLE_OK) {
            return error.CurlSetoptError;
        }

        return .{
            .allocator = allocator,
            .response_handler_arena = std.heap.ArenaAllocator.init(allocator),
            .out = opts.out,
            .in = opts.in,
            .config = opts.config,
            .curl = curl,
            .headers = headers.?,
            .message_history = opts.message_history,
            .plugins_manager = opts.plugins_manager,
        };
    }

    pub fn deinit(http_client: *HttpClient) void {
        http_client.response_handler_arena.deinit();
        c.curl_slist_free_all(http_client.headers);
        c.curl_easy_cleanup(http_client.curl);
        c.curl_global_cleanup();
    }

    pub fn submit(http_client: *HttpClient, message: Request.Message) !void {
        const writer = http_client.out.writer();
        const reader = http_client.in.reader();

        try http_client.message_history.append(message);

        const functions = http_client.plugins_manager.functions;

        message_buffer_fbs.reset();
        try std.json.stringify(
            Request{
                .model = http_client.config.model,
                .messages = http_client.message_history.items,
                .functions = if (functions.len == 0) null else functions,
                .stream = true,
            },
            .{ .emit_null_optional_fields = false },
            message_buffer_fbs.writer(),
        );
        const data = message_buffer_fbs.getWritten();

        if (c.curl_easy_setopt(http_client.curl, c.CURLOPT_POSTFIELDSIZE, data.len) != c.CURLE_OK) {
            return error.CurlSetoptError;
        }
        if (c.curl_easy_setopt(http_client.curl, c.CURLOPT_POSTFIELDS, data.ptr) != c.CURLE_OK) {
            return error.CurlSetoptError;
        }

        var response_handler = try ResponseHandler.init(http_client);
        defer response_handler.deinit();

        if (c.curl_easy_setopt(http_client.curl, c.CURLOPT_WRITEDATA, &response_handler) != c.CURLE_OK) {
            return error.CurlSetoptError;
        }

        const res = c.curl_easy_perform(http_client.curl);

        if (res == c.CURLE_OK) {
            const message_or_function_call = try response_handler.getMessageOrFunctionCall(http_client.allocator);
            if (message_or_function_call) |mofc| {
                switch (mofc) {
                    .message => |msg| {
                        try http_client.message_history.append(msg);
                    },
                    .function_call => |function_call| {
                        const arguments = function_call.arguments orelse "{}";

                        if (http_client.plugins_manager.function_map.get(function_call.name)) |plugin| {
                            const do_run = blk: {
                                if (plugin.auto_confirm) {
                                    break :blk true;
                                }
                                try std.fmt.format(writer, "{s}({s})?\n[y/N] ", .{ function_call.name, arguments });
                                var user_input = try root.readUserInput(reader);
                                if (std.mem.eql(u8, user_input, "y")) {
                                    break :blk true;
                                }
                                break :blk false;
                            };
                            if (do_run) {
                                const result = try plugin.invoke(function_call.name, arguments);
                                defer plugin.freeResult(result);
                                const function_message = Request.Message{
                                    .role = .function,
                                    .name = try http_client.allocator.dupe(u8, function_call.name),
                                    .content = try http_client.allocator.dupe(u8, result),
                                };
                                try http_client.submit(function_message);
                            }
                        } else {
                            std.log.err("Function not found: {s}", .{function_call.name});
                            return error.PluginFunctionNotFound;
                        }
                    },
                }
            }
        } else {
            const error_msg = std.mem.sliceTo(&curl_error_buffer, 0);
            std.log.err("[{d}] {s}", .{ res, error_msg });
            return error.CurlPerformError;
        }
    }
};
