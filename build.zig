const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const client_exe = b.addExecutable(.{
        .name = "zpm",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/client/client-main.zig"),
    });

    b.installArtifact(client_exe);

    const server_exe = b.addExecutable(.{
        .name = "zpm-server",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/server/server-main.zig"),
    });

    b.installArtifact(server_exe);
}
