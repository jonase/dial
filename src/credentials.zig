pub const Credentials = struct {
    openai_api_key: []const u8,
    openai_organization_id: ?[]const u8 = null,
};
