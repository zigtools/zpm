const std = @import("std");

const bear_ssl = @import("./lib/zig-bearssl/bearssl.zig");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{
        .default_target = try std.zig.CrossTarget.parse(.{
            .arch_os_abi = "native-linux", // we need at least glibc 2.25 for getentropy
            // .arch_os_abi = "native-native-musl", // preferrable, but doesn't work?!
        }),
    });

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zpm", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.addPackagePath("args", "./lib/zig-args/args.zig");
    exe.addPackagePath("network", "./lib/zig-network/network.zig");
    exe.addPackagePath("bearssl", "./lib/zig-bearssl/bearssl.zig");

    // this will add all BearSSL sources to the exe
    bear_ssl.linkBearSSL("./lib/zig-bearssl", exe, target);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
