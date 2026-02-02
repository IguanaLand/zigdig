const std = @import("std");
const dns = @import("lib.zig");
const pkt = @import("packet.zig");
const Type = dns.ResourceType;

const logger = std.log.scoped(.dns_rdata);

pub const SOAData = struct {
    mname: ?dns.Name,
    rname: ?dns.Name,
    serial: u32,
    refresh: u32,
    retry: u32,
    expire: u32,
    minimum: u32,
};

pub const MXData = struct {
    preference: u16,
    exchange: ?dns.Name,
};

pub const SRVData = struct {
    priority: u16,
    weight: u16,
    port: u16,
    target: ?dns.Name,
};

fn maybe_read_resource_name(
    reader: anytype,
    options: ResourceData.ParseOptions,
) !?dns.Name {
    return switch (options.name_provider) {
        .none => null,
        .raw => |allocator| try dns.Name.readFrom(reader, .{ .allocator = allocator }),
        .full => |name_pool| blk: {
            const name = try dns.Name.readFrom(
                reader,
                .{ .allocator = name_pool.allocator },
            );
            break :blk try name_pool.transmuteName(name.?);
        },
    };
}

/// Common representations of DNS' Resource Data.
pub const ResourceData = union(Type) {
    A: std.net.Address,

    NS: ?dns.Name,
    MD: ?dns.Name,
    MF: ?dns.Name,
    CNAME: ?dns.Name,
    SOA: SOAData,

    MB: ?dns.Name,
    MG: ?dns.Name,
    MR: ?dns.Name,

    // ????
    NULL: void,

    // TODO WKS bit map
    WKS: struct {
        addr: u32,
        proto: u8,
        // how to define bit map? align(8)?
    },
    PTR: ?dns.Name,

    // TODO replace []const u8 by Name?
    HINFO: struct {
        cpu: []const u8,
        os: []const u8,
    },
    MINFO: struct {
        rmailbx: ?dns.Name,
        emailbx: ?dns.Name,
    },
    MX: MXData,
    TXT: ?[]const u8,
    AAAA: std.net.Address,
    SRV: SRVData,
    OPT: void, // EDNS0 is not implemented

    const Self = @This();

    fn format_address_no_port(addr: std.net.Address, writer: anytype) !void {
        var buffer: [128]u8 = undefined;
        var addr_writer = std.Io.Writer.fixed(&buffer);
        try addr.format(&addr_writer);
        const full = addr_writer.buffered();
        if (full.len == 0) return;

        if (full[0] == '[') {
            if (std.mem.indexOfScalar(u8, full, ']')) |idx| {
                try writer.writeAll(full[1..idx]);
                return;
            }
        }

        if (std.mem.lastIndexOfScalar(u8, full, ':')) |idx| {
            try writer.writeAll(full[0..idx]);
            return;
        }

        try writer.writeAll(full);
    }

    /// Return the byte size of the network representation.
    pub fn networkSize(self: Self) !usize {
        return switch (self) {
            .A => 4,
            .AAAA => 16,
            .NS, .MD, .MF, .MB, .MG, .MR, .CNAME, .PTR => |maybe_name| blk: {
                const name = maybe_name orelse return error.MissingData;
                break :blk name.networkSize();
            },
            .SOA => |soa| blk: {
                const mname = soa.mname orelse return error.MissingData;
                const rname = soa.rname orelse return error.MissingData;
                break :blk mname.networkSize() + rname.networkSize() + (5 * @sizeOf(u32));
            },
            .MX => |mx| blk: {
                const exchange = mx.exchange orelse return error.MissingData;
                break :blk @sizeOf(u16) + exchange.networkSize();
            },
            .SRV => |srv| blk: {
                const target = srv.target orelse return error.MissingData;
                break :blk (3 * @sizeOf(u16)) + target.networkSize();
            },
            .TXT => |maybe_text| blk: {
                const text = maybe_text orelse return error.MissingData;
                break :blk @sizeOf(u8) + text.len;
            },

            else => return error.UnsupportedResourceType,
        };
    }

    /// Format the RData into a human-readable form of it.
    ///
    /// For example, a resource data of type A would be
    /// formatted to its representing IPv4 address.
    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .A, .AAAA => |addr| return format_address_no_port(addr, writer),

            .NS, .MD, .MF, .MB, .MG, .MR, .CNAME, .PTR => |name| return writer.print("{?f}", .{name}),

            .SOA => |soa| return writer.print("{?f} {?f} {d} {d} {d} {d} {d}", .{
                soa.mname,
                soa.rname,
                soa.serial,
                soa.refresh,
                soa.retry,
                soa.expire,
                soa.minimum,
            }),

            .MX => |mx| return writer.print("{d} {?f}", .{ mx.preference, mx.exchange }),
            .SRV => |srv| return writer.print("{d} {d} {d} {?f}", .{
                srv.priority,
                srv.weight,
                srv.port,
                srv.target,
            }),

            .TXT => |text| return writer.print("{?s}", .{text}),
            else => return writer.print("TODO support {s}", .{@tagName(self)}),
        }
    }

    /// Write the network representation of this resource data.
    pub fn writeTo(self: Self, writer: anytype) !usize {
        return switch (self) {
            .A => |addr| blk: {
                try writer.writeInt(u32, addr.in.sa.addr, .big);
                break :blk @sizeOf(@TypeOf(addr.in.sa.addr));
            },
            .AAAA => |addr| try writer.write(&addr.in6.sa.addr),

            .NS, .MD, .MF, .MB, .MG, .MR, .CNAME, .PTR => |maybe_name| blk: {
                const name = maybe_name orelse return error.MissingData;
                break :blk try name.writeTo(writer);
            },

            .SOA => |soa_data| blk: {
                const mname = soa_data.mname orelse return error.MissingData;
                const rname = soa_data.rname orelse return error.MissingData;
                const mname_size = try mname.writeTo(writer);
                const rname_size = try rname.writeTo(writer);

                try writer.writeInt(u32, soa_data.serial, .big);
                try writer.writeInt(u32, soa_data.refresh, .big);
                try writer.writeInt(u32, soa_data.retry, .big);
                try writer.writeInt(u32, soa_data.expire, .big);
                try writer.writeInt(u32, soa_data.minimum, .big);

                break :blk mname_size + rname_size + (5 * @sizeOf(u32));
            },

            .MX => |mxdata| blk: {
                const exchange = mxdata.exchange orelse return error.MissingData;
                try writer.writeInt(u16, mxdata.preference, .big);
                const exchange_size = try exchange.writeTo(writer);
                break :blk @sizeOf(@TypeOf(mxdata.preference)) + exchange_size;
            },

            .SRV => |srv| {
                const target = srv.target orelse return error.MissingData;
                try writer.writeInt(u16, srv.priority, .big);
                try writer.writeInt(u16, srv.weight, .big);
                try writer.writeInt(u16, srv.port, .big);

                const target_size = try target.writeTo(writer);
                return target_size + (3 * @sizeOf(u16));
            },

            .TXT => |maybe_text| blk: {
                const text = maybe_text orelse return error.MissingData;
                if (text.len > std.math.maxInt(u8)) return error.Overflow;
                try writer.writeByte(@as(u8, @intCast(text.len)));
                const written = try writer.write(text);
                break :blk 1 + written;
            },

            else => return error.UnsupportedResourceType,
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        switch (self) {
            .NS, .MD, .MF, .MB, .MG, .MR, .CNAME, .PTR => |maybe_name| if (maybe_name) |name| name.deinit(allocator),
            .SOA => |soa_data| {
                if (soa_data.mname) |name| name.deinit(allocator);
                if (soa_data.rname) |name| name.deinit(allocator);
            },
            .MX => |mxdata| if (mxdata.exchange) |name| name.deinit(allocator),
            .SRV => |srv| if (srv.target) |name| name.deinit(allocator),
            .TXT => |maybe_data| if (maybe_data) |data| allocator.free(data),
            else => {},
        }
    }

    pub const Opaque = struct {
        data: []const u8,
        current_byte_count: usize,
    };

    pub const NameProvider = union(enum) {
        none: void,
        raw: std.mem.Allocator,
        full: *dns.NamePool,
    };

    pub const ParseOptions = struct {
        name_provider: NameProvider = NameProvider.none,
        allocator: ?std.mem.Allocator = null,
    };

    /// Deserialize a given opaque resource data.
    ///
    /// Call deinit() with the same allocator.
    pub fn fromOpaque(
        resource_type: dns.ResourceType,
        opaque_resource_data: Opaque,
        options: ParseOptions,
    ) !ResourceData {
        const underlying_reader = std.Io.Reader.fixed(opaque_resource_data.data);

        // important to keep track of that rdata's position in the packet
        // as rdata could point to other rdata.
        var parser_ctx = dns.ParserContext{
            .current_byte_count = opaque_resource_data.current_byte_count,
        };

        const WrapperR = dns.parserlib.WrapperReader(std.Io.Reader);
        var wrapper_reader = WrapperR{
            .underlying_reader = underlying_reader,
            .ctx = &parser_ctx,
        };
        var reader = wrapper_reader.reader();

        return switch (resource_type) {
            .A => blk: {
                var ip4addr: [4]u8 = undefined;
                _ = try reader.read(&ip4addr);
                break :blk ResourceData{
                    .A = std.net.Address.initIp4(ip4addr, 0),
                };
            },
            .AAAA => blk: {
                var ip6_addr: [16]u8 = undefined;
                _ = try reader.read(&ip6_addr);
                break :blk ResourceData{
                    .AAAA = std.net.Address.initIp6(ip6_addr, 0, 0, 0),
                };
            },

            .NS => ResourceData{ .NS = try maybe_read_resource_name(reader, options) },
            .CNAME => ResourceData{ .CNAME = try maybe_read_resource_name(reader, options) },
            .PTR => ResourceData{ .PTR = try maybe_read_resource_name(reader, options) },
            .MD => ResourceData{ .MD = try maybe_read_resource_name(reader, options) },
            .MF => ResourceData{ .MF = try maybe_read_resource_name(reader, options) },

            .MX => blk: {
                break :blk ResourceData{
                    .MX = MXData{
                        .preference = try reader.readInt(u16, .big),
                        .exchange = try maybe_read_resource_name(reader, options),
                    },
                };
            },

            .SOA => blk: {
                const mname = try maybe_read_resource_name(reader, options);
                const rname = try maybe_read_resource_name(reader, options);
                const serial = try reader.readInt(u32, .big);
                const refresh = try reader.readInt(u32, .big);
                const retry = try reader.readInt(u32, .big);
                const expire = try reader.readInt(u32, .big);
                const minimum = try reader.readInt(u32, .big);

                break :blk ResourceData{
                    .SOA = SOAData{
                        .mname = mname,
                        .rname = rname,
                        .serial = serial,
                        .refresh = refresh,
                        .retry = retry,
                        .expire = expire,
                        .minimum = minimum,
                    },
                };
            },
            .SRV => blk: {
                const priority = try reader.readInt(u16, .big);
                const weight = try reader.readInt(u16, .big);
                const port = try reader.readInt(u16, .big);
                const target = try maybe_read_resource_name(reader, options);
                break :blk ResourceData{
                    .SRV = .{
                        .priority = priority,
                        .weight = weight,
                        .port = port,
                        .target = target,
                    },
                };
            },
            .TXT => blk: {
                const length = try reader.readInt(u8, .big);
                if (length > 256) return error.Overflow;

                if (options.allocator) |allocator| {
                    const text = try allocator.alloc(u8, length);
                    _ = try reader.read(text);

                    break :blk ResourceData{ .TXT = text };
                } else {
                    try reader.skipBytes(length, .{});
                    break :blk ResourceData{ .TXT = null };
                }
            },

            else => {
                logger.warn("unexpected rdata: {any}\n", .{resource_type});
                return error.UnknownResourceType;
            },
        };
    }
};
