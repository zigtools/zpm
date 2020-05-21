const std = @import("std");

const network = @import("network");
const ssl = @import("bearssl");
const http = @import("h11");

pub fn main() anyerror!void {
    const allocator = std.heap.c_allocator;

    const stdout = std.io.getStdOut().outStream();
    const stderr = std.io.getStdErr().outStream();
    const stdin = std.io.getStdIn().inStream();

    var trust_anchors = ssl.TrustAnchorCollection.init(allocator);
    defer trust_anchors.deinit();

    // Load default trust anchor for linux
    {
        var file = try std.fs.cwd().openFile("/etc/ssl/cert.pem", .{ .read = true, .write = false });
        defer file.close();

        const pem_text = try file.inStream().readAllAlloc(allocator, 1 << 20); // 1 MB
        defer allocator.free(pem_text);

        try trust_anchors.appendFromPEM(pem_text);
    }

    var socket = try network.Socket.create(.ipv4, .tcp);
    defer socket.close();

    try socket.connect(network.EndPoint{
        .address = network.Address{
            // this is mq32.de
            .ipv4 = .{ .value = .{ 81, 169, 136, 213 } },
        },
        .port = 443,
    });

    var x509 = ssl.x509.Minimal.init(trust_anchors);

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

    var http_client = http.Client.init(allocator);
    defer http_client.deinit();

    var request_headers = [_]http.HeaderField{
        http.HeaderField{ .name = "Host", .value = "mq32.de" },
        http.HeaderField{ .name = "Accept", .value = "*/*" },
        http.HeaderField{ .name = "Connection", .value = "close" },
        // h11.HeaderField{ .name = "Accept", .value = "application/vnd.github.mercy-preview+json" },
        // h11.HeaderField{ .name = "User-Agent", .value = "h11/0.1.0" },
    };

    var request = http.Request{
        .method = "GET",
        .target = "/",
        .headers = &request_headers,
    };

    var requestBytes = try http_client.send(http.Event{
        .Request = request,
    });
    defer allocator.free(requestBytes);

    try ssl_out.writeAll(requestBytes);
    try ssl_stream.flush();

    const Response = struct {
        statusCode: http.StatusCode,
        headers: []http.HeaderField,
        body: []const u8,

        // `buffer` stores the bytes read from the socket.
        // This allow to keep `headers` and `body` fields accessible after
        // the client  connection is deinitialized.
        buffer: []const u8,
    };

    var response = Response{
        .statusCode = undefined,
        .headers = undefined,
        .body = undefined,
        .buffer = undefined,
    };

    while (true) {
        var event: http.Event = while (true) {
            var event = http_client.nextEvent() catch |err| switch (err) {
                http.EventError.NeedData => {
                    var responseBuffer: [4096]u8 = undefined;
                    var nBytes = try ssl_in.read(&responseBuffer);
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
                break;
            },
            else => unreachable,
        }
    }
    defer allocator.free(response.buffer);

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
