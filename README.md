# zigdig

A small, naive DNS client library in Zig.

## What it does

- Serialize and deserialize DNS packets (RFC 1035).
- Support a subset of RDATA: SRV, MX, TXT, A, AAAA.
- Provide helpers for reading `/etc/resolv.conf`.

## What it does not do

- EDNS0.
- Support all `resolv.conf` options.
- Serialize pointer labels (it can deserialize them).
- Follow CNAME records; this is only basic serialization/deserialization.

## Requirements

- Zig 0.15.x: https://ziglang.org
- A valid `/etc/resolv.conf`
- Tested on Linux; should work on BSD

```
git clone ...
cd zigdig

zig build test
zig build install --prefix ~/.local/
```

Build modes:

```
zig build -Ddebug
zig build -Drelease
zig build -Dstrip
```

And then:

```bash
zigdig google.com a
```

With a custom resolver:

```bash
zigdig --dns 1.1.1.1 google.com a
```

Or, for the `host(1)` equivalent:

```bash
zigdig-tiny google.com
```

With a custom resolver:

```bash
zigdig-tiny --dns 1.1.1.1 google.com
```

## Using the library

### getAddressList-style api

```zig
const std = @import("std");
const dns = @import("dns");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    var allocator = gpa.allocator();

    var addresses = try dns.helpers.getAddressList("ziglang.org", 80, allocator);
    defer addresses.deinit();

    for (addresses.addrs) |address| {
        std.debug.print("we live in a society {}\n", .{address});
    }
}
```

With custom resolvers:

```zig
const std = @import("std");
const dns = @import("dns");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    var allocator = gpa.allocator();

    const resolvers = [_]dns.helpers.ResolverEndpoint{
        .{ .address = "1.1.1.1" },
        .{ .address = "8.8.8.8" },
    };

    var addresses = try dns.helpers.getAddressListWithOptions(
        "ziglang.org",
        80,
        allocator,
        .{ .resolvers = &resolvers },
    );
    defer addresses.deinit();

    for (addresses.addrs) |address| {
        std.debug.print("we live in a society {}\n", .{address});
    }
}
```

### full api

```zig
const std = @import("std");
const dns = @import("dns");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    var allocator = gpa.allocator();

    var name_buffer: [128][]const u8 = undefined;
    const name = try dns.Name.fromString("ziglang.org", &name_buffer);

    var questions = [_]dns.Question{
        .{
            .name = name,
            .typ = .A,
            .class = .IN,
        },
    };

    var packet = dns.Packet{
        .header = .{
            .id = dns.helpers.randomHeaderId(),
            .is_response = false,
            .wanted_recursion = true,
            .question_length = 1,
        },
        .questions = &questions,
        .answers = &[_]dns.Resource{},
        .nameservers = &[_]dns.Resource{},
        .additionals = &[_]dns.Resource{},
    };

    // Use a helper function to connect to a resolver in the system's
    // resolv.conf.

    const conn = try dns.helpers.connectToSystemResolver();
    defer conn.close();

    try conn.sendPacket(packet);

    // You can also do this to support any Writer:
    // const written_bytes = try packet.writeTo(some_fun_writer_goes_here);

    const reply = try conn.receiveFullPacket(allocator, 4096, .{});
    defer reply.deinit(.{});

    // You can also do this to support any Reader:
    // const incoming = try dns.helpers.parseFullPacket(some_fun_reader, allocator, .{});
    // defer incoming.deinit(.{});

    const reply_packet = reply.packet;
    std.log.info("reply: {any}", .{reply_packet});

    try std.testing.expectEqual(packet.header.id, reply_packet.header.id);
    try std.testing.expect(reply_packet.header.is_response);

    // ASSERTS that there's one A resource in the answer!!! You should verify
    // reply_packet.header.response_code to see if there are any errors.

    const resource = reply_packet.answers[0];
    var resource_data = try dns.ResourceData.fromOpaque(
        resource.typ,
        resource.opaque_rdata.?,
        .{},
    );
    defer resource_data.deinit(allocator);

    // You now have an std.net.Address to use to your heart's content.
    const ziglang_address = resource_data.A;
}

```

It is recommended to look at zigdig's source in `src/main.zig` to understand
how things tick using the library, but it boils down to three things:

- Packet generation and serialization.
- Sending/receiving (via a small shim on top of `std.os.socket`).
- Packet deserialization.
