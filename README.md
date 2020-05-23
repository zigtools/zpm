# Inofficial Package Manager for Zig

**DISCLAIMER 1**:
This is not an official package manager for Zig. It's just something to bridge the time between *now* and the official package manager release.

**DISCLAIMER 2**:
Package versioning is out of scope for ZPM. Having "stable" packages for an unstable programming language seems unreasonable to me. Zig will still have frequent breaking changes, so keeping *all* our dependencies up-to-date is imho a must.

## Concept

### Basic Idea

The ZPM is based around two features:
- [Git Submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules)
- The GitHub Topic [`zig-package`](https://github.com/topics/zig-package)

Using the [GitHub API](https://developer.github.com/v3/search/#example), you can search for all Repositories in the topic `zig-package` which allows us to verify how the repo is called, if there are forks or several versions.

### Planned Features

ZPM should allow the following things:
- Add submodules into a directory in a project
- Provide a file `packages.zig` for `build.zig` that exposes all downloaded packages as `std.build.Pkg` objects
- Recursive submodule initialization

### Planned CLI

ZPM will be a command line application with an interface similar to `git` or `zig` with the following commands:

#### `zpm search <words>`

Searches for repositories tagged with *<words>*. This allows searching for certain key words like *network*, *gui*, …

ZPM will then output a list of all found projects including a fork hierarchy if available.

#### `zpm install <repo>`

Tries to install *<repo>* to your current package colleciton. *<repo>* is either only the repository name (like `zig-network`) or the full name (like `MasterQ32/zig-network`).

When using the full name, exactly this repo will be cloned from master branch and will be added to your packages.

When using the repo name only, ZPM will do the following:
1. If only a single repository exists: Install this repo
2. If a single *root project* with several forks exist, ask the user if the want ot install the *root* or an explicit fork. Do what they chose.
3. If multiple non-fork projects exist with the same name, ask the user to chose from a list.

## Building

1. Clone the repository
2. Run `git submodule update --init --recursive`
3. Run `zig build`

## Runtime Requirements for ZPM

- Have `git` or `git.exe` in your path
- Have network access

## Debugging

List all repositories

```sh
curl -H 'Accept: application/vnd.github.mercy-preview+json' \
  'https://api.github.com/search/repositories?q=topic:zig-package' \
| jq '.items[].full_name'
```
