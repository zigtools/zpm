const std = @import("std");

const network = @import("network");
const ssl = @import("bearssl");
const http = @import("h11");
const uri = @import("uri");

pub fn main() anyerror!void {
    const allocator = std.heap.c_allocator;

    const stdout = std.io.getStdOut().outStream();
    const stderr = std.io.getStdErr().outStream();
    const stdin = std.io.getStdIn().inStream();

    https.trust_anchors = ssl.TrustAnchorCollection.init(allocator);
    defer https.trust_anchors.?.deinit();

    // Load default trust anchor for linux
    {
        var file = try std.fs.cwd().openFile("/etc/ssl/cert.pem", .{ .read = true, .write = false });
        defer file.close();

        const pem_text = try file.inStream().readAllAlloc(allocator, 1 << 20); // 1 MB
        defer allocator.free(pem_text);

        try https.trust_anchors.?.appendFromPEM(pem_text);
    }

    var response = try https.request(allocator, "http://mq32.de/");
    defer response.deinit();

    std.debug.warn("status: {}\n", .{response.statusCode});
    std.debug.warn("headers:\n", .{});
    for (response.headers) |header| {
        std.debug.warn("\t{}: {}\n", .{
            header.name,
            header.value,
        });
    }
    std.debug.warn("body:\n{}\n", .{response.body});
}

const https = struct {
    const empty_trust_anchor_set = ssl.TrustAnchorCollection.init(std.testing.failing_allocator);

    /// This contains the TLS trust anchors used to verify servers.
    /// Using a global trust anchor set should be sufficient for most HTTPs
    /// stuff.
    pub var trust_anchors: ?ssl.TrustAnchorCollection = null;

    /// Connects a socket to a given host name.
    /// This should be moved to zig-network when windows-compatible.
    fn connectToHost(host_name: []const u8, port: u16) !network.Socket {
        var temp_allocator_buffer: [5000]u8 = undefined;
        var temp_allocator = std.heap.FixedBufferAllocator.init(&temp_allocator_buffer);

        const hostname_z = try std.mem.dupeZ(&temp_allocator.allocator, u8, host_name);

        // var socket = try network.Socket.create(.ipv4, .tcp);
        // errdefer socket.close();
        const address_list = try std.net.getAddressList(&temp_allocator.allocator, hostname_z, port);
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

    fn requestWithStream(allocator: *std.mem.Allocator, url: uri.UriComponents, input: var, output: var, ssl_stream: ?*ssl.Stream) !Response {
        var http_client = http.Client.init(allocator);
        defer http_client.deinit();

        var request_headers = [_]http.HeaderField{
            http.HeaderField{ .name = "Host", .value = url.host.? },
            http.HeaderField{ .name = "Accept", .value = "*/*" },
            http.HeaderField{ .name = "Connection", .value = "close" },
            // h11.HeaderField{ .name = "Accept", .value = "application/vnd.github.mercy-preview+json" },
            // h11.HeaderField{ .name = "User-Agent", .value = "h11/0.1.0" },
        };

        var requestBytes = try http_client.send(http.Event{
            .Request = http.Request{
                .method = "GET",
                .target = url.path.?,
                .headers = &request_headers,
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

    pub fn request(allocator: *std.mem.Allocator, url: []const u8) !Response {
        var parsed_url = try uri.parse(url);
        if (parsed_url.scheme == null)
            return error.InvalidUrl;
        if (parsed_url.host == null)
            return error.InvalidUrl;
        if (parsed_url.path == null)
            return error.InvalidUrl;

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

        var socket = try connectToHost(parsed_url.host.?, switch (protocol) {
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

                try ssl_client.reset("mq32.de", false); // pass the hostname here

                // this needs to be improved by using actual zig streams
                var ssl_stream = ssl.Stream.init(ssl_client.getEngine(), socket.internal);
                defer if (ssl_stream.close()) {} else |err| {
                    std.debug.warn("error when closing the stream: {}\n", .{err});
                };

                const ssl_in = ssl_stream.inStream();
                const ssl_out = ssl_stream.outStream();

                return try requestWithStream(allocator, parsed_url, &ssl_in, &ssl_out, &ssl_stream);
            },
            .http => {
                const tcp_in = socket.inStream();
                const tcp_out = socket.outStream();

                return try requestWithStream(allocator, parsed_url, &tcp_in, &tcp_out, null);
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
