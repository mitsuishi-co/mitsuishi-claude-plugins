#!/usr/bin/env node
// 上流（gstack・superpowers）の固定を最新の HEAD に上げる（bump-upstream.yml から毎日呼ぶ。手元でも動く）
//   node scripts/bump-upstream.mjs
// gstack は HEAD が変われば pins.json の sha を上げる。
// superpowers は上流の写しを plugins/superpowers/ に同梱している（固定の sha は upstream-pins.json）。
//   HEAD が変わり、かつ上流の plugin.json の version が今の写しより semver で大きいと確かめられたときだけ、新しい sha の中身で
//   plugins/superpowers/ を丸ごと置き換え（消えたファイルも消す）、upstream-pins.json の sha を上げる
//   （Claude Code は version で更新を判断するので、version が同じか小さい中身は各 PC に届かない。確かめられないときも上げない。
//   小さいときも上げないのは、写しを前の版に戻して version を上げて出した後に、上流の低い版で上書きしないため）。
// 上げたものがあれば mitsuishi-dev の版の patch を上げ、CHANGELOG.md に 1 行足す。
// GITHUB_OUTPUT があれば changed・version・title・body を書く。本文には上流ごとの compare のリンクを載せる。
// 版は厳密な semver（x.y.z）だけを読み、置き換えが値を変えなかったら止める（黙って書き換えない）。
// テスト用（ネットワークに出ない）:
//   BUMP_HEADS='{"gstack":"<sha>","superpowers":"<sha>"}'  ls-remote の代わり
//   BUMP_VERSIONS='{"old":"x","new":"y"}'                  superpowers の version の読み取りの代わり（null は読めない）
//   BUMP_SUPERPOWERS_SRC=<フォルダ>                         superpowers の新しい sha の中身の取得（git fetch）の代わり
//   BUMP_OFFLINE=1                                         中身を取得しない（BUMP_SUPERPOWERS_SRC が無ければ確かめられないとみなす）
import { execFileSync } from 'node:child_process';
import { appendFileSync, cpSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareSemver, parseSemver } from './lib/semver.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const P = {
  pins: 'plugins/mitsuishi-dev/pins.json',
  upstream: 'upstream-pins.json',
  plugin: 'plugins/mitsuishi-dev/.claude-plugin/plugin.json',
  market: '.claude-plugin/marketplace.json',
  changelog: 'CHANGELOG.md',
};
const read = (p) => readFileSync(join(ROOT, p), 'utf8');
const write = (p, s) => writeFileSync(join(ROOT, p), s);
const temps = [];

function fail(msg) {
  console.log(`::error::${msg}`);
  for (const d of temps) rmSync(d, { recursive: true, force: true });
  process.exit(1);
}

function headOf(url, key) {
  if (process.env.BUMP_HEADS) return JSON.parse(process.env.BUMP_HEADS)[key];
  const out = execFileSync('git', ['ls-remote', url, 'HEAD'], { encoding: 'utf8' });
  const sha = out.split(/\s/)[0];
  if (!/^[0-9a-f]{40}$/.test(sha)) fail(`${url} の HEAD を読めない: ${out.trim()}`);
  return sha;
}

// superpowers の新しい sha の中身のフォルダ（取得できなければ null。.git を含むことがある）
function fetchTree(url, sha) {
  if (process.env.BUMP_SUPERPOWERS_SRC) return process.env.BUMP_SUPERPOWERS_SRC;
  if (process.env.BUMP_OFFLINE === '1') return null;
  const d = mkdtempSync(join(tmpdir(), 'bump-sp-'));
  temps.push(d);
  try {
    const g = (args) => execFileSync('git', ['-C', d, '-c', 'core.autocrlf=false', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    g(['init', '-q']);
    g(['fetch', '-q', '--depth', '1', url, sha]);
    g(['checkout', '-q', '--detach', 'FETCH_HEAD']);
    if (g(['rev-parse', 'HEAD']).trim() !== sha) return null;
    return d;
  } catch (e) {
    console.log(`superpowers の ${sha.slice(0, 7)} を取得できない: ${String(e.stderr || e.message).trim()}`);
    return null;
  }
}

// フォルダの中の .claude-plugin/plugin.json の version（読めなければ null）
function versionIn(dir) {
  if (!dir) return null;
  try {
    const v = JSON.parse(readFileSync(join(dir, '.claude-plugin/plugin.json'), 'utf8')).version;
    return typeof v === 'string' && v ? v : null;
  } catch { return null; }
}

// 1 か所だけ置き換え、値が変わったことを確かめる
function replaceOnce(text, from, to, label) {
  const n = text.split(from).length - 1;
  if (n !== 1) fail(`${label} を置き換えられない（"${from}" が ${n} か所。ちょうど 1 か所のはず）`);
  const out = text.replace(from, () => to);
  if (out === text) fail(`${label} を置き換えられない（値が変わらない）`);
  return out;
}

// GitHub のリポジトリ（owner/name）を URL から取り出す
function repoOf(url) {
  const m = /github\.com[/:]([^/]+\/[^/]+?)(?:\.git)?\/?$/.exec(url);
  return m ? m[1] : null;
}

function output(kv) {
  const f = process.env.GITHUB_OUTPUT;
  if (!f) return;
  for (const [k, v] of Object.entries(kv)) {
    const d = `EOF_${Math.random().toString(36).slice(2)}`;
    appendFileSync(f, `${k}<<${d}\n${v}\n${d}\n`);
  }
}

const pinsText = read(P.pins), upText = read(P.upstream), marketText = read(P.market), pluginText = read(P.plugin);
const pins = JSON.parse(pinsText), up = JSON.parse(upText), market = JSON.parse(marketText), plugin = JSON.parse(pluginText);
// superpowers は上流の写しを同梱し、相対パスで配る（外部の GitHub から別に clone する形は社員の PC で入らなかった）
const spPin = up.superpowers ?? {};
const spUrl = spPin.repo, spDir = spPin.path, oldS = spPin.sha;
const spRepo = typeof spUrl === 'string' ? repoOf(spUrl) : null;
if (!spRepo || !/^[0-9a-f]{40}$/.test(String(oldS)) || !/^plugins\/[a-z0-9-]+$/.test(String(spDir))) {
  fail(`${P.upstream} の superpowers が {"repo":"https://github.com/<owner>/<repo>.git","sha":"<40 桁>","path":"plugins/<名前>"} の形ではない`);
}
const spMarket = (market.plugins || []).find((p) => p.name === 'superpowers');
if (spMarket?.source !== `./${spDir}`) fail(`marketplace.json の superpowers の source が "./${spDir}" ではない（${P.upstream} の path と合わせる）`);
if (!existsSync(join(ROOT, spDir, '.claude-plugin/plugin.json'))) fail(`${spDir}/.claude-plugin/plugin.json が無い`);
const gsUrl = pins.gstack.repo;
const gsRepo = repoOf(gsUrl);

const ver = String(plugin.version ?? '');
const vm = /^(\d+)\.(\d+)\.(\d+)$/.exec(ver);
if (!vm) fail(`mitsuishi-dev の版が x.y.z の形ではない（${ver}）。prerelease などは自動で上げない。直し方: plugin.json・marketplace.json・CHANGELOG.md を x.y.z の版にそろえる`);

const oldG = pins.gstack.sha;
const newG = headOf(gsUrl, 'gstack'), newS = headOf(spUrl, 'superpowers');
const changes = [], links = [], notes = [];
const bumpG = newG !== oldG;
let bumpS = false, spSrc = null;

if (bumpG) {
  changes.push(`gstack ${oldG.slice(0, 7)}→${newG.slice(0, 7)}`);
  links.push(`- gstack: https://github.com/${gsRepo ?? gsUrl}/compare/${oldG}...${newG}`);
}
if (newS !== oldS) {
  const skip = (why) => {
    const m = `superpowers は HEAD が ${newS.slice(0, 7)} に変わったが、${why}`;
    console.log(m); notes.push(m);
  };
  spSrc = fetchTree(spUrl, newS);
  const fixed = process.env.BUMP_VERSIONS ? JSON.parse(process.env.BUMP_VERSIONS) : null;
  const ov = fixed ? fixed.old ?? null : versionIn(join(ROOT, spDir));
  const nvS = fixed ? fixed.new ?? null : versionIn(spSrc);
  if (ov === null || nvS === null || !parseSemver(ov) || !parseSemver(nvS)) skip(`plugin.json の version を確かめられないため見送った（今 ${ov ?? '読めない'}・上流 ${nvS ?? '読めない'}。次の実行で確かめる）`);
  else if (compareSemver(nvS, ov) === 0) skip(`plugin.json の version が同じ（${ov}）ため見送った（中身だけ上げても各 PC に届かない）`);
  else if (compareSemver(nvS, ov) < 0) skip(`plugin.json の version が今の写し（${ov}）より小さい（${nvS}）ため見送った（下がった版は各 PC に届かない。写しを戻して版を上げて出した後なら、上流がそれを超えるまで待つ）`);
  else if (!spSrc) skip('中身を取得できないため見送った（次の実行で取得する）');
  else {
    for (const f of ['LICENSE', '.claude-plugin/plugin.json']) {
      if (!existsSync(join(spSrc, f))) fail(`superpowers の ${newS.slice(0, 7)} に ${f} が無い（同梱の条件を満たさない）。直し方: 上流の変更を確かめ、同梱を続けるか判断する`);
    }
    bumpS = true;
    changes.push(`superpowers ${ov}→${nvS}（${oldS.slice(0, 7)}→${newS.slice(0, 7)}）`);
    links.push(`- superpowers: https://github.com/${spRepo}/compare/${oldS}...${newS}`);
    notes.push(`superpowers の version: ${ov} → ${nvS}（${spDir}/ を新しい sha の中身で丸ごと置き換えた。各 PC に届く）`);
  }
}

if (!changes.length) {
  console.log('上流は変わっていない（固定を上げるものが無い）');
  output({ changed: 'false' });
  for (const d of temps) rmSync(d, { recursive: true, force: true });
  process.exit(0);
}

const nv = `${vm[1]}.${vm[2]}.${Number(vm[3]) + 1}`;
const today = new Date().toISOString().slice(0, 10);

// 書き込む前にすべての置き換えを確かめる（途中で止まって半端に書き換えないため）
let pinsOut = pinsText, upOut = upText, marketOut = marketText;
if (bumpG) pinsOut = replaceOnce(pinsOut, oldG, newG, 'pins.json の gstack の sha');
if (bumpS) upOut = replaceOnce(upOut, `"sha": "${oldS}"`, `"sha": "${newS}"`, `${P.upstream} の superpowers の sha`);
marketOut = replaceOnce(marketOut, `"version": "${ver}"`, `"version": "${nv}"`, 'marketplace.json の mitsuishi-dev の version');
const pluginOut = replaceOnce(pluginText, `"version": "${ver}"`, `"version": "${nv}"`, 'plugin.json の version');

const line = `- ${nv} (${today}) 上流の固定を上げる: ${changes.join('、')}`;
const cl = read(P.changelog).split('\n');
const at = cl.findIndex((l) => /^- \d+\.\d+\.\d+/.test(l));
cl.splice(at < 0 ? cl.length : at, 0, line);

if (bumpS) {
  // 上流の写しを丸ごと置き換える（消えたファイルも消す）。取得元の .git は写さない。実行属性は cpSync が保つ
  const dest = join(ROOT, spDir);
  if (!statSync(spSrc).isDirectory()) fail(`superpowers の中身のフォルダが無い: ${spSrc}`);
  rmSync(dest, { recursive: true, force: true });
  cpSync(spSrc, dest, { recursive: true, filter: (s) => relative(spSrc, s).split(/[\\/]/)[0] !== '.git' });
}
write(P.pins, pinsOut);
write(P.upstream, upOut);
write(P.market, marketOut);
write(P.plugin, pluginOut);
write(P.changelog, cl.join('\n'));
for (const d of temps) rmSync(d, { recursive: true, force: true });

const body = [
  `上流の固定を最新の HEAD に上げる（bump-upstream が自動で作成）。`,
  '',
  ...changes.map((c) => `- ${c}`),
  `- mitsuishi-dev の版: ${ver} → ${nv}`,
  '',
  '上流の差分:',
  ...links,
  '',
  ...notes,
  '',
  'CI が通れば自動で取り込まれ、全員へ届く。不具合が出たら: gstack は取り込みのコミットを revert し、mitsuishi-dev の版を上げて出す。superpowers は revert では届かない（版が下がる）ので、plugins/superpowers/ の中身を前の版にし、plugin.json の version を今より上げて出す。止めるだけなら管理設定の enabledPlugins で false（README の「上流で不具合が出たら」）。このブランチ（bump-upstream）には手で積まない（翌日の実行で上書きされる）。',
].join('\n');

console.log(line);
console.log(body);
output({ changed: 'true', version: nv, title: `上流の固定を上げる (${nv})`, body });
