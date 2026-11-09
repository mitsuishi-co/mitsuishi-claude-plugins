#!/usr/bin/env bash
# gstack の導入・毎日の更新（版は pins.json の sha に固定）。session-start から呼ばれる。
#   source してから bg_status   BG_ACTION = run|none（裏で run を起動するか）、BG_STATUS = 注入する状態の 1 行
#   bash gstack-bg.sh status                       上の 2 つを 2 行で出す
#   bash gstack-bg.sh run                          ロックを取って work を打ち切りつきで走らせ、状態ファイルを書く（裏で呼ぶ）
#   bash gstack-bg.sh work full|config             本体。full = fetch → checkout → setup → 設定をそろえる、config = 設定をそろえるだけ。出力はすべて gstack.log
# いつ走らせるか: 失敗から 1 時間未満は何もしない。gstack の今の HEAD が固定と違えば（固定が上がった・未導入・前回が未完了）すぐ full、
#   同じなら前回の成功から 24 時間たったときに config だけ。
# 状態ファイル ~/.claude/mitsuishi-dev/state（key=value: last_success・head・fail_count・last_attempt。時刻は epoch 秒）
# gstack-upgrade は使わない。作業コピーは消さない（既定の場所で .git が読めないときだけ日時つきの名前に退避）。

set +e
BG_SELF="${BASH_SOURCE[0]}"
_bgsrc="${BG_SELF//\\//}"
case "$_bgsrc" in */*) _bgdir="${_bgsrc%/*}" ;; *) _bgdir=. ;; esac
. "$_bgdir/common.sh" 2>/dev/null || { [ "$BG_SELF" = "$0" ] && exit 0; return 1; }

GSTACK_DEFAULT_DIR="$HOME/.claude/skills/gstack"
GSTACK_DIR="${GSTACK_DIR:-$GSTACK_DEFAULT_DIR}"
STATE_FILE="$MITSUISHI_STATE_DIR/state"
LOCK_DIR="$MITSUISHI_STATE_DIR/gstack.lock"
GSTACK_LOG="$MITSUISHI_STATE_DIR/gstack.log"
OVERWROTE_FILE="$MITSUISHI_STATE_DIR/gstack-overwrote"
PINS_FILE="$PLUGIN_ROOT/pins.json"
DAY=86400; HOUR=3600
TIMEOUT_INSTALL=900; TIMEOUT_UPDATE=300; LOCK_GRACE=300

glog() {
  [ -d "$MITSUISHI_STATE_DIR" ] || mkdir -p "$MITSUISHI_STATE_DIR" 2>/dev/null
  stamp
  printf '[%s] %s\n' "$STAMP" "$*" >>"$GSTACK_LOG" 2>/dev/null
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
is_sha() { case "$1" in *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 40 ]; }

# pins.json の gstack の sha と repo を PIN_SHA・PIN_REPO に（1 回だけ読む）
PINS_DONE=0
pins_read() {
  [ "$PINS_DONE" = 1 ] && return
  PINS_DONE=1; PIN_SHA=""; PIN_REPO=""
  local txt=""
  [ -r "$PINS_FILE" ] && IFS= read -r -d '' txt <"$PINS_FILE"
  if [[ $txt =~ \"gstack\"[[:space:]]*:[[:space:]]*\{([^}]*)\} ]]; then
    txt="${BASH_REMATCH[1]}"
    [[ $txt =~ \"sha\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{40})\" ]] && PIN_SHA="${BASH_REMATCH[1]}"
    [[ $txt =~ \"repo\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && PIN_REPO="${BASH_REMATCH[1]}"
  fi
  [ -n "$PIN_REPO" ] || PIN_REPO="https://github.com/garrytan/gstack.git"
}

# 状態を読む。壊れている値・未来の時刻は 0（古い）とみなす
state_read() {
  ST_SUCCESS=0; ST_HEAD=""; ST_FAIL=0; ST_ATTEMPT=0
  local k v
  if [ -r "$STATE_FILE" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      v="${v%$'\r'}"
      case "$k" in
        last_success) ST_SUCCESS="$v" ;;
        head) ST_HEAD="$v" ;;
        fail_count) ST_FAIL="$v" ;;
        last_attempt) ST_ATTEMPT="$v" ;;
      esac
    done <"$STATE_FILE"
  fi
  now_ts
  is_num "$ST_SUCCESS" && [ "$ST_SUCCESS" -le "$EPOCH" ] || ST_SUCCESS=0
  is_num "$ST_ATTEMPT" && [ "$ST_ATTEMPT" -le "$EPOCH" ] || ST_ATTEMPT=0
  is_num "$ST_FAIL" || ST_FAIL=0
  is_sha "$ST_HEAD" || ST_HEAD=""
}

# 状態を書く（一時ファイルから mv）。Windows では読んでいる別プロセスやウイルス対策が掴んでいると mv が失敗するので、
# 数回やり直し、それでも失敗したらログに残す
state_write() {
  [ -d "$MITSUISHI_STATE_DIR" ] || mkdir -p "$MITSUISHI_STATE_DIR" 2>/dev/null
  local tmp="$STATE_FILE.tmp.$$" i=0 err=""
  while [ "$i" -lt 5 ]; do
    if printf 'last_success=%s\nhead=%s\nfail_count=%s\nlast_attempt=%s\n' "$ST_SUCCESS" "$ST_HEAD" "$ST_FAIL" "$ST_ATTEMPT" >"$tmp" 2>/dev/null; then
      err=$(mv -f "$tmp" "$STATE_FILE" 2>&1) && return 0
    else
      err="一時ファイルを書けない"
    fi
    i=$((i + 1))
    [ "$i" -lt 5 ] && sleep 1
  done
  rm -f "$tmp" 2>/dev/null
  glog "状態ファイルを書けない（${i} 回試した: ${err%%$'\n'*}）: $STATE_FILE"
  return 1
}

# gstack の今の HEAD を CUR_HEAD に（キャッシュする。読めなければ空）。.git/HEAD が sha ならそれを使い、git を起動しない
CUR_HEAD_DONE=0
current_head() {
  [ "$CUR_HEAD_DONE" = 1 ] && return
  CUR_HEAD_DONE=1; CUR_HEAD=""
  [ -e "$GSTACK_DIR/.git" ] || return
  local h=""
  [ -f "$GSTACK_DIR/.git/HEAD" ] && { IFS= read -r h <"$GSTACK_DIR/.git/HEAD"; h="${h%$'\r'}"; }
  if ! is_sha "$h"; then
    h=$(git -C "$GSTACK_DIR" rev-parse HEAD 2>/dev/null)
    h="${h%$'\r'}"
  fi
  is_sha "$h" && CUR_HEAD="$h"
}

# 走らせる必要があれば 0（DUE_MODE = full|config）
due() {
  now_ts; current_head; pins_read
  DUE_MODE=""
  if [ "$ST_FAIL" -gt 0 ] && [ $((EPOCH - ST_ATTEMPT)) -lt "$HOUR" ]; then return 1; fi
  if [ -z "$CUR_HEAD" ] || [ "$CUR_HEAD" != "$PIN_SHA" ] || [ "$ST_HEAD" != "$CUR_HEAD" ] || [ "$ST_SUCCESS" -eq 0 ]; then
    DUE_MODE=full; return 0
  fi
  if [ $((EPOCH - ST_SUCCESS)) -ge "$DAY" ]; then DUE_MODE=config; return 0; fi
  return 1
}

# ロックの中身: "PID 時刻 打ち切り秒"。先に持ち主の PID を見る（kill -0）: 死んでいれば古い。
# 生きていても（または PID が読めなくても）、打ち切り秒 + 300 秒を過ぎていれば古い（PID の使い回しに備える）。
# 打ち切り秒が無ければ初回の導入の 900 秒
LOCK_INFO_PID=""; LOCK_INFO_TS=""
lock_fresh() {
  [ -d "$LOCK_DIR" ] || return 1
  local pid ts lim
  { read -r pid ts lim <"$LOCK_DIR/info"; } 2>/dev/null
  LOCK_INFO_PID="$pid"; LOCK_INFO_TS="$ts"
  is_num "$lim" || lim="$TIMEOUT_INSTALL"
  if is_num "$pid" && [ "$pid" -gt 0 ] && ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  now_ts
  if is_num "$ts" && [ "$ts" -le "$EPOCH" ]; then
    [ $((EPOCH - ts)) -lt $((lim + LOCK_GRACE)) ]
    return
  fi
  # 時刻が読めなければフォルダの更新時刻で見る
  [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin +$(( (lim + LOCK_GRACE + 59) / 60 )) 2>/dev/null)" ]
}

lock_write() {
  local pid i=0
  while [ "$i" -lt 3 ]; do
    now_ts
    printf '%s %s %s\n' "$$" "$EPOCH" "$BG_TIMEOUT" >"$LOCK_DIR/info" 2>/dev/null
    { read -r pid _ <"$LOCK_DIR/info"; } 2>/dev/null
    [ "$pid" = "$$" ] && return 0
    # 取り直しの途中の別プロセスが一時的に動かしている。戻るのを待って書き直す
    sleep 1; i=$((i + 1))
  done
  return 1
}

# ロックを確かに持っていれば 0（info の PID が自分）
lock_held() {
  local pid
  { read -r pid _ <"$LOCK_DIR/info"; } 2>/dev/null
  [ "$pid" = "$$" ]
}

# 古いロックは消さずに自分用の名前へ mv してから mkdir する（mv に成功した側だけが進む）
lock_take() {
  [ -d "$MITSUISHI_STATE_DIR" ] || mkdir -p "$MITSUISHI_STATE_DIR" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then lock_write; return; fi
  lock_fresh && return 1
  local seen_pid="$LOCK_INFO_PID" seen_ts="$LOCK_INFO_TS" mine="$LOCK_DIR.stale.$$" pid ts lim
  mv "$LOCK_DIR" "$mine" 2>/dev/null || return 1
  { read -r pid ts lim <"$mine/info"; } 2>/dev/null
  if [ "$pid" != "$seen_pid" ] || [ "$ts" != "$seen_ts" ]; then
    # 古いと見た後に、別のプロセスが取り直した新しいロックを動かしてしまった。戻して譲る
    mv "$mine" "$LOCK_DIR" 2>/dev/null || rm -rf "$mine" 2>/dev/null
    return 1
  fi
  glog "古いロックを取り直す（PID ${seen_pid:-不明}・時刻 ${seen_ts:-不明}）"
  rm -rf "$mine" 2>/dev/null
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  lock_write
}

# 自分のロックだけを外す
lock_release() {
  local pid ts lim
  { read -r pid ts lim <"$LOCK_DIR/info"; } 2>/dev/null
  [ "$pid" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null
}

last_date() {
  if [ "$ST_SUCCESS" -le 0 ]; then REPLY="不明"
  elif [ "$HAS_PRINTF_TIME" = 1 ]; then printf -v REPLY '%(%Y-%m-%d)T' "$ST_SUCCESS"
  else REPLY=$(date -d "@$ST_SUCCESS" '+%Y-%m-%d' 2>/dev/null || date -r "$ST_SUCCESS" '+%Y-%m-%d' 2>/dev/null || printf '不明'); fi
}

# have <コマンド> : PATH にあるか。is_windows : Git Bash などの Windows か（uname が MINGW・MSYS・CYGWIN）
have() { command -v "$1" >/dev/null 2>&1; }
is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# missing_tools : 足りないもの（Git・Node.js〔Windows だけ〕・Bun の順）を「と」でつないで REPLY に、
#   それを入れる winget の 1 行（; でつなぐ。Windows 以外は空）を MISSING_WINGET に
missing_tools() {
  local names="" cmds="" win=0 n id
  is_windows && win=1
  for n in git node bun; do
    case "$n" in
      git) have git && continue; names="${names:+$names と }Git"; id=Git.Git ;;
      node) { [ "$win" = 1 ] && ! have node; } || continue; names="${names:+$names と }Node.js"; id=OpenJS.NodeJS.LTS ;;
      bun) have bun && continue; names="${names:+$names と }Bun"; id=Oven-sh.Bun ;;
    esac
    cmds="${cmds:+$cmds; }winget install --id $id -e --source winget"
  done
  REPLY="$names"
  MISSING_WINGET=""
  [ "$win" = 1 ] && MISSING_WINGET="$cmds"
}
WINGET_LEAD="PowerShell で次を実行し、アプリを完全に終了して開き直すよう利用者に伝える"

manual_steps() {
  pins_read
  REPLY="cd \"$GSTACK_DIR\" && rm -f .git/index.lock && { git stash -u || true; } && git fetch --depth 1 $PIN_REPO $PIN_SHA && git checkout --detach $PIN_SHA && ./setup -q --no-plan-tune-hooks"
}

# 利用者が自分で入れていた gstack を上書きした知らせ（一度だけ。出したら印を消す）
overwrote_note() {
  OVERWROTE_NOTE=""
  [ -f "$OVERWROTE_FILE" ] || return
  local sha=""
  { read -r sha _ <"$OVERWROTE_FILE"; } 2>/dev/null
  rm -f "$OVERWROTE_FILE" 2>/dev/null
  OVERWROTE_NOTE="利用者が入れていた gstack（版 ${sha:0:7}）を固定の版に置き換えた（取得は --depth 1 のため、作業コピーの履歴は浅い取得（shallow）になった。履歴が要れば git fetch --unshallow）。"
}

bg_status() {
  local d
  BG_ACTION=none; BG_STATUS=""
  if ! have git; then
    missing_tools
    if [ -n "$MISSING_WINGET" ]; then
      BG_STATUS="【注意】編集ガード無効（git なし）。メインのコード編集を止められず、gstack も導入できない（$REPLY が無い）。$WINGET_LEAD: $MISSING_WINGET"
    else
      BG_STATUS="【注意】編集ガード無効（git なし）。メインのコード編集を止められず、gstack も導入できない。Git を入れて起動し直すよう利用者に伝える。"
    fi
    return
  fi
  state_read
  current_head
  missing_tools
  if [ -n "$REPLY" ]; then
    if [ -n "$MISSING_WINGET" ]; then
      BG_STATUS="【注意】gstack: 未導入または更新できない（$REPLY が無い）。$WINGET_LEAD: $MISSING_WINGET"
    else
      BG_STATUS="【注意】gstack: 未導入または更新できない（$REPLY が無い）。README の手順で入れて起動し直すよう利用者に伝える。"
    fi
    return
  fi
  if lock_fresh; then
    BG_STATUS="gstack: 導入中（裏で作業中。終わると次のセッションから使える）。"
    return
  fi
  if [ "$ST_FAIL" -ge 3 ]; then
    due && BG_ACTION=run
    manual_steps
    BG_STATUS="【注意】gstack の更新に $ST_FAIL 回続けて失敗している（ログ: $GSTACK_LOG）。gstack を使う前に利用者に伝え、手で直す手順を示す: $REPLY"
    return
  fi
  overwrote_note
  last_date; d="$REPLY"
  if due; then
    BG_ACTION=run
    if [ -n "$CUR_HEAD" ]; then
      BG_STATUS="gstack: 導入済（最終更新 $d）。${OVERWROTE_NOTE}今日の更新を裏で確かめている。"
    else
      BG_STATUS="gstack: 導入中（裏で導入を始めた。終わると次のセッションから使える）。"
    fi
    return
  fi
  if [ -z "$CUR_HEAD" ]; then
    BG_STATUS="gstack: 未導入（前回の導入に失敗。1 時間たつと裏で再試行する。ログ: $GSTACK_LOG）。"
  elif [ "$ST_FAIL" -gt 0 ]; then
    BG_STATUS="gstack: 導入済（最終更新 $d）。${OVERWROTE_NOTE}前回の更新に失敗（1 時間たつと裏で再試行する。ログ: $GSTACK_LOG）。"
  else
    BG_STATUS="gstack: 導入済（最終更新 $d）。${OVERWROTE_NOTE}"
  fi
}

# ps -ef（2 列目 PID・3 列目 PPID）から子孫の PID を集める
descendants() {
  ps -ef 2>/dev/null | awk -v root="$1" '
    NR > 1 { kids[$3] = kids[$3] " " $2 }
    END {
      q = root; g = 0
      while (q != "" && g++ < 50) {
        split(q, a, " "); q = ""
        for (j in a) if (a[j] != "" && kids[a[j]] != "") { printf "%s", kids[a[j]]; q = q kids[a[j]] }
      }
    }'
}

# プロセスの木ごと止める（Windows は taskkill //T、ほかは setsid のプロセスグループ。どちらも ps で集めた子孫も止める）
kill_tree() {
  local pid="$1" w kids
  kids=$(descendants "$pid")
  if [ -r "/proc/$pid/winpid" ] && command -v taskkill >/dev/null 2>&1; then
    w=$(cat "/proc/$pid/winpid" 2>/dev/null)
    [ -n "$w" ] && taskkill //T //F //PID "$w" >/dev/null 2>&1
  elif [ "$BG_SETSID" = 1 ]; then
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 1
    kill -KILL -- "-$pid" 2>/dev/null
  fi
  # shellcheck disable=SC2086
  kill -KILL "$pid" $kids 2>/dev/null
}

# gstack の .git に残った古い *.lock（ロックの古さと同じ基準）を片付ける
# ロックを確かに持っているときだけ行う（持っていなければ別の実行中の git のロックを消しかねない）
clean_git_locks() {
  lock_held || { glog "ロックを持っていないため .git の古いロックは片付けない"; return 0; }
  [ -d "$GSTACK_DIR/.git" ] || return 0
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f" 2>/dev/null && glog "gstack の .git の古いロックを片付けた: $f"
  done <<EOF
$(find "$GSTACK_DIR/.git" -path "$GSTACK_DIR/.git/objects" -prune -o -type f -name '*.lock' -mmin +$(( (BG_TIMEOUT + LOCK_GRACE + 59) / 60 )) -print 2>/dev/null)
EOF
}

cmd_run() {
  current_head
  # MITSUISHI_GSTACK_TIMEOUT は正の整数のときだけ使う（それ以外は既定）
  if is_num "${MITSUISHI_GSTACK_TIMEOUT:-}" && [ "${#MITSUISHI_GSTACK_TIMEOUT}" -le 9 ] && [ "$((10#$MITSUISHI_GSTACK_TIMEOUT))" -gt 0 ]; then
    BG_TIMEOUT="$((10#$MITSUISHI_GSTACK_TIMEOUT))"
  elif [ -n "$CUR_HEAD" ]; then BG_TIMEOUT="$TIMEOUT_UPDATE"
  else BG_TIMEOUT="$TIMEOUT_INSTALL"; fi
  lock_take || exit 0
  trap 'lock_release' EXIT
  # 状態と今の HEAD はロックを取った後に読み直す（待っている間に別の実行が書き換えたかもしれない）
  state_read
  CUR_HEAD_DONE=0; current_head
  due || exit 0
  now_ts; ST_ATTEMPT="$EPOCH"; state_write
  pins_read
  local foreign=""
  if [ "$DUE_MODE" = full ] && [ -n "$CUR_HEAD" ] && [ "$CUR_HEAD" != "$PIN_SHA" ] && [ "$CUR_HEAD" != "$ST_HEAD" ]; then
    foreign="$CUR_HEAD"
  fi
  glog "開始（$DUE_MODE、固定 $PIN_SHA、場所 $GSTACK_DIR、打ち切り ${BG_TIMEOUT} 秒）"
  [ -n "$foreign" ] && glog "作業コピーの HEAD $foreign は固定と違う（利用者が入れた版）。固定の版で上書きする"
  [ "$DUE_MODE" = full ] && clean_git_locks

  BG_SETSID=0
  if command -v setsid >/dev/null 2>&1 && [ ! -r /proc/$$/winpid ]; then
    BG_SETSID=1
    setsid bash "$BG_SELF" work "$DUE_MODE" </dev/null >>"$GSTACK_LOG" 2>&1 &
  else
    bash "$BG_SELF" work "$DUE_MODE" </dev/null >>"$GSTACK_LOG" 2>&1 &
  fi
  local pid=$! el=0 rc=""
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$el" -ge "$BG_TIMEOUT" ]; then
      glog "打ち切り（${BG_TIMEOUT} 秒）"
      kill_tree "$pid"
      wait "$pid" 2>/dev/null
      rc=124
      break
    fi
    sleep 1
    el=$((el + 1))
  done
  [ -n "$rc" ] || { wait "$pid"; rc=$?; }

  if [ "$rc" -eq 0 ]; then
    CUR_HEAD_DONE=0; current_head
    now_ts; ST_SUCCESS="$EPOCH"; ST_HEAD="$CUR_HEAD"; ST_FAIL=0
    glog "完了（HEAD $ST_HEAD）"
    if [ -n "$foreign" ] && [ "$ST_HEAD" = "$PIN_SHA" ]; then
      printf '%s %s\n' "$foreign" "$EPOCH" >"$OVERWROTE_FILE" 2>/dev/null
    fi
  else
    ST_FAIL=$((ST_FAIL + 1))
    manual_steps
    glog "失敗（終了コード $rc、連続 $ST_FAIL 回）。手で直す: $REPLY"
  fi
  state_write
}

cmd_work() {
  local mode="${1:-full}" kv k v cur bak
  pins_read
  if [ "$mode" = full ]; then
    [ -n "$PIN_SHA" ] || { echo "pins.json の gstack.sha を読めない: $PINS_FILE"; exit 1; }
    if [ -e "$GSTACK_DIR" ] && ! { [ -e "$GSTACK_DIR/.git" ] && git -C "$GSTACK_DIR" rev-parse --git-dir >/dev/null 2>&1; }; then
      if [ "$GSTACK_DIR" = "$GSTACK_DEFAULT_DIR" ]; then
        bak="$GSTACK_DIR.bak-$(date '+%Y%m%d%H%M%S')"
        echo "$GSTACK_DIR の .git を読めないため $bak に退避する"
        mv "$GSTACK_DIR" "$bak" || { echo "退避に失敗"; exit 1; }
      else
        echo "$GSTACK_DIR は git の作業コピーではない。中を確かめて、要らなければ消すか別の場所に移してから起動し直す"
        exit 1
      fi
    fi
    if [ ! -e "$GSTACK_DIR" ]; then
      mkdir -p "$(dirname "$GSTACK_DIR")" && git init -q "$GSTACK_DIR" || { echo "git init に失敗"; exit 1; }
    fi
    git -C "$GSTACK_DIR" fetch -q --depth 1 "$PIN_REPO" "$PIN_SHA" || { echo "fetch に失敗"; exit 1; }
    git -C "$GSTACK_DIR" checkout -q --detach "$PIN_SHA" || { echo "checkout に失敗（手で変えたファイルがあれば git stash -u で退避してから直す）"; exit 1; }
    (cd "$GSTACK_DIR" && ./setup -q --no-plan-tune-hooks </dev/null) || { echo "setup に失敗"; exit 1; }
  fi

  local cfg="$GSTACK_DIR/bin/gstack-config"
  [ -f "$cfg" ] || { echo "$cfg が無い"; exit 1; }
  for kv in auto_upgrade=false codex_reviews=disabled telemetry=off; do
    k="${kv%%=*}"; v="${kv#*=}"
    cur=$(bash "$cfg" get "$k" </dev/null 2>/dev/null)
    cur="${cur%$'\r'}"
    [ "$cur" = "$v" ] && continue
    bash "$cfg" set "$k" "$v" </dev/null || { echo "設定 $k=$v を書けない"; exit 1; }
    echo "設定 $k=$v（前は '$cur'）"
  done
  exit 0
}

if [ "$BG_SELF" = "$0" ]; then
  case "$1" in
    status) bg_status; printf '%s\n%s\n' "$BG_ACTION" "$BG_STATUS" ;;
    run) cmd_run ;;
    work) cmd_work "$2" ;;
  esac
  exit 0
fi
