# klua official registry template

This folder is the starter content for the official alias registry
(`kiru0414/klua-registry`).

> **Deployment path matters:** copy the *contents* of this folder — the
> `v1/` directory (and optionally `README.md`) — to the **root** of the
> `klua-registry` repository. Do **not** commit the `registry-template/`
> wrapper directory itself, or shards end up at `registry-template/v1/`
> and klua's `<registry>/v1/<char>.yaml` requests will 404.

klua fetches shards from:

```
https://raw.githubusercontent.com/kiru0414/klua-registry/main/v1/<char>.yaml
```

That URL is the default registry embedded in `builtin/default_init.lua`.
The resulting repository layout must be:

```
README.md
v1/
  b.yaml
  f.yaml
  ...
```

## Shard format

Each `v1/<char>.yaml` file is a flat YAML mapping of alias -> scheme target.
The shard character is the lowercase first letter of the alias; aliases
starting with a non-letter live in `v1/_.yaml`.

```yaml
fd: gh:sharkdp/fd
fzf: gh:junegunn/fzf
```

The starter shards include aliases for `ripgrep`, `fd`, `bat`, `eza`, `fzf`,
`zoxide`, `starship`, `neovim`/`nvim`, `gh`, `lazygit` and `glab`.

Supported target schemes: `gh:user/repo[@tag]`, `gl:user/repo[@tag]`,
`url:https://...`, `sys:pkg1,pkg2` (also `apt:pkg`, `brew:pkg`, ...).

## Adding an alias

1. Pick the shard file for the alias's first character.
2. Add one `alias: scheme-target` line (keep entries sorted).
3. Open a pull request. No rebuild of klua is needed — registries are
   fetched at runtime.
