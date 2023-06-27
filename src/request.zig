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
    };

    pub const Function = struct {
        name: []const u8,
        description: []const u8,
        parameters: std.json.Value,
    };

    pub const FunctionCall = struct {
        name: []const u8,
        arguments: ?[]const u8,
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
    };

    fn deinit(request: Request, allocator: std.mem.Allocator) void {
        allocator.free(request.messages);
        if (request.functions) |fns| {
            allocator.free(fns);
        }
    }
};

const FunctionCallRequestStrategy = union(enum) {
    pub const Strat = enum { none, auto };

    strat: Strat,
    name: []const u8,

    const strat_map = std.ComptimeStringMap(Strat, .{.{ "none", .none, "auto", .auto }});

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
