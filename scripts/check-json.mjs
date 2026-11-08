#!/usr/bin/env node
// JSON の構文検査と、session-start が出す注入 JSON の検査（CI の必須の段）
//   node scripts/check-json.mjs
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
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
try {
  const out = execFileSync('bash', [join(ROOT, 'plugins/mitsuishi-dev/hooks/session-start')], {
    input: JSON.stringify({ session_id: 'ci', hook_event_name: 'SessionStart', cwd: outside }),
    cwd: outside,
    env: { ...process.env, HOME: home, MITSUISHI_HOOKS_OFF: '', CLAUDE_PLUGIN_ROOT: join(ROOT, 'plugins/mitsuishi-dev') },
    encoding: 'utf8',
  });
  const j = JSON.parse(out);
  const ctx = j?.hookSpecificOutput?.additionalContext;
  if (j?.hookSpecificOutput?.hookEventName !== 'SessionStart' || typeof ctx !== 'string') errors.push('session-start の出力に hookEventName / additionalContext が無い');
  else if (!ctx.includes('TOP_ALIASES') || !ctx.includes('gstack')) errors.push('session-start の注入文に MODELS.md か gstack の状態が無い');
  else if (/[\u0000-\u0008\u000b-\u001f\u007f]/.test(ctx)) errors.push('session-start の注入文に制御文字が残っている');
  else console.log(`注入 JSON: parse できた（${ctx.length} 文字）`);
} catch (e) {
  errors.push(`session-start の出力を JSON として読めない: ${e.message}`);
} finally {
  rmSync(home, { recursive: true, force: true });
  rmSync(outside, { recursive: true, force: true });
}

if (errors.length) {
  for (const e of errors) console.log(`::error::${e}`);
  process.exit(1);
}
console.log('JSON の検査: 成功');
