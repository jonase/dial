const std = @import("std");
const Credentials = @import("Credentials.zig");
const CredentialsParser = @This();

allocator: std.mem.Allocator,
parsed: std.json.Parsed(Credentials),
source: []const u8,
credentials: Credentials,

pub fn parse(allocator: std.mem.Allocator, home_path: []const u8) !CredentialsParser {
    const path = try std.fs.path.join(allocator, &.{ home_path, ".dial/credentials.json" });
    defer allocator.free(path);

    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    var parsed = try std.json.parseFromSlice(Credentials, allocator, source, .{});

    return CredentialsParser{
        .allocator = allocator,
        .parsed = parsed,
        .source = source,
        .credentials = parsed.value,
    };
}

pub fn deinit(credentials_parser: *CredentialsParser) void {
    credentials_parser.allocator.free(credentials_parser.source);
    credentials_parser.parsed.deinit();
}
