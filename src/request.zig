const std = @import("std");

pub const Request = struct {

    // ID of the model to use. See the model endpoint compatibility table for
    // details on which models work with the Chat API.
    model: []const u8,

    // A list of messages comprising the conversation so far.
    messages: []const Message,

    // A list of functions the model may generate JSON inputs for.
    functions: ?[]const Function = null,

    // Controls how the model responds to function calls. "none" means the
    // model does not call a function, and responds to the end-user. "auto"
    // means the model can pick between an end-user or calling a function.
    // Specifying a particular function via {"name":\ "my_function"} forces
    // the model to call that function. "none" is the default when no functions
    // are present. "auto" is the default if functions are present.
    function_call: ?FunctionCallRequestStrategy = null,

    // If set, partial message deltas will be sent, like in ChatGPT. Tokens
    // will be sent as data-only server-sent events as they become available,
    // with the stream terminated by a data: [DONE] message.
    stream: ?bool = null,

    pub const Message = struct {

        // The role of the messages author. One of system, user, assistant, or
        // function.
        role: Role,

        // The contents of the message. content is required for all messages except
        // assistant messages with function calls.
        content: ?[]const u8 = null,

        // The name of the author of this message. name is required if role is
        // function, and it should be the name of the function whose response is in
        // the content. May contain a-z, A-Z, 0-9, and underscores, with a maximum
        // length of 64 characters.
        name: ?[]const u8 = null,

        // The name and arguments of a function that should be called, as generated
        // by the model.
        function_call: ?FunctionCall = null,

        fn fromJson(value: std.json.Value) !Message {
            switch (value) {
                .object => |object| {
                    const role = try Role.fromJson(object.get("role") orelse return error.ParseError);
                    const content = try parseStringAllowNull(object.get("content"));
                    const name = try parseStringAllowNull(object.get("name"));
                    const function_call = try FunctionCall.fromJson(object.get("function_call"));

                    return .{
                        .role = role,
                        .content = content,
                        .name = name,
                        .function_call = function_call,
                    };
                },
                else => return error.ParseError,
            }
        }
    };

    pub const Function = struct {
        name: []const u8,
        description: ?[]const u8,
        parameters: ?std.json.Value,

        fn fromJson(value: std.json.Value) !Function {
            switch (value) {
                .object => |object| {
                    const name = try parseString(object.get("name") orelse return error.ParseError);
                    const description = try parseStringAllowNull(object.get("description"));
                    const parameters = object.get("parameters");
                    return .{
                        .name = name,
                        .description = description,
                        .parameters = parameters,
                    };
                },
                else => return error.ParseError,
            }
        }
    };

    pub const FunctionCall = struct {
        name: []const u8,
        arguments: ?[]const u8,

        fn fromJson(value: ?std.json.Value) !?FunctionCall {
            if (value) |val| {
                switch (val) {
                    .object => |object| {
                        const name = try parseString(object.get("name") orelse return error.ParseError);
                        const arguments = try parseStringAllowNull(object.get("arguments"));
                        return .{
                            .name = name,
                            .arguments = arguments,
                        };
                    },
                    .null => return null,
                    else => return error.ParseError,
                }
            } else {
                return null;
            }
        }
    };

    pub const Role = enum {
        system,
        user,
        assistant,
        function,

        const role_map = std.ComptimeStringMap(Role, .{
            .{ "system", .system },
            .{ "user", .user },
            .{ "assistant", .assistant },
            .{ "function", .function },
        });

        pub fn jsonStringify(
            role: @This(),
            options: std.json.StringifyOptions,
            out_stream: anytype,
        ) !void {
            try std.json.encodeJsonString(@tagName(role), options, out_stream);
        }

        fn fromJson(value: std.json.Value) !Role {
            switch (value) {
                .string => |string| {
                    return role_map.get(string) orelse error.ParseError;
                },
                else => return error.ParseError,
            }
        }
    };

    pub fn parseFunctions(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const Request.Function {
        if (value) |val| {
            switch (val) {
                .array => |array| {
                    var array_list = std.ArrayList(Request.Function).init(allocator);
                    defer array_list.deinit();

                    for (array.items) |item| {
                        try array_list.append(try Request.Function.fromJson(item));
                    }
                    return try array_list.toOwnedSlice();
                },
                .null => return null,
                else => return error.ParseError,
            }
        } else {
            return null;
        }
    }

    fn deinit(request: Request, allocator: std.mem.Allocator) void {
        allocator.free(request.messages);
        if (request.functions) |fns| {
            allocator.free(fns);
        }
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Request {
        switch (value) {
            .object => |object| {
                const model = try parseString(object.get("model") orelse return error.ParseError);
                const messages = try parseMessages(allocator, object.get("messages") orelse return error.ParseError);
                const functions = try parseFunctions(allocator, object.get("functions"));
                const function_call = try FunctionCallRequestStrategy.fromJson(object.get("function_call"));
                const stream = try parseBoolAllowNull(object.get("stream"));

                return .{
                    .model = model,
                    .messages = messages,
                    .functions = functions,
                    .function_call = function_call,
                    .stream = stream,
                };
            },
            else => return error.ParseError,
        }
    }
};

// TODO Better naming,
const FunctionCallRequestStrategy = union(enum) {
    pub const Strat = enum { none, auto };

    strat: Strat,
    name: []const u8,

    const strat_map = std.ComptimeStringMap(Strat, .{.{ "none", .none, "auto", .auto }});

    pub fn fromJson(value: ?std.json.Value) !?FunctionCallRequestStrategy {
        if (value) |val| {
            switch (val) {
                .null => return null,
                .string => |string| {
                    const strat = strat_map.get(string) orelse return error.ParseError;
                    return .{ .strat = strat };
                },
                .object => |object| {
                    const name = try parseString(object.get("name") orelse return error.ParseError);
                    return .{ .name = name };
                },
                else => return error.ParseError,
            }
        } else {
            return null;
        }
    }

    pub fn jsonStringify(
        function_call_request_strategy: @This(),
        options: std.json.StringifyOptions,
        out_stream: anytype,
    ) !void {
        switch (function_call_request_strategy) {
            .strat => |inner| {
                try std.json.encodeJsonString(@tagName(inner), options, out_stream);
            },
            .name => |inner| {
                try out_stream.writeByte('{');
                try std.json.encodeJsonString("name", options, out_stream);
                try out_stream.writeByte(':');
                try std.json.encodeJsonString(inner, options, out_stream);
                try out_stream.writeByte('}');
            },
        }
    }
};

fn parseMessages(allocator: std.mem.Allocator, value: std.json.Value) ![]const Request.Message {
    switch (value) {
        .array => |array| {
            var array_list = std.ArrayList(Request.Message).init(allocator);
            defer array_list.deinit();

            for (array.items) |val| {
                try array_list.append(try Request.Message.fromJson(val));
            }
            return try array_list.toOwnedSlice();
        },
        else => return error.parseError,
    }
}

fn parseString(value: std.json.Value) ![]const u8 {
    switch (value) {
        .string => |string| return string,
        else => return error.ParseError,
    }
}

fn parseStringAllowNull(value: ?std.json.Value) !?[]const u8 {
    if (value) |val| {
        switch (val) {
            .null => return null,
            .string => |string| return string,
            else => return error.ParseError,
        }
    } else {
        return null;
    }
}

fn parseBoolAllowNull(value: ?std.json.Value) !?bool {
    if (value) |val| {
        switch (val) {
            .bool => |boolean| return boolean,
            .null => return null,
            else => return error.ParseError,
        }
    } else {
        return null;
    }
}
