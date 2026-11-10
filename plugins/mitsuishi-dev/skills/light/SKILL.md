---
name: light
description: 社内の決まり（mitsuishi-dev）を外して既定（軽い進め方）に戻す。/mitsuishi-dev:workflow で宣言したセッションを元に戻すときに利用者が呼ぶ。
disable-model-invocation: true
---

社内の決まり（mitsuishi-dev）を外して既定に戻すコマンド。切り替えはフックが行い、その旨が 1 行添えられる。利用者には切り替えたことを一言で伝え、以後は宣言前と同じ進め方に戻る。また使うときは `/mitsuishi-dev:workflow`。
