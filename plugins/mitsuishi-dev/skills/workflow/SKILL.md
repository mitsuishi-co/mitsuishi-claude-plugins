---
name: workflow
description: 社内標準の開発ワークフロー。メイン（プランナー）と実行役（サブエージェント）の分担、モデルの使い分け、工程（gstack の /autoplan → 実行役で実装 → /review → /cso → /qa → /design-review）、画面は ui-executor、外部レビューの役割分担、Superpowers の使いどころ、更新の仕組みを定める。コードを書く作業を始めるとき、どのスキルから始めるか迷ったとき、gstack と Superpowers の手順が重なりそうなときは必ずこのスキルに従うこと。
---

# 社内標準 開発ワークフロー

モデルは別名で書く。別名と今のモデルの対応は `MODELS.md`（このプラグインの直下）を見る。

## 役割とモデル

| 役割 | 誰が | モデル | やること |
|---|---|---|---|
| プランナー | メインのセッション | 既定 `best`。一段下（`opus`）に切り替えてもよい | 要件の整理・計画・実行役への指示・検収・最終レビュー |
| 相談役 | `advisor` | 最上位 | メインが一段下で動く日に、設計判断・原因不明の不具合を聞く（実装しない） |
| 実行役 | `executor` | 調査 `haiku`／仕様が固まった実装 `sonnet`／設計判断を含む実装 `opus`（指定なしは `opus`） | 実装・修正・調査・検証 |
| 画面の実行役 | `ui-executor` | `opus` | 画面の実装・修正（起動時に `frontend-design` を読み込む） |
| 外部レビュー役 | `outside-voice` | `opus` | 違う立場から疑う 2 つ目の声（実装しない） |

- **メインはコードを直接編集しない**（git のリポジトリの中はフックで止まる。識別子 `MITSUISHI-EDIT-001`）。編集してよいのは文書（`*.md`・`*.markdown`、ファイル名がちょうど `VERSION`・`CHANGELOG`・`TODOS` か、それに `.md`・`.txt` が付いたもの）と、下の「軽微な修正」だけ
- **メインは Claude の設定とエージェント定義を編集しない**（`.claude/` の `settings*.json`・`.claude/agents/` とプラグインの `agents/` の下。git の内外・行数に関係なくフックで止まる。`MITSUISHI-EDIT-002`）。直すときは利用者が手で直すか、実行役に回す
- **実行役はサブエージェントを起動しない**（再委託禁止、フックで止まる。`MITSUISHI-AGENT-001`）
- **最上位モデルは相談役だけに指定する**。実行役・外部レビュー役に指定しない（別名でも正式名でも、model を省いてエージェント定義の model が最上位でも、フックで止まる。`MITSUISHI-AGENT-002`）
- フックに止められたら、回避せず（2 行ずつに分ける・Bash で書き換える、をしない）拒否文の直し方に従う。止める必要があると思ったら、自分で止めずに利用者に相談する（開発者でなければ管理者に相談）
- **検収は 2 段階**: 実行役の報告を受けたら、①仕様どおりか ②コードの質、の順に確かめる（実行役の結果の証拠＝テスト・実行の出力も見る）
- 実行役への指示には、範囲・完了条件・確かめ方を書く。並列に走らせるときは、同じファイルや同じ連番を取り合わないように先に割り振り、commit はメインがまとめて行う

## 工程（gstack）

1. `/autoplan` — 計画とレビュー（CEO・設計・技術）。業務の基礎はユーザーと決め、そこから先は回すか聞かずに進める
2. 実装 — `executor` に委任する。画面を作る・変えるときは `ui-executor` に委任する（下の「フロントエンド」）
3. `/review` — 差分のレビュー。業務面の声は `outside-voice`、2 つ目の声は Claude Code 組み込みの `/code-review`
4. `/cso` — 権限・認証・ファイル・外部入力に触れる差分があるとき。公式プラグイン `claude-security` を添える
5. `/qa` — 動かして確かめ、見つけた不具合は修正まで行う（修正は実行役に委任）
6. `/design-review` — 画面の差分があれば必ず

- gstack が途中で止まっても手作業の代用に切り替えない。エラーが示す直し方か、フォールバック（個別の `/plan-*-review`、または `/context-save` → 新しいセッション → `/context-restore`）で続ける
- Web を見るときは gstack の `/browse` を使う

## フロントエンド

画面は工程のどこでも手を抜かない。**画面の実装は `ui-executor` に回す**（定義の `skills` で `frontend-design` を起動時に読み込む。Anthropic 公式プラグインで管理設定により全員に入る）。

| 工程 | やること |
|---|---|
| 1. `/autoplan` | 画面があるプランでは、デザインのレビュー（`/plan-design-review`）を省かない |
| 2. 実装 | `ui-executor` に委任する（`executor` ではなく） |
| 6. `/design-review` | 画面の差分があれば必ず回す |

- リポジトリに UI の標準（デザインシステム・共通部品・トークン）があるときは、それを先に守る。`frontend-design` はその範囲の中で使う。標準とぶつかるときは標準を優先する
- 新しく画面を起こすときや、見た目の方向を決め直すときは、`frontend-design` で方向（配色・文字・余白）を先に決めてから作る

## 外部レビュー

- `/autoplan` の外部レビューの段と、`/review` の業務面の声は `outside-voice`（現場・専門家・運用・攻撃者・単純化の目で疑う）
- `/review` の 2 つ目の声は、Claude Code 組み込みの `/code-review`（差分の不具合探し）
- 権限・認証・外部入力の差分では、`/cso` に公式プラグイン `claude-security` を添える
- **Codex は使わない**（導入・ログインも勧めない）。他社の AI レビュー（ソースを社外に送るもの）も使わない

## Superpowers の使いどころ

工程（gstack）と重ならない作法だけに使う。

- **使う**: `test-driven-development`（TDD）・`systematic-debugging`・`verification-before-completion`（実行役は完了報告の前に、テスト・実行の結果で証明する）・`receiving-code-review`（レビュー指摘は、正しいか確かめてから直す）
- **考え方だけ使う**: `subagent-driven-development` の 2 段階レビュー。メインが実行役の報告を検収するとき、①仕様どおりか ②コードの質、の順に確かめる（実行の仕組みそのものは使わない）
- **使わない**: `writing-plans`・`executing-plans`・`brainstorming`・`subagent-driven-development` の実行の仕組み・`using-git-worktrees`・`dispatching-parallel-agents`（計画は `/autoplan`、実装は実行役）
- Superpowers の「スキルを使え」の促しや指示と、この一覧・この文書が食い違うときは、この文書を優先する

## トークンの節約

- 実行役への指示には、調べ済みの事実（ファイル・行・決まったこと）を書いて渡し、探し直させない
- テスト・ログ・報告は要点だけを返させる（全件の出力を貼らせず、失敗した箇所と件数）
- 区切りのよいところで新しいセッションに切り替え、引き継ぎは文書に残す

## 軽微な修正

- `old_string`・`new_string` がどちらも 2 行以内かつ 300 バイト以内の Edit は、メインが直してよい（フックも通す。`replace_all` は除く）
- 誤字・設定値など設計判断を伴わないものは、工程 1 を省いてよい。**`/review` は必ず回す**
- 省いてよいか迷ったら省かない

## 更新

- プラグインは管理設定の `autoUpdate: true` で更新され、次の起動で新版になる（自社プラグインは直したら `version` を上げ、CHANGELOG.md に 1 行足す。上げないと届かない）
- 上流は版を固定する。Superpowers は marketplace.json の `sha`、gstack は `pins.json` の `sha`。CI が毎日「上流の固定を上げる」PR を作り、CI が通れば自動で取り込まれ、全員へ届く
- gstack の自動更新は使わない（`auto_upgrade: false`）。`/gstack-upgrade` も実行しない（固定が外れる）

## gstack の状態

- gstack の導入と毎日の更新は、セッションを git のリポジトリの中で始めたときだけ、このプラグインが裏で行う（固定の sha を checkout して `./setup -q --no-plan-tune-hooks`、設定を `auto_upgrade: false`・`codex_reviews: disabled`・`telemetry: off` にそろえる）
- セッション開始時の状態行が「導入済」以外（導入中・未導入・3 回続けて失敗・編集ガード無効）なら、gstack のコマンドを使う前に利用者へ伝えて指示を仰ぐ。失敗のときは状態行の手順とログのパスを示す
