# ZPM Next Generation

> This project is vaporware right now. If you feel the urge to implement it, go ahead!

## Usage Examples

```sh-session
[user@host] ~ $ zpm add-index zig.pm https://index.zig.pm/api/v1/
[user@host] ~ $ 
```

```sh-session
[user@host] ~ $ zpm search network

masterq32/network 1.0.0 @ zig.pm
  A smallest-common-subset of socket functions for crossplatform networking, TCP & UDP

marler8997/ziget 1.2.3 @ zig.pm
  Zig library/tool to request network assets

[user@host] ~ $ 
```

```sh-session
[user@host] ~ $ zpm add masterq32/network
Adding masterq32/network...                 [/]
Done.

Use this code to add the dependency to your project:

    const network_dep = b.dependency("masterq32/network", .{});

    const network_mod = network_dep.module("network");

[user@host] ~ $ 
```

```sh-session
[user@host] ~ $ zpm update --auto
Updating 2 dependencies...                  [/]

    masterq32/network 1.0.0 => 1.0.5
    masterq32/args    1.4.5 => 1.9.2

[user@host] ~ $ 
```

```sh-session
[user@host] ~ $ zpm update --auto --major
Updating 1 dependency...                    [/]

    masterq32/network 1.0.0 => 2.1.7

[user@host] ~ $ 
```

```sh-session
[user@host] ~ $ zpm update
Updating 1 dependency...                    [/]

    masterq32/network 1.0.0 => 2.1.7 [yN]
```

```sh-session
[user@host] ~ $ zpm package
path: /home/user/.cache/zpm/bundles/network.tar.xz
hash: 1220a1f050f3a67785cbe68283b252f02f72885eea80d6a9e1856b02cd66deaf1492
```

```sh-session
[user@host] ~ $ zpm push
Uploading masterq32/network to zig.pm...     [/]
[user@host] ~ $ 
```

## `build.zig.zon` Extension

```zig
.{
    .name = "network", // this is displayed after the user name
    .version = "1.2.3", // this is displayed in the search
    .dependencies = .{
        .inner = .{
            .url = "…",
            .hash = "…",

            .index = "zig.pm",                  // which index was used to fetch
            .package_name = "masterq32/inner",  // what is the package named there
            .package_version = "0.9.3",         // which version was installed last
        },
    },
    // Where can we fetch our packages?
    .package_indices = .{
        .@"zig.pm" = .{
            .base_url = "https://index.zig.pm/api/v1/",
        },
    },
}
```

## Package Index Format

### `/index.json`

Describes the root of a package index.

Should be served with a backend that supports `index.json?search=<query>&sort=<key>` with `<key>` being one of the fields of an entry of `packages` and `<query>` should be able to do a full text search.

```json
{
    "last_update": {
        "unix": "1714076768",
        "iso": "2024-04-25T20:26:08.690159"
    },
    "packages": [
        {
            "name": "masterq32/network",
            "short_desc": "A smallest-common-subset of socket functions for crossplatform networking, TCP & UDP",

            "zig_version": "0.12.0",
            
            "pkg_version": "0.11.0-43-ge107f8d11",
            "pkg_hash": "12203149d62eb94d919582cfd2482a4abd14b7908a69928ec0fe2724969388a2ad01",
            "pkg_url": "https://downloads.zig.pm/packages/masterq32/network/0.11.0-43-ge107f8d11.tar.xz",
            "pkg_metadata": "https://downloads.zig.pm/packages/masterq32/network.json"
        },
        …
    ]
}
```

### `metadata.json`

This file is served under the url provided at `pkg_metadata` and describes a package more in-depth including
all published versions and some generic package metadata.

```json
{
    "package_name": "masterq32/network",
    "description": "A smallest-common-subset of socket functions for crossplatform networking, TCP & UDP",
    "versions": {
        "0.11.0-43-ge107f8d11": {
            "package": {
                "hash": "12200466d72927f83a1e427d04d15e7ab71ab735ae6f175b6dee22bde2d64bab34a3",
                "url": "https://downloads.zig.pm/packages/masterq32/network/0.11.0-43-ge107f8d11.tar.xz",
                "files": [
                    "LICENSE",
                    "build.zig",
                    "build.zig.zon",
                    "src/network.zig"
                ]
            },
            "created": {
                "unix": "1714076768",
                "iso": "2024-04-25T20:26:08.690159"
            },
            "archive": {
                "size": "218662",
                "sha256sum": "786101a5548c7f5687a2f401c9b011badd734b68051c600d6a2a0e31b0bf7629"
            },
            "dependencies": {
                "inner": {
                    "name": "masterq32/inner",
                    "version": "0.9.3"
                },
            },
        }
    }
}
```