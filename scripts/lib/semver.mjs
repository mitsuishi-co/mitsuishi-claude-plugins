// semver の読み取りと比較（check-version.mjs と bump-upstream.mjs が使う）
export function parseSemver(v) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(String(v ?? '').trim());
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ?? null };
}

// a > b なら正、a < b なら負、等しければ 0
export function compareSemver(a, b) {
  const x = parseSemver(a), y = parseSemver(b);
  if (!x || !y) throw new Error(`semver として読めない: ${!x ? a : b}`);
  for (const k of ['major', 'minor', 'patch']) if (x[k] !== y[k]) return x[k] - y[k];
  if (x.pre === y.pre) return 0;
  if (x.pre === null) return 1;
  if (y.pre === null) return -1;
  const xs = x.pre.split('.'), ys = y.pre.split('.');
  for (let i = 0; i < Math.max(xs.length, ys.length); i++) {
    if (xs[i] === undefined) return -1;
    if (ys[i] === undefined) return 1;
    const xn = /^\d+$/.test(xs[i]), yn = /^\d+$/.test(ys[i]);
    if (xn && yn && +xs[i] !== +ys[i]) return +xs[i] - +ys[i];
    if (xn !== yn) return xn ? -1 : 1;
    if (xs[i] !== ys[i]) return xs[i] < ys[i] ? -1 : 1;
  }
  return 0;
}
