# Taps & the Alias Registry

Bare targets (`klua install fd`) are resolved through **alias sharding**:
small YAML files fetched at runtime from static HTTPS hosts. No database,
no server logic — just files.

## Resolution pipeline

```
klua install fd
  |
  ├─ contains ':' ?  ── yes ──> dispatch to provider (gh:, gl:, url:, ...)
  |
  └─ no: shard char = lowercase first letter ('f'); non-letter -> '_'
       |
       for each registry (taps first, then klua.registries):
         GET <registry>/v1/f.yaml
         parse YAML in memory
         alias present? ── yes ──> install the mapped scheme target
       |
       └─ none matched ──> error: alias not found
```

Details:

- Shard files are flat mappings: `alias: scheme-target`.
- Registries are tried in order; the first HTTP 200 containing the alias
  wins. 404s and invalid YAML move on to the next registry.
- Order: `taps.yaml` entries first, then `klua.registries` (which defaults
  to the official registry). Duplicates removed, trailing slashes stripped.
- Resolution is recursive: an alias may map to another bare alias.

## Shard cache

Successful `v1/<char>.yaml` responses are cached under
`~/.cache/klua/shards/` (`$XDG_CACHE_HOME/klua/shards` when set). A sibling
`.ts` file records the fetch time; entries younger than `klua.shard_ttl`
(default one hour) are reused without contacting the registry, so repeated
installs and `klua search` runs are instant.

```sh
klua install --no-cache fd   # refetch v1/f.yaml now
klua search --no-cache fd    # bypass cache for all 27 shards
```

If a refresh fails, a stale cached body is used with a warning. Set
`klua.shard_ttl = 0` in `~/.config/klua/init.lua` to disable reuse entirely.
Only HTTP 200 responses are cached; 404s and invalid YAML still fall through
to the next registry.

## Shard format

`v1/f.yaml`:

```yaml
fd: gh:sharkdp/fd
fzf: gh:junegunn/fzf
```

Valid target schemes: `gh:user/repo[@tag]`, `gl:user/repo[@tag]`,
`url:https://...`, `apt:pkg`. Aliases starting with a digit or symbol go
in `v1/_.yaml`.

## The official registry

Embedded default in `builtin/default_init.lua`:

```
https://raw.githubusercontent.com/kiru0414/klua-registry/main
```

Starter content lives in [`registry-template/`](../registry-template/README.md)
of this repository. Copy its `v1/` contents to the **root** of the registry
repository — nesting them under `registry-template/v1/` makes every shard
404.

### Contributing an alias

1. Fork `kiru0414/klua-registry`.
2. Open (or create) the shard for your alias's first character under `v1/`.
3. Add one line, keeping entries sorted:
   ```yaml
   mytool: gh:you/mytool
   ```
4. Open a pull request. Nothing in klua needs rebuilding — registries are
   fetched at runtime, so merged aliases work immediately.

Guidelines: point at repositories with real releases (or a `klua.yaml`
with `build.steps`); prefer upstream repos over forks; one canonical
alias per tool, extra spellings as additional entries (`rg` and `ripgrep`).

## Hosting your own tap

Any static HTTPS file host works — GitHub, GitLab, S3, nginx, even a
local server for testing.

### GitHub recipe

1. Create a repository (any name, e.g. `klua-tap`), public or private*
   with the layout:
   ```
   v1/f.yaml
   v1/j.yaml
   ...
   ```
2. The tap URL is the raw base:
   ```
   https://raw.githubusercontent.com/<you>/<repo>/main
   ```
3. Register it:
   ```sh
   klua tap add https://raw.githubusercontent.com/<you>/<repo>/main
   klua install mytool
   ```

*Private repos need auth on raw fetches; `klua.http_get` sends no tokens,
so use a public repo or a host with signed URLs.

### Local testing

```sh
mkdir -p tap/v1
printf 'hello: gh:jqlang/jq\n' > tap/v1/h.yaml
python3 -m http.server 8000 --directory tap &
klua tap add http://127.0.0.1:8000
klua install hello
```

### Managing taps

```sh
klua tap add <url>       # appends to ~/.config/klua/taps.yaml (deduplicated)
klua tap list
klua tap remove <url>
```

`taps.yaml` is a plain YAML list:

```yaml
- https://raw.githubusercontent.com/you/klua-tap/main
- https://corp.example/registry
```

Taps shadow the official registry because they are consulted first —
useful for pinning internal forks of popular tools.

## Replacing the default registry

In `~/.config/klua/init.lua`:

```lua
klua.registries = { "https://corp.example/klua-registry" }
```

Setting it to `{}` disables registry defaults entirely (taps still apply).
