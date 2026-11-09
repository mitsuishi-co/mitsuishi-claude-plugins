# mitsuishi-claude-plugins

社内用の Claude Code プラグイン置き場（マーケットプレイス `mitsuishi`）です。管理設定で全員に配布し、Claude Code を使うときは必ず適用されるようにします。
**このリポジトリは公開です**（中身は社内ルールだけで秘密を含まず、公開にすることで社員側の認証設定を不要にしています）。個人名・社内システムの情報・秘密は書かないでください。
仕様の正本は `DECISIONS.md`、変更の記録は `CHANGELOG.md` です。

## 管理者の導入チェックリスト

- [ ] **壊れたときは、管理設定の `enabledPlugins` で `"mitsuishi-dev@mitsuishi": false` にする**（全員のフック・注入が止まる。直したら `true` に戻す）
- [ ] GitHub に `mitsuishi-co/mitsuishi-claude-plugins`（公開）を作って push し、main を保護ブランチにする（PR 必須・CI 必須・force push 禁止）
- [ ] GitHub Actions の secret を置く: `FORBIDDEN_WORDS`（禁止語。改行かカンマ区切り。未設定なら検査を飛ばす）・`BUMP_TOKEN`（必須。このリポジトリの Contents と Pull requests に書き込める fine-grained トークン。無いと「上流の固定を上げる」ジョブが失敗して知らせる。既定のトークンで作った PR では CI が走らず取り込めないため）。秘密の検査（gitleaks）は本体を直接実行するのでライセンスキーは要らない
- [ ] claude.ai の「組織設定 > Claude Code > 管理設定」（Owner 権限）に `admin/managed-settings.json` を貼って保存する。次のセッション開始時に全員へ入り、利用者は無効にできない
- [ ] 社員の PC に Git for Windows・Node.js・Bun を最初に入れる（Git が無いとプラグインが入らず、フックも動かない。gstack の導入には Node.js と Bun も要る）。PowerShell で `winget install --id Git.Git -e --source winget; winget install --id OpenJS.NodeJS.LTS -e --source winget; winget install --id Oven-sh.Bun -e --source winget`（社内のネットワークで msstore が証明書のエラーになるため `--source winget` を付ける）。入れたらアプリを開き直し、セッションを始める（どのフォルダでもよい。gstack は裏で入り、初回は最大 15 分）
- [ ] 管理設定で入ったプラグインが「無効」で届くことがある。設定 → プラグインの「…」→「オンにする」で有効にする（CLI なら `claude plugin enable <名前>`）
- [ ] 実行役（`executor`）に git の中のコードを 5 行以上 Write させて止まらないことを確かめる（フックの入力に `agent_id` が付いている）。メインに同じことをさせると `MITSUISHI-EDIT-001` で止まる
- [ ] 管理設定の `env` に `MITSUISHI_HOOKS_OFF` を入れたとき、各 PC のフックが止まることを 1 台で確かめる（下の「全員を止める」）
- [ ] 開発に使う PC で Claude Code を起動し、裏の gstack の導入がセッション終了後も完了して `~/.claude/mitsuishi-dev/state` に書かれることを確かめる（Windows を含む）
- [ ] gstack の導入・更新の後、`~/.claude/settings.json` に余計なフックが増えていないことを確かめる
- [ ] `ui-executor` を起動し、読み込まれたスキルの名前を聞くと `frontend-design` が含まれることを確かめる（`claude --debug` の出力に frontend-design と skip を含む行が無い）
- [ ] 1 か月後に、全員の既定 `best` の利用量を確かめる（管理設定の `model` は部署ごとに分けられない）
- [ ] リポジトリの設定（Settings > General）で「Allow auto-merge」を有効にし、main の保護で CI のジョブを必須チェック（Require status checks）に指定する（「上流の固定を上げる」PR は CI が通ると自動で取り込まれる。**必須チェックが無いと CI を待たずに即取り込まれる**）
- [ ] 「上流の固定を上げる」PR の `bump-upstream` ブランチには手で積まない（翌日の実行で上書きされる）。直したいことがあれば別のブランチで PR を出す
- [ ] 各 PC の前提ツール（gstack の導入に使う。足りなければセッション開始時の状態行に出る）

| ツール | 入れ方 |
|---|---|
| Git | 通常は導入済み（無いとメインの編集ガードも効かない） |
| Bun | macOS / Linux: `curl -fsSL https://bun.sh/install | bash`／Windows: `powershell -c "irm bun.sh/install.ps1 | iex"` |
| Node.js | Windows のみ。https://nodejs.org/ |

### 旧版（2.1 まで）からの移行

1. 停止の環境変数は `MITSUISHI_HOOKS_OFF` の 1 つになった（編集ガードだけなら `planner-edit`）。2.1 までの `…_ALLOW_PLANNER_EDIT` は効かない
2. gstack は自動更新（`auto_upgrade: true`）をやめ、このプラグインが固定の版に合わせる（gstack の設定は `auto_upgrade: false` に直す）
3. 編集ガードは git のリポジトリの中のファイルだけが対象になった（デスクトップなどの git の外は止めない）

## 中身

- **mitsuishi-dev**（自社製）
  - メイン（プランナー）と実行役（サブエージェント）の分担。モデルは別名で書き、対応表は `MODELS.md` の 1 か所
  - エージェント `executor`（実行役）・`ui-executor`（画面専用の実行役、起動時に frontend-design を読み込む）・`advisor`（相談役）・`outside-voice`（外部レビュー役）
  - フックで止めるのは、メインのコード編集・メインによる Claude の設定とエージェント定義の編集・実行役からの再委託・advisor 以外への最上位モデルの指定・`gstack-upgrade` のスキルの起動だけ（下の「フックに止められたとき」）。フックは促しであり仕切りではない（Bash・PowerShell 経由の書き換え、2 行 Edit の連打、model を定義にも持たない起動は止めない）
  - `/review`・`/cso`・`/autoplan`・`/qa`・`/design-review` を呼ぶ瞬間（Skill の起動・プロンプト先頭のスラッシュコマンド）に、その段の社内の決まりを 1〜2 行添える。`/gstack-upgrade` は止める（`MITSUISHI-SKILL-001`）
  - セッション開始時にワークフロー規則と `MODELS.md` と gstack の状態を注入し、どのフォルダで始めても（git があれば）gstack の導入・毎日の更新を裏で行う（セッションは待たない）
- **superpowers**（`obra/superpowers` の固定の sha の写しを `plugins/superpowers/` に同梱し、相対パスで配る。中身は書き換えない）
  - 使うのは `test-driven-development`・`systematic-debugging`・`verification-before-completion`・`receiving-code-review` の 4 つだけ
  - superpowers だけ止める: 管理設定の `enabledPlugins` で `"superpowers@mitsuishi": false` にする
- **frontend-design**・**claude-security**（Anthropic 公式マーケットプレイス `claude-plugins-official`。公式の更新に追従）

## 構成

```
.claude-plugin/marketplace.json        マーケットプレイス定義（名前: mitsuishi。2 つとも相対パスで配る）
upstream-pins.json                      superpowers の固定する sha（上流の写しの出どころ。各 PC は読まない）
plugins/mitsuishi-dev/
  .claude-plugin/plugin.json
  MODELS.md                             モデル別名の対応表と最上位の判定行（新モデル時はここだけ直す）
  pins.json                             gstack の固定する sha
  agents/                               executor・ui-executor・advisor・outside-voice
  hooks/hooks.json                      フックの登録（SessionStart は 30 秒）
  hooks/session-start                   ルールと状態の注入、裏の gstack の導入・更新の起動
  hooks/guard-planner-edit              メインのコード編集・Claude の設定とエージェント定義の編集を止める
  hooks/guard-subagent                  再委託と最上位モデルの誤指定を止める
  hooks/skill-reminder                  gstack の段を呼ぶときにその段の決まりを添え、gstack-upgrade を止める
  hooks/lib/common.sh                   共通関数（JSON の読み取り・git の判定・ログ・拒否文）
  hooks/lib/gstack-bg.sh                gstack の導入・更新（裏で動く。状態ファイル・ロック・打ち切り）
  hooks/lib/json-flatten.awk            JSON の読み取り（jq 不要）
  skills/workflow/SKILL.md              ワークフロー規則の本体
admin/managed-settings.json             管理画面に貼り付ける設定
scripts/                                CI の検査（版・JSON・禁止語）と上流の固定を上げるスクリプト
.github/workflows/ci.yml                CI（ubuntu と windows）
.github/workflows/bump-upstream.yml     上流の固定を上げる PR を毎日つくり、CI が通ったら自動で取り込む
tests/run-hooks-test.sh                 フックと CI のスクリプトの動作確認（ネットワークに出ない）
plugins/superpowers/                    obra/superpowers の写し（LICENSE は MIT。手で書き換えない。bump-upstream が丸ごと置き換える）
```

## フックに止められたとき

拒否文の 1 行目の識別子で見分けます。どれも PC の中の `~/.claude/mitsuishi-dev/hooks.log` に 1 行残ります。

- **`MITSUISHI-EDIT-001`**: メイン（プランナー）が git のリポジトリの中のコードを直接編集しようとした。実行役（`executor`、画面は `ui-executor`）に指示書を渡して委任する。次のものは止めない: 文書（`*.md`・`*.markdown`、ファイル名がちょうど `VERSION`・`CHANGELOG`・`TODOS` か、それに `.md`・`.txt` が付いたもの。`todos.ts` などは文書に入らない）／old_string・new_string がどちらも 2 行以内かつ 300 バイト以内の Edit（`replace_all` を除く。MultiEdit は合計で 2 行・300 バイト）／git の外のファイル。2 行ずつに分けて回避しない
- **`MITSUISHI-EDIT-002`**: メインが Claude の設定・エージェント定義・ガード自身・git の管理フォルダを編集しようとした。対象は、パスに `.claude/` を含む `settings*.json`／`.claude/agents/` の下（サブフォルダも）／`.claude/plugins/` の下すべて／`.claude.json`／`.mcp.json`／このプラグイン自身のフォルダの下／プラグインの `agents/` の下／パスに `/.git/` を含むもの（git のフックや設定）／長すぎて切り詰められたパス。パスは判定の前に正規化する（`\` を `/` に、`//`・`/./`・`..` をつぶす、末尾のドット・空白と `:` 以降（代替データストリーム）を落とす、大文字小文字を区別しない）。git の内外・行数・文書の例外に関係なく止める（AI が自分でガードを外したり、最上位モデルの制限を回り込んだりしないため）。利用者が手で直すか、実行役に回す
- **`MITSUISHI-AGENT-001`**: 実行役（サブエージェント）がさらにサブエージェントを起動しようとした（再委託禁止）。実行役は自分の手で行い、分ける必要があれば「要判断」としてメインに返す
- **`MITSUISHI-AGENT-002`**: `advisor` 以外に最上位モデルを指定した（`MODELS.md` の `TOP_ALIASES` の別名か `TOP_PREFIXES` の正式名の前方一致）。`model` を省いたときは、エージェント定義（プロジェクトの `.claude/agents/`（cwd から git のルートまで上って探す）・`~/.claude/agents/`（どちらもサブフォルダも）・`~/.claude/plugins/` の下の各プラグインの `agents/`）から frontmatter の `name:` が一致するもの（`<プラグイン>:<名前>` ならそのプラグインのもの）を探し、その `model` で判定する（YAML のコメント・引用符は取り除く）。advisor として通すのは `advisor` と `mitsuishi-dev:advisor` だけ。実行役には `opus`・`sonnet`・`haiku` を指定する
- **`MITSUISHI-SKILL-001`**: `gstack-upgrade` のスキルを呼ぼうとした。gstack は固定の版を使い、更新はプラグインが自動で行う（下の「更新の仕組み」）。プロンプトに `/gstack-upgrade` と打ったときは止めず、「実行しない」決まりを添えるだけ
- `MITSUISHI-FAIL-*`（ログだけ）: フックが判定できずに通した（`LIB` = 共通関数を読めない／`JSON` = 入力を読めない・文字列の中に生の改行や制御文字がある／`GIT` = git が無い・git の判定に失敗）

拒否文と注入文には止め方を書いていません（AI が自分でガードを外さないため）。止める必要があると AI が判断したときは、利用者に相談するよう促します。

どうしても止めるときは、人が環境変数 `MITSUISHI_HOOKS_OFF` を付けて Claude Code を起動し直します。

| 値 | 止まるもの |
|---|---|
| `1` か `all` | 全部 |
| `planner-edit`・`subagent`・`session-start`・`skill-reminder`（カンマ区切りで複数可） | そのフックだけ |
| 空・`0`・`false`・`no`・`off`・`none` | 止めない（全部動く） |
| それ以外の値 | 全部（打ち間違いでも止まる側に倒す） |

空白・大文字小文字は区別しません。

### 全員を止める（管理者）

管理設定の `env` に次の 1 行を足して保存すると、次のセッションから全員のフックが止まります（効くことを導入時に確かめる。効かない旧版では `enabledPlugins` の `mitsuishi-dev@mitsuishi` を `false` にする）。

```json
"env": { "CLAUDE_CODE_SUBAGENT_MODEL": "opus", "MITSUISHI_HOOKS_OFF": "1" }
```

### 版を戻す（管理者）

直した版を出すのが基本です。急ぐときは、前の版の中身に戻して版を上げて出します（版を下げると各 PC に届かない）。

```bash
git switch -c revert-plugin origin/main
git checkout <戻したい版のコミット> -- plugins/mitsuishi-dev
# plugin.json と marketplace.json の version を今より大きくし、CHANGELOG.md の先頭に 1 行足す
bash tests/run-hooks-test.sh && node scripts/check-version.mjs origin/main
git commit -am "mitsuishi-dev を <戻したい版> の中身に戻す" && git push -u origin revert-plugin   # PR を作って取り込む
```

## 更新の仕組み

- **自社プラグイン**: 管理設定の 2 つのマーケットプレイスは `autoUpdate: true`。Claude Code はセッション中に更新を確かめ、次の起動で新版になる。`plugins/mitsuishi-dev/` を変えたら `plugin.json` と `marketplace.json` の `version` を上げ、`CHANGELOG.md` の先頭に 1 行足す（**上げないと届かない**。CI が検査する）
- **上流は版を固定する**: superpowers は `upstream-pins.json` の `sha` の中身を `plugins/superpowers/` に同梱、gstack は `plugins/mitsuishi-dev/pins.json` の `sha`。CI（`bump-upstream.yml`）が毎日両方の最新を調べ、変わっていれば「上流の固定を上げる」PR を作り、CI が通れば自動で取り込まれ（auto-merge、squash）、全員へ届く（本文に上流ごとの compare のリンク）。CI は自社のフックを確かめるだけで、上流の中身は確かめない
  - **上流で不具合が出たら**: その取り込みコミット（「上流の固定を上げる」）を revert し、mitsuishi-dev の版は今より上げて CHANGELOG に 1 行足して PR で出す（下の「版を戻す」と同じ。版を下げると届かない）。固定が前の sha に戻り、全員が前の版に戻る。superpowers は取り込みを revert しても版が下がるため届かない。戻すときは `plugins/superpowers/` の中身を前の版にし（`git checkout <前の取り込みのコミット> -- plugins/superpowers`）、`plugins/superpowers/.claude-plugin/plugin.json` の `version` を今より上げて PR で出す（上流の `version` がその版を超えた日の自動の PR で上流の写しに戻る）。止めるだけなら管理設定の `enabledPlugins` で `"superpowers@mitsuishi": false` にする
  - **superpowers は上流の `version` が今の写しより大きいときだけ上げる**: Claude Code は plugin.json の `version` で更新を判断し、superpowers は自分の plugin.json に `version` を持つ（マーケットプレイス側の `version` より優先される）。中身だけ上げても各 PC には届かないため、上流の `version` が今の写しと同じ・小さい（写しを戻して版を上げた後など）・確かめられないときは superpowers を変えない（semver で比べる）（gstack だけが変わっていれば gstack だけ上げる）。上げるときは新しい sha の中身で `plugins/superpowers/` を丸ごと置き換え（消えたファイルも消す）、`upstream-pins.json` の sha を上げる
  - 禁止語の検査は `plugins/superpowers/` を見ない（上流の写しで自社の語を書かない場所。非公開の語の一覧と上流の文言の重なりで毎日の PR を止めないため）。JSON の構文検査と gitleaks は同梱した中身も見る
  - PR は secret `BUMP_TOKEN` で作る。無ければジョブが失敗して知らせる。`bump-upstream` ブランチには手で積まない
- **gstack**: どのフォルダでセッションを始めても（git があれば）、裏で（`hooks/lib/gstack-bg.sh`）動く。gstack の今の HEAD が固定の sha と違えば（固定が上がった・未導入・前回が未完了）すぐ、固定の sha を checkout して `./setup -q --no-plan-tune-hooks` を実行する。同じなら、前回の成功から 24 時間ごとに設定を `auto_upgrade: false`・`codex_reviews: disabled`・`telemetry: off` にそろえるだけ。失敗から 1 時間未満は何もしない。打ち切りは初回の導入 900 秒・更新 300 秒。`gstack-upgrade` は使わない。ログは `~/.claude/mitsuishi-dev/gstack.log`、状態は `~/.claude/mitsuishi-dev/state`
  - 自分で入れていた gstack（HEAD が固定と違う）は固定の版で上書きし、その日の状態行で一度だけ知らせる
  - 3 回続けて失敗するとセッション開始時の状態行に出る。手で直すときは状態行に出る手順（`cd ~/.claude/skills/gstack && rm -f .git/index.lock && { git stash -u || true; } && git fetch --depth 1 <repo> <sha> && git checkout --detach <sha> && ./setup -q --no-plan-tune-hooks`）を実行する。`git stash -u` は手で変えたファイルを退避する（`git stash list` で確かめられる）

## モデル

- 管理設定の `model` は `best`（最上位。使えない環境では `opus` と同じモデルになる）。メインは一段下（`opus`）に切り替えてもよい
- サブエージェントの既定はエージェント定義で決まる（executor・ui-executor・outside-voice = opus、advisor = fable）。定義に `model` を持たない汎用のエージェントも最上位を継がないよう、管理設定の `env` に `CLAUDE_CODE_SUBAGENT_MODEL=opus` を置く。`CLAUDE_CODE_SUBAGENT_MODEL_FORCE` は使わない
- 新しいモデルが出たら `plugins/mitsuishi-dev/MODELS.md` だけを直して版を上げる

## 動作確認

- 手元: `bash tests/run-hooks-test.sh`（偽の git・setup で動き、gstack とネットワークには触らない）・`node scripts/check-version.mjs main`・`claude plugin validate .`
- 社員の PC: `/plugin` に `mitsuishi-dev` と `superpowers` が管理設定由来で出る／`/status` に Enterprise managed settings が出る／git のリポジトリの中でメインに「src のファイルを 5 行直して」と頼むと `MITSUISHI-EDIT-001` で止まり、実行役への委任に切り替わる

## ルールを変えるとき

1. `DECISIONS.md` を先に直す
2. `skills/workflow/SKILL.md`（必要ならフック・`MODELS.md`）を直し、`bash tests/run-hooks-test.sh` を通す
3. `plugin.json` と `marketplace.json` の `version` をそろえて上げ、`CHANGELOG.md` に 1 行足して PR を出す
