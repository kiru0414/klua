# タップとエイリアスレジストリ

スキーム指定のないターゲット（`klua install fd`）は、**エイリアスシャーディング**によって
解決されます。静的な HTTPS ホストから実行時に取得される小さな YAML ファイルによる
仕組みで、データベースもサーバー側の処理もなく、単なるファイルだけです。

## 解決パイプライン

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

詳細：

- シャードファイルはフラットなマッピングです：`alias: scheme-target`。
- レジストリは順番に試され、そのエイリアスを含む最初の HTTP 200 が
  採用されます。404 や不正な YAML の場合は次のレジストリに進みます。
- 順序はまず `taps.yaml` のエントリ、次に `klua.registries`（既定では公式
  レジストリ）です。重複は除去され、末尾のスラッシュも取り除かれます。
- 解決は再帰的です。エイリアスが別のスキームなしエイリアスを指す場合があります。

## シャードキャッシュ

成功した `v1/<char>.yaml` レスポンスは
`~/.cache/klua/shards/`（設定時は `$XDG_CACHE_HOME/klua/shards`）に
キャッシュされます。隣接する `.ts` ファイルが取得時刻を記録し、
`klua.shard_ttl`（既定は 1 時間）より新しいエントリはレジストリへ
問い合わせず再利用されるため、再インストールや `klua search` は
即時です。シャードが欠落または古い場合、`klua search` は 1 件ずつではなく、
`klua.http_get_batch`（最大 8 ワーカーに制限された C++20 プール）で一括取得します。

```sh
klua install --no-cache fd   # refetch v1/f.yaml now
klua search --no-cache fd    # bypass cache for all 27 shards
```

更新に失敗した場合は、警告を出して古いキャッシュ本文を使用します。再利用を
完全に無効にするには `~/.config/klua/init.lua` で `klua.shard_ttl = 0` を
設定します。キャッシュされるのは HTTP 200 レスポンスのみで、404 や不正な
YAML は引き続き次のレジストリへ処理が移ります。

## シャード形式

`v1/f.yaml`:

```yaml
fd: gh:sharkdp/fd
fzf: gh:junegunn/fzf
```

有効なターゲットスキーム：`gh:user/repo[@tag]`、`gl:user/repo[@tag]`、
`url:https://...`、`sys:pkg1,pkg2`（`apt:pkg`、`brew:pkg` なども可）。数字や
記号で始まるエイリアスは `v1/_.yaml` に入ります。初期シャードには
`ripgrep`、`fd`、`bat`、`eza`、`fzf`、`zoxide`、`starship`、`neovim`/`nvim`、
`gh`、`lazygit`、`glab` が含まれます。

## 公式レジストリ

`builtin/default_init.lua` に埋め込まれた既定値：

```
https://raw.githubusercontent.com/kiru0414/klua-registry/main
```

初期コンテンツはこのリポジトリの [`registry-template/` のスターターコンテンツ](https://github.com/kiru0414/klua/tree/main/registry-template) に
あります。その `v1/` の内容をレジストリリポジトリの**ルート**にコピー
してください。`registry-template/v1/` 下に置くと、すべてのシャードが
404 になります。

### エイリアスのコントリビューション

1. `kiru0414/klua-registry` をフォークします。
2. `v1/` 配下で、エイリアスの先頭文字に対応するシャードを開きます（または作成します）。
3. エントリをソートした状態で、次の 1 行を追加します：
   ```yaml
   mytool: gh:you/mytool
   ```
4. プルリクエストを作成します。klua の再ビルドは不要です。レジストリは
   実行時に取得されるため、マージされたエイリアスはすぐに利用できます。

ガイドライン：実際のリリースがあるリポジトリ（`build.steps` 付きの `klua.yaml` が
あるリポジトリも可）を指し、フォークよりアップストリームを優先してください。
正規エイリアスはツールごとに 1 つとし、別表記は追加エントリ（`rg` と `ripgrep`）にします。

## 独自のタップをホストする

静的な HTTPS ファイルホストであればどこでも利用できます。GitHub、GitLab、S3、
nginx、テスト用のローカルサーバーでも構いません。

### GitHub での手順

1. リポジトリを作成します（名前は任意、例：`klua-tap`）。公開・プライベート*の
   どちらでも構いません。構成は次のとおりです：
   ```
   v1/f.yaml
   v1/j.yaml
   ...
   ```
2. タップ URL は raw のベース URL です：
   ```
   https://raw.githubusercontent.com/<you>/<repo>/main
   ```
3. 登録します：
   ```sh
   klua tap add https://raw.githubusercontent.com/<you>/<repo>/main
   klua install mytool
   ```

*プライベートリポジトリは raw 取得時に認証が必要ですが、`klua.http_get` はトークンを
送信しません。公開リポジトリ、または署名付き URL に対応するホストを使用してください。

### ローカルでのテスト

```sh
mkdir -p tap/v1
printf 'hello: gh:jqlang/jq\n' > tap/v1/h.yaml
python3 -m http.server 8000 --directory tap &
klua tap add http://127.0.0.1:8000
klua install hello
```

### タップの管理

```sh
klua tap add <url>       # appends to ~/.config/klua/taps.yaml (deduplicated)
klua tap list
klua tap remove <url>
```

`taps.yaml` は単純な YAML リストです：

```yaml
- https://raw.githubusercontent.com/you/klua-tap/main
- https://corp.example/registry
```

タップは最初に参照されるため、公式レジストリより優先されます。人気ツールの
内部フォークを固定する場合に便利です。

## 既定のレジストリを置き換える

`~/.config/klua/init.lua` で設定します：

```lua
klua.registries = { "https://corp.example/klua-registry" }
```

`{}` にするとレジストリの既定値は完全に無効になります（タップは引き続き適用されます）。
