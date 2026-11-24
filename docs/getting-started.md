# Getting Started

klua is a self-healing package manager: a C++20 core does the heavy lifting
(HTTP, extraction, filesystem, YAML/JSON parsing), Lua 5.4 does the thinking
(providers, resolution, lifecycle hooks). Linux and macOS only.

## Installation

### From GitHub Releases

Static Linux binaries (x86_64, arm64) and macOS binaries are attached to
every `v*` release:

```sh
curl -LO https://github.com/kiru0414/klua/releases/latest/download/klua-v0.4.0-linux-x86_64.tar.gz
tar -xzf klua-v0.4.0-linux-x86_64.tar.gz
install -m 755 klua ~/.local/bin/klua   # or /usr/local/bin
klua --version
```

Make sure `~/.local/bin` is on your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"    # add to ~/.bashrc / ~/.zshrc
```

### From source

Requirements: CMake >= 3.24, a C++20 compiler (GCC 11+ / Clang 14+), git,
OpenSSL dev headers (`libssl-dev` on Debian/Ubuntu, `brew install openssl@3`
on macOS). Everything else (Lua 5.4, sol2, CLI11, yaml-cpp, nlohmann/json,
cpp-httplib) is fetched by CMake at configure time. `tar` is required at
runtime; `unzip` only for `.zip` assets.

```sh
git clone https://github.com/kiru0414/klua.git
cd klua
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/klua --version
```

Fully static Linux build (what CI ships):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXE_LINKER_FLAGS=-static -DOPENSSL_USE_STATIC_LIBS=ON
cmake --build build -j
```

On Windows, build inside WSL — POSIX is the only supported target.

## XDG paths

| Purpose | Default | Override |
| ------- | ------- | -------- |
| Config  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `taps.yaml`) | `XDG_CONFIG_HOME` |
| Store   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` | `XDG_DATA_HOME` |
| Bin     | `~/.local/bin/<name>` (symlinks into the store) | none (always `~/.local/bin`) |
| Cache   | `~/.cache/klua/` (`downloads/`, `build/`) | `XDG_CACHE_HOME` |

Overrides are honored only when absolute. Archives are extracted intact
into the store (single top-level wrapper directories are stripped), so
relative layouts of complex tools survive.

## CLI

```
klua install [--force] <target>...   (alias: klua i)
klua run <target> [--] [args...]     # store-only execution, no symlink
klua search <query>
klua info <target>
klua cleanup
klua doctor
klua add <target>...
klua remove <target>...    (aliases: klua rm, klua uninstall)
klua sync [path_or_url]
klua upgrade [target...]
klua tap <add|remove|list> [url]
klua list
klua repair [--dry-run|--diff]
klua init-manifest [--force]
klua --version | --help
```

Mistyped subcommands, flags, and aliases get a Levenshtein-based hint:

```
$ klua instll
warning: unknown command 'instll'; did you mean 'install'?
$ klua --helo
warning: unknown option '--helo'; did you mean '--help'?
$ klua i bzp3
warning: did you mean 'bzip3'?
$ klua serach jq
warning: unknown command 'serach'; did you mean 'search'?
```

### install / i

Targets are either scheme-qualified or bare aliases:

```sh
klua install gh:jqlang/jq        # GitHub Releases (latest)
klua i gh:jqlang/jq@jq-1.7.1     # pinned tag
klua install gl:user/repo        # GitLab Releases
klua install url:https://example.com/tool.tar.gz
klua install fd                  # alias -> v1/f.yaml -> gh:sharkdp/fd
```

Pipeline: direct scheme dispatch, or alias sharding lookup, then (for
gh/gl) an in-repo [`klua.yaml`](klua-yaml.md) manifest check, then release
asset scoring by OS/arch, download, extraction into the store, binary
discovery (ELF/Mach-O magic or exec bits), `chmod +x`, conflict-checked
symlink into `~/.local/bin`. See [taps-and-registry.md](taps-and-registry.md)
for alias resolution.

### Conflict safety

Before creating any link, klua scans `PATH` and:

- refuses to shadow protected core commands such as `git`, `curl`, `python`,
  `python3`, `apt`, `sudo` and `klua` itself;
- warns when a binary with the same name already exists on `PATH` or at the
  link destination and is not managed by klua;
- never links shared/static libraries (`.so`, `.so.*`, `.dylib`, `.a`, `.la`,
  `.dll`) — they stay inside the store.

A skipped link is not an install failure: the package remains staged in the
store. Existing links that point into the store are replaced normally, so
upgrades keep working. Pass `--force` to consciously override either guard:

```sh
klua install git            # warns and leaves ~/.local/bin/git alone
klua install --force git    # creates the link anyway
```

### run

```sh
klua run jq --version
klua run gh:jqlang/jq -r '.version'
```

`run` picks a non-library executable from the newest installed store version,
installs the package store-only (no symlinks) if needed, and executes it with
store `bin` directories prepended to `PATH` and store library directories on
`LD_LIBRARY_PATH` (macOS: `DYLD_LIBRARY_PATH`). Arguments after the target —
including flags — are passed through unchanged; use `--` to separate them
explicitly.

### search / info

```sh
klua search bzip3   # substring match in aliases and targets, all shards a-z + _
klua info fd        # alias resolution, installed versions, links, release info
```

`search` walks every shard of every configured registry (taps first) and
prints `alias<TAB>target` matches sorted by alias; the first registry that
defines an alias wins. `info` works offline for local state and only emits a
warning if release metadata cannot be fetched.

### cleanup / doctor

```sh
klua cleanup        # keep newest version per package; remove stale links/caches
klua doctor         # report dirs, PATH, registries, broken/shadowed links
```

Version ordering is digit-aware (`1.10.0` is newer than `1.9.0`). `cleanup`
removes old store versions, symlinks pointing to missing store files, library
links, and the `downloads/` and `build/` caches. `doctor` exits `1` only for
real errors (e.g. unwritable directories); warnings are informational.

### add / sync

```sh
klua add gh:jqlang/jq fd         # record targets in packages.yaml (deduped)
klua sync                        # install everything in packages.yaml
klua sync ./dotfiles.yaml        # explicit local source
klua sync https://host/set.yaml  # remote source; follows includes:
```

`packages.yaml` supports `includes:` (recursive, cycle-safe) and
`packages:`; duplicate targets are installed once. A bare YAML list is
also accepted as a source.

### upgrade

```sh
klua upgrade                     # every installed gh/gl package
klua upgrade gh:jqlang/jq        # one target (aliases resolved too)
```

Reinstalls the latest release and reports `upgraded X: old -> new` or
`X is up to date (version)`.

### tap / list

```sh
klua tap add https://example.com/my-registry
klua tap list
klua tap remove https://example.com/my-registry
klua list                        # provider:user/repo  version, from the store
```

### remove / rm / uninstall

```sh
klua remove fd                   # alias target
klua rm gh:jqlang/jq             # scheme target
klua uninstall url:https://example.com/tool.tar.gz
```

Removal is complete: symlinks in `~/.local/bin` that point into the
package's store directory are deleted, the store tree
(`~/.local/share/klua/store/<provider>/<user>/<repo>/`) is removed, and
matching entries in `packages.yaml` (bare alias, resolved target, or
untagged scheme target) are pruned. Removing a package that is not
installed reports an error and changes nothing.

### repair

```sh
klua repair
klua repair --dry-run    # or: klua repair --diff
```

Restores `~/.config/klua/init.lua` from the clean embedded baseline.
Implemented natively in C++, so it works even when Lua is broken. Before
overwriting, the current file is copied to
`~/.config/klua/init.lua.bak.<timestamp>` and the backup path is printed —
custom Lua is never silently destroyed. If the file already matches the
baseline, nothing is written. `--dry-run` / `--diff` prints the backup path
and a unified diff of the pending change and leaves all files untouched.

## Self-healing behavior

Startup sequence on every command except `repair`:

1. The embedded Lua baseline (baked into the binary at build time) loads
   first and always succeeds.
2. Your `~/.config/klua/init.lua` runs in a protected call on top of it.
3. If your file has a syntax or runtime error, klua prints the Lua
   diagnostic, discards all Lua state, reloads the embedded baseline, and
   continues with default logic:

```
error: failed to load /home/you/.config/klua/init.lua: [string "..."]:1: ...
warning: falling back to the built-in default logic. Run 'klua repair' to restore a clean init.lua.
```

A broken config never bricks the tool. Fix the file, or run `klua repair`.

## Exit codes

`0` success, `1` any failure (usage errors, provider errors, Lua errors).
Lua command handlers may return other codes; the CLI passes them through.

## Next steps

- Customize providers and hooks: [lua-api.md](lua-api.md)
- Package your own repo: [klua-yaml.md](klua-yaml.md)
- Run or contribute to a registry: [taps-and-registry.md](taps-and-registry.md)
