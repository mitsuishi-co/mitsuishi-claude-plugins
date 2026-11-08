#!/usr/bin/env node
// 版の検査（CI の必須の段。手元でも動く）
//   node scripts/check-version.mjs [基準の ref]
//   基準: 引数（push なら github.event.before）。空・0 だけ・読めない ref のときは origin/main → main の順に使う
// 確かめること:
//   1. plugin.json・marketplace.json（mitsuishi-dev）・CHANGELOG.md の先頭の版が一致する
//   2. MODELS.md に TOP_ALIASES の行がある
//   3. plugins/mitsuishi-dev/ が基準から変わっていれば、版が基準より大きい（semver で比較）
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareSemver, parseSemver } from './lib/semver.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PLUGIN_DIR = 'plugins/mitsuishi-dev';
const PLUGIN_JSON = `${PLUGIN_DIR}/.claude-plugin/plugin.json`;
const errors = [];

const git = (args) => execFileSync('git', ['-C', ROOT, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
const tryGit = (args) => { try { return git(args); } catch { return null; } };
const read = (p) => readFileSync(join(ROOT, p), 'utf8');

function resolveBase(arg) {
  const cands = [];
  if (arg && !/^0+$/.test(arg)) cands.push(arg);
  cands.push('origin/main', 'main');
  for (const c of cands) {
    if (tryGit(['rev-parse', '--verify', '--quiet', `${c}^{commit}`]) !== null) return c;
  }
  return null;
}

function main() {
  // 1. 3 か所の一致
  let pv, mv, cv;
  try { pv = JSON.parse(read(PLUGIN_JSON)).version; } catch (e) { errors.push(`${PLUGIN_JSON} を読めない: ${e.message}`); }
  try {
    const mk = JSON.parse(read('.claude-plugin/marketplace.json'));
    mv = (mk.plugins || []).find((p) => p.name === 'mitsuishi-dev')?.version;
  } catch (e) { errors.push(`.claude-plugin/marketplace.json を読めない: ${e.message}`); }
  try {
    const m = /^- (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\b/m.exec(read('CHANGELOG.md'));
    cv = m?.[1];
  } catch { /* 下で扱う */ }
  if (!cv) errors.push('CHANGELOG.md に版の行（例: "- 2.2.0 (2026-11-07) 変更の説明"）が無い');
  if (pv && !parseSemver(pv)) errors.push(`plugin.json の version が semver ではない: ${pv}`);
  if (pv && mv && cv && !(pv === mv && mv === cv)) {
    errors.push(`版が 3 か所で一致しない: plugin.json=${pv} / marketplace.json=${mv ?? '無し'} / CHANGELOG.md=${cv}。直し方: 3 か所を同じ版にそろえる`);
  } else if (!mv) {
    errors.push('marketplace.json の mitsuishi-dev に version が無い');
  }

  // 2. MODELS.md の TOP_ALIASES 行
  try {
    if (!/^TOP_ALIASES:[ \t]*\S/m.test(read(`${PLUGIN_DIR}/MODELS.md`))) errors.push(`${PLUGIN_DIR}/MODELS.md に "TOP_ALIASES: ..." の行が無い（フックが読む行。書式を変えない）`);
  } catch { errors.push(`${PLUGIN_DIR}/MODELS.md を読めない`); }

  // 3. 変えたら版を上げる
  const base = resolveBase(process.argv[2]);
  if (!base) {
    console.log('::warning::基準の版（origin/main・main）が見つからないため、版を上げたかの検査を飛ばした');
  } else {
    const changed = [
      ...(tryGit(['diff', '--name-only', base, '--', PLUGIN_DIR]) ?? '').split('\n'),
      ...(tryGit(['ls-files', '--others', '--exclude-standard', '--', PLUGIN_DIR]) ?? '').split('\n'),
    ].filter(Boolean);
    const baseText = tryGit(['show', `${base}:${PLUGIN_JSON}`]);
    if (changed.length && baseText && pv) {
      let bv;
      try { bv = JSON.parse(baseText).version; } catch { bv = null; }
      if (bv && parseSemver(bv) && parseSemver(pv) && compareSemver(pv, bv) <= 0) {
        const list = changed.slice(0, 10).join(', ') + (changed.length > 10 ? ` ほか ${changed.length - 10} 件` : '');
        errors.push(`${PLUGIN_DIR}/ を変えたのに版が上がっていない。変わったファイル: ${list}。今の版 ${pv}・基準（${base}）の版 ${bv}。直し方: plugin.json・marketplace.json の version を上げ、CHANGELOG.md の先頭に 1 行足す`);
      }
    }
    console.log(`基準 ${base}、${PLUGIN_DIR}/ の変更 ${changed.length} 件、今の版 ${pv ?? '不明'}`);
  }

  if (errors.length) {
    for (const e of errors) console.log(`::error::${e}`);
    process.exit(1);
  }
  console.log('版の検査: 成功');
}

main();
