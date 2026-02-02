const std = @import("std");
const dns = @import("lib.zig");

fn parsePort(port_text: []const u8) !u16 {
    if (port_text.len == 0) return error.InvalidPort;
    return std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
}

pub fn parseResolverEndpoint(input: []const u8) !dns.helpers.ResolverEndpoint {
    if (input.len == 0) return error.InvalidResolver;

    if (input[0] == '[') {
        const end = std.mem.indexOfScalar(u8, input, ']') orelse return error.InvalidResolver;
        const addr = input[1..end];
        if (addr.len == 0) return error.InvalidResolver;

        if (end + 1 == input.len) {
            return .{ .address = addr, .port = null };
        }
        if (input[end + 1] != ':') return error.InvalidResolver;

        const port = try parsePort(input[end + 2 ..]);
        return .{ .address = addr, .port = port };
    }

    const colon_count = std.mem.count(u8, input, ":");
    if (colon_count > 1) {
        return .{ .address = input, .port = null };
    }
    if (colon_count == 1) {
        const idx = std.mem.indexOfScalar(u8, input, ':') orelse return error.InvalidResolver;
        const addr = input[0..idx];
        if (addr.len == 0) return error.InvalidResolver;
        const port = try parsePort(input[idx + 1 ..]);
        return .{ .address = addr, .port = port };
    }

    return .{ .address = input, .port = null };
}
