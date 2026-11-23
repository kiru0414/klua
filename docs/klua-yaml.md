# klua.yaml — in-repo package manifests

When installing `gh:user/repo` or `gl:user/repo`, klua first fetches
`klua.yaml` from the repository root:

```
https://raw.githubusercontent.com/<user>/<repo>/<ref>/klua.yaml   (gh)
https://gitlab.com/<user>/<repo>/-/raw/<ref>/klua.yaml            (gl)
```

`<ref>` is the pinned tag (`repo@tag`) or `HEAD`. If the file exists and
parses, it overrides the release heuristics. If it is missing, invalid, or
comment-only, klua silently falls back to asset scoring.

Generate a starter in any repo:

```sh
klua init-manifest            # writes ./klua.yaml, refuses to overwrite
klua init-manifest --force    # overwrite
```

## Schema

All fields are optional. Unknown fields are ignored.

```yaml
assets:                      # list of glob patterns
  - "mytool-*-linux-*.tar.gz"

bins:                        # list of paths relative to the store root
  - mytool
  - bin/helper

configs:                     # list of {src, dest} mappings
  - src: config.example.toml
    dest: ~/.config/mytool/config.toml

build:
  steps:                     # list of shell commands
    - cargo build --release
```

## assets

Explicit release-asset selection. Patterns support `*` (any run of
characters) and `?` (one character); matching is case-sensitive and
anchored (the whole asset name must match).

- The first asset matching any pattern wins (assets are scanned in API
  order, patterns in list order).
- When `assets` is present it **replaces** OS/arch scoring entirely —
  include the OS/arch tokens in your patterns yourself.
- If nothing matches, klua falls through to `build.steps` (if present),
  otherwise the install fails.

```yaml
assets:
  - "mytool-*-x86_64-unknown-linux-musl.tar.gz"
  - "mytool-*-linux-amd64.tar.gz"     # fallback pattern
```

Without `assets`, klua scores every release asset: OS token must match
(`linux`, or `darwin`/`macos`/`apple`), wrong-architecture assets are
rejected, checksums/signatures/packages (`.sha256`, `.sig`, `.deb`,
`.rpm`, ...) are ignored, exact-arch matches score highest, archives and
musl builds get small bonuses.

## bins

Binaries to make executable and symlink into `~/.local/bin`. Paths are
relative to the store root (i.e. the extracted archive after the
single-top-level-directory strip). Each entry is linked under its
basename:

```yaml
bins:
  - nvim            # -> ~/.local/bin/nvim
  - bin/extra-tool  # -> ~/.local/bin/extra-tool
```

- Missing paths fail the install with a clear error.
- Without `bins`, klua auto-detects executables (ELF/Mach-O magic bytes or
  any exec bit) and links the best candidate: name matching the repo
  first, then files under `bin/`, then the shortest path.
- Raw (non-archive) release assets without `bins` are linked under the
  repo name (`jq-linux-amd64` -> `jq`).

## configs

Files copied out of the store into user locations after linking:

```yaml
configs:
  - src: config.example.toml          # relative to the store root
    dest: ~/.config/mytool/config.toml
  - src: completions/
    dest: ~/.local/share/bash-completion/completions/   # trailing / = directory
```

- `~` expands to `$HOME`.
- A trailing `/` on `dest` means "copy into this directory" (the source
  basename is appended).
- Parent directories are created; existing files are overwritten.
- A missing `src` fails the install.

## build.steps

Source build fallback, used when there is **no release** or **no suitable
asset**:

```yaml
build:
  steps:
    - cargo build --release
    - strip target/release/mytool
bins:
  - target/release/mytool
```

Mechanics:

1. `git clone --depth 1` (plus `--branch <tag>` when pinned) into
   `~/.cache/klua/build/<user>-<repo>`.
2. Each step runs as `cd <clone> && <step>` via the system shell; any
   non-zero exit aborts the install.
3. Produced binaries are collected: `bins` entries first; otherwise the
   first non-empty of `target/release/`, `build/`, `bin/`; otherwise a
   full scan of the clone for executables.
4. Binaries are copied into the store under version `source` (or the
   pinned tag), chmod'ed, and symlinked. `configs` apply as usual.

The clone URL base is overridable (`klua.github_clone` / `klua.gitlab_clone`
in `init.lua`) for mirrors and local testing.

## Complete examples

Raw-binary release, no manifest needed — but explicit naming:

```yaml
bins:
  - mytool
```

Archive with docs and a config file:

```yaml
assets:
  - "mytool-*-linux-*.tar.gz"
bins:
  - mytool
configs:
  - src: config.example.toml
    dest: ~/.config/mytool/config.toml
```

No releases at all, pure source build:

```yaml
build:
  steps:
    - make -j4
bins:
  - build/mytool
```

## Precedence summary

1. Manifest `assets` patterns > OS/arch scoring.
2. Manifest `bins` > executable auto-detection.
3. Release install > `build.steps` (build only runs when no release or no
   matching asset).
4. Missing/invalid manifest > nothing — heuristics proceed unchanged.
