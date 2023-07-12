id: []const u8,
object: []const u8,
created: u64,
model: []const u8,
choices: []const Choice,

const Delta = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    function_call: ?FunctionCall = null,
};

const FunctionCall = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8,
};

const Choice = struct {
    delta: Delta,
    index: usize,
    finish_reason: ?[]const u8,
};
