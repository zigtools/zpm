const std = @import("std");

const network = @import("network");
const ssl = @import("bearssl");
const http = @import("h11");
const uri = @import("uri");
const args_parser = @import("args");

fn printUsage() !void {
    const stderr = std.io.getStdErr().outStream();
    try stderr.writeAll(
        \\Usage:
        \\  zpm [mode] ...
        \\Mode may be one of the following:
        \\  help
        \\    Lists this help text
        \\  search <words>
        \\    Searches for packages on GitHub. If no <words> are given, *all* packages are listed.
        \\  install <repo>
        \\    Installs the repository <repo>. May be only the repo name or the full repository name:
        \\    (1) `zpm install package-name`
        \\    (2) `zpm install creator/package-name`
        \\    When using (1), the package will be installed directly when only one package with that
        \\    name is found. Otherwise, you will be queried to chose on of the options.
        \\
    );
}

const CliMode = @TagType(CommandLineInterface);

const HelpOptions = struct {};
const InstallOptions = struct {};
const SearchOptions = struct {};
const UninstallOptions = struct {};

const CommandLineInterface = union(enum) {
    help: args_parser.ParseArgsResult(HelpOptions),
    install: args_parser.ParseArgsResult(InstallOptions),
    search: args_parser.ParseArgsResult(SearchOptions),
    uninstall: args_parser.ParseArgsResult(UninstallOptions),

    fn deinit(self: @This()) void {
        switch (self) {
            .help => |v| v.deinit(),
            .install => |v| v.deinit(),
            .search => |v| v.deinit(),
            .uninstall => |v| v.deinit(),
        }
    }
};

var debug_file: std.fs.File = undefined;

pub fn main() anyerror!u8 {
    const stdout = std.io.getStdOut().outStream();
    const stderr = std.io.getStdErr().outStream();
    const stdin = std.io.getStdIn().inStream();

    debug_file = try std.fs.cwd().createFile("raw.txt", .{});
    defer debug_file.close();

    var tester = std.testing.LeakCountAllocator.init(std.heap.c_allocator);
    defer tester.validate() catch {};

    const allocator = if (std.builtin.mode == .Debug)
        &tester.allocator
    else
        std.heap.c_allocator;

    var args = std.process.args();

    // Ignore executable name for now…
    {
        const executable_name = try (args.next(allocator) orelse {
            try std.io.getStdErr().outStream().writeAll("Failed to get executable name from the argument list!\n");
            return error.NoExecutableName;
        });
        allocator.free(executable_name);
    }

    const mode = blk: {
        const mode_name = try (args.next(allocator) orelse {
            try printUsage();
            return 1;
        });
        defer allocator.free(mode_name);

        break :blk std.meta.stringToEnum(CliMode, mode_name) orelse {
            try stderr.print("Unknown mode: {}\n", .{
                mode_name,
            });
            return 1;
        };
    };

    const base_cli: CommandLineInterface = switch (mode) {
        .help => CommandLineInterface{
            .help = try args_parser.parse(HelpOptions, &args, allocator),
        },
        .search => CommandLineInterface{
            .search = try args_parser.parse(SearchOptions, &args, allocator),
        },
        .install => CommandLineInterface{
            .install = try args_parser.parse(InstallOptions, &args, allocator),
        },
        .uninstall => CommandLineInterface{
            .uninstall = try args_parser.parse(UninstallOptions, &args, allocator),
        },
    };
    defer base_cli.deinit();

    switch (base_cli) {
        .help => |cli| {
            try printUsage();
            return 0;
        },

        .search => |cli| {
            // this requires usage of HTTPS
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

            // {
            //     var file = try std.fs.cwd().createFile("request.txt", .{ .exclusive = false });
            //     defer file.close();

            //     try file.writeAll(response.buffer);
            // }

            if (response.statusCode == http.StatusCode.Ok) {
                var parser = std.json.Parser.init(allocator, false); // don't cop strings, we keep the request
                parser.deinit();

                var tree = try parser.parse(response.body);
                defer tree.deinit();

                printPackages(tree.root) catch |err| switch (err) {
                    error.UnexpectedValue => {
                        std.debug.warn("Got invalid JSON!\n", .{});
                    },
                    else => return err,
                };

                // std.debug.warn("body:\n{}\n", .{tree});
            } else {
                std.debug.warn("Failed to execute query:\n", .{});

                std.debug.warn("status: {}\n", .{response.statusCode});
                std.debug.warn("headers:\n", .{});
                for (response.headers) |header| {
                    std.debug.warn("\t{}: {}\n", .{
                        header.name,
                        header.value,
                    });
                }
            }
        },

        .install => |cli| {
            if (cli.positionals.len == 0) {
                try printUsage();
                return 1;
            }

            for (cli.positionals) |repo_spec| {
                if (std.mem.indexOf(u8, repo_spec, "/")) |split| {
                    const owner = repo_spec[0..split];
                    const repo = repo_spec[split + 1 ..];

                    std.debug.warn("Install (1) {}/{}\n", .{
                        owner,
                        repo,
                    });
                } else {
                    const repo = repo_spec;

                    std.debug.warn("Install (2) {}/{}\n", .{
                        "???",
                        repo,
                    });
                }
            }
        },

        .uninstall => |cli| {},
    }

    return 0;
}

fn printPackages(root: std.json.Value) !void {
    if (root != .Object)
        return error.UnexpectedValue;
    if (root.Object.get("items")) |items_kv| {
        if (items_kv.value != .Array)
            return error.UnexpectedValue;

        for (items_kv.value.Array.items) |repo_val| {
            if (repo_val != .Object)
                return error.UnexpectedValue;
            const repo = &repo_val.Object;

            const licence = repo.get("license").?.value;
            if (licence == .Null) {
                std.debug.warn("{} (no licence)\n", .{
                    repo.get("full_name").?.value.String,
                });
            } else {
                std.debug.warn("{} ({})\n", .{
                    repo.get("full_name").?.value.String,
                    licence.Object.get("name").?.value.String,
                });
            }
        }
    } else {
        return error.UnexpectedValue;
    }
}

const https = struct {
    pub const HeaderMap = std.StringHashMap([]const u8);

    const empty_trust_anchor_set = ssl.TrustAnchorCollection.init(std.testing.failing_allocator);

    /// This contains the TLS trust anchors used to verify servers.
    /// Using a global trust anchor set should be sufficient for most HTTPs
    /// stuff.
    pub var trust_anchors: ?ssl.TrustAnchorCollection = null;

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

                        while (true) {
                            var nBytes = try input.read(&responseBuffer);
                            if (nBytes == 0)
                                break;

                            const slice = responseBuffer[0..nBytes];

                            try debug_file.writeAll(slice);

                            // std.debug.warn("input({}) => \"{}\"\n", .{ nBytes, responseBuffer[0..nBytes] });

                            try http_client.receiveData(slice);
                        }
                        continue;
                    },
                    else => {
                        return err;
                    },
                };
                break event;
            } else unreachable;

            std.debug.warn("http event: {}\n", .{
                @as(http.EventTag, event),
            });

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

        var socket = try network.connectToHost(allocator, parsed_url.host.?, switch (protocol) {
            .http => @as(u16, 80),
            .https => @as(u16, 443),
        }, .tcp);
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
