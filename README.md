# A package composition tool for zig

A package configuration and discovery tool.

## Usage

```sh
# initializes a zpm instance in the current directory by creating a hidden .zpm folder.
# packages will then be auto-collected and .zpm/pkgs.zig will be created.
zpm init 

# re-runs package autodetection and will regenerate .zpm/pkgs.zig
zpm update
```

After initialization, ZPM will create the folder `.zpm` which contains a file `.zpm/pkgs.zig`. This file contain all collected 
packages that are available and can be imported into `build.zig`.

It will look roughly like this:
```zig
const std = @import("std");

pub const pkgs = struct {
    pub const android = std.build.Pkg{
        .name = "android",
        .path = .{ .path = "../vendor/AndroidSdk/source/android.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
};

pub const imports = struct {
    pub const AndroidSdk = @import("../vendor/AndroidSdk/Sdk.zig");
};
```

### Configuration

ZPM will create a `zpm.conf` file in the `.zpm` directory that can be used to configure the project instance. This config file is a ini file and has the following entries:

```ini
# configures the path where the build.zig import file is generated.
# the path is relative to this file.
pkgs-file = pkgs.zig
```

## Add packages

To add a new package, put a `.zpm` file anywhere in your project tree next or below the `.zpm` folder. These files must be ini files where each section declares a package named after the section.

The section allows the following keys:
```ini
[zpm]
file = rel/path/to/source.zig # a path relative to this files folder
                              # where the package root is located
deps = args, ini, uri         # comma-separated list of dependencies names
kind = default                # default = a normal runtime package, available under .pkgs
                              # build   = the package will be available under .imports 
                              # combo   = mixed build- and runtime package
```

These package files don't have to reside next to the package, but can also be declared outside the *package* source tree. This allows to configure external packages in the `.zpm` folder for example.

If you change anything in your package declaration files, run `zpm update`.

## Contributing

This reboot of ZPM is made to be super-simple, but the implementation might be *too simple* right now. If you feel
like something is missing, feel free to fork and PR!
