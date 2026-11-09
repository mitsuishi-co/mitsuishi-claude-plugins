# フック共通の関数（bash から source する）。jq に依存しない。
# 使い方: read_input で標準入力の JSON を 1 回だけ読み、要る値を J_* の変数にまとめて入れる。
# 速さのため、呼び出しごとに外部コマンド（awk・tr・date など）を起動しない書き方にしている（bash 3.2 でも動く）。
# MITSUISHI_HOOKS_OFF の判定は各フックの最初（この lib を読む前）に行う。

_src="${BASH_SOURCE[0]//\\//}"
case "$_src" in
  */*) HOOK_LIB_DIR="${_src%/*}" ;;
  *) HOOK_LIB_DIR=. ;;
esac
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$HOOK_LIB_DIR/../..}"
MITSUISHI_STATE_DIR="$HOME/.claude/mitsuishi-dev"
HOOKS_LOG="$MITSUISHI_STATE_DIR/hooks.log"
README_URL="https://github.com/mitsuishi-co/mitsuishi-claude-plugins#フックに止められたとき"
HAS_PRINTF_TIME=0
[ "${BASH_VERSINFO[0]:-3}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-3}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; } && HAS_PRINTF_TIME=1

# lower <文字列> : 小文字にして REPLY に
lower() {
  if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then REPLY="${1,,}"
  else REPLY=$(printf '%s' "$1" | tr 'A-Z' 'a-z'); fi
}

# 1 行に収める（改行・制御文字を落とす）。結果は REPLY に
one_line() {
  local LC_ALL=C
  REPLY="${1//[[:cntrl:]]/}"
}

# now_ts : 今の時刻（epoch 秒）を EPOCH に
now_ts() {
  if [ -n "${EPOCHSECONDS:-}" ]; then EPOCH=$EPOCHSECONDS
  elif [ "$HAS_PRINTF_TIME" = 1 ]; then printf -v EPOCH '%(%s)T' -1
  else EPOCH=$(date +%s); fi
}

# stamp : ログの時刻を STAMP に
stamp() {
  if [ "$HAS_PRINTF_TIME" = 1 ]; then printf -v STAMP '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  else STAMP=$(date '+%Y-%m-%dT%H:%M:%S%z'); fi
}

# json_escape <文字列> : JSON の文字列の中身にして REPLY に
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  REPLY="$s"
}

# read_input : 標準入力の JSON を平らにして（json-flatten.awk を 1 回だけ起動）、要る値を変数に入れる
#   J_ERR（読めない）・J_TOOL・J_AGENT_ID・J_AGENT_TYPE・J_CWD・J_FILE・J_FILE_TR（切り詰め）・J_NB・J_NB_TR
#   Edit: J_OLD_L・J_OLD_B・J_NEW_L・J_NEW_B・J_REPLACE_ALL／Write: J_CONTENT_L／NotebookEdit: J_SRC_L
#   MultiEdit: J_EDITS_SEEN・J_EDITS_BAD（replace_all あり）・J_EDITS_L・J_EDITS_B（各 edit の多い方の合計）
#   Agent: J_TYPE・J_MODEL／Skill: J_SKILL／J_EVENT（hook_event_name）・J_PROMPT（UserPromptSubmit。512 文字まで）
read_input() {
  local flat k l b tr v idx
  local -a el eb
  J_ERR=0; J_TOOL=; J_AGENT_ID=; J_AGENT_TYPE=; J_CWD=; J_FILE=; J_FILE_TR=0; J_NB=; J_NB_TR=0
  J_SKILL=; J_EVENT=; J_PROMPT=
  J_OLD_L=0; J_OLD_B=0; J_NEW_L=0; J_NEW_B=0; J_REPLACE_ALL=; J_CONTENT_L=0; J_SRC_L=0
  J_EDITS_SEEN=0; J_EDITS_BAD=0; J_EDITS_L=0; J_EDITS_B=0; J_TYPE=; J_MODEL=
  flat=$(LC_ALL=C awk -f "$HOOK_LIB_DIR/json-flatten.awk") || { J_ERR=1; return; }
  [ -n "$flat" ] || { J_ERR=1; return; }
  while IFS=$'\t' read -r k l b tr v; do
    case "$k" in
      tool_name) J_TOOL=$v ;;
      agent_id) J_AGENT_ID=$v ;;
      agent_type) J_AGENT_TYPE=$v ;;
      cwd) J_CWD=$v ;;
      tool_input.file_path) J_FILE=$v; J_FILE_TR=$tr ;;
      tool_input.notebook_path) J_NB=$v; J_NB_TR=$tr ;;
      tool_input.old_string) J_OLD_L=$l; J_OLD_B=$b ;;
      tool_input.new_string) J_NEW_L=$l; J_NEW_B=$b ;;
      tool_input.replace_all) J_REPLACE_ALL=$v ;;
      tool_input.content) J_CONTENT_L=$l ;;
      tool_input.new_source) J_SRC_L=$l ;;
      tool_input.subagent_type) J_TYPE=$v ;;
      tool_input.model) J_MODEL=$v ;;
      tool_input.skill) J_SKILL=$v ;;
      hook_event_name) J_EVENT=$v ;;
      prompt) J_PROMPT=$v ;;
      tool_input.edits\[*)
        J_EDITS_SEEN=1
        idx="${k#tool_input.edits\[}"; idx="${idx%%\]*}"
        case "$idx" in ''|*[!0-9]*) continue ;; esac
        case "$k" in
          *\].old_string|*\].new_string)
            [ "$l" -gt "${el[idx]:-0}" ] && el[idx]=$l
            [ "$b" -gt "${eb[idx]:-0}" ] && eb[idx]=$b ;;
          *\].replace_all) [ "$v" = true ] && J_EDITS_BAD=1 ;;
        esac ;;
      __error__) J_ERR=1 ;;
    esac
  done <<<"$flat"
  for v in "${el[@]}"; do J_EDITS_L=$((J_EDITS_L + v)); done
  for v in "${eb[@]}"; do J_EDITS_B=$((J_EDITS_B + v)); done
}

# hook_log <フック> <識別子> <ツール> <対象> : hooks.log に 1 行。1500 行を超えたら最後の 1000 行に切り詰める（失敗は無視）
hook_log() {
  [ -d "$MITSUISHI_STATE_DIR" ] || mkdir -p "$MITSUISHI_STATE_DIR" 2>/dev/null || return 0
  stamp; one_line "${4:--}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$STAMP" "$1" "$2" "${3:--}" "$REPLY" >>"$HOOKS_LOG" 2>/dev/null || return 0
  local n
  n=$(wc -l <"$HOOKS_LOG" 2>/dev/null)
  n="${n//[!0-9]/}"
  if [ "${n:-0}" -gt 1500 ] 2>/dev/null; then
    tail -n 1000 "$HOOKS_LOG" >"$HOOKS_LOG.tmp.$$" 2>/dev/null && mv -f "$HOOKS_LOG.tmp.$$" "$HOOKS_LOG" 2>/dev/null
    rm -f "$HOOKS_LOG.tmp.$$" 2>/dev/null
  fi
  return 0
}

# deny <フック> <識別子> <ツール> <対象> <1 行目> <2 行目> : PreToolUse で止める（3 行の拒否文）
# 止め方（環境変数の名前と値）は書かない（AI が自分でガードを外さないため。止め方は人向けの README だけ）
deny() {
  hook_log "$1" "$2" "$3" "$4"
  local msg="[$2] $5
$6
止める必要があると思ったら、自分で止めずに利用者に相談する（開発者でなければ管理者に相談）。説明は README の『フックに止められたとき』（$README_URL）"
  json_escape "$msg"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REPLY"
  exit 0
}

# norm_path <パス> [<相対パスの基準>] : 判定用に正規化した絶対パスを NP に（小文字にはしない。ファイルは見ない）
#   \ → /、相対パスは基準（無ければ $PWD）につなぐ、MSYS の /c/... は c:/... に、// ・/./ をつぶし .. で 1 つ上がる、
#   各部分の : 以降（代替データストリーム）と末尾のドット・空白を落とす（Windows はこれらを同じファイルとみなす。
#   止めすぎる側に倒すため、どの OS でも落とす）
norm_path() {
  local p="${1//\\//}" base="${2//\\//}" pre="" seg r="" n=0 i noglob=0 IFS=/
  local -a parts out
  case "$p" in
    /*|[A-Za-z]:/*) ;;
    [A-Za-z]:) p="$p/" ;;
    *) [ -n "$base" ] || base="${PWD//\\//}"; p="${base%/}/$p" ;;
  esac
  case "${OSTYPE:-}" in
    msys*|cygwin*) [[ $p =~ ^/([A-Za-z])(/.*)?$ ]] && p="${BASH_REMATCH[1]}:${BASH_REMATCH[2]:-/}" ;;
  esac
  case "$p" in
    [A-Za-z]:/*) pre="${p:0:2}"; p="${p:2}" ;;
    //*) pre="/" ;;
  esac
  case $- in *f*) noglob=1 ;; esac
  set -f
  parts=($p)
  [ "$noglob" = 1 ] || set +f
  for seg in "${parts[@]}"; do
    case "$seg" in
      ''|.) continue ;;
      ..) [ "$n" -gt 0 ] && n=$((n - 1)); continue ;;
    esac
    seg="${seg%%:*}"
    while :; do
      case "$seg" in *.|*' ') seg="${seg%?}" ;; *) break ;; esac
    done
    [ -n "$seg" ] || continue
    out[n]="$seg"; n=$((n + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do r="$r/${out[i]}"; i=$((i + 1)); done
  NP="$pre${r:-/}"
  # MSYS の /tmp・/usr などの割り当て（mount）は cygpath で Windows の形に（.. をつぶした後に。このときだけ外部コマンドを起動する）
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      if [ -z "$pre" ] && [ -n "$r" ] && command -v cygpath >/dev/null 2>&1; then
        i=$(cygpath -m -- "$NP" 2>/dev/null) && [ -n "$i" ] && NP="$i"
      fi ;;
  esac
}

# parent_dir <パス> : 親のフォルダを PD に（それ以上上がれなければ同じもの）
parent_dir() {
  local p="$1" q
  case "$p" in
    /|//|[A-Za-z]:/) PD="$p"; return ;;
  esac
  p="${p%/}"
  case "$p" in
    */*) q="${p%/*}" ;;
    *) q="." ;;
  esac
  case "$q" in
    "") q="/" ;;
    [A-Za-z]:) q="$q/" ;;
  esac
  PD="$q"
}

# git_judge <対象のパス> [<相対パスの基準>] : 0 = git のリポジトリの中 / 1 = 外 / 2 = 判定できない（GIT_JUDGE_ERR に理由）
# パスの \ は / に直し、存在するフォルダまで親へ上がる（最大 64 回）。シンボリックリンクは解決しない。
git_judge() {
  local p="${1//\\//}" base="${2//\\//}" d i out
  GIT_JUDGE_ERR=""
  [ -n "$p" ] || { GIT_JUDGE_ERR="対象のパスが空"; return 2; }
  case "$p" in
    /*|[A-Za-z]:/*) ;;
    *) [ -n "$base" ] || base="$PWD"; p="${base%/}/$p" ;;
  esac
  d="$p"; i=0
  while [ "$i" -lt 64 ] && [ ! -d "$d" ]; do
    parent_dir "$d"
    [ "$PD" = "$d" ] && break
    d="$PD"; i=$((i + 1))
  done
  [ -d "$d" ] || { GIT_JUDGE_ERR="存在するフォルダまで上がれない"; return 2; }
  command -v git >/dev/null 2>&1 || { GIT_JUDGE_ERR="git が無い"; return 2; }
  out=$(unset GIT_DIR GIT_WORK_TREE; LC_ALL=C LANGUAGE=C git -c safe.directory='*' -C "$d" rev-parse --is-inside-work-tree 2>&1)
  case "$out" in
    true) return 0 ;;
    false) return 1 ;;
    *"not a git repository"*) return 1 ;;
  esac
  GIT_JUDGE_ERR="git の判定に失敗: ${out%%$'\n'*}"
  return 2
}

# read_models : MODELS.md の TOP_ALIASES（読めなければ best だけ）と TOP_PREFIXES を、小文字・空白区切りで TOP_A・TOP_P に
read_models() {
  local line a="" p="" sa=0 sp=0
  if [ -r "$PLUGIN_ROOT/MODELS.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#$'\xef\xbb\xbf'}"
      case "$line" in
        TOP_ALIASES:*) [ "$sa" = 0 ] && { a="${line#TOP_ALIASES:}"; sa=1; } ;;
        TOP_PREFIXES:*) [ "$sp" = 0 ] && { p="${line#TOP_PREFIXES:}"; sp=1; } ;;
      esac
    done <"$PLUGIN_ROOT/MODELS.md"
  fi
  lower "${a//$'\r'/}"; TOP_A="$REPLY"
  lower "${p//$'\r'/}"; TOP_P="$REPLY"
  [ -n "${TOP_A//[[:space:]]/}" ] || TOP_A="best"
}
