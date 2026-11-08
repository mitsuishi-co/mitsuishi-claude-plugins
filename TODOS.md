# TODOS

## strictKnownMarketplaces で許可するマーケットプレイスを絞る
- **What:** 管理設定に strictKnownMarketplaces を足し、mitsuishi と claude-plugins-official だけを許可する
- **Why:** 社員が任意のマーケットプレイスを足すと、検査していないコードが PC で動く
- **Pros:** 供給網の入口を 2 つに限れる
- **Cons:** 社員が自分で試したいプラグインを入れられなくなる
- **Context:** CEO レビュー（2026-11-07）で延期。社員の自由度を変える判断なので、利用者が決める
- **Depends on:** なし

## 組織としての成功の物差し
- **What:** フックの拒否の件数・/review の実施率などを、PC の外に送らずに月 1 回まとめる方法を決める
- **Why:** 規則が守られているか、品質が上がったかを組織として知る手段がない
- **Pros:** 規則の見直しの根拠になる
- **Cons:** 集計の手間。外に送らない方針と両立させる工夫が要る
- **Context:** CEO・DX レビューで延期。ログは `~/.claude/mitsuishi-dev/hooks.log` に PC ごとにある
- **Depends on:** E7 のログ

## `claude plugin validate` を CI の必須に上げるか
- **What:** 初回の CI で認証なしに動くか確かめ、動けば必須にする
- **Why:** 今は任意の段（失敗しても全体は落ちない）
- **Context:** Eng レビュー DX13。CI を GitHub に置いた後の最初の実行で判断する（判断する人: リポジトリの管理者）
- **Depends on:** CI（E3）

## best が一段下に落ちたことの表示
- **What:** Fable が使えない環境で best が opus になったとき、利用者に分かるようにする
- **Why:** 費用・品質の想定が外れても気づけない
- **Context:** DX レビューで延期。フックからは実際に使われているモデルが取れない
- **Depends on:** Claude Code 側の情報
