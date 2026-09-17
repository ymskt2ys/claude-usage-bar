# ClaudeUsageBar

Claude のプラン使用率を macOS のメニューバーに常駐表示する。

```
5h 14% · 7d 31% · F 3%
```

- `5h` — 5 時間枠 (session limit)
- `7d` — 週の全体枠 (weekly_all)
- `F` — 週のモデル別枠 (weekly_scoped、現状は Fable)

クリックすると各枠のバー・パーセント・リセットまでの残り時間、データの取得時刻が出る。
75% で橙、90% で赤。60 秒ごとに自動更新。

## ビルドと起動

```bash
./build.sh
cp -R build/ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

`build.sh` は毎回 `build/` を作り直すので、常駐させる実体は `/Applications` に置く。

Xcode プロジェクトは不要。`swiftc` で 2 ファイルを直接コンパイルして `.app` を組み立てる。
`LSUIElement` を立てているので Dock にアイコンは出ない。

## ログイン時の自動起動

パネルの「ログイン時に起動」チェックボックスで切り替える (`SMAppService` でシステム設定の
ログイン項目に登録する)。コマンドラインからも操作できる。

```bash
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --enable-login-item
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --disable-login-item
```

登録は `.app` のパスに紐づく。アプリを移動したら、移動前のパスで `--disable-login-item`、
移動後のパスで `--enable-login-item` を実行して登録し直す。

## データの取り方

枠ごとにソースが違う。上から順に試して、取れたところで確定する。

| 枠 | ソース | 認証 | 更新頻度 |
|---|---|---|---|
| 5時間枠・週(全体) | `~/Library/Application Support/Claude/plan-usage-history.json` | 不要 | Claude デスクトップアプリが 15 分ごとに記録 |
| 週(モデル別 = Fable) | `GET https://api.anthropic.com/api/oauth/usage` | OAuth 必要 | 都度 |
| 上が全部ダメな時 | `~/.claude.json` の `cachedUsageUtilization` | 不要 | Claude Code CLI が動いた時だけ |

モデル別の週枠は**ローカルのどこにも保存されていない**ので、API が通らないとキャッシュの古い値になる。
パネルでは古い値の行に「9/14 12:50 時点」と注記が出る。

キャッシュの値は、その枠のリセット時刻を過ぎたら 0 に戻っているはずなので、もう信用できない。
その場合は数字を出さず `—` にして「リセット済みで不明」と注記する。古い数字を黙って出し続けない。

### OAuth について

Keychain の `Claude Code-credentials` から `claudeAiOauth.accessToken` を読む。
期限切れなら `POST https://platform.claude.com/v1/oauth/token` (`grant_type=refresh_token`) で更新し、
**Keychain に書き戻す**。書き戻さないとリフレッシュトークンのローテーションで Claude Code 本体の
ログインが壊れるため、更新と保存は必ずセットで行う。`claudeAiOauth` 以外のキー (`mcpOAuth` など) は
読んだまま保持する。

リフレッシュトークンまで無効な場合 (`invalid_grant`) は、ターミナルで一度 `claude` にログインし直すと復旧する。
その間もローカルソースから 5時間枠と週は出続ける。

### 診断

```bash
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --diagnose
```

どの枠がどのソースから来たか、API が失敗していればその理由を標準出力に出して終了する。

## 構成

| ファイル | 役割 |
|---|---|
| `Sources/Usage.swift` | Keychain 読み出し、API 取得、キャッシュ読み、JSON パース |
| `Sources/App.swift` | `MenuBarExtra` の UI とポーリング |
| `build.sh` | `.app` バンドル生成 + ad-hoc 署名 |

署名 ID を `build.sh` で固定しているのは、再ビルドのたびに Keychain の許可を訊かれないようにするため。
