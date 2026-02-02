const std = @import("std");
const dns = @import("lib.zig");
const cli_helpers = @import("cli_helpers.zig");

const logger = std.log.scoped(.zigdig_main);
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = logfn,
};

pub var current_log_level: std.log.Level = .info;

fn logfn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(@import("root").current_log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

fn formatAddressNoPort(address: std.net.Address, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try address.format(&writer);
    const full = writer.buffered();
    if (full.len == 0) return full;

    if (full[0] == '[') {
        if (std.mem.indexOfScalar(u8, full, ']')) |idx| {
            return full[1..idx];
        }
    }

    if (std.mem.lastIndexOfScalar(u8, full, ':')) |idx| {
        return full[0..idx];
    }

    return full;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    const debug = std.process.getEnvVarOwned(allocator, "DEBUG") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(debug);
    if (std.mem.eql(u8, debug, "1")) current_log_level = .debug;

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.skip();

    var resolvers = std.ArrayList(dns.helpers.ResolverEndpoint).empty;
    defer resolvers.deinit(allocator);

    var name_arg: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dns") or std.mem.eql(u8, arg, "-s")) {
            const resolver_arg = args_it.next() orelse {
                logger.warn("missing resolver after {s}", .{arg});
                return error.InvalidArgs;
            };
            const endpoint = cli_helpers.parseResolverEndpoint(resolver_arg) catch {
                logger.warn("invalid resolver: {s}", .{resolver_arg});
                return error.InvalidArgs;
            };
            try resolvers.append(allocator, endpoint);
            continue;
        }

        if (name_arg == null) {
            name_arg = arg;
            continue;
        }

        logger.warn("too many arguments", .{});
        return error.InvalidArgs;
    }

    const name_string = name_arg orelse {
        logger.warn("no name provided", .{});
        return error.InvalidArgs;
    };

    const resolver_override = if (resolvers.items.len > 0) resolvers.items else null;
    var addrs = try dns.helpers.getAddressListWithOptions(
        name_string,
        80,
        allocator,
        .{ .resolvers = resolver_override },
    );
    defer addrs.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer = std.fs.File.stdout().writer(stdout_buffer[0..]);
    defer stdout_file_writer.interface.flush() catch {};
    var stdout = &stdout_file_writer.interface;

    for (addrs.addrs) |addr| {
        var addr_buffer: [128]u8 = undefined;
        const addr_str = try formatAddressNoPort(addr, &addr_buffer);
        try stdout.print("{s} has address {s}\n", .{ name_string, addr_str });
    }
}
