const std = @import("std");

const network = @import("network");
const ssl = @import("bearssl");
const http = @import("h11");
const uri = @import("uri");

pub fn main() anyerror!void {
    var tester = std.testing.LeakCountAllocator.init(std.heap.c_allocator);
    defer tester.validate() catch {};
    // const allocator = std.heap.c_allocator;
    const allocator = &tester.allocator;

    const stdout = std.io.getStdOut().outStream();
    const stderr = std.io.getStdErr().outStream();
    const stdin = std.io.getStdIn().inStream();

    https.trust_anchors = ssl.TrustAnchorCollection.init(allocator);
    defer {
        https.trust_anchors.?.deinit();
        https.trust_anchors = null;
    }

    // Load default trust anchor for linux
    {
        var file = try std.fs.cwd().openFile("/etc/ssl/cert.pem", .{ .read = true, .write = false });
        defer file.close();

        const pem_text = try file.inStream().readAllAlloc(allocator, 1 << 20); // 1 MB
        defer allocator.free(pem_text);

        try https.trust_anchors.?.appendFromPEM(pem_text);
    }

    var headers = https.HeaderMap.init(allocator);
    defer headers.deinit();

    try headers.putNoClobber("Accept", "application/vnd.github.mercy-preview+json");

    var response = try https.request(allocator, "https://api.github.com/search/repositories?q=topic:zig-package", &headers);
    defer response.deinit();

    if (response.statusCode == http.StatusCode.Ok) {
        std.debug.warn("status: {}\n", .{response.statusCode});
        std.debug.warn("headers:\n", .{});
        for (response.headers) |header| {
            std.debug.warn("\t{}: {}\n", .{
                header.name,
                header.value,
            });
        }

        var parser = std.json.Parser.init(allocator, false); // don't cop strings, we keep the request
        parser.deinit();

        var tree = try parser.parse(response.body);
        defer tree.deinit();

        std.debug.warn("body:\n{}\n", .{tree});
    } else {
        std.debug.warn("Failed to execute query!\n", .{});
    }
}

const https = struct {
    pub const HeaderMap = std.StringHashMap([]const u8);

    const empty_trust_anchor_set = ssl.TrustAnchorCollection.init(std.testing.failing_allocator);

    /// This contains the TLS trust anchors used to verify servers.
    /// Using a global trust anchor set should be sufficient for most HTTPs
    /// stuff.
    pub var trust_anchors: ?ssl.TrustAnchorCollection = null;

    /// Connects a socket to a given host name.
    /// This should be moved to zig-network when windows-compatible.
    fn connectToHost(host_name: [:0]const u8, port: u16) !network.Socket {
        var temp_allocator_buffer: [5000]u8 = undefined;
        var temp_allocator = std.heap.FixedBufferAllocator.init(&temp_allocator_buffer);

        // var socket = try network.Socket.create(.ipv4, .tcp);
        // errdefer socket.close();
        const address_list = try std.net.getAddressList(&temp_allocator.allocator, host_name, port);
        defer address_list.deinit();

        return for (address_list.addrs) |addr| {
            var ep = network.EndPoint.fromSocketAddress(&addr.any, addr.getOsSockLen()) catch |err| switch (err) {
                error.UnsupportedAddressFamily => continue,
                else => return err,
            };

            var sock = try network.Socket.create(ep.address, .tcp);
            errdefer sock.close();

            sock.connect(ep) catch {
                sock.close();
                continue;
            };

            break sock;
        } else return error.CouldNotConnect;
    }

    fn requestWithStream(allocator: *std.mem.Allocator, url: uri.UriComponents, headers: HeaderMap, input: var, output: var, ssl_stream: ?*ssl.Stream) !Response {
        var http_client = http.Client.init(allocator);
        defer http_client.deinit();

        var request_headers = try allocator.alloc(http.HeaderField, headers.count());
        defer allocator.free(request_headers);

        var iter = headers.iterator();
        var i: usize = 0;
        while (iter.next()) |kv| {
            request_headers[i] =
                http.HeaderField{
                .name = kv.key,
                .value = kv.value,
            };
            i += 1;
        }
        std.debug.assert(i == request_headers.len);

        // we know that the URL was parsed from a single string, so
        // we can reassemble parts of that string again
        var target = url.path.?;
        if (url.query) |q| {
            target = target.ptr[0..((@ptrToInt(q.ptr) - @ptrToInt(target.ptr)) + q.len)];
        }
        if (url.fragment) |f| {
            target = target.ptr[0..((@ptrToInt(f.ptr) - @ptrToInt(target.ptr)) + f.len)];
        }

        var requestBytes = try http_client.send(http.Event{
            .Request = http.Request{
                .method = "GET",
                .target = target,
                .headers = request_headers,
            },
        });
        defer allocator.free(requestBytes);

        try output.writeAll(requestBytes);

        if (ssl_stream) |stream| {
            try stream.flush();
        }

        var response = Response.init(allocator);

        while (true) {
            var event: http.Event = while (true) {
                var event = http_client.nextEvent() catch |err| switch (err) {
                    http.EventError.NeedData => {
                        var responseBuffer: [4096]u8 = undefined;
                        var nBytes = try input.read(&responseBuffer);

                        // std.debug.warn("input({}) => \"{}\"\n", .{ nBytes, responseBuffer[0..nBytes] });

                        try http_client.receiveData(responseBuffer[0..nBytes]);
                        continue;
                    },
                    else => {
                        return err;
                    },
                };
                break event;
            } else unreachable;

            switch (event) {
                .Response => |*responseEvent| {
                    response.statusCode = responseEvent.statusCode;
                    response.headers = responseEvent.headers;
                },
                .Data => |*dataEvent| {
                    response.body = dataEvent.body;
                },
                .EndOfMessage => {
                    response.buffer = http_client.buffer.toOwnedSlice();
                    return response;
                },
                else => unreachable,
            }
        }
    }

    fn tryInsertHeader(headers: *HeaderMap, key: []const u8, value: []const u8) !void {
        const gop = try headers.getOrPut(key);
        if (!gop.found_existing) {
            gop.kv.value = value;
        }
    }

    pub fn request(allocator: *std.mem.Allocator, url: []const u8, headers: ?*HeaderMap) !Response {
        var parsed_url = try uri.parse(url);
        if (parsed_url.scheme == null)
            return error.InvalidUrl;
        if (parsed_url.host == null)
            return error.InvalidUrl;
        if (parsed_url.path == null)
            return error.InvalidUrl;

        var temp_allocator_buffer: [1000]u8 = undefined;
        var temp_allocator = std.heap.FixedBufferAllocator.init(&temp_allocator_buffer);

        var buffered_headers = HeaderMap.init(&temp_allocator.allocator);
        defer buffered_headers.deinit();

        const hdrmap = if (headers) |set|
            set
        else
            &buffered_headers;

        try tryInsertHeader(hdrmap, "Host", parsed_url.host.?);
        try tryInsertHeader(hdrmap, "Accept", "*/*");
        try tryInsertHeader(hdrmap, "Connection", "close");
        try tryInsertHeader(hdrmap, "User-Agent", "zpm/1.0.0");

        const Protocol = enum {
            http,
            https,
        };

        const protocol = if (std.mem.eql(u8, parsed_url.scheme.?, "https"))
            Protocol.https
        else if (std.mem.eql(u8, parsed_url.scheme.?, "http"))
            Protocol.http
        else
            return error.UnsupportedProtocol;

        const hostname_z = try std.mem.dupeZ(&temp_allocator.allocator, u8, parsed_url.host.?);

        var socket = try connectToHost(hostname_z, switch (protocol) {
            .http => @as(u16, 80),
            .https => @as(u16, 443),
        });
        defer socket.close();

        switch (protocol) {
            .https => {
                // When we have no global trust anchors, use empty ones.
                var x509 = ssl.x509.Minimal.init(if (trust_anchors) |ta| ta else empty_trust_anchor_set);

                var ssl_client = ssl.Client.init(x509.getEngine());
                ssl_client.relocate();

                try ssl_client.reset(hostname_z, false); // pass the hostname here

                // this needs to be improved by using actual zig streams
                var ssl_stream = ssl.Stream.init(ssl_client.getEngine(), socket.internal);
                defer if (ssl_stream.close()) {} else |err| {
                    std.debug.warn("error when closing the stream: {}\n", .{err});
                };

                const ssl_in = ssl_stream.inStream();
                const ssl_out = ssl_stream.outStream();

                return try requestWithStream(allocator, parsed_url, hdrmap.*, &ssl_in, &ssl_out, &ssl_stream);
            },
            .http => {
                const tcp_in = socket.inStream();
                const tcp_out = socket.outStream();

                return try requestWithStream(allocator, parsed_url, hdrmap.*, &tcp_in, &tcp_out, null);
            },
        }
    }

    pub const Response = struct {
        const Self = @This();

        allocator: *std.mem.Allocator,
        statusCode: http.StatusCode,
        headers: []http.HeaderField,
        body: []const u8,
        // `buffer` stores the bytes read from the socket.
        // This allow to keep `headers` and `body` fields accessible after
        // the client  connection is deinitialized.
        buffer: []const u8,

        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .statusCode = .ImATeapot,
                .headers = &[_]http.HeaderField{},
                .body = &[_]u8{},
                .buffer = &[_]u8{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.headers);
            self.allocator.free(self.buffer);
        }
    };
};
