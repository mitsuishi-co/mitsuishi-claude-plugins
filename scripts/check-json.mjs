#!/usr/bin/env node
// JSON の構文検査と、session-start が出す注入 JSON の検査（CI の必須の段）
//   node scripts/check-json.mjs
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const errors = [];

const files = execFileSync('git', ['-C', ROOT, 'ls-files', '-co', '--exclude-standard', '--', '*.json'], { encoding: 'utf8' })
  .split('\n').filter(Boolean);
for (const f of files) {
  try { JSON.parse(readFileSync(join(ROOT, f), 'utf8')); }
  catch (e) { errors.push(`${f}: JSON の構文が誤り（${e.message}）`); }
}
console.log(`JSON ${files.length} 件を検査`);

// 注入 JSON: 一時 HOME・git の外のフォルダで起動する（gstack には触らない）
const home = mkdtempSync(join(tmpdir(), 'mhome-'));
const outside = mkdtempSync(join(tmpdir(), 'mout-'));
// 既定（社内の決まりは無効）と、/mitsuishi-dev:workflow で宣言した（印がある）セッションの両方
const runSessionStart = (sid) => {
  const out = execFileSync('bash', [join(ROOT, 'plugins/mitsuishi-dev/hooks/session-start')], {
    input: JSON.stringify({ session_id: sid, hook_event_name: 'SessionStart', cwd: outside }),
    cwd: outside,
    env: { ...process.env, HOME: home, MITSUISHI_HOOKS_OFF: '', CLAUDE_PLUGIN_ROOT: join(ROOT, 'plugins/mitsuishi-dev') },
    encoding: 'utf8',
  });
  const j = JSON.parse(out);
  const ctx = j?.hookSpecificOutput?.additionalContext;
  if (j?.hookSpecificOutput?.hookEventName !== 'SessionStart' || typeof ctx !== 'string') throw new Error('出力に hookEventName / additionalContext が無い');
  if (/[\u0000-\u0008\u000b-\u001f\u007f]/.test(ctx)) throw new Error('注入文に制御文字が残っている');
  return ctx;
};
try {
  const def = runSessionStart('ci-default');
  if (!def.includes('gstack') || !def.includes('/mitsuishi-dev:workflow') || def.includes('TOP_ALIASES')) errors.push('session-start の既定の注入文が「社内の決まりは既定で無効」の案内と gstack の状態だけになっていない');
  else console.log(`注入 JSON（既定）: parse できた（${def.length} 文字）`);
  mkdirSync(join(home, '.claude/mitsuishi-dev/full'), { recursive: true });
  writeFileSync(join(home, '.claude/mitsuishi-dev/full/ci-full'), '');
  const full = runSessionStart('ci-full');
  if (!full.includes('TOP_ALIASES') || !full.includes('gstack')) errors.push('session-start の宣言後の注入文に MODELS.md か gstack の状態が無い');
  else console.log(`注入 JSON（宣言後）: parse できた（${full.length} 文字）`);
} catch (e) {
  errors.push(`session-start の出力を JSON として読めない: ${e.message}`);
} finally {
  // session-start が裏で起動した gstack の導入が一時 HOME に書き続けることがあるため、片付けの失敗は検査の失敗にしない
  for (const d of [home, outside]) {
    try { rmSync(d, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { /* 一時フォルダは OS が片付ける */ }
  }
}

if (errors.length) {
  for (const e of errors) console.log(`::error::${e}`);
  process.exit(1);
}
console.log('JSON の検査: 成功');
