[English](../index.md) | [日本語](index.md)

![](asset/logo-1.svg)
# klua

**C++20** と **Lua 5.4**（sol2）で構築された、**Linux と macOS** を対象とする高速・依存ゼロ・自己修復型のパッケージマネージャーです。

> **Homebrew より安全で、Nix よりシンプル、そして Lua で無限にハッキング可能。**

HTTP、展開、ファイルシステム、YAML といった重処理はネイティブの C++20 が担い、解決ロジック、プロバイダー、ライフサイクルフックは Lua で拡張できます。パッケージは個別に分離されたストアに保管され、共有ライブラリが `~/.local/bin` を汚すことはありません。シンボリックリンクを作成する前に PATH の競合を検出し、`init.lua` を書き換えれば再コンパイルなしですべてのプロバイダーやコマンドを進化させられます。

## インストール
```sh
curl -fsSL https://raw.githubusercontent.com/kiru0414/klua/main/install.sh | bash
```


## ドキュメント

- [はじめに](getting-started.md) — インストール、XDG パス、CLI、自己修復
- [klua.yaml マニフェスト](klua-yaml.md) — assets、bins、configs、build.steps
- [Lua API リファレンス](lua-api.md) — ネイティブプリミティブ、フック、レシピ
- [Taps とレジストリ](taps-and-registry.md) — エイリアスのシャーディング、tap の公開、エイリアスの貢献

## 設計思想

- **分離されたストア。** すべてのバージョンは `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` 配下にそのまま展開され、`~/.local/bin` には選択されたバイナリへのシンボリックリンクのみが置かれます。
- **共有ライブラリの汚染なし。** `.so`、`.so.*`、`.dylib`、`.a`、`.la`、`.dll` ファイルがグローバルにリンクされることはありません。`klua run` は、起動するプロセスに対してのみ `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` を通じてこれらを公開します。
- **PATH 競合の自動保護。** リンクを作成する前に klua は `PATH` を走査して既存コマンドを警告し、`--force` が指定されない限り保護されたコアコマンドを覆い隠すことを拒否します。また、衝突を避けるため `--as NAME` も利用できます。
- **検証済みダウンロード。** 展開前に、一致する `.sha256`、`.sha256sum`、`checksums.txt` アセットを検査します。不一致の場合は、`--skip-checksum` が明示的に指定されない限りインストールを中止します。ロックされたインストールでは `packages.lock.yaml` に記録された正確な SHA-256 も検証されます。trust-on-first-use（初回利用時の信頼）は厳格に運用されるため、ロックファイル自体が未変更でも、上流のペイロードが変更されていれば中止されます。さらに、任意の `verify:` コマンドフックで、展開前に `cosign verify-blob`、`gpg
   --verify`、あるいは任意のホストツールを実行できます。
- **リモートコマンドの明示的な承認。** リモートの `klua.yaml` が提供するシェルコマンド（`build.steps` と `verify:`）は、黙って実行されることはありません。自動化では `--yes` / `-y` を渡すか、表示されたコマンドを対話的に確認します。EOF や非対話的な stdin は拒否として扱われます。
- **元に戻せるプレビュー。** `sync --dry-run` と `upgrade --dry-run` は、ダウンロード、リンク、ロックファイルの書き込みを行わずに、対象パッケージ、バージョン変更、使用するシステムコマンドを表示します。
- **再現可能なインストール。** `sync --lock` はバージョン、アセット URL、ダイジェストを記録します。`sync --locked` はリリース探索を行わずにこれらを再現し、わずかな不一致でも失敗します。
- **既定で並列処理。** レジストリシャードの取得と複数パッケージのアーカイブダウンロードは、上限付きの C++20 ワーカープール（同時リクエストは最大 8 件）を共有し、結果は入力順に返されます。
- **自己進化する Lua カスタマイズ。** 組み込みのベースラインが常にフォールバックとなり、`init.lua` でプロバイダー、コマンドハンドラー、リンク方針を実行時に上書きできます。`klua repair` はカスタム Lua を黙って破棄せず、バックアップするようになりました。

## ステータス

マイルストーン 1、2、3 に加え、v0.4.0 の安全性リリース、v0.5.0 の解決／検証リリース、v0.6.0 の委譲／再現性リリース、v0.7.0 のパフォーマンス／耐障害性リリース、v0.8.0 の安全性とプレビューのリリースが実装済みです：

**マイルストーン 1 — コアスケルトン**

- `builtin/default_init.lua` を生成される `embedded_assets.hpp` の生文字列リテラルに埋め込む CMake ビルド。
- CLI11 のサブコマンド: `install` / `i`、`add`、`sync`、`upgrade`、`repair`、`tap`、`list`。
- 自己修復起動を備えた sol2 エンジン: 組み込み Lua ベースラインを最初に読み込み、その後 `~/.config/klua/init.lua` を保護された呼び出しで実行します。ユーザーファイルに構文エラーや実行時エラーがある場合、klua は明確な英語の診断を表示し、組み込みのデフォルトにフォールバックします。
- `klua repair` は組み込みベースラインから `~/.config/klua/init.lua` を復元します（ネイティブ実装のため、Lua が壊れていても動作します）。まず既存ファイルを `~/.config/klua/init.lua.bak.<timestamp>` にバックアップし、そのパスを表示します。`klua repair --dry-run`（`--diff`）は、ファイルを一切変更せずにバックアップパスと unified diff をプレビューします。

**マイルストーン 2 — フェッチャーとインストーラー**

- ネイティブ HTTPS クライアント（cpp-httplib + OpenSSL）：`klua.http_get`、`klua.http_head_redirect`、`klua.download`（ストリーミング、リダイレクト追従）、`klua.sha256`（OpenSSL EVP）。
- システムの `tar` / `unzip` によるアーカイブ展開（`.tar.gz`、`.tar.xz`、`.tar.bz2`、`.tar`、`.zip`）。単一の最上位ディレクトリは自動的に取り除かれます。POSIX シンボリックリンクと `chmod +x` はネイティブに処理されます。
- エイリアスのシャーディング: 修飾子のないターゲットは、設定されたレジストリ／tap から取得した `v1/<first_char>.yaml` を通じて解決され、メモリ上で解析されます（yaml-cpp）。
- `gh:user/repo[@tag]`: 最新タグは `releases/latest` の HTTP リダイレクトから検出し、アセットは `releases/expanded_assets/<tag>` から解析します。REST API はフォールバックにすぎません。OS／アーキテクチャによるアセットのスコアリング、キャッシュへのダウンロード、チェックサム検証、`~/.local/share/klua/store/gh/<user>/<repo>/<version>/` へのそのままの展開、バイナリ検出（ELF／Mach-O のマジックナンバーまたは実行ビット）、`~/.local/bin/` へのシンボリックリンク作成を行います。
- `gl:`（GitLab Releases）と `url:`（直接ダウンロード）のプロバイダー。
- `klua tap add/remove/list` は `taps.yaml` 内のレジストリを管理します（重複は排除されます）。
- `klua list` はストアからインストール済みパッケージを列挙します。

**マイルストーン 3 — マニフェスト、sync、リリース対応**

- リポジトリ内の `klua.yaml` マニフェスト（リリースのヒューリスティックより先に検査されます）：`assets`（glob パターン）、`bins`（明示的にリンクするバイナリ）、`configs`（ユーザーの場所へコピーするファイル、`~` に対応）、`build.steps`（適切なリリースアセットがない場合に `git clone` でソースからビルド）。
- `klua add <target...>` はターゲットを `packages.yaml` に記録します（重複は排除されます）。
- `klua sync [path_or_url]` は宣言された一式をインストールします。既定値は `~/.config/klua/packages.yaml` で、`includes:` を循環検出付きで再帰的に辿り、エントリの重複を排除します。
- `klua upgrade [target...]` は最新リリースを再インストールしてバージョン変更を報告します。引数なしの場合は、インストール済みのすべての gh/gl パッケージをアップグレードします。
- `klua remove <target...>`（`rm`、`uninstall`）は `~/.local/bin` のシンボリックリンク、ストアディレクトリ、対応する `packages.yaml` のエントリを削除します。
- `klua init-manifest [--force]` は雛形の `klua.yaml` を生成します。
- 公式レジストリの既定値: `https://raw.githubusercontent.com/kiru0414/klua-registry/main`（githubusercontent.com）。シャードの雛形は `registry-template/v1/` にあります。`v1/` の内容を `klua-registry` リポジトリの**ルート**にコピーしてください（`registry-template/` のラッパーではありません）。
- `.github/workflows/release.yml` は `v*` タグで静的 Linux バイナリ（x86_64 + arm64）と macOS バイナリ（x86_64 + arm64）をビルドし、GitHub リリースに添付します。

**v0.4.0 — 競合の安全性、分離実行、管理**

- リンクを作成する前に klua は `PATH` を走査し、保護されたコアコマンド（`git`、`curl`、`python`、`python3`、`apt`、`sudo`、`klua`、…）を覆い隠すことを拒否し、既存バイナリについて警告します。パッケージ自体はストアにインストールされたままです。`klua install --force` でこれらのガードを明示的に上書きでき、`klua install --as NAME` でプライマリバイナリのコマンド名を指定できます。
- 共有／静的ライブラリ（`.so`、`.so.*`、`.dylib`、`.a`、`.la`、`.dll`）は `~/.local/bin/` にリンクされず、ストア内に分離されたままになります。
- `klua run <target> [args...]` は、パッケージが存在しない場合にリンクを作成せずストアへ配置し、ストアの `bin` ディレクトリを `PATH` に、ストアのライブラリを `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` に設定してバイナリを実行します。
- `klua search <query>` はすべてのレジストリシャード（`a`～`z` と `_`）を検索します。`klua info <target>` は解決結果、インストール済みバージョン、ストアパス、リンク、リリースメタデータを表示します。`klua cleanup` は古いバージョン、壊れたリンクやライブラリリンク、キャッシュを整理します。`klua doctor` はディレクトリ、PATH、レジストリ、リンクを検査します。
- Levenshtein による誤字ヒントは、サブコマンド（`install`、`run`、`search`、`info`、`cleanup`、`doctor`、`remove`/`rm`/`uninstall`、…）、フラグ（`--force`、`--as`、`--no-cache`、`--skip-checksum`、`--dry-run`、…）、レジストリエイリアスを対象とします。例えば `klua serach jq` と打ち間違えると `search` が提案されます。
- `klua repair` は既定で非破壊です。カスタム Lua を `init.lua.bak.<timestamp>` にバックアップしてパスを表示します。`--dry-run` / `--diff` はファイルを変更せずにバックアップパスと unified diff を表示します。

**v0.5.0 — レート制限なしの解決、シャードキャッシュ、チェックサム**

- GitHub インストールでは、最初に `api.github.com` を呼び出さなくなりました。`https://github.com/<user>/<repo>/releases/latest` への HEAD リダイレクトからタグを取得し、`releases/expanded_assets/<tag>` からダウンロードリンクを得ます。タグを固定している場合はリダイレクトを完全にスキップします。REST API はフォールバックとして残り、`GITHUB_TOKEN` または `GH_TOKEN` が設定されている場合は `Authorization: Bearer` を自動的に送信します。
- レジストリシャードは既定で 1 時間、`~/.cache/klua/shards/` にキャッシュされます（`init.lua` の `klua.shard_ttl`）。`--no-cache` は再取得を強制します。ネットワーク障害時は、警告を出して古いキャッシュエントリを再利用します。
- 選択されたリリースアセットは `klua.sha256` でハッシュ化され、展開前に一致する `.sha256`、`.sha256sum`、`checksums.txt` アセットと比較されます。不一致の場合は明確なエラーで中止します。`--skip-checksum` を指定すると検証を明示的にスキップできます。GitLab Releases も同じ検証経路を使用します。
- `--no-cache` と `--skip-checksum` は `install`、`run`、`search`、`info`、`cleanup`、`doctor`、`sync`、`upgrade`、`remove` で受け付けられ、Levenshtein による誤字ヒントの対象にも含まれます。

**v0.6.0 — システム処理の一括委譲、CI トークン、ロックファイル**

- `sys:pkg1,pkg2,...`（および `apt:`、`dnf:`、`yum:`、`pacman:`、`apk:`、`brew:`）は、まずパッケージの状態を確認し、パッケージごとに `sudo` を呼び出すのではなく、**1 回**のマネージャーコマンドですべての未インストールパッケージをインストールします。`klua.yaml` の `depends:` も同じキューを使用し、インストール済みパッケージはスキップされます。`klua.system.manager`、`.status()`、`.install()` で検出処理を上書きできます。
- ネイティブ HTTP クライアントは、`GITHUB_TOKEN`/`GH_TOKEN` が設定されていれば `api.github.com` に `Authorization: Bearer` を送信し、`GITLAB_TOKEN` が設定されていれば GitLab API エンドポイントに `PRIVATE-TOKEN` と Bearer を送信します。`KLUA_GITHUB_API_HOST` / `KLUA_GITLAB_API_HOST` を使えば、信頼できるセルフホスト型ミラーでも同じ動作を有効にできます。トークンが raw ファイルやダウンロード先に送られることはありません。
- `packages.lock.yaml` は、解決された各ターゲットのプロバイダー、バージョン、アセット URL、SHA-256 を記録します。`sync --lock` はこれを書き出し、`sync --locked` はこれを必須として Web／API によるリリース探索をスキップし、展開前に記録済みダイジェストを検証します。`install --lock` / `install --locked` も同様に動作します。
- スターターレジストリには、現在 `ripgrep`、`fd`、`bat`、`eza`、`fzf`、`zoxide`、`starship`、`neovim`/`nvim`、`gh`、`lazygit`、`glab` が含まれます。

**v0.7.0 — 並列バッチ、耐障害性のある解決、署名フック**

- ネイティブの `klua.http_get_batch(urls)` と `klua.download_batch(items)` は、上限付き C++20 スレッドプール（最大 8 ワーカー、ワーカーごとに 1 つの `httplib::Client`）を使用します。`klua search` は不足しているシャードを並列取得し、`klua sync` と `klua upgrade` は解決済みのアーカイブをすべて並行ダウンロードします。結果は常に呼び出し元の入力順に保たれます。
- GitHub リリースの解決は、失敗に強い 3 段階のチェーンになりました：`releases/expanded_assets/<tag>` の HTML スクレイパー、次に `releases.atom`、そして REST API です。**0 件**のアセットとして解析されたページは失敗として扱われるため、空だが成功したリリースとして偽装されることはありません。
- `packages.lock.yaml` は trust-on-first-use のピンとして強制されます。`sync --locked` はダウンロードしたアセットを再ハッシュし、不一致があれば中止するため、上流での黙々とした改ざんを防ぎます。`--locked` は `--skip-checksum` と併用できません。
- 任意の `verify:` コマンド（`klua.yaml` 内、または `init.lua` の `klua.verify.command`）は、チェックサム検証後、展開前に実行されます。コマンドテンプレートには `{payload}`、`{asset}`、`{version}`、`{target}`、`{sha256}` を埋め込めます。Lua の `klua.verify.hook(context)` でペイロードを直接検査・拒否することもできます。検証は fail-close（失敗時は拒否）で動作します。

**v0.8.0 — 明示的な承認、プレビュー、ドリフト報告**

- `install`、`remove`、`run`、`sync`、`upgrade` は `--yes` / `-y` を受け付けます。リモートの `klua.yaml` にある `build.steps` とマニフェストの `verify:` コマンドは表示され、対話的またはこのフラグによって承認する必要があります。拒否された場合、clone、ビルド手順、検証コマンドが実行される前にインストールは失敗します。
- `remove` は `--lock` がなくても対応する `packages.lock.yaml` のエントリを整理するため、後で `sync --locked` を実行しても意図的に削除したパッケージが復活しません。ベースラインはカスタムコマンドハンドラー向けに `klua.lockfile.prune(removed)` も公開しています。
- `run --upgrade`（別名 `run --latest`）は固定された `@tag` を無視し、最新リリースをストアのみに配置してから実行します。ターゲットより後のフラグは klua に消費されず、パッケージのバイナリへ転送されます。
- `url:` のストアパスは、完全な正規 URL の SHA-256 の先頭 12 文字をキーとします：`store/url/<host>/<stem>-<url-hash>/direct`。ホストとファイル名が同じでも URL が異なる場合、`info`、`remove`、`klua run` で衝突しなくなりました。
- `klua outdated [targets...]` はインストール済みの `gh:` / `gl:` バージョンを最新リリースと比較し、利用可能なアップグレードを一覧表示します。
- `sync --dry-run` と `upgrade --dry-run` は、ストア、リンク、ロックファイルを変更せずに、アクション、バージョン変更、生成される `sys:` コマンドをプレビューします。`--dry-run` は `--lock` と併用できません。

完全なロードマップは `AGENTS.md` を参照してください。

## テスト

```sh
bash tests/test_milestone1.sh   # offline: CLI, repair, self-healing, XDG
bash tests/test_milestone2.sh   # network: taps, alias sharding, real installs
bash tests/test_milestone3.sh   # add/sync/upgrade + local manifest & build tests
bash tests/test_ux.sh           # remove, CLI/alias typo suggestions
bash tests/test_v04.sh          # offline: conflict safety, run, management, repair
bash tests/test_v05.sh          # offline: API-free GitHub, shard cache, SHA-256
bash tests/test_v06.sh          # offline: sys batching, tokens, lockfiles
bash tests/test_v07.sh          # offline: parallel batches, 3-tier fallback, TOFU, verify
bash tests/test_v08.sh          # offline: approvals, pruning, run refresh, outdated, dry-run
```

## ビルド（Linux / macOS）

要件: CMake >= 3.24、C++20 コンパイラ（GCC 11+ / Clang 14+）、git。その他の依存関係（Lua 5.4、sol2、CLI11）はすべて CMake の `FetchContent` で自動取得されるため、システムパッケージは不要です。

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/klua --version
```

Windows では WSL 内でビルドしてください（本プロジェクトは POSIX のみを対象としています）：

```sh
wsl bash -c "cmake -S . -B build && cmake --build build -j"
```

## 使い方

```sh
klua tap add https://example.com/klua-registry  # register an alias registry
klua install fd               # alias sharding -> v1/f.yaml -> gh:sharkdp/fd
klua install gh:jqlang/jq     # direct GitHub Releases install
klua i gh:jqlang/jq@jq-1.7.1  # pinned tag
klua install --force git      # override shadowing/protected-command guard
klua install --as jq2 jq      # link the primary binary as ~/.local/bin/jq2
klua install --no-cache fd    # refetch the registry shard instead of using cache
klua install --skip-checksum jq  # bypass SHA-256 verification (explicit)
klua install --yes gh:user/repo  # approve remote build.steps / verify commands
klua install sys:git,curl     # skip installed packages; batch the rest
klua sync --lock              # write versions, URLs and digests to the lockfile
klua sync --locked            # reproduce exactly; abort on any hash mismatch
klua sync --dry-run           # preview packages and sys commands; change nothing
klua install --locked gh:jqlang/jq  # TOFU: verify against the locked digest
klua run jq --version         # execute from the store, no global symlink
klua run --upgrade jq         # stage the newest release, then run it
klua run --latest gh:user/repo # alias for --upgrade
klua outdated                 # list installed gh/gl packages with newer releases
klua search jq                # search alias shards across all registries
klua info jq                  # resolution, versions, links, release metadata
klua cleanup                  # prune old versions, broken links and caches
klua doctor                   # diagnose dirs, PATH, registries, links
klua add gh:jqlang/jq fd      # record targets in packages.yaml
klua sync                     # install everything in packages.yaml
klua sync https://host/dotfiles.yaml  # remote source, follows includes:
klua upgrade --dry-run        # preview version changes and sys commands
klua upgrade                  # upgrade all installed packages
klua remove fd                # delete links, store dir, packages.yaml + lock entries
klua rm gh:jqlang/jq          # alias of remove
klua uninstall url:https://host/tool.tar.gz  # alias of remove
klua list                     # installed packages from the store
klua init-manifest            # starter klua.yaml for a package repo
klua repair                   # back up and restore a clean init.lua
klua repair --dry-run         # preview backup path and diff, change nothing
```

## ディレクトリ構成（XDG）

| 用途 | パス |
| ------- | ----------------------------------------------- |
| 設定  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `packages.lock.yaml`, `taps.yaml`) |
| ストア   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` |
| URL ストア | `~/.local/share/klua/store/url/<host>/<stem>-<url-hash>/direct/` |
| Bin     | `~/.local/bin/` (ストアへのシンボリックリンク)       |
| キャッシュ   | `~/.cache/klua/` (`downloads/`, `checksums/`, `build/`, `shards/`) |

`<url-hash>` は完全な正規ダウンロード URL の SHA-256 の先頭 12 文字（16 進数）です。そのため、異なるパスにある同名ファイルも分離されたままになります。

ライブラリは `~/.local/bin/` にリンクされません。ストア内に留まり、`klua run` に対して `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` を通じて公開されます。

`XDG_CONFIG_HOME`、`XDG_DATA_HOME`、`XDG_CACHE_HOME` による上書きにも対応しています。

## カスタマイズ

カスタムプロバイダーを登録したりコマンドハンドラーを上書きしたりするには、`~/.config/klua/init.lua` を編集します：

```lua
klua.register_provider("my", function(rest, target)
    klua.info("custom provider handling " .. target)
    return 0
end)
```

Lua から利用できるネイティブプリミティブ: `klua.info/warn/error`、`klua.file_exists/is_dir/is_executable/read_file/write_file/mkdir/copy/remove/list_dir`、`klua.find_executables`、`klua.readlink`、`klua.env`、`klua.exec`、`klua.confirm`、`klua.register_provider`、`klua.http_get/http_get_batch/http_head_redirect/download/download_batch`、`klua.sha256/sha256_text`、`klua.extract/is_archive`、`klua.symlink`、`klua.chmod_exec`、`klua.json_parse/yaml_parse`、`klua.platform`、`klua.paths`、`klua.version`。1 時間のキャッシュ有効期間を変更するには `klua.shard_ttl` を設定し、独自ハンドラーから `--no-cache`、`--skip-checksum`、`--lock`、`--locked`、`--yes`、`--latest`、`--upgrade`、`--dry-run` を確認するには `klua.cli_flags` を参照します。`klua.system` でシステムパッケージの検出・状態確認・インストールを上書きでき、`klua.lockfile` は解析済みのロックエントリと `require/get/record/verify/save/prune` ヘルパーを公開します。カスタムハンドラーで `klua.install_opts = { force = ..., link = ..., as = ... }` を設定すると、競合の上書き制御、プライマリリンクの改名、ストアのみ（実行専用）のインストールを指定できます。ここが「self-evolving」の部分です。`klua.commands.<name>` を再バインドするか `init.lua` でプロバイダーを登録すると、CLI の動作が即座に変わります。
