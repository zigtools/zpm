const std = @import("std");

fn pkgRoot() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub const pkgs = struct {
    pub const args = std.build.Pkg{
        .name = "args",
        .path = .{ .path = pkgRoot() ++ "/../lib/zig-args/args.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
    pub const uri = std.build.Pkg{
        .name = "uri",
        .path = .{ .path = pkgRoot() ++ "/../lib/zig-uri/uri.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
    pub const ini = std.build.Pkg{
        .name = "ini",
        .path = .{ .path = pkgRoot() ++ "/../.zpm/../lib/ini/src/ini.zig" },
        .dependencies = &[_]std.build.Pkg{args},
    };
};

pub const imports = struct {
    pub const custom = @import("../.zpm/../src/main.zig");
};
