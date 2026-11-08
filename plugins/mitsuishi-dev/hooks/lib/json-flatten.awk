# フック入力の JSON を「パス<TAB>行数<TAB>バイト数<TAB>切り詰め<TAB>値」の行に平らにする（jq を使わないため）。
#   パスの例: tool_name / agent_id / tool_input.old_string / tool_input.edits[0].new_string
#   行数: 文字列の行数（空文字は 0、末尾の改行は数えない）。文字列以外は 0
#   バイト数: デコードした後のバイト数（\uXXXX は UTF-8 のバイト数。サロゲートは 2 ずつ）
#   切り詰め: 値を切り詰めたら 1
#   値: 文字列は簡易デコード（改行・タブは空白に置換、\uXXXX はそのまま）。512 文字で切る。
#       ただし tool_input.file_path・tool_input.notebook_path・cwd は 4096 文字まで切り詰めない
# 上限を超えた残りは、64KB ずつまとめて行数とバイト数だけを数える（1 文字ずつ見ない速い経路）。
# 文字列の中の生の制御文字（改行・タブを含む）・不正なエスケープは不正な JSON とみなす。
# POSIX awk で動く書き方にしている（gawk だけ入力を一括で読む）。呼び出し側で LC_ALL=C を付ける（バイト単位で読むため）。
# 壊れた JSON でも止まらない（途中までを出し、最後に __error__ の行を出して終わる）。

BEGIN {
  CAP = 512; FULLCAP = 4096; CH = 65536
  CTRL = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]"
  HEX = "0123456789abcdef"
  # 入力全体を一括で読む（1 行ずつの連結は行の多い入力で遅い）。gawk は RS = "^$" で全体が 1 レコードになる。
  # ほかの awk（POSIX）は 1 行ずつ読んでつなぐ（RS = "^$" は POSIX では 1 文字目の ^ を区切りとみなすため使わない）
  if ("version" in PROCINFO) { RS = "^$"; WHOLE = 1 }
}

WHOLE { buf = $0; next }
{ buf = buf $0 "\n" }

END {
  s = buf; n = length(s); i = 1
  # 入力の最後に足した改行は JSON の外の空白として読み飛ばす。文字列の中の生の改行は誤りになる
  val("")
  ws()
  if (i <= n || n == 0) ERR = 1
  if (ERR) emit("__error__", 0, 0, 0, "1")
}

function ws(  c) {
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
    else break
  }
}

function val(p,  c) {
  ws()
  if (i > n) { ERR = 1; return }
  c = substr(s, i, 1)
  if (c == "{") obj(p)
  else if (c == "[") arr(p)
  else if (c == "\"") {
    str(p == "tool_input.file_path" || p == "tool_input.notebook_path" || p == "cwd" ? FULLCAP : CAP)
    emit(p, SL, SB, ST, SV)
  }
  else prim(p)
}

function obj(p,  c, k) {
  i++
  ws()
  if (substr(s, i, 1) == "}") { i++; return }
  while (i <= n) {
    ws()
    if (substr(s, i, 1) != "\"") { ERR = 1; i = n + 1; return }
    str(CAP); k = SV
    ws()
    if (substr(s, i, 1) != ":") { ERR = 1; i = n + 1; return }
    i++
    val(p == "" ? k : p "." k)
    ws()
    c = substr(s, i, 1); i++
    if (c == "}") return
    if (c != ",") { ERR = 1; i = n + 1; return }
  }
}

function arr(p,  c, k) {
  i++
  ws()
  if (substr(s, i, 1) == "]") { i++; return }
  k = 0
  while (i <= n) {
    val(p "[" k "]")
    k++
    ws()
    c = substr(s, i, 1); i++
    if (c == "]") return
    if (c != ",") { ERR = 1; i = n + 1; return }
  }
}

# \uXXXX の UTF-8 のバイト数
function ubytes(h,  j, d, v) {
  v = 0
  h = tolower(h)
  for (j = 1; j <= 4; j++) {
    d = index(HEX, substr(h, j, 1)) - 1
    if (d < 0) { ERR = 1; return 1 }
    v = v * 16 + d
  }
  if (v < 128) return 1
  if (v < 2048) return 2
  if (v >= 55296 && v <= 57343) return 2
  return 3
}

# s[i] が開きの " の位置で呼ぶ。SV（値）・SL（行数）・SB（バイト数）・ST（切り詰め）を返す。
function str(cap,  c, d, v, len, nl, bytes, lastnl, nonempty, closed) {
  i++
  v = ""; len = 0; nl = 0; bytes = 0; lastnl = 0; nonempty = 0; closed = 0; ST = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"") { i++; closed = 1; break }
    if (len >= cap) {
      # 上限を超えた残りは速い経路で数える
      ST = 1
      FNONEMPTY = nonempty; FLASTNL = lastnl
      fast()
      closed = FCLOSED; nl += FNL; bytes += FBYTES; nonempty = FNONEMPTY; lastnl = FLASTNL
      break
    }
    nonempty = 1
    if (c < " ") ERR = 1
    if (c == "\\") {
      d = substr(s, i + 1, 1)
      if (d == "n") { nl++; c = " "; lastnl = 1; bytes++; i += 2 }
      else if (d == "t" || d == "r") { c = " "; lastnl = 0; bytes++; i += 2 }
      else if (d == "b" || d == "f") { c = ""; lastnl = 0; bytes++; i += 2 }
      else if (d == "u") { c = "\\u" substr(s, i + 2, 4); bytes += ubytes(substr(s, i + 2, 4)); lastnl = 0; i += 6 }
      else if (d == "\"" || d == "\\" || d == "/") { c = d; lastnl = 0; bytes++; i += 2 }
      else { ERR = 1; c = d; lastnl = 0; bytes++; i += 2 }
    } else {
      lastnl = 0; bytes++; i++
    }
    v = v c; len += length(c)
  }
  if (!closed) ERR = 1
  SV = v; SB = bytes
  SL = nonempty ? nl + (lastnl ? 0 : 1) : 0
}

# 文字列の残り（s[i] から閉じの " まで）を 64KB ずつ数える。i は閉じの " の次へ進む。
# チャンクを \ で split し、エスケープの数だけ回す（gsub は C ロケールの gawk で遅いので使わない）。
# FNL（改行の数）・FBYTES・FCLOSED を返し、FNONEMPTY・FLASTNL（最後が改行か）は呼ぶ側の値を引き継いで更新する。
function fast(  t, np, A, k, a, d, rest, end, stop) {
  FNL = 0; FBYTES = 0; FCLOSED = 0
  while (i <= n) {
    t = substr(s, i, CH)
    end = (length(t) < CH)
    np = split(t, A, "\\")
    FPOS = 0; stop = 0
    if (plainseg(A[1])) stop = 1
    k = 2
    while (!stop && k <= np) {
      a = A[k]
      if (a == "") {
        # \ がチャンクの最後: 次のチャンクへ回す（入力の最後なら閉じていない）
        if (k == np) break
        # \\ の組（次の部分は普通の文字）
        FBYTES++; FNONEMPTY = 1; FLASTNL = 0; FPOS += 2
        if (plainseg(A[k + 1])) stop = 1
        k += 2
        continue
      }
      d = substr(a, 1, 1)
      if (d == "u") {
        if (length(a) < 5) {
          if (k == np && !end) break
          ERR = 1
        }
        FBYTES += ubytes(substr(a, 2, 4)); rest = substr(a, 6); FPOS += 6; FLASTNL = 0
      } else {
        if (d == "n") { FNL++; FLASTNL = 1 }
        else {
          FLASTNL = 0
          if (d != "\"" && d != "/" && d != "b" && d != "f" && d != "r" && d != "t") ERR = 1
        }
        FBYTES++; rest = substr(a, 2); FPOS += 2
      }
      FNONEMPTY = 1
      if (plainseg(rest)) stop = 1
      k++
    }
    if (substr(t, 1, FPOS) ~ CTRL) ERR = 1
    i += FPOS
    if (FCLOSED) return
    if (end || FPOS == 0) { i = n + 1; return }
  }
}

# エスケープを含まない部分。閉じの " があればそこまで数えて 1 を返す
function plainseg(seg,  q) {
  q = index(seg, "\"")
  if (q > 0) {
    if (q > 1) { FBYTES += q - 1; FNONEMPTY = 1; FLASTNL = 0 }
    FPOS += q; FCLOSED = 1
    return 1
  }
  if (length(seg) > 0) { FBYTES += length(seg); FNONEMPTY = 1; FLASTNL = 0; FPOS += length(seg) }
  return 0
}

function prim(p,  c, v) {
  v = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
    v = v c; i++
  }
  if (v == "") { ERR = 1; i = n + 1; return }
  emit(p, 0, length(v), 0, v)
}

function emit(p, l, b, t, v) {
  printf "%s\t%d\t%d\t%d\t%s\n", p, l, b, t, v
}
