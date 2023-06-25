const std = @import("std");

pub const Credentials = struct {
    arena: std.heap.ArenaAllocator,
    openai_api_key: []const u8,
    openai_organization_id: ?[]const u8,

    pub fn parse(allocator: std.mem.Allocator, home_path: []const u8) !Credentials {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();
        errdefer arena.deinit();

        const file_path = try std.fs.path.join(arena_allocator, &.{ home_path, ".dial/credentials.json" });

        const file = try std.fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const json_string = try file.readToEndAlloc(arena_allocator, std.math.maxInt(usize));

        const parsed = try std.json.parseFromSlice(
            struct {
                openai_api_key: []const u8,
                openai_organization_id: ?[]const u8 = null,
            },
            arena_allocator,
            json_string,
            .{},
        );
        defer parsed.deinit();

        return .{
            .arena = arena,
            .openai_api_key = parsed.value.openai_api_key,
            .openai_organization_id = parsed.value.openai_organization_id,
        };
    }

    pub fn deinit(credentials: Credentials) void {
        credentials.arena.deinit();
    }
};
