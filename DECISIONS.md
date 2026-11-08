# 決定事項（mitsuishi-dev プラグイン）

社内で決まったこと。実装はこの文書に合わせる。変えるときはここを先に直す。決定ごとに記述は 1 つだけにする（古い記述は残さない。経緯は git の履歴と `.gstack/plans/`）。
このリポジトリは公開なので、個人名・社内システムの情報・秘密は書かない。

## 1. 前提

- gstack と Superpowers（obra/superpowers）を併用する
- 組織プラグインとして配り、Claude Code 利用時は必須にする
- 実行役とプランナーを分ける
- 土台は社内で実際に回している開発の設定（推測より実績を優先）

## 2. モデル

- メイン（プランナー）の既定は `best`。その一段下（今は `opus`）に切り替えてもよい
- モデル名は書かず別名で書く。別名と今のモデルの対応は `plugins/mitsuishi-dev/MODELS.md` の 1 か所だけに置き、新モデルが出たらそこを直す（変更履歴も同じファイルに書く）
- 最上位モデルの担当: 計画・指示・検収・最終レビュー。メインが一段下の日は、設計判断・原因不明の不具合を相談役 `advisor`（最上位）に聞く
- 実行役のモデル: 調査 = haiku、仕様が固まった実装 = sonnet、設計判断を含む実装 = opus。指定なしは opus（管理設定の `env` に `CLAUDE_CODE_SUBAGENT_MODEL=opus`。別名を書ける。model を定義に持たない汎用のエージェントもこれで opus になり、最上位を継がない）。`CLAUDE_CODE_SUBAGENT_MODEL_FORCE` は使わない
- 管理設定で全員の既定を `best` にする（部署ごとには分けられない。月の利用量は後で確かめる）

## 3. 役割（エージェント）

| エージェント | モデル | 役目 |
|---|---|---|
| `executor` | opus | 実装・修正・調査・検証。再委託しない（`disallowedTools: Agent`） |
| `ui-executor` | opus | 画面の実装。起動時に `frontend-design` を読み込む（`skills` 欄）。再委託しない |
| `advisor` | fable（最上位） | 相談役。読み取りだけ |
| `outside-voice` | opus | 外部レビュー役（業務の立場から疑う）。読み取りだけ |

## 4. フック（止めるのは 3 つ。フックは促しであり仕切りではない）

止めるもの:
1. **メインのコード編集**（`MITSUISHI-EDIT-001`）: git のリポジトリの中のファイルだけが対象。文書（`*.md`・`*.markdown`、ファイル名がちょうど VERSION・CHANGELOG・TODOS か、それに `.md`・`.txt` が付いたもの）は通す。Edit で old_string・new_string がどちらも 2 行以内かつ 300 バイト以内なら通す（replace_all は除く）。MultiEdit は各 edit の行数の合計が 2 行以内かつ合計 300 バイト以内なら通す。Write と NotebookEdit のコードは止める。パスは切り詰めずに判定し、読み取りで切り詰められたパスは例外に入れない
1b. **メインによる Claude の設定・エージェント定義・ガード自身の編集**（`MITSUISHI-EDIT-002`、2026-11-07 /review で追加・2 回目で拡大）: 次は git の内外・行数・文書の例外に関係なく止める（AI が自分でガードを外したり、最上位モデルの制限を回り込んだりしないため）。直すときは利用者が手で直すか、実行役に回す
   - パスに `.claude/` を含む `settings*.json`、`.claude/agents/` の下（サブフォルダも）、`.claude/plugins/` の下すべて、`.claude.json`、`.mcp.json`、このプラグイン自身のフォルダの下、プラグインの `agents/` の下
   - パスに `/.git/` を含むもの（git のフックや設定）
   - 判定の前にパスを正規化する（`\`→`/`、`//`・`/./`・`..` をつぶす、Windows の末尾のドット・空白と `:` 以降の代替データストリームを落とす、大文字小文字を区別しない）。切り詰められたパスは止める
2. **実行役からの再委託**（`MITSUISHI-AGENT-001`）: 入力の最上位に `agent_id` があれば止める
3. **advisor 以外への最上位モデルの指定**（`MITSUISHI-AGENT-002`）: `model` が MODELS.md の `TOP_ALIASES`（別名の完全一致）か `TOP_PREFIXES`（正式名の前方一致）に当たれば止める。`model` を省いたときは、subagent_type のエージェント定義（プロジェクトの `.claude/agents/`（cwd から git のルートまで上って探す。BOM 付きも読む）・`~/.claude/agents/`（サブフォルダも）・`~/.claude/plugins/` の下の各プラグインの `agents/`）から、frontmatter の `name:` が一致するもの（名前空間つきならそのプラグインのもの）を探し、`model` を同じ表で照合する（YAML のコメント・引用符は取り除く）。advisor として通すのは、名前が `advisor` か `mitsuishi-dev:advisor` のものだけ

既知の限界（2.3.1 で追記。普段使いで当たらない抜け道はコードを足さずここに書く）:
- フックは事故防止の柵で、攻撃への防御ではない
- ドライブ相対パス（`C:.git\...` のような形）は `MITSUISHI-EDIT-002` で止まらない
- `\\?\`・`\\.\`・`\\localhost\c$\` の形は、`--plugin-dir` で開発中のプラグイン自身の保護をすり抜ける（配布で入れた版は対象）
- clone したリポジトリの `.claude/settings.json` の `env` で `MITSUISHI_HOOKS_OFF` を入れると、知らせずに全フックが止まる
- `~/.claude/plugins` の検索は marketplaces の写しや古い版を拾うことがあり、順序は決まっていない
- ロックの生死判定（`kill -0`）は同じ MSYS の中でしか効かない
- SessionStart は resume を対象にしない（意図した動作。再開した会話には前回の注入が残っているため）

止めないもの（限界として明記）: Bash・PowerShell 経由の書き換え・2 行 Edit の連打・model を定義にも持たない起動（管理設定の `CLAUDE_CODE_SUBAGENT_MODEL=opus` で opus になる）・Windows の 8.3 形式の短い名前（`CLAUDE~1` など）で書いたパス（判定のたびに外部コマンドで変換すると遅くなるため）・定義が `model: inherit` のエージェント（メインのモデルを継ぐ。フックからはメインのモデルが分からないため）。git の判定は所有者の確認を外す（`safe.directory='*'`。所有者の違うフォルダでガードが黙って外れないため。代わりに他人が置いた上位の `.git` で「中」と判定され、止まりすぎる側に倒れることがある）。

git の判定: 対象ファイルのパスの `\` を `/` に直し、存在するフォルダまで親へ上がる（最大 64 回、dirname が変わらなくなったら終わり）。そこで `git -c safe.directory='*' -C <d> rev-parse --is-inside-work-tree` を実行し、`true` なら止める対象。「not a git repository」なら通す。git が無い・その他の失敗は通して、ログに 1 行残す。シンボリックリンクは解決しない。

拒否文の形（3 行）: 1 行目 = 識別子と直し方／2 行目 = 何を止めたか（ツール・対象・行数・上限。2 行ずつに分けて回避しない）／3 行目 = 「止める必要があると思ったら、自分で止めずに利用者に相談する（開発者でなければ管理者に相談）。説明は README の『フックに止められたとき』」。**止め方（環境変数の名前と値）は AI が読む文（拒否文・注入文）に書かない**（2026-11-07 /review で変更。AI が自分でガードを外さないため）。止め方は人向けの README だけに書く。載せるパスは改行・制御文字を落とす。guard-subagent は呼んだ側・subagent_type・model・当たった別名を入れる。

失敗の扱い: lib を読めない・JSON を読めないときは通す（全員の作業を止めない）が、ログに 1 行残す。

停止: 環境変数 `MITSUISHI_HOOKS_OFF` の 1 つだけ。`1`・`all` = 全フック、`planner-edit`・`subagent`・`session-start` をカンマ区切りで指定するとそのフックだけ。空白・大文字小文字は正規化し、`0`・`false`・`no`・`off`・`none` は「止めない」、それ以外の未知の値は全部止める。判定は各フックの最初（lib を読む前）。全員を止めるときは管理者が管理設定の `env` に足す（効くことを導入時に実機で確かめる）。それも効かない旧版では `enabledPlugins` の `mitsuishi-dev@mitsuishi` を false にする。

ログ: `~/.claude/mitsuishi-dev/hooks.log` に拒否と失敗を 1 行ずつ（時刻・フック・識別子・ツール・対象）。1500 行を超えたら最後の 1000 行に切り詰める（失敗は無視）。PC の中だけに置き、対象のパスはそのまま残す。

## 5. セッション開始（session-start）

- タイムアウトは 30 秒。常に exit 0
- 注入文: 先頭に案内 3 行（このプラグインの役目・フックに止められたら利用者に相談すること・README の URL）。止め方は書かない→ ワークフロー規則（SKILL.md）→ MODELS.md → gstack の状態 1 行（導入済・最終更新日／導入中／未導入〔git の外で起動、など理由〕／更新に 3 回続けて失敗〔ログのパスと手で直す手順〕／編集ガード無効〔git なし〕）。注入する文字列は制御文字を落としてから JSON にする
- gstack の導入と毎日の更新は、セッションを git のリポジトリの中で始めたときだけ行う（開発以外の PC には入れない）
- 導入・更新は `hooks/lib/gstack-bg.sh` が裏で行い、セッションは待たない（`( … ) </dev/null >/dev/null 2>&1 &`）。session-start は呼ぶだけ
- gstack-bg.sh:
  - 状態は 1 ファイル `~/.claude/mitsuishi-dev/state`（最終成功時刻・gstack の HEAD・連続失敗回数・最終試行時刻）。壊れている・時刻が未来なら古いとみなす
  - 失敗から 1 時間未満なら何もしない。gstack の今の HEAD が pins.json の sha と違えば（固定が上がった・未導入）すぐ走らせ、fetch・checkout・setup を行う。同じなら、前回成功から 24 時間たったときに設定をそろえるだけ（fetch・setup はしない）
  - 既存の作業コピー（利用者が自分で入れた gstack）の HEAD が固定と違うときは、上書きした日に状態の 1 行で一度だけ知らせる
  - 自前のロック `mkdir ~/.claude/mitsuishi-dev/gstack.lock`（PID と時刻。持ち主の PID が生きていれば古くない。死んでいるか、打ち切り時間 + 300 秒を過ぎていれば古いとみなす）。状態はロックを取った後に読み直す。状態ファイルの書き込みに失敗したら数回やり直し、それでも失敗したらログに残す。裏の処理は setsid があれば別のセッションで起動するで 1 本だけ走らせる。古いロックは消さずに自分用の名前へ mv してから mkdir し、mv に成功した側だけが進む
  - 作業の前に、gstack の `.git` に残った古い `*.lock`（ロックの古さと同じ基準）を片付ける
  - 打ち切りは bash だけで、初回の導入は 900 秒・更新は 300 秒（`timeout` コマンドに頼らない）。打ち切るときはプロセスの木ごと（Windows は `taskkill //T //F //PID`、ほかは `setsid` があればプロセスグループへ）
  - 状態の HEAD と gstack の今の HEAD が違えば、前回は未完了とみなす
  - 作業コピーを自動で消さない。既定の場所（`$HOME/.claude/skills/gstack`）で .git が読めないときだけ、日時つきの名前に退避（mv）してから clone する。それ以外の異常はログと手順を出すだけ
  - gstack の出力本文はログ（`~/.claude/mitsuishi-dev/gstack.log`）だけに置き、注入文には定型文だけを出す
- gstack の版: 次の 6 を参照

## 6. 更新（毎日・上流は版を固定して CI が毎日上げ、CI が通れば自動で取り込む）

- 自社プラグイン: 管理設定の `extraKnownMarketplaces` で 2 つのマーケットプレイス（mitsuishi・claude-plugins-official）を `autoUpdate: true`。プラグインは 4 つ（mitsuishi-dev・superpowers・frontend-design・claude-security）。Claude Code はセッションを始めるたびに更新を確かめ、次の起動で新版になる
- 自社プラグインの版: `plugin.json` と marketplace.json の `version` は残す。`plugins/mitsuishi-dev/` を変えたら両方を上げ、CHANGELOG.md に 1 行足す（上げないと届かない。CI で検査）
- **上流は版を固定する**（利用者の判断、2026-11-07 最終関門）:
  - superpowers: `obra/superpowers` の固定の sha の中身（`.git` を除く）を `plugins/superpowers/` にそのまま同梱し、marketplace.json では mitsuishi-dev と同じ相対パス（`"source": "./plugins/superpowers"`）で配る。中身は書き換えない（上流の写し。LICENSE〔MIT〕を残す）。固定の sha はルートの `upstream-pins.json` に置く（各 PC が読む `pins.json` には入れない）。外部の GitHub から別に clone させる形（github 形式は SSH で鍵の無い PC で入らず、url〔HTTPS〕形式も取得経路の `git ls-remote` は通るのに社員の PC で入らなかった。2026-11-09）はやめた
  - gstack: 固定する sha を `plugins/mitsuishi-dev/pins.json` に置く。gstack-bg.sh は導入・更新のとき、その sha を checkout して `./setup -q --no-plan-tune-hooks` を実行する（`gstack-upgrade` は使わない）。gstack 自身の `auto_upgrade` は `false` にそろえる（スキル実行時に最新へ上がって固定を外さないため）
  - CI が毎日、両方の上流の最新の sha を調べ、変わっていれば「固定を上げる PR」を自動で作る（版を上げ、CHANGELOG に 1 行、テストを回す。superpowers は新しい sha の中身で `plugins/superpowers/` を丸ごと置き換え〔消えたファイルも消す〕、`upstream-pins.json` の sha を上げる）。PR は CI が通れば自動で取り込まれ（`gh pr merge --auto --squash`、`BUMP_TOKEN` で）、全員へ届く（利用者の判断、2026-11-08）
  - 自動の取り込みには、リポジトリ設定の「Allow auto-merge」と、main の保護で CI のジョブを必須チェックに指定することが要る（必須チェックが無いと CI を待たずに即取り込まれる）
  - CI は自社のフックを確かめるだけで、上流の中身は確かめない。上流で不具合が出たら、その取り込みコミットを revert すれば固定が前の sha に戻り、全員が前の版に戻る（mitsuishi-dev の版は下げずに今より上げて出す。下げると届かない）。superpowers は取り込みを revert しても版が下がるため届かない。戻すときは `plugins/superpowers/` の中身を前の版にし、その plugin.json の `version` を今より上げて出す（上流の写しを書き換える唯一の例外。上流の `version` がその版を超えた日の自動の PR で上流の写しに戻る）。止めるだけなら管理設定の `enabledPlugins` で `false` にする
  - superpowers は中身だけ変えても各 PC に届かない（版は superpowers 自身の plugin.json の `version` が優先される。code.claude.com/docs/en/plugins/loading.md）。届くのは `version` が上がったときだけなので、固定を上げる PR は上流の `version` が今の写しより semver で大きいときだけ作る（同じ・小さいときは見送り、理由をログと PR の本文に出す。小さいときも上げないのは、写しを戻して版を上げた後に上流の低い版で上書きしないため）
  - 上流の写しは自社の検査の一部から外す: 禁止語の検査は `plugins/superpowers/` を見ない（自社の語は書かない場所で、非公開の語の一覧と上流の文言の重なりで毎日の PR を止めないため）。版の検査の「変えたら版を上げる」は `plugins/mitsuishi-dev/` だけ（superpowers の版は上流の plugin.json のもの）。JSON の構文検査と gitleaks は同梱した中身も見る
  - 固定を上げる PR で CI を走らせるため、PR は専用のトークン（secret `BUMP_TOKEN`）で作る（既定のトークンで作った PR では CI が走らず、保護ブランチで取り込めない）。トークンが無ければジョブを失敗させて知らせる。トークンの用意は導入時の作業
  - PR の本文に上流の差分の比較リンク（compare）を載せる。不具合を追うときに使う。`bump-upstream` ブランチには人が手で積まない（翌日の実行で上書きされる）
- 公式プラグイン（frontend-design・claude-security）は公式マーケットプレイスの更新に追従する

## 7. CI（GitHub Actions、ubuntu と windows の両方）

- 必須: `bash tests/run-hooks-test.sh`／JSON の構文検査（node）／版の検査（push は `github.event.before`、新ブランチと PR は `origin/main` と比べる。semver は node で比較。plugin.json・marketplace.json・CHANGELOG.md の 3 か所の一致。MODELS.md の `TOP_ALIASES` 行の存在）／注入 JSON を node で parse／禁止語の検査（語の一覧は GitHub Actions の secret `FORBIDDEN_WORDS` から読み、リポジトリに書かない）／秘密の検査（gitleaks の本体を版を固定して直接実行する。組織のリポジトリで gitleaks-action に要るライセンスキーを不要にするため）
- GitHub Actions の action は、書き込み権限やトークンを持つジョブを含め、すべてコミットの sha で固定する（タグはコメントに残す）
- 任意: `claude plugin validate .`（失敗時は `::warning::`。必須に上げるかは TODOS.md）
- 失敗文には、変わったファイル・今と基準の版・直し方の 1 行を出す
- main は保護ブランチ（PR 必須・CI 必須・force push 禁止）。CI が通った PR だけを取り込む

## 8. 工程

- 流れは gstack: `/autoplan` → 実装（executor、画面は ui-executor）→ `/review` → `/cso` → `/qa`（修正まで）→ `/design-review`（画面の差分があれば必ず）
- メインは実行役の報告を 2 段で検収する: ①仕様どおりか ②コードの質（実行役のテスト・実行の出力も見る）
- Superpowers は工程と重ならない作法だけ。使う = `test-driven-development`・`systematic-debugging`・`verification-before-completion`・`receiving-code-review`。使わない = `writing-plans`・`executing-plans`・`brainstorming`・`subagent-driven-development` の実行の仕組み・`using-git-worktrees`・`dispatching-parallel-agents`。Superpowers の促しよりこの一覧を優先する
- 軽微な修正（2 行以内の Edit）は設計の工程を省いてよいが、`/review` は必ず回す
- フロントエンド: `/autoplan` のデザインレビューを省かない。画面は ui-executor。リポジトリに UI の標準があればそちらを優先する
- 外部レビュー: `/autoplan` の外部レビューの段と `/review` の業務面の声 = outside-voice。`/review` の 2 つ目の声 = Claude Code 組み込みの `/code-review`。権限・認証・外部入力の差分では `/cso` に `claude-security` を添える。Codex と、ソースを社外に送る他社の AI レビューは使わない
- gstack の設定は `codex_reviews: disabled`・`telemetry: off`・`auto_upgrade: false`（6 の固定のため）にそろえる

## 9. 公開リポジトリ

- 公開（非公開だと社員全員に GitHub の権限と認証が要る）。個人名・社内システムの情報・秘密は書かない。検討の経緯メモは社内に置く

## 10. 本家に同等の機能が出たら外すもの

MODELS.md の対応表と最上位モデルの判定（guard-subagent の model 判定）／実行役とプランナーの分離の仕組み（guard-planner-edit）／advisor／外部レビュー役の組み合わせ。四半期ごとに見直す。

## 11. 導入時の実機確認（受入条件）

- GitHub で main の保護ブランチを設定し、CI のジョブを必須チェックに指定した。リポジトリ設定で「Allow auto-merge」を有効にした
- 実行役（executor）に git の中のコードを 5 行以上 Write させて止まらない（フックの入力に `agent_id` が付いている）。メインに同じことをさせると `MITSUISHI-EDIT-001` で止まる
- 1 か月後に、全員の既定 `best` の利用量を確かめる
- 管理設定の `env` の `MITSUISHI_HOOKS_OFF` が各 PC のフックに届く
- Windows で、裏の gstack の導入・更新がセッション終了後も完了し、状態ファイルに書かれる（だめなら次の起動で続きを行う形に直す）
- gstack の更新の後、`~/.claude/settings.json` に余計なフックが増えていない。別のセッションを開いたまま更新しても壊れない
- ui-executor の起動時に frontend-design が読み込まれる（`claude --debug` の出力に frontend-design と skip を含む行が無い。ui-executor に読み込まれたスキルの名前を聞くと frontend-design が含まれる）

## 未決定

- TODOS.md を参照（strictKnownMarketplaces・組織の成功の物差し・validate の必須化・best が一段下に落ちた表示）
