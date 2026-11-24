# Lua API リファレンス

klua でカスタマイズできるものはすべて `~/.config/klua/init.lua` にあります。組み込みのベースライン（`builtin/default_init.lua`、バイナリに埋め込まれています）が最初に実行され、既定のプロバイダーとコマンドハンドラーを定義します。その上でユーザーのファイルが保護呼び出し（protected call）で実行され、あらゆる要素を上書きできます。エラーが発生した場合は klua がベースラインにフォールバックします。詳細は [getting-started.md](getting-started.md#self-healing-behavior) を参照してください。

利用可能な Lua ライブラリは `base`, `string`, `table`, `math`, `os`, `coroutine`, `utf8` です。`io` と `package` はありません。代わりに後述のネイティブファイルプリミティブを使用してください。

> **Homebrew より安全、Nix よりシンプル、そして Lua で無限にハッカブル。**
> C++ コアは分離されたストアを強制し、共有ライブラリを `~/.local/bin` に置かせず、リンク前に
> PATH の競合を確認します。ポリシーを再定義するのが Lua の役割です。
> `init.lua` に不備があっても組み込みベースラインが自動的に再読み込みされ、
> `repair` がカスタムコードをバックアップするため、klua が使えなくなることはありません。

## Lua における設計思想

- すべてのパッケージバージョンは `klua.paths.store` 配下に展開されます。`klua.paths.bin` に置かれるのは、選択された実行ファイルのシンボリックリンクだけです。
- ライブラリ名はベースラインの `safe_link` ヘルパーによってフィルタリングされます。ストアのみにインストールするには `klua.install_opts.link = false` を使用し、ライブラリは `klua run` に対してのみ公開します。
- ベースラインはリンク前に `klua.env("PATH")` を走査し、コアコマンドを保護します。CLI からのインストールでは、`--force` と `--as NAME` がそれぞれ `install_opts.force` と `install_opts.as` として渡されます。
- `klua.commands.run`、`klua.commands.search`、`klua.commands.info`、`klua.commands.cleanup`、`klua.commands.doctor`、`klua.commands.remove` も、他のハンドラーと同じように再バインドできます。再ビルドは不要です。
- `gh:` の解決は既定では API を使用せず、REST API の前に `releases.atom` へのフォールバックを試みます。検証済みのチェックサムとオプションの署名フックが展開の可否を決定します。これら 2 つのポリシーはベースラインの Lua 内にあり、置き換え可能です。
- 独立した HTTP リクエストには上限付きのバッチプリミティブを使用するため、`search`、`sync`、`upgrade` は無制限にスレッドを生成することなく高速に動作します。

## グローバル変数

| 名前 | 型 | 意味 |
| ---- | ---- | ------- |
| `klua.version` | string | klua のバージョン（例: `"0.8.0"`） |
| `klua.paths` | table | `config`, `store`, `bin`, `cache`, `shards`, `init`, `packages`, `lock`, `taps`（絶対パスの文字列） |
| `klua.providers` | table | スキーム -> `function(rest, target)` |
| `klua.commands` | table | コマンド名 -> `function(args)`（終了コードを返す） |
| `klua.install_opts` | table | インストール時のフラグ: `force`（リンクガードを上書き）、`link`（`false` = ストアのみへのインストール）、`as`（`--as` によるプライマリリンク名） |
| `klua.registries` | array | エイリアスシャーディング用のレジストリベース URL（既定は公式レジストリ） |
| `klua.shard_ttl` | number | レジストリシャードキャッシュの有効期間（秒、既定値 `3600`）。`0` で再利用を無効化 |
| `klua.cli_flags` | table | `no_cache`, `skip_checksum`, `locked`, `lock`, `yes`, `latest`, `upgrade`, `dry_run`（ディスパッチ前に CLI スイッチから公開される） |
| `klua.system` | table | システムパッケージ委譲の上書き: `manager`, `status`, `install` |
| `klua.lockfile` | table | パース済みの `packages.lock.yaml` の状態（`entries`, `loaded`）と `prune` などのヘルパー |
| `klua.verify` | table | オプションの署名フック: `command`, `hook` |

### サービスエンドポイントの上書き

ミラー、GitHub Enterprise、テスト用には、`init.lua` で以下を設定します。

```lua
klua.github_api   = "https://api.github.com"          -- Releases API base
klua.gitlab_api   = "https://gitlab.com/api/v4"       -- Releases API base
klua.raw_github   = "https://raw.githubusercontent.com"  -- klua.yaml fetch base
klua.raw_gitlab   = "https://gitlab.com"                 -- klua.yaml fetch base
klua.github_web   = "https://github.com"              -- web release redirect/assets
klua.github_clone = "https://github.com"              -- git clone base (build.steps)
klua.gitlab_clone = "https://gitlab.com"              -- git clone base (build.steps)
```

REST フォールバックが `api.github.com` にアクセスする際、`GITHUB_TOKEN` / `GH_TOKEN` が `Authorization: Bearer` ヘッダーとして追加されます。信頼できるカスタムホスト名を `KLUA_GITHUB_API_HOST` に設定すると、そのホストの API パスにも同じヘッダーが付与されます（生ファイルやダウンロードには付与されません）。

GitLab API へのリクエストでは、`GITLAB_TOKEN` が `PRIVATE-TOKEN` と `Authorization: Bearer` として送信されます。セルフホスト環境では `KLUA_GITLAB_API_HOST` を設定してください。カスタムホストにトークンが送られるのは API らしいパス（`/api/...` または `/repos/...`）のみで、マニフェスト、生ファイル、アセットのダウンロードには送られません。

## ロギング

```lua
klua.info("message")    -- stdout, plain
klua.warn("message")    -- stderr, "warning: " prefix
klua.error("message")   -- stderr, "error: " prefix
```

## ファイルシステムプリミティブ

| 関数 | 戻り値 | 備考 |
| -------- | ------- | ----- |
| `klua.file_exists(path)` | bool | |
| `klua.is_dir(path)` | bool | ディレクトリの場合に true（シンボリックリンクを辿る） |
| `klua.is_executable(path)` | bool | 実行ビットが 1 つでも立っている通常ファイルの場合に true（PATH の走査に使用） |
| `klua.read_file(path)` | string or nil | ファイル全体、バイナリセーフ |
| `klua.write_file(path, content)` | ok, err | 親ディレクトリを作成し、内容を切り詰めて書き込む |
| `klua.mkdir(path)` | bool | 再帰的 |
| `klua.copy(src, dest)` | ok, err | バイト単位で同一、親ディレクトリを作成し、上書き |
| `klua.remove(path)` | ok, err | 再帰的。存在しないパスは何もしない |
| `klua.list_dir(path)` | array | エントリ `{name=, path=, is_dir=}`、ソート済み。存在しない場合は空 |
| `klua.find_executables(dir)` | array | 再帰的。ELF/Mach-O のマジックナンバーまたはいずれかの実行ビット。`.sha256 .sha256sum .sig .asc .md .txt .json .yaml .yml .pem .pub .html` をスキップ。ソート済み |
| `klua.symlink(target, link)` | ok, err | POSIX シンボリックリンク。切れたリンクを含む既存エントリを置き換え、親ディレクトリを作成 |
| `klua.readlink(path)` | string or nil | 生のシンボリックリンク先（解決なし）。シンボリックリンクでない場合は nil |
| `klua.chmod_exec(path)` | ok, err | `u+x,g+x,o+x` を追加 |
| `klua.cwd()` | string | プロセスの作業ディレクトリ |
| `klua.env(name)` | string or nil | 環境変数 |

"ok, err" は、成功時は `true, nil`、失敗時は `false, "message"` を意味します。

## プロセスの実行

```lua
local code = klua.exec("git clone --depth 1 https://... /tmp/x")
```

文字列はシステムシェル（`/bin/sh -c`）で実行され、正規化された終了コード（0 = 成功）が返ります。信頼できない値は自分でクォートしてください（ベースライン同様、シングルクォートで囲み `'\\''` でエスケープします）。

```lua
local approved = klua.confirm("execute these remote commands? [y/N] ")
```

`klua.confirm(prompt)` はプロンプトを表示し、stdin から 1 行読み取り、`y` または `yes` の場合のみ `true` を返します。EOF や非対話入力は拒否とみなされるため、スクリプトでは `--yes` / `-y` を使用します。ベースラインはこのフラグを `klua.cli_flags.yes` として公開し、リモートの `build.steps` や `verify:` コマンドを実行する前に `klua.confirm` を使用します。

`sync --dry-run` / `upgrade --dry-run` では `klua.cli_flags.dry_run` が true になります。ベースラインはこのフラグに基づき、ダウンロード、リンク、`sys:` コマンドの実行、ロックファイルへの書き込みの代わりに `dry-run: ...` の通知を出力します。カスタムハンドラーも、変更を伴う処理を追加する際は同じフラグを尊重すべきです。

## HTTP

```lua
local body, status, err = klua.http_get("https://api.github.com/...")
-- err ~= nil  -> transport failure (status 0, body "")
-- err == nil  -> status is the HTTP code; body is the response text

local location, status, err = klua.http_head_redirect(
    "https://github.com/user/repo/releases/latest")
-- HEAD without following redirects; Location may be "" on 200/404

local ok, err = klua.download("https://host/tool.tar.gz", "/path/dest")

-- Bounded parallel requests: at most 8 workers, one httplib::Client each.
-- Results are returned in input order.
local responses = klua.http_get_batch({
    "http://host/v1/a.yaml",
    "http://host/v1/b.yaml",
})
for _, response in ipairs(responses) do
    -- { body = string, status = number, error = string|nil }
end

local results = klua.download_batch({
    { url = "http://host/a.tar.gz", dest = "/cache/a.tar.gz" },
    { url = "http://host/b.tar.gz", dest = "/cache/b.tar.gz" },
})
for _, result in ipairs(results) do
    -- { url = ..., dest = ..., ok = bool, error = string|nil }
end
```

- `http_get_batch` と `download_batch` はネイティブのバッチプリミティブです。`klua search` は不足しているシャードの取得に、`klua sync` / `klua upgrade` はアーカイブの並行ダウンロードにこれらを使用します。各項目は専用の `httplib::Client` で取得され、結果は入力順に保持されます。プリフェッチに失敗した項目は、通常のプロバイダーによる再試行に任されます。
- HTTPS は OpenSSL 経由です。`http_get` と `download` はホストをまたぐリダイレクトも追跡します。
- `http_head_redirect` はリダイレクトを**追跡せず**、生の `Location` ヘッダーを返します。ベースラインはこれを API を使わないタグ検出に使用します。
- `User-Agent: klua/<version>` を送信します。`GITHUB_TOKEN` または `GH_TOKEN` が設定されている場合は、`api.github.com` へのリクエストに `Authorization: Bearer <token>` も付与されます。`GITLAB_TOKEN` が設定されている場合は、GitLab API へのリクエストに `PRIVATE-TOKEN` と Bearer 認証が付与されます。
- `download` はディスクへストリーミング書き込みし、親ディレクトリを作成し、HTTP 200 のみを受け付け、失敗時には途中までのファイルを削除します。
- 一時的な失敗（`403`、`429`、`5xx`、接続切断。GitHub のリリースアセット CDN でよく発生します）は、指数バックオフで最大 4 回まで再試行されます。
- タイムアウト: 接続 30 秒、読み取り 300 秒、書き込み 120 秒。

## SHA-256

```lua
local digest, err = klua.sha256("/path/to/archive.tar.gz")
-- digest: lowercase 64-character hex on success; "" plus err on failure

local url_digest = klua.sha256_text("https://host/dir/tool.tar.gz")
-- digest of an in-memory string; the baseline uses its first 12 characters
-- in url: store paths such as store/url/host/tool-<hash>/direct
```

どちらのヘルパーも OpenSSL の `EVP_Digest` を使用します。リリースに `<asset>.sha256`、`<asset>.sha256sum`、`checksums.txt` が含まれる場合、ベースラインは展開前にダウンロード済みペイロードに対して `sha256` を実行します。`<hash>  <filename>`、`<hash> *<filename>`、BSD 形式の `SHA256(<filename>) = <hash>`、およびアセット固有のサイドカー文件中的むき出しのダイジェストを受け付けます。不一致の場合、ストアにファイルが書き込まれる前に `SHA-256 mismatch for <asset>` が表示され、終了コード `1` となります。`klua.cli_flags.skip_checksum`（`--skip-checksum` 由来）は警告を出して検証をスキップします。ロックされたインストールでは、代わりに `packages.lock.yaml` に記録されたダイジェストを検証し、リリースのチェックサムサイドカーは無視されます。[Lockfile](#lockfile) を参照してください。ロック済みダイジェストは、カスタムプロバイダーがヘルパーを直接呼び出した場合でもスキップされません。これは上流のバイト列の変更を検出する初回信頼（trust-on-first-use）の保証です。

<a id="system-package-delegation"></a>

## システムパッケージの委譲

ベースラインは `sys:` およびマネージャー固有のスキーム（`apt:`, `apt-get:`, `dnf:`, `yum:`, `pacman:`, `apk:`, `brew:`）を実装しており、パッケージを 1 回のインストールバッチにキューイングします。キューイング前にステータスが確認され、重複する名前は除去されます。既定のマネージャーは実行時に利用可能なツールから検出されます。

| マネージャー | ステータス確認 | インストールコマンド |
| ------- | ------------ | --------------- |
| `apt` | `dpkg-query -W -f='${Status}' <pkg>` | `apt-get install -y -- <pkgs>` |
| `dnf` / `yum` | `rpm -q <pkg>` | `dnf install -y <pkgs>` / `yum install -y <pkgs>` |
| `pacman` | `pacman -Q <pkg>` | `pacman -S --noconfirm -- <pkgs>` |
| `apk` | `apk info -e <pkg>` | `apk add <pkgs>` |
| `brew` | `brew list <pkg>` | `brew install <pkgs>` |

すべてのコマンドはシングルクォートのエスケープ処理を経てシェルで実行されます。プロセスが root でない場合は `sudo` がバッチ全体に対して一度だけ付与されます（`brew` には付与されません）。`init.lua` でカスタマイズできます。

```lua
-- Option 1: choose a known manager (or any name when both hooks are supplied).
klua.system = {
    manager = "apt",
    status_cmd = "dpkg-query -W -f='${Status}' %s 2>/dev/null | grep -qx 'install ok installed'",
    install_cmd = "apt-get install -y -- %s",
}

-- Option 2: full hooks. `install` receives the whole missing batch as an array.
klua.system = {
    manager = "nix",
    status = function(pkg)
        return klua.exec("nix profile list | grep -q " .. pkg) == 0
    end,
    install = function(pkgs)
        return klua.exec("nix profile install nixpkgs#" .. table.concat(pkgs, " nixpkgs#"))
    end,
}
```

`status(pkg)` はインストール済みの場合に true（または数値の `0`）を返します。`install(pkgs)` は成功時に `0`/true を返します。どちらのフックも省略可能ですが、既知の実装がないカスタム `manager` 文字列では両方が必要です。マニフェストの `depends:` エントリのうち、スキームがないもの、またはシステムスキームのものは同じバッチを使用します。それ以外のターゲットは通常のプロバイダーにディスパッチされます。

<a id="lockfile"></a>

## ロックファイル

`packages.lock.yaml` は `klua.paths.lock`（通常は `~/.config/klua/packages.lock.yaml`）から読み込まれます。キーは正規化されたスキーム付きターゲットです。`gh:` / `gl:` ターゲットからタグが除去されるため、`gh:user/repo@v1` と `gh:user/repo` は同じエントリを共有します。各エントリには `provider`、`version`、`asset`、`url`、および小文字 64 文字の `sha256` が含まれます。

`--lock` は解決に成功した後にこれらの値を記録します。`--locked` はそれらの存在を要求し、新たなリリースの検出をスキップします。ベースラインは以下を公開します。

```lua
klua.lockfile.require()                         -- bool; --locked needs a lockfile
local entry = klua.lockfile.get(target, provider) -- nil, true on a locked-target error
klua.lockfile.record(target, provider, version, asset, url, sha256) -- only with --lock
local code = klua.lockfile.verify(payload, asset, entry, "my:provider")
klua.lockfile.save()                            -- writes the file only with --lock
klua.lockfile.prune({ ["gh:user/removed"] = true }) -- drop entries on remove
```

ロック機能をサポートしたいカスタムプロバイダーは、ネットワークアクセス前に `get()` を呼び、値が存在する場合は `entry.url` / `entry.version` を使用し、ダウンロード後に `verify()` を呼び、`--lock` が指定されていれば解決済みメタデータとともに `record()` を呼ぶ必要があります。組み込みの `gh:`、`gl:`、`url:` プロバイダーはすでにこの処理を行っています。`--locked` は `--lock` および `--skip-checksum` と同時に指定できません。`sys:` とリリース以外のカスタムスキームはロックされません。`verify()` はロックされた実行時に常にペイロードを再ハッシュし、不一致なら中止します。ロックファイルが以前に書き込まれ、その後上流アセットが変更されていても、TOFU は厳密に適用されます。

`prune(removed)` は正規化されたターゲットキーの集合を受け取り、一致するロックエントリを削除します。組み込みの `remove` ハンドラーは、削除が成功した後に `--lock` が指定されていない場合でもこれを呼び、何かが削除されたときは `lockfile pruned: N entry/entries removed` を報告します。`--dry-run` ではファイルを書き換える代わりにプレビューを出力します。

<a id="signature-verification"></a>

## 署名検証

オプションの検証段階は、チェックサム検証の後、展開の前に実行されます。そのため署名検証の失敗でストアに不完全な内容が残ることはありません。`klua.yaml` の `verify:` フィールド（または `init.lua` の `klua.verify.command`）はシェルコマンドのテンプレートで、`{payload}`、`{file}`、`{asset}`、`{version}`、`{target}`、`{sha256}` はシェル用にクォートされた値に置換されます。テンプレートにファイルのプレースホルダーがない場合は、ペイロードのパスが自動的に末尾に追加されます。`klua.verify.hook(context)` も同じフィールドを検査でき、`false`、0 以外の数値を返すか、エラーを発生させてペイロードを拒否できます。検証は fail-close です。ツールが見つからない、コマンドが 0 以外の値を返す、フックが拒否する、といった場合にはインストールが中止されます。**リモート**の `klua.yaml` で定義されたコマンドは表示され、実行前に対話的な承認または `--yes` / `-y` が必要です。`init.lua` のコマンドは信頼されます。そのパッケージのフックを無効にするには、マニフェストに `verify: false` を設定します。

```lua
klua.verify = {
    command = "cosign verify-blob --certificate {payload}.pem {payload}",
    hook = function(context)
        return context.sha256 ~= ""
    end,
}
```

## レジストリシャードのキャッシュ

`resolve_alias` と `klua.commands.search` は `klua.paths.shards` 配下のローカルキャッシュを共有します。`search` は不足しているシャードをすべて収集し、パース前に `klua.http_get_batch`（最大 8 並行リクエスト）で取得します。各 URL は安定したファイル名にハッシュされ、隣接する `.ts` ファイルに取得時刻が保存されます。`klua.shard_ttl`（既定 3600 秒）より新しいエントリはネットワークリクエストなしで再利用されます。`--no-cache` は `klua.cli_flags.no_cache = true` を設定して再取得を強制します。再取得に失敗した場合は、警告を出して古いエントリを再利用します。返されたボディは常に `klua.yaml_parse` でパースされます。

## アーカイブ

```lua
local ok, err = klua.extract("/cache/tool.tar.gz", "/store/tool/1.0")
klua.is_archive("tool.tar.gz")   -- true
```

対応形式は `.tar.gz`/`.tgz`、`.tar.xz`/`.txz`、`.tar.bz2`、`.tar`（システムの `tar`）、`.zip`（システムの `unzip`）です。展開はそのまま行われ、単一の最上位ラッパーディレクトリは自動的に除去されます。

## パース

```lua
local value, err = klua.json_parse(text)   -- GitHub/GitLab API responses
local value, err = klua.yaml_parse(text)   -- shards, taps, manifests
```

JSON オブジェクト / YAML マッピングはテーブルになり、配列 / シーケンスは 1 始まりのテーブルになります。スカラーは string/number/boolean/nil に対応します。パース失敗時は `nil, "message"` が返ります。

## プラットフォーム

```lua
local p = klua.platform()   -- { os = "linux"|"macos", arch = "x86_64"|"arm64" }
```

アセットのスコアリングに使用される、コンパイル時の識別情報です。

## プロバイダー

```lua
klua.register_provider("scheme", function(rest, target)
    -- rest:   everything after "scheme:"
    -- target: the full original target string
    return 0   -- exit code; non-number returns count as 0
end)
```

スキームは空ではなく、`:` を含んでいてはなりません。登録するとそのスキームの既存ハンドラーが上書きされます。これが組み込みの `gh`/`gl`/`url`/`apt` プロバイダーを置き換える方法です。プロバイダー内で発生したエラーは捕捉されて報告され、インストールは終了コード 1 で失敗します。

## コマンドハンドラー

CLI は `klua.commands.<name>(args)` をディスパッチします。`args` は位置引数の文字列からなる配列です。名前は `install`, `run`, `search`, `info`, `cleanup`, `doctor`, `add`, `remove`, `sync`, `upgrade`, `outdated`, `tap`, `list`, `init-manifest` です（ハイフンに注意: `klua.commands["init-manifest"]`）。`run` にはターゲットと、それ以降に渡されたすべての引数が渡されます。CLI 全体のスイッチ（`--no-cache`, `--skip-checksum`, `--lock`, `--locked`, `--yes`, `--latest`, `--upgrade`, `--dry-run`）は `klua.cli_flags` として公開され、`args` には含まれません。`run` は CLI11 の prefix コマンドであるため、klua のフラグはターゲットより前に置く必要があります。ベースラインはそこでフラグを消費し、ターゲット以降をパッケージのバイナリに転送します。プロセスの終了コードを返してください。自由に上書きしたりラップしたりできます。

```lua
local default_list = klua.commands.list
klua.commands.list = function(args)
    klua.info("== installed packages ==")
    return default_list(args)
end
```

## 競合安全なリンクと run の分離

ベースラインはすべてのリンクをローカルの `safe_link` ヘルパー（`builtin/default_init.lua` 内）に通します。以下の順に確認します。

1. `klua.install_opts.link == false` → リンクを完全にスキップ（ストアのみ）。
2. `klua.install_opts.as` → 最初にリンクするバイナリをそのコマンド名に変更（CLI の `--as NAME` 由来）。追加のバイナリは各自の名前を保持します。
3. ライブラリのように見える名前（`.so`, `.so.*`, `.dylib`, `.a`, `.la`, `.dll`）→ 警告を出し、ファイルをストア内に残します。
4. リンク先に既存の klua 以外のリンク/ファイルがある → `klua.install_opts.force` が設定されていない限り警告を出してスキップします。
5. 保護されたコアコマンド名（シェル、coreutils、ネットワークツール、言語ランタイム、コンパイラ、システムパッケージマネージャー、エディター、`klua`）→ 強制指定がない限り警告を出してスキップします。
6. `PATH` 上の別の場所に同じ名前の実行ファイルがある → 強制指定がない限り警告を出してスキップします。

リンクがスキップされても成功とみなされ、パッケージはストアに配置されます。すでにストアを指しているリンクは置き換えられるため、アップグレードが機能します。CLI は呼び出しごとにこれらのオプションを設定します。

```lua
-- klua install --force ...
klua.install_opts = { force = true, link = true }

-- klua install --as jq2 jq ...
klua.install_opts = { force = false, link = true, as = "jq2" }

-- klua run ... (install missing package store-only)
klua.install_opts = { force = false, link = false }
```

CLI はディスパッチ前に `--as` を検証します。単一の空でない名前であること、`/`、`.`、`..`、制御文字を含まないこと、インストールターゲットが 1 つだけの場合にのみ併用できることが必要です。選択された名前は、上述のライブラリ、占有、保護コマンド、PATH の各ガードをまったく同じように通過します。

`klua run` は、ストアの `bin` ディレクトリを `PATH` の先頭に、ストアのライブラリディレクトリを `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` の先頭に追加した状態で、選択されたバイナリをシェル経由で実行します。ライブラリディレクトリは `klua.is_dir` で最大 2 階層まで探索し、すべての引数に `shq()` 形式のシングルクォートエスケープを適用します。`klua.cli_flags.upgrade` または `klua.cli_flags.latest` が指定されている場合、ベースラインは固定された `@tag` を除去し、最新リリースをストアのみに強制的に再インストールして、そのバイナリを実行します。自らリンクを作成するカスタムプロバイダーは、`klua.install_opts.link` を尊重し、`klua.readlink`、`klua.is_executable`、`klua.env("PATH")` を用いて同等の競合チェックを行うべきです。

## 自己修復と `klua repair`

組み込みベースラインは `init.lua` より先に読み込まれます。ユーザーファイルに構文エラーや実行時エラーがあると、その内容が報告され、ベースラインが自動的に再読み込みされます。`repair` はネイティブに実装されているため、Lua が壊れていても動作します。

- `klua repair` は現在のファイルを `~/.config/klua/init.lua.bak.<timestamp>` にコピーし、そのパスを表示してから、組み込みベースラインを書き込みます。ファイルがすでに一致している場合は何も書き込まれません。
- `klua repair --dry-run`（別名 `--diff`）は、バックアップ先のパスと適用予定の変更の unified diff を表示するだけで、ファイルには触れません。

新しいコマンド名（`run`, `search`, `info`, `cleanup`, `doctor`, `outdated`, `remove`/`rm`/`uninstall`）とフラグ（`--force`, `--as`, `--no-cache`, `--skip-checksum`, `--dry-run`, `--diff`, `--yes`, `-y`, `--latest`, `--upgrade`）のタイプミス候補は、レーベンシュタイン距離に基づいて提示されます。

## レシピ

### 内部スキーム用のカスタムプロバイダー

```lua
klua.register_provider("corp", function(rest)
    local url = "https://artifacts.corp.example/tools/" .. rest .. ".tar.gz"
    local payload = klua.paths.cache .. "/downloads/" .. rest .. ".tar.gz"
    local ok, err = klua.download(url, payload)
    if not ok then klua.error(tostring(err)); return 1 end
    local store = klua.paths.store .. "/corp/tools/" .. rest .. "/latest"
    ok, err = klua.extract(payload, store)
    if not ok then klua.error(tostring(err)); return 1 end
    for _, bin in ipairs(klua.find_executables(store)) do
        klua.chmod_exec(bin)
        -- In production, guard this with the conflict checks described above
        -- and respect klua.install_opts.link / .force.
        klua.symlink(bin, klua.paths.bin .. "/" .. bin:match("([^/]+)$"))
    end
    return 0
end)
-- klua install corp:mytool
```

### GitHub トークンのフォールバック

ネイティブの HTTP クライアントは、`GITHUB_TOKEN`（優先）または `GH_TOKEN` が設定されていれば `api.github.com` に対して `Authorization: Bearer <token>` をすでに付与するため、プライベート REST フォールバックにモンキーパッチは不要です。通常のインストールは GitHub の Web エンドポイント経由で解決されるため、トークンはその検出経路が失敗したときにのみ使用されます。

カスタムホストの場合は、エンドポイントの上書きと環境変数 `KLUA_GITHUB_API_HOST` の両方を設定します。

```sh
export GH_TOKEN=ghp_...
export KLUA_GITHUB_API_HOST=github.corp.example
```

別の認証スキームが必要な場合は、従来どおり `klua.http_get` をラップしてください。ただし Web での検出には `klua.http_head_redirect` が使われるため、リダイレクト要求にもトークンが必要な場合はこちらもラップする必要があります。

### マニフェストなしでのカスタムソースビルド

```lua
klua.register_provider("src", function(rest)
    local dir = klua.paths.cache .. "/build/" .. rest:gsub("/", "-")
    klua.remove(dir)
    if klua.exec("git clone --depth 1 https://github.com/" .. rest .. " '" .. dir .. "'") ~= 0 then
        klua.error("clone failed"); return 1
    end
    if klua.exec("cd '" .. dir .. "' && make -j4") ~= 0 then
        klua.error("build failed"); return 1
    end
    local bins = klua.find_executables(dir .. "/bin")
    if #bins == 0 then bins = klua.find_executables(dir) end
    for _, bin in ipairs(bins) do
        klua.chmod_exec(bin)
        klua.symlink(bin, klua.paths.bin .. "/" .. bin:match("([^/]+)$"))
    end
    return 0
end)
-- klua install src:user/repo
```

リポジトリ側で管理するビルドには [`klua.yaml` `build.steps`](klua-yaml.md) を推奨します。ユーザー設定は不要です。

### GitHub Enterprise / ミラー

```lua
klua.github_api   = "https://github.corp.example/api/v3"
klua.github_web   = "https://github.corp.example"  -- releases/latest + expanded_assets
klua.raw_github   = "https://github.corp.example/raw"
klua.github_clone = "https://github.corp.example"
```

### tap を使わない追加レジストリ

```lua
klua.registries[#klua.registries + 1] = "https://corp.example/klua-registry"
```

tap（`klua tap add`）は `klua.registries` よりも先に参照されます。[taps-and-registry.md](taps-and-registry.md) を参照してください。
