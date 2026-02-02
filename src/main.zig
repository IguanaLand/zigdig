const std = @import("std");
const builtin = @import("builtin");
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

fn formatAddress(address: std.net.Address, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try address.format(&writer);
    return writer.buffered();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    if (builtin.os.tag == .windows) {
        const debug = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "DEBUG");
        defer allocator.free(debug);

        const debug_expected = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "1");
        defer allocator.free(debug_expected);

        if (std.mem.eql(u16, std.process.getenvW(debug) orelse &[_]u16{0}, debug_expected)) current_log_level = .debug;
    } else {
        if (std.mem.eql(u8, std.posix.getenv("DEBUG") orelse "", "1")) current_log_level = .debug;
    }

    var args_it = try std.process.argsWithAllocator(allocator);
    defer args_it.deinit();
    _ = args_it.skip();

    var resolvers = std.ArrayList(dns.helpers.ResolverEndpoint).empty;
    defer resolvers.deinit(allocator);

    var name_arg: ?[]const u8 = null;
    var qtype_arg: ?[]const u8 = null;

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
        if (qtype_arg == null) {
            qtype_arg = arg;
            continue;
        }

        logger.warn("too many arguments", .{});
        return error.InvalidArgs;
    }

    const name_string = name_arg orelse {
        logger.warn("no name provided", .{});
        return error.InvalidArgs;
    };

    const qtype_str = qtype_arg orelse {
        logger.warn("no qtype provided", .{});
        return error.InvalidArgs;
    };

    const qtype = dns.ResourceType.fromString(qtype_str) catch |err| switch (err) {
        error.InvalidResourceType => {
            logger.warn("invalid query type provided", .{});
            return error.InvalidArgs;
        },
    };

    var name_buffer: [128][]const u8 = undefined;
    const name = try dns.Name.fromString(name_string, &name_buffer);

    var questions = [_]dns.Question{
        .{
            .name = name,
            .typ = qtype,
            .class = .IN,
        },
    };

    var empty = [0]dns.Resource{};

    // create question packet
    var packet = dns.Packet{
        .header = .{
            .id = dns.helpers.randomHeaderId(),
            .is_response = false,
            .wanted_recursion = true,
            .question_length = 1,
        },
        .questions = &questions,
        .answers = &empty,
        .nameservers = &empty,
        .additionals = &empty,
    };

    logger.debug("packet: {any}", .{packet});

    const resolver_override = if (resolvers.items.len > 0) resolvers.items else null;
    const conn = if (resolver_override) |list|
        try dns.helpers.connectToResolver(list[0].address, list[0].port)
    else if (builtin.os.tag == .windows)
        try dns.helpers.connectToResolver("8.8.8.8", null)
    else
        try dns.helpers.connectToSystemResolver();
    defer conn.close();

    var addr_buffer: [128]u8 = undefined;
    const addr_str = try formatAddress(conn.address, &addr_buffer);
    logger.info("selected nameserver: {s}\n", .{addr_str});
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer = std.fs.File.stdout().writer(stdout_buffer[0..]);
    defer stdout_file_writer.interface.flush() catch {};
    const stdout = &stdout_file_writer.interface;

    // print out our same question as a zone file for debugging purposes
    try dns.helpers.printAsZoneFile(&packet, undefined, stdout);

    try conn.sendPacket(packet);

    // as we need Names inside the NamePool to live beyond the call to
    // receiveFullPacket (since we need to deserialize names in RDATA)
    // we must take ownership of them and deinit ourselves
    var name_pool = dns.NamePool.init(allocator);
    defer name_pool.deinitWithNames();

    const reply = try conn.receiveFullPacket(
        allocator,
        4096,
        .{ .name_pool = &name_pool },
    );
    defer reply.deinit(.{ .names = false });

    const reply_packet = reply.packet;
    logger.debug("reply: {any}", .{reply_packet});

    try std.testing.expectEqual(packet.header.id, reply_packet.header.id);
    try std.testing.expect(reply_packet.header.is_response);

    try dns.helpers.printAsZoneFile(reply_packet, &name_pool, stdout);
}
