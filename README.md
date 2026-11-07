# mitsuishi-claude-plugins

社内用の Claude Code プラグイン置き場（マーケットプレイス）です。
管理設定で全員に配布し、Claude Code を使うときは必ず次の内容が適用されるようにします。

- **mitsuishi-dev**（自社製）
  - プランナー（メインのセッション＝Fable）と実行役（サブエージェント）を分ける
    - プランナーがコードを直接編集しようとするとフックで止め、実行役への委任を促す
    - サブエージェントに Fable を指定しようとするとフックで止める
  - 社内標準の開発ワークフロー（gstack × Superpowers の分担ルール）を、毎セッション開始時に注入する
  - gstack が未導入なら自動で導入し、導入済みならセッション開始のたびに最新版へ更新する
- **superpowers**（obra/superpowers、MIT）
  - 計画書作成、サブエージェントによる実行、TDD、2段階レビュー

## 構成

```
.claude-plugin/marketplace.json        マーケットプレイス定義（名前: mitsuishi）
plugins/mitsuishi-dev/
  .claude-plugin/plugin.json
  hooks/hooks.json                      フックの登録
  hooks/session-start                   gstack の導入・更新とルール注入
  hooks/guard-planner-edit              プランナーによるコード編集を止める
  hooks/guard-subagent-model            サブエージェントへの Fable 指定を止める
  skills/workflow/SKILL.md              分担ルール本体（ここを編集すれば全員に反映）
admin/managed-settings.json             管理画面に貼り付ける設定
```

## 導入手順（管理者が1回だけ）

### 1. GitHub にリポジトリを作る

このフォルダ一式を `mitsuishi-claude-plugins` という名前で GitHub に push します。

- 非公開リポジトリにする場合は、Claude Code を使う社員全員にそのリポジトリの読み取り権限が必要です（各PCの git がそのまま clone するため）。
- 中身は社内ルールのみで機密情報を含まないため、公開リポジトリにすると権限管理が不要になります。

### 2. 管理設定に貼り付ける

1. `admin/managed-settings.json` の `YOUR-GITHUB-ORG` を実際の GitHub の組織名（またはユーザー名）に置き換える
2. claude.ai の「組織設定 > Claude Code > 管理設定」を開く（Owner 権限が必要）
3. JSON を貼り付けて保存する

保存すると、組織の全メンバーの次回セッション開始時に、プラグインが自動でインストールされます。
メンバー側では無効化できません。

### 3. 各PCの前提ツール

gstack の導入に次のツールが必要です。足りない場合、Claude Code がセッション開始時に案内します。

| ツール | 用途 | 入れ方 |
|---|---|---|
| Git | gstack の取得・更新 | 通常は導入済み |
| Bun（1.4.2 以上を推奨） | gstack のビルド | macOS / Linux: `curl -fsSL https://bun.sh/install \| bash`<br>Windows: `powershell -c "irm bun.sh/install.ps1 \| iex"` |
| Node.js | Windows のみ必要 | https://nodejs.org/ |

Intune で配布する場合は、上記を必須アプリに含めておくと手間がありません。

## モデルの設定

管理設定で次のように指定しています。

- `model`：メインのセッション（プランナー）のモデル。`claude-fable-5-1`
- `env.CLAUDE_CODE_SUBAGENT_MODEL`：サブエージェント（実行役）でモデル指定がないときの既定値。`claude-opus-5-5`

Superpowers は作業の難しさに応じて haiku・sonnet・opus を使い分けて実行役を起動します。この使い分けは活かしたまま、Fable だけを実行役から締め出しています。
全サブエージェントを1つのモデルに固定したい場合は、`env` に `"CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"` を追加します。

組織のプランで Claude Code から Fable を使えるかは、事前に `/model` で確認してください。

## 動作確認

社員のPCで Claude Code を起動し、次を確認します。

- `/plugin` に `mitsuishi-dev` と `superpowers` が表示され、管理設定由来（managed）になっている
- `/status` の Setting sources に `Enterprise managed settings` が含まれている
- `~/.claude/mitsuishi-dev/gstack.log` に gstack の導入・更新の記録がある
- メインのセッションで「src 以下のファイルを1行直して」と頼むと、直接は編集されず実行役への委任に切り替わる

初回のセッション開始時は gstack のビルドが走るため、数分かかることがあります。

## ルールを変えるとき

1. `plugins/mitsuishi-dev/skills/workflow/SKILL.md` を編集する
2. `plugins/mitsuishi-dev/.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json` の `version` を上げる
3. push する

`autoUpdate: true` にしているため、各PCには自動で反映されます。

## 注意事項

- **プランナーの編集制限は、Edit／Write などの編集ツールに対するものです。** シェルコマンド経由の書き換えまでは止めません（ルールでは禁止しています）。緊急時は環境変数 `MITSUISHI_ALLOW_PLANNER_EDIT=1` を付けて起動すると制限を外せます。

- **gstack は毎セッション開始時に更新されます。** 更新は gstack 公式の無人アップデータ（`bin/gstack-upgrade`）で行い、gstack の stable チャンネル（タグ付きリリース）に追従します。オフラインなどで更新できなかった場合もセッションは止まらず、Claude が利用者にその旨を伝えます。
- **Superpowers は作者のリポジトリを直接参照しています。** 作者側の更新がそのまま全員に配られます。版を固定したい場合は、自社でフォークして `marketplace.json` の `repo` をフォーク先に変えてください。
- **管理画面からの設定は組織全員に一律で適用されます。** 部署ごとに分けることはできません。
- 許可するマーケットプレイスを公式と自社のみに絞りたい場合は、管理設定に `strictKnownMarketplaces` を追加します（Claude Code 公式ドキュメント「Manage Claude Code plugins for your organization」参照）。
