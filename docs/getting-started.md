# Getting Started

klua is a self-healing package manager: a C++20 core does the heavy lifting
(HTTP, extraction, filesystem, YAML/JSON parsing), Lua 5.4 does the thinking
(providers, resolution, lifecycle hooks). Linux and macOS only.

## Installation

### From GitHub Releases

Static Linux binaries (x86_64, arm64) and macOS binaries are attached to
every `v*` release:

```sh
curl -fLO https://github.com/kiru0414/klua/releases/download/v0.3.0/klua-0.3.0-linux-x86_64.tar.gz
tar -xzf "klua*.tar.gz"
mkdir -p ~/.local/bin
install -m 755 klua ~/.local/bin/klua
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
klua install <target>...   (alias: klua i)
klua add <target>...
klua sync [path_or_url]
klua upgrade [target...]
klua tap <add|remove|list> [url]
klua list
klua repair
klua init-manifest [--force]
klua --version | --help
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
discovery (ELF/Mach-O magic or exec bits), `chmod +x`, symlink into
`~/.local/bin`. See [taps-and-registry.md](taps-and-registry.md) for alias
resolution.

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

### repair

```sh
klua repair
```

Forcefully overwrites `~/.config/klua/init.lua` with the clean embedded
baseline. Implemented natively in C++ — it works even when Lua is broken.

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
