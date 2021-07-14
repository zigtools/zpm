const std = @import("std");
const uri = @import("uri");
const ini = @import("ini");
const args_parser = @import("args");

const logger = std.log;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = &gpa.allocator;

const SelectedCommand = union(enum) {
    help: args_parser.ParseArgsResult(HelpArgs),
    init: args_parser.ParseArgsResult(InitArgs),
    update: args_parser.ParseArgsResult(UpdateArgs),

    const HelpArgs = struct {};
    const InitArgs = struct {
        help: bool = false,
    };
    const UpdateArgs = struct {
        help: bool = false,
    };
};

pub fn main() !u8 {
    defer _ = gpa.deinit();

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    var command = blk: {
        var parser = std.process.args();

        const exe_name = try (parser.next(global_allocator) orelse return 1);
        defer global_allocator.free(exe_name);

        const verb = try (parser.next(global_allocator) orelse {
            try printUsage(stderr);
            return 1;
        });
        defer global_allocator.free(verb);

        if (std.mem.eql(u8, verb, "help")) {
            break :blk SelectedCommand{ .help = args_parser.parse(
                SelectedCommand.HelpArgs,
                &parser,
                global_allocator,
                .print,
            ) catch return 1 };
        } else if (std.mem.eql(u8, verb, "init")) {
            break :blk SelectedCommand{ .init = args_parser.parse(
                SelectedCommand.InitArgs,
                &parser,
                global_allocator,
                .print,
            ) catch return 1 };
        } else if (std.mem.eql(u8, verb, "update")) {
            break :blk SelectedCommand{ .update = args_parser.parse(
                SelectedCommand.UpdateArgs,
                &parser,
                global_allocator,
                .print,
            ) catch return 1 };
        }

        try stderr.print("Unknown verb: {s}\n", .{verb});
        return 1;
    };
    defer switch (command) {
        .help => |*cmd| cmd.deinit(),
        .init => |*cmd| cmd.deinit(),
        .update => |*cmd| cmd.deinit(),
    };

    switch (command) {
        .help => {
            try printUsage(stdout);
            return 0;
        },
        .init => |cmd| {
            return try initPackage(cmd);
        },
        .update => |cmd| {
            return try updatePackage(cmd);
        },
    }
}

const zpm_config_dir_name = ".zpm";

fn initPackage(cli_args: args_parser.ParseArgsResult(SelectedCommand.InitArgs)) !u8 {
    if (cli_args.options.help) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    }

    std.fs.cwd().makeDir(zpm_config_dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var stderr = std.io.getStdErr().writer();
            try stderr.writeAll("ZPM was already initialized in this directory!\nRun 'zpm update' to refresh your dependencies!\n");
            return 1;
        },
        else => |e| return e,
    };

    var dir = try std.fs.cwd().openDir(zpm_config_dir_name, .{});
    defer dir.close();

    // Create initial set of files
    for (initial_files) |file_info| {
        var file = try dir.createFile(file_info.name, .{});
        defer file.close();

        try file.writeAll(file_info.content);
    }

    var config = try loadConfig(global_allocator, dir);
    defer config.deinit();

    try performUpdate(config, dir);

    return 0;
}

fn findZpmRoot() !?std.fs.Dir {
    const cwd_path = try std.process.getCwdAlloc(global_allocator);
    defer global_allocator.free(cwd_path);

    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        var search_dir = try std.fs.cwd().openDir(dirname, .{});
        defer search_dir.close();

        if (search_dir.openDir(zpm_config_dir_name, .{})) |cfg_dir| {
            return cfg_dir;
        } else |err| {
            switch (err) {
                error.FileNotFound => {
                    dirname = std.fs.path.dirname(dirname) orelse return null;
                },
                else => |e| return e,
            }
        }
    }
}

fn updatePackage(cli_args: args_parser.ParseArgsResult(SelectedCommand.UpdateArgs)) !u8 {
    if (cli_args.options.help) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    }

    var dir = (try findZpmRoot()) orelse {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll(
            \\Could not find .zpm folder in this or any parent directory.
            \\Make sure you have initialized ZPM correctly!
            \\
        );
        return 1;
    };
    defer dir.close();

    var config = try loadConfig(global_allocator, dir);
    defer config.deinit();

    try performUpdate(config, dir);
    return 0;
}

fn performUpdate(config: Config, zpm_dir: std.fs.Dir) !void {
    var root_dir = try zpm_dir.openDir("..", .{ .iterate = true });
    errdefer root_dir.close();

    var walker = std.fs.Walker{
        //       [        std.fs.Walker.StackItem        ]
        .stack = std.meta.fieldInfo(std.fs.Walker, .stack).field_type.init(global_allocator),
        .name_buffer = blk: {
            var name_buffer = std.ArrayList(u8).init(global_allocator);
            errdefer name_buffer.deinit();

            try name_buffer.appendSlice("..");
            break :blk name_buffer;
        },
    };
    defer walker.deinit();

    try walker.stack.append(.{
        .dir_it = root_dir.iterate(),
        .dirname_len = 2,
    });

    var arena = std.heap.ArenaAllocator.init(global_allocator);
    defer arena.deinit();

    var packages = std.ArrayList(Package).init(global_allocator);
    defer packages.deinit();

    while (try walker.next()) |item| {
        if (item.kind != .File)
            continue;
        if (!std.mem.endsWith(u8, item.basename, ".zpm"))
            continue;

        loadPackageDesc(&arena.allocator, &packages, item) catch |err| {
            logger.err("Failed to open {s}: {s}", .{
                item.path,
                @errorName(err),
            });
        };
    }

    var package_file = try zpm_dir.createFile(config.pkgs_file, .{});
    defer package_file.close();
    {
        const writer = package_file.writer();

        try writer.writeAll(
            \\const std = @import("std");
            \\
            \\fn pkgRoot() []const u8 {
            \\    return std.fs.path.dirname(@src().file) orelse ".";
            \\}
            \\
            \\pub const pkgs = struct {
            \\
        );
        for (packages.items) |item| {
            if (item.kind != .default and item.kind != .combo)
                continue;
            try writer.print("    pub const {} = std.build.Pkg{{\n", .{
                std.zig.fmtId(item.name),
            });
            try writer.print("        .name = \"{s}\",\n", .{item.name});
            try writer.print("        .path = .{{ .path = pkgRoot() ++ \"/{s}\" }},\n", .{item.path});
            try writer.writeAll("        .dependencies = &[_]std.build.Pkg{");
            for (item.deps) |dep, i| {
                if (i > 0) {
                    try writer.writeAll(", ");
                }
                try writer.writeAll(dep);
            }
            try writer.writeAll("},\n");
            try writer.writeAll("    };\n");
        }
        try writer.writeAll(
            \\};
            \\
        );

        try writer.writeAll(
            \\
            \\pub const imports = struct {
            \\
        );
        for (packages.items) |item| {
            if (item.kind != .build and item.kind != .combo)
                continue;
            try writer.print("    pub const {} = @import(\"{s}\");\n", .{
                std.zig.fmtId(item.name),
                item.path,
            });
        }
        try writer.writeAll(
            \\};
            \\
        );
    }
}

const Package = struct {
    name: []const u8,
    path: []const u8,
    deps: []const []const u8 = &[_][]const u8{},
    kind: PackageKind = .default,
};

const PackageKind = enum {
    /// It's a normal package, meant to be consumed by a typical zig application
    default,
    /// A build package meant to be imported by build.zig
    build,
    /// A package that can be used both at build time as well as runtime.
    combo,
};

fn loadPackageDesc(allocator: *std.mem.Allocator, packages: *std.ArrayList(Package), item: std.fs.Walker.Entry) !void {
    var file = try item.dir.openFile(item.basename, .{});
    defer file.close();

    var parser = ini.parse(allocator, file.reader());
    defer parser.deinit();

    var current_pkg: ?*Package = null;

    while (try parser.next()) |record| {
        switch (record) {
            .section => |heading| {
                current_pkg = try packages.addOne();
                errdefer _ = packages.pop();

                current_pkg.?.* = .{
                    .name = try allocator.dupe(u8, heading),
                    .path = "",
                    .kind = .default,
                };
            },
            .property => |kv| {
                if (current_pkg) |pkg| {
                    if (std.mem.eql(u8, kv.key, "file")) {
                        pkg.path = try std.fs.path.join(allocator, &[_][]const u8{
                            std.fs.path.dirname(item.path) orelse ".",
                            kv.value,
                        });
                    } else if (std.mem.eql(u8, kv.key, "kind")) {
                        pkg.kind = std.meta.stringToEnum(PackageKind, kv.value) orelse {
                            logger.warn("Unexpected package kind {s}.", .{kv.value});
                            return error.InvalidFile;
                        };
                    } else if (std.mem.eql(u8, kv.key, "deps")) {
                        var items = std.mem.tokenize(kv.value, " \t,");
                        var count: usize = 0;
                        while (items.next()) |_| {
                            count += 1;
                        }
                        items.reset();

                        var deps = std.ArrayList([]const u8).init(allocator);
                        try deps.resize(count);

                        var index: usize = 0;
                        while (items.next()) |val| {
                            deps.items[index] = try allocator.dupe(u8, val);
                            index += 1;
                        }

                        pkg.deps = deps.toOwnedSlice();
                    } else {
                        logger.warn("{s} contains a unknown key: {s}", .{ item.basename, kv.key });
                    }
                } else {
                    logger.warn("{s} contains keys without a section!", .{item.basename});
                    return error.InvalidFile;
                }
            },

            .enumeration => {
                logger.warn("{s} contains a invalid enumeration!", .{item.basename});
            },
        }
    }
}

const Config = struct {
    arena: std.heap.ArenaAllocator,

    pkgs_file: []const u8,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn loadConfig(allocator: *std.mem.Allocator, zpm_dir: std.fs.Dir) !Config {
    const cfg_log = std.log.scoped(.config);

    var cfg = Config{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .pkgs_file = "pkgs.zig",
    };

    if (zpm_dir.openFile("zpm.conf", .{})) |*file| {
        defer file.close();

        var parser = ini.parse(allocator, file.reader());
        defer parser.deinit();

        while (try parser.next()) |record| {
            switch (record) {
                .section => |heading| {
                    cfg_log.warn("unexpected heading [{s}] in the config!", .{heading});
                },
                .property => |kv| {
                    if (std.mem.eql(u8, kv.key, "pkgs-file")) {
                        cfg.pkgs_file = try cfg.arena.allocator.dupe(u8, kv.value);
                    } else {
                        cfg_log.warn("unexpected key '{s}' in the config!", .{kv.key});
                    }
                },

                .enumeration => |e| {
                    cfg_log.warn("unexpected enumeration '{s}' in the config!", .{e});
                },
            }
        }
    } else |err| {
        switch (err) {
            // when file is not found, just use the defaults.
            error.FileNotFound => {},
            else => |e| return e,
        }
    }

    return cfg;
}

fn printUsage(stream: anytype) !void {
    try stream.writeAll(
        \\zpm [verb] ...
        \\  verbs:
        \\    init
        \\      initializes a new zpm instance
        \\    update
        \\      updates an already existing zpm instance
        \\    help
        \\      prints this help text
        \\
    );
}

const initial_files = [_]PregeneratedFile{
    // TODO: Do we really want to ignore the pkgs.zig file?
    // PregeneratedFile{
    //     .name = ".gitignore",
    //     .content =
    //     \\*.zig
    //     \\
    //     ,
    // },
    PregeneratedFile{
        .name = "zpm.conf",
        .content = 
        \\# configures the path where the build.zig import file is generated.
        \\# the path is relative to this file.
        \\# pkgs-file = ./pkgs.zig
        ,
    },
};

const PregeneratedFile = struct {
    name: []const u8,
    content: []const u8,
};
