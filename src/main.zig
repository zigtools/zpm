const std = @import("std");

const network = @import("network");
const ssl = @import("bearssl");

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

    try ssl_out.writeAll(
        \\GET /index.htm HTTP/1.0
        \\Host: mq32.de
        \\
        \\
    );
    try ssl_stream.flush();

    var work_buf: [2048]u8 = undefined;

    while (true) {
        const size = try ssl_in.read(&work_buf);
        if (size == 0)
            break;
        try stdout.writeAll(work_buf[0..size]);
    }
}
