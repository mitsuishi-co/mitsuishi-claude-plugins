# モデルの対応表

| 段 | 別名 | 今のモデル | 使う人 |
|---|---|---|---|
| 最上位 | `best` | Fable | メイン（既定）・相談役 advisor |
| 一段下 | `opus` | Opus | メイン（切り替えたとき）・実行役（設計判断を含む実装、既定）・画面専用の実行役 ui-executor・外部レビュー役 outside-voice |
| 実行役 | `sonnet` | Sonnet | 実行役（仕様が固まった実装） |
| 実行役 | `haiku` | Haiku | 実行役（調査） |

新しいモデルが出たら、この表と下の `TOP_ALIASES`・`TOP_PREFIXES` だけを直し、版を上げて配り直す。
ルール文・フックはここを参照し、モデルの固有名を持たない（エージェント定義の `model` も別名なので通常は直さない）。

フックが読む行（書式を変えない。1 行に空白区切り。Agent ツールの `model` が `TOP_ALIASES` の別名に完全一致するか、`TOP_PREFIXES` の正式名の前方一致に当たれば最上位とみなす）:

```
TOP_ALIASES: best fable
TOP_PREFIXES: claude-fable-
```

## 変更履歴

| 日付 | 変更 |
|---|---|
| 2026-11-07 | `TOP_PREFIXES: claude-fable-` を追加（正式名で最上位モデルを指定したときも止める） |
