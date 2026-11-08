#!/usr/bin/env node
// 禁止語の検査（CI の必須の段）。語の一覧は環境変数 FORBIDDEN_WORDS（改行かカンマ区切り。GitHub Actions の secret）から読み、
// リポジトリには書かない。当たった場所はファイルと行だけを出し、語そのものは出さない。未設定なら飛ばす。
//   FORBIDDEN_WORDS=... node scripts/check-forbidden.mjs
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const words = (process.env.FORBIDDEN_WORDS ?? '').split(/[\n,]/).map((w) => w.trim().toLowerCase()).filter(Boolean);
if (!words.length) {
  console.log('::notice::FORBIDDEN_WORDS が未設定のため、禁止語の検査を飛ばした');
  process.exit(0);
}

// plugins/superpowers/ は上流（obra/superpowers）の写しで、自社の語は書かない（中身を書き換えない）。
// 語の一覧は非公開で上流の語と重なるかを確かめられず、毎日の「上流の固定を上げる」PR が上流の文言で止まらないよう対象外にする
const UPSTREAM_COPIES = ['plugins/superpowers/'];
const files = execFileSync('git', ['-C', ROOT, 'ls-files', '-co', '--exclude-standard'], { encoding: 'utf8' })
  .split('\n').filter(Boolean).filter((f) => !UPSTREAM_COPIES.some((d) => f.startsWith(d)));
let hits = 0;
for (const f of files) {
  let text;
  try { text = readFileSync(join(ROOT, f), 'utf8'); } catch { continue; }
  if (text.includes('\u0000')) continue; // バイナリは見ない
  const lines = text.toLowerCase().split('\n');
  lines.forEach((line, i) => {
    words.forEach((w, wi) => {
      if (line.includes(w)) {
        hits++;
        console.log(`::error file=${f},line=${i + 1}::禁止語（一覧の ${wi + 1} 番目）に当たる。直し方: 語を消すか一般的な言い方に変える`);
      }
    });
  });
}
if (hits) process.exit(1);
console.log(`禁止語の検査: 成功（${files.length} ファイル、${words.length} 語）`);
