# klua.yaml — リポジトリ内パッケージマニフェスト

`gh:user/repo` または `gl:user/repo` をインストールするとき、klua はまずリポジトリのルートから `klua.yaml` を取得します。

```
https://raw.githubusercontent.com/<user>/<repo>/<ref>/klua.yaml   (gh)
https://gitlab.com/<user>/<repo>/-/raw/<ref>/klua.yaml            (gl)
```

`<ref>` は固定されたタグ（`repo@tag`）または `HEAD` です。`@VERSION` による固定はスキーム付きターゲットだけでなくエイリアスにも適用され、`klua install rg@14.0.0` はエイリアスを解決してからリリースを固定します。ファイルが存在し、正常に解析できた場合、リリースのヒューリスティックを上書きします。ファイルがない場合、不正な場合、あるいはコメントのみの場合、klua は黙ってアセットのスコアリングにフォールバックします。

> **Homebrew より安全で、Nix よりシンプル、そして Lua で無限に拡張可能。**
> マニフェストは分離されたストア内に何を置くかだけを記述し、それを*どのように*公開するかはコアが決定します。ライブラリファイルはストア内に留まり、シンボリックリンクを作成するたびに PATH の衝突が確認され、ダウンロードはチェックサムで検証され、Lua フックでポリシーを詳細に調整できます。

## v0.4.0+ のマニフェスト連携

- `bins` は、自動検出された実行ファイルと同じ衝突安全なリンカーに渡されます。ライブラリのように見える名前（`.so`、`.so.*`、`.dylib`、`.a`、`.la`、`.dll`）は警告付きでスキップされ、`~/.local/bin` にリンクされることはありません。
- `klua install --as NAME` はマニフェストの**主要な**バイナリを `NAME` としてリンクします。追加の `bins` は各自のベースネームを保持します。`klua install --force` は、指定した名前に対する保護コマンドや PATH 衝突のガードを上書きします。
- `klua run <target> [args...]` は、シンボリックリンクを作成せずに、ストアのライブラリを `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` に設定したうえで、マニフェストのバイナリをストアから直接実行します。
- インストール済みのマニフェストは `klua search`、`klua info`、`klua cleanup`、`klua doctor`、`klua remove`（エイリアス `rm`、`uninstall`）で管理できます。これらの名前やフラグの入力ミスには、レーベンシュタイン距離による候補が提示されます。
- v0.5.0 は REST API を使わずに `gh:` リリースを解決し（HEAD リダイレクト + `expanded_assets`）、展開前に選択したアセットを対応する `.sha256`、`.sha256sum`、または `checksums.txt` で検証します。明示的にスキップするには `--skip-checksum` を、1 時間キャッシュされたコピーではなくエイリアスのシャードを再取得するには `--no-cache` を使用します。
- v0.6.0 はシステムパッケージの委譲のために `depends:` を追加しました。不足しているパッケージは 1 回の klua 実行全体から収集され、1 つのマネージャーコマンドでインストールされます。すでにインストール済みのパッケージはスキップされます。`--lock` / `--locked` は解決されたバージョン、URL、ダイジェストを `packages.lock.yaml` に記録し、再現します。
- v0.7.0 は、チェックサム検証後かつ展開前に実行される任意の署名コマンドのために `verify:` を追加しました。リリースの検出では REST API の前に `releases.atom` へフォールバックするようになり、`expanded_assets` のスクレイピング結果が空の場合は失敗として扱われます。
- v0.8.0 では、リモートマニフェスト由来のシェルコマンドの実行に承認が必要になりました。`build.steps` と `verify:` は実行前に表示され、`--yes` / `-y` を指定しない限り、標準入力が対話的でない場合は拒否されます。`sync --dry-run` と `upgrade --dry-run` は、予定されたコマンドを表示するだけで実行しません。
- `init.lua` 内のカスタム Lua で、マニフェストを処理するプロバイダーやコマンドハンドラーを上書きできます。`klua repair` はベースラインを復元する前に `init.lua` を `init.lua.bak.<timestamp>` にバックアップします。プレビューには `klua repair --dry-run` / `--diff` を使用してください。

任意のリポジトリで雛形を生成できます。

```sh
klua init-manifest            # writes ./klua.yaml, refuses to overwrite
klua init-manifest --force    # overwrite
```

## スキーマ

すべてのフィールドは省略可能です。未知のフィールドは無視されます。

```yaml
depends:                     # system packages (batched) or other targets
  - git
  - sys:curl
  - gh:jqlang/jq

assets:                      # list of glob patterns
  - "mytool-*-linux-*.tar.gz"

bins:                        # list of paths relative to the store root
  - mytool
  - bin/helper

configs:                     # list of {src, dest} mappings
  - src: config.example.toml
    dest: ~/.config/mytool/config.toml

verify:                      # optional signature/artifact command
  - "cosign verify-blob --signature {payload}.sig {payload}"

build:
  steps:                     # list of shell commands
    - cargo build --release
```

## verify（署名検証）

`verify` には、単一のコマンド文字列、コマンドのリスト、`command` フィールドを持つマッピング、あるいはフックを明示的に無効化する `false` を指定できます。コマンドはチェックサム検証後、展開前に実行され、終了コードが 0 以外ならインストールが中止されます。`{payload}` / `{file}`、`{asset}`、`{version}`、`{target}`、`{sha256}` はシェルでクォートされた値に置き換えられ、ファイルのプレースホルダーがなければペイロードのパスが末尾に追加されます。

```yaml
verify: "cosign verify-blob --certificate {payload}.pem {payload}"
```

`init.lua` のグローバルな `klua.verify.command` は、マニフェストに `verify:` フィールドがない場合に適用されます。また、`klua.verify.hook(context)` は `false`、0 以外の数値、またはエラーを返してペイロードを拒否できます。検証は fail-close です。ツールが見つからない場合やフックが拒否した場合、インストールは停止します。**リモート**マニフェスト由来のコマンドは対話的に、または `--yes` / `-y` で承認する必要があります。グローバルな `init.lua` のコマンドは信頼されます。詳細は [lua-api.md](lua-api.md#signature-verification) を参照してください。

## assets（アセット）

リリースアセットを明示的に選択します。パターンは `*` （任意の文字列）と `?` （1 文字）に対応します。一致判定は大文字と小文字を区別し、アンカー付きです（アセット名全体が一致する必要があります）。

- いずれかのパターンに一致した最初のアセットが選択されます（アセットは Web/API の順序で、パターンはリストの順序で走査されます）。
- チェックサムのサイドカーは選択時には無視されますが、ダウンロード後の検証用に保持されます。
- `assets` が存在すると、OS/アーキテクチャのスコアリングは**完全に置き換えられます**。OS/アーキテクチャのトークンはパターン側に自分で含めてください。
- 一致するものがない場合、klua は `build.steps`（あれば）へ進み、それもなければインストールは失敗します。

```yaml
assets:
  - "mytool-*-x86_64-unknown-linux-musl.tar.gz"
  - "mytool-*-linux-amd64.tar.gz"     # fallback pattern
```

`assets` がない場合、klua はすべてのリリースアセットをスコアリングします。OS トークンは一致する必要があり（`linux`、または `darwin` / `macos` / `apple`）、アーキテクチャが異なるアセットは除外され、チェックサム/署名/パッケージ（`.sha256`、`.sig`、`.deb`、`.rpm`、...）は無視されます。アーキテクチャが完全一致するものが最高得点となり、アーカイブと musl ビルドはわずかなボーナスを得ます。

## bins（バイナリ）

実行可能にして `~/.local/bin` へシンボリックリンクするバイナリです。パスはストアのルート（つまり、最上位ディレクトリが 1 つだけの場合にそれを除去した後の展開済みアーカイブ）からの相対パスです。各エントリはベースネームでリンクされます。

```yaml
bins:
  - nvim            # -> ~/.local/bin/nvim
  - bin/extra-tool  # -> ~/.local/bin/extra-tool
```

- パスが存在しない場合は、明確なエラーでインストールが失敗します。
- `bins` がない場合、klua は実行ファイル（ELF/Mach-O のマジックバイト、またはいずれかの実行ビット）を自動検出し、最適な候補をリンクします。まずリポジトリ名と一致するもの、次に `bin/` 配下のファイル、そして最短のパスの順です。
- `bins` がない生の（アーカイブではない）リリースアセットは、リポジトリ名でリンクされます（`jq-linux-amd64` -> `jq`）。
- すべてのリンクは作成前に `PATH` と保護コマンド一覧に対して確認されます。衝突してもインストールは失敗せず警告が出るだけで、パッケージはストアに残ります。上書きするには `--force` を、主要なバイナリに別のコマンド名を付けるには `klua install --as NAME <target>` を使用してください。

## configs（設定ファイル）

リンク作成後にストアからユーザーの場所へコピーされるファイルです。

```yaml
configs:
  - src: config.example.toml          # relative to the store root
    dest: ~/.config/mytool/config.toml
  - src: completions/
    dest: ~/.local/share/bash-completion/completions/   # trailing / = directory
```

- `~` は `$HOME` に展開されます。
- `dest` の末尾が `/` の場合は「このディレクトリにコピーする」という意味です（ソースのベースネームが追加されます）。
- 親ディレクトリは作成され、既存のファイルは上書きされます。
- `src` が存在しない場合はインストールが失敗します。

<a id="depends"></a>
## depends（依存関係）

ツールが必要とするシステムパッケージです。スキームのないエントリ、またはシステムスキーム（`sys:`、`apt:`、`apt-get:`、`dnf:`、`yum:`、`pacman:`、`apk:`、`brew:`）付きのエントリは、検証および重複排除され、**1 つ**のインストーラーコマンドにキューに入れられます。

```yaml
depends:
  - git
  - sys:curl,wget
  - brew:jq
  - target: gh:jqlang/jq    # non-system target, installed via its own provider
  - system:                 # grouped form is also supported
      - ca-certificates
      - openssl
```

- キューに入れる前に、検出されたマネージャーでパッケージの状態が確認されるため、インストール済みのパッケージは報告されてスキップされます。
- マニフェストとコマンドラインにわたる不足パッケージはすべて、`klua` の 1 回の実行につき 1 回、まとめてインストールされます。ソースビルドの場合、最初の `build.steps` コマンドが実行される前にこのバッチがフラッシュされます。
- 非システムのターゲット（例: `gh:user/repo` や単独のエイリアス）は通常のプロバイダーを通じてインストールされ、実行ごとに重複排除されます。
- `klua.system.manager`、`klua.system.status(pkg)`、`klua.system.install(pkgs)` で `init.lua` 内の検出とコマンドを上書きできます。詳細は [lua-api.md](lua-api.md#system-package-delegation) を参照してください。
- システムパッケージのインストールが失敗すると全体のインストールも失敗します。システムパッケージは `packages.lock.yaml` には記録されません。

## build.steps（ソースビルド手順）

**リリースがない**または**適切なアセットがない**場合に使用されるソースビルドのフォールバックです。

```yaml
build:
  steps:
    - cargo build --release
    - strip target/release/mytool
bins:
  - target/release/mytool
```

処理の流れ:

1. リモートマニフェストのコマンドは表示され、何かをクローンする前に、対話的に、または `klua install --yes` / `-y` で承認する必要があります。
2. `~/.cache/klua/build/<user>-<repo>` に対して `git clone --depth 1`（固定されている場合は `--branch <tag>` も付与）を実行します。
3. 各手順はシステムシェル経由で `cd <clone> && <step>` として実行されます。終了コードが 0 以外の場合、インストールは中止されます。
4. 生成されたバイナリが収集されます。まず `bins` のエントリ、次に `target/release/`、`build/`、`bin/` のうち最初に非空のもの、それ以外の場合はクローン全体を走査して実行ファイルを探します。
5. バイナリはバージョン `source`（または固定タグ）としてストアにコピーされ、chmod されてシンボリックリンクが作成されます。`configs` は通常どおり適用されます。

ミラーやローカルでのテスト向けに、クローン URL のベースを（`init.lua` の `klua.github_clone` / `klua.gitlab_clone` で）上書きできます。

## 完全な例

生バイナリのリリース。マニフェストは不要ですが、明示的な名前付けが必要です:

```yaml
bins:
  - mytool
```

ドキュメントと設定ファイルを含むアーカイブ:

```yaml
assets:
  - "mytool-*-linux-*.tar.gz"
bins:
  - mytool
configs:
  - src: config.example.toml
    dest: ~/.config/mytool/config.toml
```

リリースがまったくなく、純粋なソースビルドの場合:

```yaml
build:
  steps:
    - make -j4
bins:
  - build/mytool
```

## 優先順位の概要

1. マニフェストの `assets` パターン > OS/アーキテクチャのスコアリング。
2. マニフェストの `bins` > 実行ファイルの自動検出。
3. リリースのインストール > `build.steps`（ビルドはリリースがない場合、または一致するアセットがない場合にのみ実行されます）。
4. マニフェストの欠落/不正 > 何も行わない — ヒューリスティックはそのまま続行されます。
