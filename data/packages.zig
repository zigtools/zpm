// zpm package file. do not modify (without knowing what you're doing)!
const std = @import(std);

pub fn get(comptime name: []const u8) std.build.Pkg {
    return @field(packages, name);
}

pub fn addAllTo(exe: *std.build.LibExeObjStep) void {
    inline for (std.meta.decls(packages)) |decl| {
        exe.addPackage(@field(packages, decl.name));
    }
}

const packages = struct {
    // begin pkg
    const @"name" = std.build.Pkg{
        .name = "name",
        .path = "…",
        .dependencies = null, // for now
    };
    // end pkg
};
