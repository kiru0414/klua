# はじめに

klua は自己修復型のパッケージマネージャーです。C++20 コアが重量級の処理（HTTP、展開、ファイルシステム、YAML/JSON の解析）を担い、Lua 5.4 が判断（プロバイダー、解決、ライフサイクルフック）を担当します。対応 OS は Linux と macOS のみです。

> **Homebrew より安全、Nix よりシンプル、Lua で無限にハッカブル。**

つまり、パッケージのバージョンごとに分離されたストア、`~/.local/bin` への共有ライブラリの混入なし、シンボリックリンクを作成するたびの自動的な PATH 競合保護、そしていつでも進化させられる Lua の `init.lua` を意味します。`klua repair` は、埋め込みベースラインを復元する前にカスタムコードをバックアップします。

## インストール

### GitHub Releases から

すべての `v*` リリースには、静的リンクされた Linux バイナリ（x86_64、arm64）と macOS バイナリが添付されています:

[v0.8.0](https://github.com/kiru0414/klua/releases/download/v0.8.0/klua-v0.8.0-linux-x86_64.tar.gz)

```sh
curl -fsSL https://raw.githubusercontent.com/kiru0414/klua/main/install.sh | bash
```
`~/.local/bin` が `PATH` に含まれていることを確認してください:

```sh
export PATH="$HOME/.local/bin:$PATH"    # add to ~/.bashrc / ~/.zshrc
```

### ソースからビルド

必要なもの: CMake >= 3.24、C++20 対応コンパイラ（GCC 11+ / Clang 14+）、git、OpenSSL の開発用ヘッダー（Debian/Ubuntu では `libssl-dev`、macOS では `brew install openssl@3`）。それ以外（Lua 5.4、sol2、CLI11、yaml-cpp、nlohmann/json、cpp-httplib）は CMake の構成時に取得されます。実行時には `tar` が必要です。`unzip` は `.zip` アセットにのみ必要です。

```sh
git clone https://github.com/kiru0414/klua.git
cd klua
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/klua --version
```

完全静的リンクの Linux ビルド（CI が配布するもの）:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXE_LINKER_FLAGS=-static -DOPENSSL_USE_STATIC_LIBS=ON
cmake --build build -j
```

Windows では WSL 内でビルドしてください。サポート対象は POSIX のみです。

## XDG パス

| 目的 | デフォルト | 上書き |
| ------- | ------- | -------- |
| Config  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `packages.lock.yaml`, `taps.yaml`) | `XDG_CONFIG_HOME` |
| Store   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` | `XDG_DATA_HOME` |
| URL store | `~/.local/share/klua/store/url/<host>/<stem>-<url-hash>/direct/` | `XDG_DATA_HOME` |
| Bin     | `~/.local/bin/<name>` (symlinks into the store) | none (always `~/.local/bin`) |
| Cache   | `~/.cache/klua/` (`downloads/`, `checksums/`, `build/`, `shards/`) | `XDG_CACHE_HOME` |

上書き設定は絶対パスの場合のみ有効です。アーカイブはストアにそのまま展開され（最上位にディレクトリが 1 つだけある場合はそのラッパーが除去されます）、複雑なツールの相対的なレイアウトが保持されます。`<url-hash>` は正規化された完全な URL の SHA-256 の最初の 12 文字（16 進数）で、異なるパスから同名の `url:` をダウンロードした場合も互いに分離されます。

## 設計思想

- **分離されたストア:** バイナリとライブラリは `~/.local/share/klua/store/...` に配置され、`~/.local/bin` にはシンボリックリンクのみが置かれます。
- **共有ライブラリの混入なし:** ライブラリと見なされるファイルがグローバルにリンクされることはありません。`klua run` はストア内のライブラリを起動したプロセスに対してのみ公開します。
- **自動的な PATH 競合保護:** klua は `PATH` をスキャンし、衝突時にはスキップまたは警告を行い、コアコマンドを保護します。システムを黙って上書きする代わりに `--force` / `--as` を提供します。
- **再現可能なインストール:** `sync --lock` はバージョン、URL、ダイジェストを記録します。`sync --locked` はリリースの探索なしでそれらを再利用し、不一致があれば拒否します。
- **自己進化する Lua カスタマイズ:** `init.lua` でプロバイダーやコマンドハンドラーを差し替えられます。埋め込みベースラインが常に安全なフォールバックとなります。

## CLI

```
klua install [--force] [--as NAME] [--no-cache] [--skip-checksum] [--lock|--locked] [--yes] <target>...  (alias: klua i)
klua run [--no-cache] [--skip-checksum] [--yes] [--upgrade|--latest] <target> [--] [args...]  # store-only
klua search [--no-cache] <query>
klua info [--no-cache] <target>
klua cleanup [--no-cache]
klua doctor [--no-cache]
klua add <target>...
klua remove [--no-cache] [--yes] <target>...    (aliases: klua rm, klua uninstall)
klua sync [--no-cache] [--skip-checksum] [--lock|--locked] [--dry-run] [--yes] [path_or_url]
klua upgrade [--no-cache] [--skip-checksum] [--lock] [--dry-run] [--yes] [target...]
klua outdated [--no-cache] [target...]
klua tap <add|remove|list> [url]
klua list
klua repair [--dry-run|--diff]
klua init-manifest [--force]
klua --version | --help
```

サブコマンド、フラグ、エイリアスの入力ミスには、レーベンシュタイン距離に基づくヒントが表示されます。提案辞書には `install`、`run`、`search`、`info`、`cleanup`、`doctor`、`remove`/`rm`/`uninstall` や、`--force`、`--as`、`--no-cache`、`--skip-checksum`、`--lock`、`--locked`、`--dry-run`、`--diff`、`--yes`、`-y`、`--latest`、`--upgrade` といったフラグが含まれます:

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

対象はスキーム付きの指定か、単体のエイリアスです:

```sh
klua install gh:jqlang/jq        # GitHub Releases (latest)
klua i gh:jqlang/jq@jq-1.7.1     # pinned tag
klua install gl:user/repo        # GitLab Releases
klua install url:https://example.com/tool.tar.gz
klua install sys:git,curl        # install missing system packages in one batch
klua install apt:jq              # same delegation with an explicit manager
klua install fd                  # alias -> v1/f.yaml -> gh:sharkdp/fd
```

パイプライン: スキームの直接ディスパッチ、またはエイリアスのシャード検索を行い、続いて（gh/gl の場合）リリースの検出（`gh:` では API を使わずに実施）と、解決されたタグ時点でのリポジトリ内 [`klua.yaml`](klua-yaml.md) の確認を行います。その後、OS/アーキテクチャによるアセットのスコアリング、ダウンロード、SHA-256 検証、ストアへの展開、バイナリの検出（ELF/Mach-O のマジックバイトまたは実行ビット）、`chmod +x`、競合チェック付きの `~/.local/bin` へのシンボリックリンク作成が続きます。エイリアスの解決については [taps-and-registry.md](taps-and-registry.md) を、リリースの検出、キャッシュ、チェックサムについては以下のセクションを参照してください。

### API を使わない GitHub の解決

`gh:user/repo` は最初に `api.github.com` を呼び出しません。klua は `https://github.com/<user>/<repo>/releases/latest` に HEAD リクエストを送り、`Location` リダイレクトからタグを取得します。次に `releases/expanded_assets/<tag>` を取得し、パスに `/<user>/<repo>/releases/download/<tag>/...` を含む `href` リンクを解析します。タグを固定した指定（`gh:user/repo@v1.2.3`）ではリダイレクトをスキップし、そのタグのアセットページを直接読み取ります。これにより、未認証の REST 制限を完全に回避できます。

リリースの検出は、失敗に備えた 3 段階の連鎖です。expanded-assets ページが取得できない場合や、解析の結果ダウンロードリンクが **0 件** の場合、klua は直ちに次に `releases.atom` を読み取ります。フィードにも利用可能なアセットリンクがない場合、最後に REST API を呼び出します。空のスクレイピング結果は常に失敗とみなされ、空の成功として扱われることはありません。したがって、GitHub のレイアウトが変更されても、壊れたインストールが黙って作られることはありません。成功した解決結果は、そのコマンドの実行中はキャッシュされます。

REST 段階が実行されると、`GITHUB_TOKEN` または `GH_TOKEN`（この順序で）が `Authorization: Bearer ...` として自動的に送信されます。信頼できるカスタム API ホストについては、そのホスト名を `KLUA_GITHUB_API_HOST` に設定します。トークンはそのホストの API らしいパスにのみ送られます。

GitLab のリリースでは `klua.gitlab_api` を直接利用します。`GITLAB_TOKEN` が設定されている場合、GitLab API のエンドポイントへのリクエストには `PRIVATE-TOKEN` と `Authorization: Bearer ...` の両方が付与されます。セルフホスト環境では、ホスト名を `KLUA_GITLAB_API_HOST` に設定してください。いずれの場合も、トークンは API らしいパス（`/api/...` または `/repos/...`）にのみ付与され、生ファイルやアセットのダウンロードには付与されません。

### レジストリシャードのキャッシュ

取得した `v1/<char>.yaml` シャードは `~/.cache/klua/shards/` に保存され、TTL は 1 時間です（`init.lua` の `klua.shard_ttl`）。繰り返しのインストールや `klua search` ではキャッシュされた本文が再利用されます。`klua search` は、未取得のシャードをすべて `klua.http_get_batch` に送信します。これは最大 8 件の並行リクエストに制限された C++20 のワーカープールで、結果は入力順にキャッシュされます。`--no-cache` は強制的な再取得を意味します。再取得に失敗した場合は警告を出して古いエントリを再利用するため、オフラインでも作業を続けられます。

```sh
klua install --no-cache fd   # bypass the shard cache for this invocation
klua search --no-cache fd    # same for search (all 27 shards)
```

### SHA-256 検証

リリースに `<asset>.sha256`、`<asset>.sha256sum`、`checksums.txt` のいずれかが含まれる場合、klua はダウンロードしたファイルを OpenSSL EVP でハッシュ化し、展開 **前** にダイジェストを検証します。`<hash>  <filename>`、`<hash> *<filename>`、`SHA256(<filename>) = <hash>` の形式のチェックサム行に対応しており、アセット専用のサイドカーファイルには 64 文字の 16 進数だけのダイジェストも受け付けます。不一致の場合はインストールを中止し、ストアは変更されません。

```sh
klua install gh:jqlang/jq               # verifies automatically if a checksum exists
klua install --skip-checksum gh:jqlang/jq  # explicit bypass, warns and continues
```

ロックされたインストールでは、さらに厳しくなります。`packages.lock.yaml` に記録された SHA-256 は常に強制されます（初回利用時の信頼、trust on first use）。ロックファイルの書き込み後に上流のバイト列が変更された場合、`sync --locked` はロックファイル自体が編集されていなくても、展開前にハッシュの不一致を検出して中止します。`--locked` と `--skip-checksum` は同時に指定できません。

GitLab のリリースも同じ検証パスを通ります。レジストリやチェックサムファイル自体には署名がありません。この機構はダウンロードの途中中断や破損から守るものであり、悪意を持って公開されたチェックサムから守るものではありません。

### 署名検証フック

署名付きアーティファクトでは、`klua.yaml` に `verify:` を追加してください（`init.lua` で `klua.verify.command` を設定しても構いません）。このコマンドはチェックサム検証後、展開前に実行され、終了コードが 0 以外の場合はインストールを中止します。プレースホルダー `{payload}`、`{asset}`、`{version}`、`{target}`、`{sha256}` はシェルに対して安全な引用符で置換され、テンプレート内でペイロードが明示されていない場合はそのパスが末尾に追加されます:

```yaml
verify: "cosign verify-blob --signature {payload}.sig --certificate {payload}.pem {payload}"
```

```lua
-- Global alternative in ~/.config/klua/init.lua
klua.verify = {
    command = "cosign verify-blob {payload}",
    hook = function(ctx)
        if ctx.sha256 == "" then return false end
        return true
    end,
}
```

マニフェストの `verify: false` は、そのパッケージのフックを無効化します。検証は fail-close（安全側に倒す）方式で、ツールが見つからない場合やフックが拒否した場合はインストールが停止します。詳細は [lua-api.md](lua-api.md#signature-verification) を参照してください。

### リモートコマンドの承認

リモートの `klua.yaml` に記述されたコマンドは、既定では信頼されません。`build.steps` やマニフェストの `verify:` コマンドを実行する前に、klua はすべてのコマンドを表示して承認を求めます。受け付けられるのは `y` または `yes` のみです。EOF（非対話的な標準入力）やその他の回答は拒否とみなされ、インストールは中止されます。スクリプトでは `install`、`remove`、`run`、`sync`、`upgrade` に `--yes` / `-y` を渡してください:

```sh
klua install gh:user/source-only-tool   # prompts before build.steps
klua install --yes gh:user/source-only-tool
klua sync -y
```

ローカルの `init.lua` のフックは信頼されます。承認機構はリモートリポジトリのマニフェストに埋め込まれたコマンドを対象とします。`--dry-run` では、確認プロンプトと実行の両方がスキップされます。

### システムパッケージの委譲

`sys:pkg1,pkg2,...` と明示的なマネージャースキーム（`apt:`、`apt-get:`、`dnf:`、`yum:`、`pacman:`、`apk:`、`brew:`）は、ホストのパッケージマネージャーに処理を委譲します。klua はまず各パッケージのインストール状態を確認し、すでに存在するものはスキップして、残りをキューに入れます。1 回の CLI 実行で見つかった未インストールのパッケージは、パッケージごとに `sudo` を起動するのではなく、**1 つ** のマネージャーコマンド（Debian/Ubuntu では `sudo apt-get install -y ...`、macOS では `brew install ...` など）でインストールされます。マニフェストの [`depends:`](klua-yaml.md#depends) に記載されたパッケージも同じキューを使用します。

```sh
klua install sys:git,curl,wget   # one batch; already-installed packages skipped
klua install apt:jq              # force a particular manager scheme
```

マネージャーは実行時に `dpkg-query`、`dnf`、`yum`、`pacman`、`apk`、`brew` から検出されます。`init.lua` で `klua.system.manager` を設定して上書きするか、独自環境向けに `klua.system.status(pkg)` / `klua.system.install(pkgs)` フックを提供できます。詳細は [lua-api.md](lua-api.md#system-package-delegation) を参照してください。

<a id="locked-installs"></a>
### ロックされたインストール

`packages.lock.yaml` は設定ディレクトリ内の `packages.yaml` と同じ場所に置かれ、解決された各対象のプロバイダー、バージョン、アセット URL、SHA-256 を正確に記録します:

```yaml
version: 1
entries:
  gh:jqlang/jq:
    provider: gh
    version: jq-1.7.1
    asset: jq-linux-amd64
    url: https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
    sha256: 0123456789abcdef...
```

```sh
klua sync --lock      # resolve normally, then write/update the lockfile
klua sync --locked    # require the lockfile; install exactly what it records
klua install --locked gh:jqlang/jq
```

`--locked` を指定した場合、ロックファイルがないときや対象が記録されていないときは、klua は実行を拒否します。最新タグのリダイレクト、リリースページ、REST API の呼び出しをスキップし、記録された URL をダウンロードして、展開前に記録済みのダイジェストを検証します。タグがロックされたバージョンと一致しない場合、URL が変更された場合、ハッシュが一致しない場合はインストールに失敗します。`--locked` は `--lock` および `--skip-checksum` と排他です。`upgrade --lock` はエントリを更新します。`upgrade --locked` は拒否されます。アップグレードはロックされた再現とは正反対の操作だからです。システムパッケージとカスタムスキームはロックされません。

`klua remove` は `--lock` を指定しなくても `packages.lock.yaml` から該当するエントリを削除します。そのため、後で `sync --locked` を実行しても、意図的に削除したパッケージが再インストールされることはありません。カスタムハンドラーから `klua.lockfile.prune(removed)` を呼び出すこともできます。

### ドライランによるプレビュー

`sync --dry-run` と `upgrade --dry-run` は、入力を解決して実行される内容を表示します。未インストールの `sys:` パッケージに対して生成されるシェルコマンドも正確に表示されます。アーカイブのダウンロード、ストアの変更、リンクの作成、ロックファイルへの書き込みは行いません。`upgrade --dry-run` は予定されたバージョン変更を `v1.0.0 -> v2.0.0` の形式で報告します。`--dry-run` は `--lock` と併用できません。実際のコマンドの前に、読み取り専用の計画ステップとして利用してください。

```sh
klua sync --dry-run                 # preview packages.yaml actions
klua upgrade --dry-run gh:jqlang/jq # preview one upgrade
```

### 競合時の安全性

リンクを作成する前に、klua は `PATH` をスキャンし、次のように動作します:

- `git`、`curl`、`python`、`python3`、`apt`、`sudo`、そして `klua` 自身などの保護されたコアコマンドを覆い隠すことを拒否します。
- `PATH` 上またはリンク先に同名のバイナリが存在し、klua が管理していない場合は警告します。
- 共有・静的ライブラリ（`.so`、`.so.*`、`.dylib`、`.a`、`.la`、`.dll`）は決してリンクしません。これらはストア内に留まります。

リンクがスキップされてもインストールの失敗にはなりません。パッケージはストアに配置されたままになります。ストア内のファイルを指す既存のリンクは通常どおり置き換えられるため、アップグレードも問題なく動作します。これらの保護を明示的に無効にするには `--force` を、競合しないコマンド名でインストールするには `--as NAME` を指定してください:

```sh
klua install git                # warns and leaves ~/.local/bin/git alone
klua install --force git        # creates the link anyway
klua install --as jq2 jq        # links ~/.local/bin/jq2 instead of ~/.local/bin/jq
```

`--as` はプライマリのバイナリのみをリネームします。同じパッケージに含まれる追加のバイナリは各自の名前を保持します。対象は 1 つである必要があり、パス区切り文字や `.` / `..` は拒否され、選択した名前ですべての競合チェックが引き続き実行されます。

### run

```sh
klua run jq --version
klua run gh:jqlang/jq -r '.version'
klua run --upgrade gh:jqlang/jq@jq-1.7.0   # ignore the pin; run the latest release
klua run --latest jq                       # alias for --upgrade
```

`run` はインストール済みの最新ストアバージョンからライブラリ以外の実行ファイルを選び、必要であればパッケージをストアのみに（シンボリックリンクなしで）インストールして、ストアの `bin` ディレクトリを `PATH` の先頭に追加し、ストアのライブラリディレクトリを `LD_LIBRARY_PATH`（macOS では `DYLD_LIBRARY_PATH`）に設定した状態で実行します。対象より後ろの引数は、フラグも含めて変更せずにそのまま渡されます。明示的に区切るには `--` を使用します。klua のフラグは対象 **より前** に置く必要があります。`--upgrade` / `--latest` は固定された `@tag` を外し、最新リリースをストアに配置して、リンクを作成せずにそのバイナリを実行します。

### search / info

```sh
klua search bzip3   # substring match in aliases and targets, all shards a-z + _
klua info fd        # alias resolution, installed versions, links, release info
```

`search` は設定されたすべてのレジストリのすべてのシャードを（tap を優先して）走査し、`alias<TAB>target` の一致結果をエイリアス順に出力します。エイリアスを最初に定義したレジストリが優先されます。`info` はローカルの状態についてはオフラインでも動作し、リリース情報を取得できない場合にのみ警告を出します。

### cleanup / doctor

```sh
klua cleanup        # keep newest version per package; remove stale links/caches
klua doctor         # report dirs, PATH, registries, broken/shadowed links
```

バージョンの並び順は数字を考慮します（`1.10.0` は `1.9.0` より新しいと判定されます）。`cleanup` は古いストアバージョン、存在しないストアファイルを指すシンボリックリンク、ライブラリへのリンク、および `downloads/` と `build/` のキャッシュを削除します。`doctor` が終了コード `1` を返すのは実際のエラー（書き込み不可のディレクトリなど）がある場合のみで、警告は参考情報です。

### add / sync

```sh
klua add gh:jqlang/jq fd         # record targets in packages.yaml (deduped)
klua sync                        # install everything in packages.yaml
klua sync ./dotfiles.yaml        # explicit local source
klua sync https://host/set.yaml  # remote source; follows includes:
klua sync --lock                 # write versions/URLs/digests to the lockfile
klua sync --locked               # reproduce exactly from the lockfile
klua sync --dry-run              # preview actions without touching state
```

`packages.yaml` は `includes:`（再帰的で循環も安全に処理）と `packages:` に対応し、重複する対象は 1 回だけインストールされます。ソースとして YAML の単純なリストも使用できます。複数のアーカイブを取得する必要がある場合、`sync` はまずすべての対象を解決し、その後 `klua.download_batch`（シャードで使用したものと同じ 8 ワーカーまでのプール）でダウンロードし、`batch: downloading N asset(s) in parallel` を出力します。事前取得に失敗した場合は、通常のプロバイダーのパスで再試行されます。

ロックの意味については [ロックされたインストール](#locked-installs) を参照してください。

### upgrade

```sh
klua upgrade                     # every installed gh/gl package
klua upgrade gh:jqlang/jq        # one target (aliases resolved too)
klua upgrade --dry-run           # preview version changes and sys commands
klua outdated                    # list packages with newer releases available
klua outdated gh:jqlang/jq       # check one explicit target
```

複数のパッケージを同時にアップグレードする場合、`upgrade` は `sync` と同じ並列事前取得を使用します。

最新リリースを再インストールし、`upgraded X: old -> new` または `X is up to date (version)` を報告します。`--lock` を追加すると、新たに解決されたバージョンでロック済みエントリを更新できます。`outdated` は読み取り専用です。インストール済みの `gh:` / `gl:` バージョンを最新リリースと比較し、アップグレード可能なものには `outdated: <target> <installed> -> <latest>` を、それ以外の場合は `outdated: all checked packages are up to date` を出力します。

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

削除は完全に行われます。パッケージのストアディレクトリを指す `~/.local/bin` 内のシンボリックリンクが削除され、ストアのツリー（`~/.local/share/klua/store/<provider>/<user>/<repo>/`）が取り除かれ、`packages.yaml` の該当するエントリ（単体のエイリアス、解決済みの対象、タグなしのスキーム指定）も整理されます。該当する `packages.lock.yaml` のエントリも削除されるため、`--locked` で削除済みのパッケージが復活することはありません。インストールされていないパッケージを削除しようとするとエラーが報告され、何も変更されません。

### repair

```sh
klua repair
klua repair --dry-run    # or: klua repair --diff
```

埋め込みのクリーンなベースラインから `~/.config/klua/init.lua` を復元します。C++ でネイティブに実装されているため、Lua が壊れていても動作します。上書きの前に、現在のファイルが `~/.config/klua/init.lua.bak.<timestamp>` にコピーされ、バックアップ先のパスが表示されます。カスタムの Lua が黙って失われることはありません。ファイルがすでにベースラインと一致している場合は、何も書き込まれません。`--dry-run` / `--diff` はバックアップ先のパスと、適用予定の変更の unified diff を表示するだけで、すべてのファイルを変更せずに残します。

<a id="self-healing-behavior"></a>
## 自己修復の動作

`repair` を除くすべてのコマンドの起動時の流れ:

1. 埋め込みの Lua ベースライン（ビルド時にバイナリに組み込まれる）が最初に読み込まれ、常に成功します。
2. その上で、あなたの `~/.config/klua/init.lua` が保護された呼び出し（protected call）で実行されます。
3. ファイルに構文エラーや実行時エラーがある場合、klua は Lua の診断メッセージを表示し、Lua の状態をすべて破棄して埋め込みベースラインを再読み込みし、既定のロジックで処理を続けます:

```
error: failed to load /home/you/.config/klua/init.lua: [string "..."]:1: ...
warning: falling back to the built-in default logic. Run 'klua repair' to restore a clean init.lua.
```

壊れた設定ファイルがツールを使えなくすることはありません。ファイルを修正するか、`klua repair` を実行してください。

## 終了コード

`0` は成功、`1` はあらゆる失敗（使用方法のエラー、プロバイダーのエラー、Lua のエラー）です。Lua のコマンドハンドラーが他のコードを返す場合があり、CLI はそのまま渡します。

## 次のステップ

- プロバイダーやフックのカスタマイズ: [lua-api.md](lua-api.md)
- 自分のリポジトリをパッケージ化する: [klua-yaml.md](klua-yaml.md)
- レジストリの運用や貢献: [taps-and-registry.md](taps-and-registry.md)
