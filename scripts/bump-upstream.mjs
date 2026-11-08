#!/usr/bin/env node
// 上流（gstack・superpowers）の固定を最新の HEAD に上げる（bump-upstream.yml から毎日呼ぶ。手元でも動く）
//   node scripts/bump-upstream.mjs
// gstack は HEAD が変われば pins.json の sha を上げる。
// superpowers は HEAD が変わり、かつ上流の plugin.json の version が変わったと確かめられたときだけ marketplace.json の sha を上げる
//   （Claude Code は version で更新を判断するので、version が同じ sha は各 PC に届かない。確かめられないときも上げない）。
// 上げたものがあれば mitsuishi-dev の版の patch を上げ、CHANGELOG.md に 1 行足す。
// GITHUB_OUTPUT があれば changed・version・title・body を書く。本文には上流ごとの compare のリンクを載せる。
// 版は厳密な semver（x.y.z）だけを読み、置き換えが値を変えなかったら止める（黙って書き換えない）。
// テスト用（ネットワークに出ない）:
//   BUMP_HEADS='{"gstack":"<sha>","superpowers":"<sha>"}'  ls-remote の代わり
//   BUMP_VERSIONS='{"old":"x","new":"y"}'                  superpowers の version の取得の代わり（null は取得失敗）
//   BUMP_OFFLINE=1                                         version を取得しない（確かめられないとみなす）
import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const P = {
  pins: 'plugins/mitsuishi-dev/pins.json',
  plugin: 'plugins/mitsuishi-dev/.claude-plugin/plugin.json',
  market: '.claude-plugin/marketplace.json',
  changelog: 'CHANGELOG.md',
};
const read = (p) => readFileSync(join(ROOT, p), 'utf8');
const write = (p, s) => writeFileSync(join(ROOT, p), s);

function fail(msg) {
  console.log(`::error::${msg}`);
  process.exit(1);
}

function headOf(url, key) {
  if (process.env.BUMP_HEADS) return JSON.parse(process.env.BUMP_HEADS)[key];
  const out = execFileSync('git', ['ls-remote', url, 'HEAD'], { encoding: 'utf8' });
  const sha = out.split(/\s/)[0];
  if (!/^[0-9a-f]{40}$/.test(sha)) fail(`${url} の HEAD を読めない: ${out.trim()}`);
  return sha;
}

// superpowers の plugin.json の version（取得できなければ null）
async function upstreamVersion(repo, sha, which) {
  if (process.env.BUMP_VERSIONS) return JSON.parse(process.env.BUMP_VERSIONS)[which] ?? null;
  if (process.env.BUMP_OFFLINE === '1') return null;
  try {
    const r = await fetch(`https://raw.githubusercontent.com/${repo}/${sha}/.claude-plugin/plugin.json`);
    if (!r.ok) return null;
    const v = (await r.json()).version;
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

const pinsText = read(P.pins), marketText = read(P.market), pluginText = read(P.plugin);
const pins = JSON.parse(pinsText), market = JSON.parse(marketText), plugin = JSON.parse(pluginText);
const sp = market.plugins.find((p) => p.name === 'superpowers');
// superpowers は url（HTTPS）形式で固定している（github 形式は SSH で clone され、鍵の無い PC で入らない）
const spUrl = sp.source.url;
const spRepo = sp.source.source === 'url' && typeof spUrl === 'string' ? repoOf(spUrl) : null;
if (!spRepo) fail(`marketplace.json の superpowers の source が {"source":"url","url":"https://github.com/<owner>/<repo>.git"} の形ではない`);
const gsUrl = pins.gstack.repo;
const gsRepo = repoOf(gsUrl);

const ver = String(plugin.version ?? '');
const vm = /^(\d+)\.(\d+)\.(\d+)$/.exec(ver);
if (!vm) fail(`mitsuishi-dev の版が x.y.z の形ではない（${ver}）。prerelease などは自動で上げない。直し方: plugin.json・marketplace.json・CHANGELOG.md を x.y.z の版にそろえる`);

const oldG = pins.gstack.sha, oldS = sp.source.sha;
const newG = headOf(gsUrl, 'gstack'), newS = headOf(spUrl, 'superpowers');
const changes = [], links = [], notes = [];
const bumpG = newG !== oldG;
let bumpS = false;

if (bumpG) {
  changes.push(`gstack ${oldG.slice(0, 7)}→${newG.slice(0, 7)}`);
  links.push(`- gstack: https://github.com/${gsRepo ?? gsUrl}/compare/${oldG}...${newG}`);
}
if (newS !== oldS) {
  const [ov, nvS] = await Promise.all([upstreamVersion(spRepo, oldS, 'old'), upstreamVersion(spRepo, newS, 'new')]);
  if (ov === null || nvS === null) {
    const m = `superpowers は HEAD が ${newS.slice(0, 7)} に変わったが、plugin.json の version を確かめられないため見送った（次の実行で確かめる）`;
    console.log(m); notes.push(m);
  } else if (ov === nvS) {
    const m = `superpowers は HEAD が ${newS.slice(0, 7)} に変わったが、plugin.json の version が同じ（${ov}）ため見送った（sha だけ上げても各 PC に届かない）`;
    console.log(m); notes.push(m);
  } else {
    bumpS = true;
    changes.push(`superpowers ${String(oldS).slice(0, 7)}→${newS.slice(0, 7)}`);
    links.push(`- superpowers: https://github.com/${spRepo}/compare/${oldS}...${newS}`);
    notes.push(`superpowers の version: ${ov} → ${nvS}（各 PC に届く）`);
  }
}

if (!changes.length) {
  console.log('上流は変わっていない（固定を上げるものが無い）');
  output({ changed: 'false' });
  process.exit(0);
}

const nv = `${vm[1]}.${vm[2]}.${Number(vm[3]) + 1}`;
const today = new Date().toISOString().slice(0, 10);

let pinsOut = pinsText, marketOut = marketText;
if (bumpG) pinsOut = replaceOnce(pinsOut, oldG, newG, 'pins.json の gstack の sha');
if (bumpS) marketOut = replaceOnce(marketOut, `"sha": "${oldS}"`, `"sha": "${newS}"`, 'marketplace.json の superpowers の sha');
marketOut = replaceOnce(marketOut, `"version": "${ver}"`, `"version": "${nv}"`, 'marketplace.json の mitsuishi-dev の version');
const pluginOut = replaceOnce(pluginText, `"version": "${ver}"`, `"version": "${nv}"`, 'plugin.json の version');

const line = `- ${nv} (${today}) 上流の固定を上げる: ${changes.join('、')}`;
const cl = read(P.changelog).split('\n');
const at = cl.findIndex((l) => /^- \d+\.\d+\.\d+/.test(l));
cl.splice(at < 0 ? cl.length : at, 0, line);

write(P.pins, pinsOut);
write(P.market, marketOut);
write(P.plugin, pluginOut);
write(P.changelog, cl.join('\n'));

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
  'CI が通れば自動で取り込まれ、全員へ届く（不具合が出たら取り込みのコミットを revert し、版を上げて出す）。このブランチ（bump-upstream）には手で積まない（翌日の実行で上書きされる）。',
].join('\n');

console.log(line);
console.log(body);
output({ changed: 'true', version: nv, title: `上流の固定を上げる (${nv})`, body });
