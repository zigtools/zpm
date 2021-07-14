const std = @import("std");

pub const pkgs = struct {
    pub const args = std.build.Pkg{
        .name = "args",
        .path = .{ .path = "../lib/zig-args/args.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
    pub const uri = std.build.Pkg{
        .name = "uri",
        .path = .{ .path = "../lib/zig-uri/uri.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
    pub const ini = std.build.Pkg{
        .name = "ini",
        .path = .{ .path = "../lib/ini/src/ini.zig" },
        .dependencies = &[_]std.build.Pkg{args},
    };
};

pub const imports = struct {
    pub const custom = @import("../src/main.zig");
};
