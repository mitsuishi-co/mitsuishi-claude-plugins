#!/usr/bin/env bash
# フックと CI のスクリプトの動作確認。
# 使い方: bash tests/run-hooks-test.sh   （jq 不要。Git Bash でも動く。ネットワークに出ない）
# gstack には触らない（一時 HOME・偽の git / setup / gstack-config で動かす）。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/plugins/mitsuishi-dev/hooks"
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/mitsuishi-dev"
OLD_VAR="MITSUISHI_ALLOW""_PLANNER_EDIT"   # 2.1 までの停止の変数（撤去済み。効かないことを確かめる）
unset MITSUISHI_HOOKS_OFF "$OLD_VAR" GSTACK_DIR MITSUISHI_GSTACK_TIMEOUT GIT_DIR GIT_WORK_TREE

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
ng()   { FAIL=$((FAIL + 1)); printf 'NG   %s\n' "$1"; [ -n "$2" ] && printf '     %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s（%s）\n' "$1" "$2"; }
t()    { if eval "$2"; then ok "$1"; else ng "$1" "$3"; fi; }

# JSON の文字列に埋め込む（\ と " を逃がす）
jstr() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
now() { date +%s; }

IS_WIN=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;; esac

TMP=$(mktemp -d 2>/dev/null || { d="${TMPDIR:-/tmp}/mhooks.$$"; mkdir -p "$d"; echo "$d"; })
trap 'rm -rf "$TMP" 2>/dev/null' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
HLOG="$HOME/.claude/mitsuishi-dev/hooks.log"

REAL_GIT=$(command -v git)
export REAL_GIT
REPO="$TMP/repo"; "$REAL_GIT" init -q "$REPO"
OUTSIDE="$TMP/outside"; mkdir -p "$OUTSIDE"
PIN=$(sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' "$CLAUDE_PLUGIN_ROOT/pins.json")

# check <名前> <フック> <期待 deny|allow> <入力 JSON> [環境変数=値 ...]  （出力は LAST_OUT）
check() {
  local name="$1" hook="$2" want="$3" input="$4"; shift 4
  local got
  LAST_OUT=$(printf '%s' "$input" | env "$@" bash "$HOOKS/$hook" 2>&1)
  if printf '%s' "$LAST_OUT" | grep -q '"permissionDecision":"deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then ok "$name"; else ng "$name（期待 $want、結果 $got）" "$LAST_OUT"; fi
}
reason() { printf '%s' "$LAST_OUT" | sed -n 's/.*"permissionDecisionReason":"\(.*\)"}}$/\1/p'; }
log_has() { grep -q "$1" "$HLOG" 2>/dev/null; }

SID='"session_id":"t","transcript_path":"/tmp/t.jsonl","hook_event_name":"PreToolUse"'
SUB='"agent_id":"a123","agent_type":"executor",'
TS=$(jstr "$REPO/src/a.ts")
W="{$SID,\"cwd\":\"$(jstr "$REPO")\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"export const a = 1;\\n\"}}"

echo "── guard-planner-edit ──"
check "git の中の .ts Write は拒否" guard-planner-edit deny "$W"
R=$(reason)
t "拒否文は 3 行（識別子・止めたもの・利用者に相談）" \
  '[ "$(printf "%s" "$R" | grep -o "\\\\n" | wc -l | tr -d " ")" = 2 ] && printf "%s" "$R" | grep -q "^\[MITSUISHI-EDIT-001\]" && printf "%s" "$R" | grep -q "止めたもの: Write で .*a.ts（変更 1 行、メインが直せる上限は 2 行・300 バイト）" && printf "%s" "$R" | grep -q "自分で止めずに利用者に相談する" && printf "%s" "$R" | grep -q "フックに止められたとき"' "$R"
t "拒否文に止め方（環境変数）を書かない" '! printf "%s" "$R" | grep -q "MITSUISHI_HOOKS_OFF"' "$R"
t "拒否は hooks.log に 1 行（時刻・フック・識別子・ツール・対象）" \
  'tail -n 1 "$HLOG" | awk -F"\t" "NF==5 && \$2==\"planner-edit\" && \$3==\"MITSUISHI-EDIT-001\" && \$4==\"Write\"" | grep -q a.ts'
check "git の中の .md Write は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO/docs/plan.md")\",\"content\":\"# 計画\\n\\n本文\\n\"}}"
for f in VERSION CHANGELOG TODOS CHANGELOG.md TODOS.md TODOS.txt version.txt README.markdown; do
  check "文書（$f）は許可" guard-planner-edit allow \
    "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO/$f")\",\"content\":\"a\\nb\\nc\\n\"}}"
done
for f in src/todos.ts src/changelog.js changelog-old.txt VERSION.json TODOS.ts versions.txt; do
  check "文書に見える名前のコード（$f）は拒否" guard-planner-edit deny \
    "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO/$f")\",\"content\":\"a\\nb\\nc\\n\"}}"
done
check "2 行 Edit は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\\nb\",\"new_string\":\"a\\nc\\n\",\"replace_all\":false}}"
check "3 行 Edit は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\\nb\",\"new_string\":\"a\\nb\\nc\",\"replace_all\":false}}"
t "3 行 Edit の拒否文に行数と上限" 'reason | grep -q "変更 3 行、メインが直せる上限は 2 行"'
check "replace_all の Edit は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":true}}"
check "サブエージェント内の Edit は許可" guard-planner-edit allow \
  "{$SID,$SUB\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\\nb\\nc\\nd\",\"new_string\":\"x\\ny\\nz\\nw\"}}"
check "本文に agent_id の文字があっても拒否（なりすまし）" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"{\\\"agent_id\\\": \\\"x\\\"}\"}}"
check "\\\" を含む 1 行 Edit は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"say(\\\"a\\\\n\\\")\",\"new_string\":\"say(\\\"b\\\\n\\\")\"}}"
# rep <文字列> <回数> : 繰り返してつなぐ（文字列に本物の改行を含めない）
rep() { [ "$2" -gt 0 ] && yes "$1" | head -n "$2" | tr -d '\n'; }
check "1 行 300 バイトの Edit は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"$(rep a 300)\",\"new_string\":\"$(rep b 300)\"}}"
check "1 行 301 バイトの Edit は拒否（2 行の例外は 300 バイトまで）" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\",\"new_string\":\"$(rep b 301)\"}}"
t "バイト数の拒否文に上限" 'reason | grep -q "300 バイト"' "$(reason)"
check "\\u を含む 1 行 Edit はデコードしたバイト数で判定（100 文字の あ = 300 バイトは許可）" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\",\"new_string\":\"$(rep 'あ' 100)\"}}"
check "\\u を含む 1 行 Edit（101 文字の あ = 303 バイト）は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"a\",\"new_string\":\"$(rep 'あ' 101)\"}}"
check "MultiEdit 合計 302 バイト（各 151）は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$TS\",\"edits\":[{\"old_string\":\"a\",\"new_string\":\"$(rep b 151)\"},{\"old_string\":\"c\",\"new_string\":\"$(rep d 151)\"}]}}"
check "MultiEdit 合計 2 行は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$TS\",\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\"},{\"old_string\":\"c\",\"new_string\":\"d\"}]}}"
check "MultiEdit 合計 3 行は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$TS\",\"edits\":[{\"old_string\":\"a\\nb\",\"new_string\":\"b\"},{\"old_string\":\"c\",\"new_string\":\"d\"}]}}"
check "MultiEdit の replace_all は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$TS\",\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":true}]}}"
check "NotebookEdit は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"$(jstr "$REPO/a.ipynb")\",\"new_source\":\"x\"}}"

# Claude の設定とエージェント定義（MITSUISHI-EDIT-002。git の内外・行数に関係なく止める）
E1() { printf '{%s,%s"cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$SID" "$2" "$(jstr "${3:-$OUTSIDE}")" "$(jstr "$1")"; }
check "git の中の .claude/settings.json の 1 行 Edit は拒否" guard-planner-edit deny "$(E1 "$REPO/.claude/settings.json")"
t "設定の拒否文は MITSUISHI-EDIT-002 で 3 行" 'reason | grep -q "^\[MITSUISHI-EDIT-002\]" && [ "$(reason | grep -o "\\\\n" | wc -l | tr -d " ")" = 2 ] && ! reason | grep -q MITSUISHI_HOOKS_OFF' "$(reason)"
t "設定の拒否は hooks.log に 1 行" 'tail -n 1 "$HLOG" | grep -q "planner-edit	MITSUISHI-EDIT-002	Edit"'
check "git の外の .claude/settings.local.json も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/settings.local.json")"
check "~/.claude/settings.json も拒否" guard-planner-edit deny "$(E1 "$HOME/.claude/settings.json")"
check "相対パス .claude/settings.json（cwd は git の外）も拒否" guard-planner-edit deny "$(E1 ".claude/settings.json")"
check "大文字の .Claude/Settings.JSON も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.Claude/Settings.JSON")"
check ".claude/agents/ の下の .md も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/agents/foo.md")"
mkdir -p "$OUTSIDE/myplugin/.claude-plugin"
check "プラグインの agents/ の下（.claude-plugin がある）も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/myplugin/agents/x.md")"
check "~/.claude/plugins/ の下のプラグインの agents/ も拒否" guard-planner-edit deny "$(E1 "$HOME/.claude/plugins/cache/m/p/1.0.0/agents/x.md")"
check "プラグインでない docs/agents/ の .md は許可" guard-planner-edit allow "$(E1 "$OUTSIDE/docs/agents/x.md")"
check ".claude/ の settings 以外の JSON（git の外）は許可" guard-planner-edit allow "$(E1 "$OUTSIDE/.claude/launch.json")"
check ".claude ではない claude/settings.json（git の外）は許可" guard-planner-edit allow "$(E1 "$OUTSIDE/claude/settings.json")"
check "サブエージェント内の .claude/settings.json の編集は許可" guard-planner-edit allow "$(E1 "$REPO/.claude/settings.json" "$SUB")"
if command -v cygpath >/dev/null 2>&1; then
  check "Windows 形式（\\ 区切り）の .claude\\settings.json も拒否" guard-planner-edit deny "$(E1 "$(cygpath -w "$OUTSIDE")\\.claude\\settings.json")"
fi
# 判定の前にパスを正規化する（// ・/./・..・末尾のドットと空白・: 以降の代替データストリーム・大文字小文字）
check ".claude/./agents/x.md も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/./agents/x.md")"
t "正規化して止めたものは MITSUISHI-EDIT-002" 'reason | grep -q "^\[MITSUISHI-EDIT-002\]"' "$(reason)"
check ".claude//agents/x.md も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude//agents/x.md")"
check ".claude/agentsX/../agents/x.md も拒否（.. をつぶす）" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/agentsX/../agents/x.md")"
check "大文字の .CLAUDE/AGENTS/x.md も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.CLAUDE/AGENTS/x.md")"
check "末尾にドットのある settings.json. も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/settings.json.")"
check "末尾に空白のある settings.json␣ も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/settings.json ")"
check "代替データストリームの settings.json::\$DATA も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/.claude/settings.json::\$DATA")"
check "git の .git/hooks/pre-commit も拒否（git の中）" guard-planner-edit deny "$(E1 "$REPO/.git/hooks/pre-commit")"
t ".git の下は MITSUISHI-EDIT-002" 'reason | grep -q "^\[MITSUISHI-EDIT-002\]"' "$(reason)"
check ".git/config も拒否（git の外の .git）" guard-planner-edit deny "$(E1 "$OUTSIDE/x/.git/config")"
check "~/.claude/plugins/ の下の hooks.json も拒否" guard-planner-edit deny "$(E1 "$HOME/.claude/plugins/cache/m/p/1.0.0/hooks/hooks.json")"
check "~/.claude/plugins/ の下の .md も拒否（文書の例外より先）" guard-planner-edit deny "$(E1 "$HOME/.claude/plugins/cache/m/p/1.0.0/skills/s/SKILL.md")"
check ".mcp.json も拒否" guard-planner-edit deny "$(E1 "$OUTSIDE/proj/.mcp.json")"
check "~/.claude.json も拒否" guard-planner-edit deny "$(E1 "$HOME/.claude.json")"
check "相対パス ../.claude.json（cwd から解決）も拒否" guard-planner-edit deny "$(E1 "../.claude.json" "" "$OUTSIDE/sub")"
check ".gitignore は許可（git の外）" guard-planner-edit allow "$(E1 "$OUTSIDE/.gitignore")"
check "mcp.json（先頭のドットなし）は許可（git の外）" guard-planner-edit allow "$(E1 "$OUTSIDE/mcp.json")"
PSELF="$TMP/plugin-self"; cp -R "$CLAUDE_PLUGIN_ROOT" "$PSELF"
check "このプラグイン自身のフォルダの下（hooks/lib/common.sh）も拒否" guard-planner-edit deny "$(E1 "$PSELF/hooks/lib/common.sh")" CLAUDE_PLUGIN_ROOT="$PSELF"
check "このプラグイン自身のフォルダの下の文書（MODELS.md）も拒否" guard-planner-edit deny "$(E1 "$PSELF/MODELS.md")" CLAUDE_PLUGIN_ROOT="$PSELF"
check "このプラグイン自身のフォルダを .. で指しても拒否" guard-planner-edit deny "$(E1 "$PSELF/x/../pins.json")" CLAUDE_PLUGIN_ROOT="$PSELF"
check "プラグインのフォルダの隣（名前の前方一致）は許可" guard-planner-edit allow "$(E1 "${PSELF}2/a.ts")" CLAUDE_PLUGIN_ROOT="$PSELF"
if command -v cygpath >/dev/null 2>&1; then
  check "このプラグイン自身のフォルダ（C:\\ 形式・大文字）も拒否" guard-planner-edit deny "$(E1 "$(cygpath -w "$PSELF" | tr 'a-z' 'A-Z')\\HOOKS\\guard-subagent")" CLAUDE_PLUGIN_ROOT="$PSELF"
fi
LONGP="$OUTSIDE/$(rep a 4200)/x.ts"
check "切り詰められたパス（4096 文字超）は止める（git の外でも）" guard-planner-edit deny "$(E1 "$LONGP")"
t "切り詰めたパスは MITSUISHI-EDIT-002" 'reason | grep -q "^\[MITSUISHI-EDIT-002\]"' "$(reason | head -c 300)"

# git の判定
check "git の外（CSV の Write）は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$OUTSIDE/data.csv")\",\"content\":\"a,b\\n1,2\\n3,4\\n\"}}"
check "git の外の存在しない深いパスは許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$OUTSIDE/a/b/c/d/e/f/g.ts")\",\"content\":\"x\\ny\\nz\"}}"
DEEP="$REPO"; for i in $(seq 1 20); do DEEP="$DEEP/d$i"; done
check "git の中の存在しない深いパス（20 段）は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$DEEP/a.ts")\",\"content\":\"x\"}}"
DEEP="$REPO"; for i in $(seq 1 70); do DEEP="$DEEP/d$i"; done
check "65 段より深い存在しないパスは上限で打ち切って許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$DEEP/a.ts")\",\"content\":\"x\"}}"
t "上限の打ち切りは hooks.log に失敗として 1 行" 'tail -n 1 "$HLOG" | grep -q "MITSUISHI-FAIL-GIT"'
check "相対パスは入力の cwd から判定（git の中は拒否）" guard-planner-edit deny \
  "{$SID,\"cwd\":\"$(jstr "$REPO")\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"src/a.ts\",\"content\":\"x\"}}"
check "相対パスで cwd が git の外なら許可" guard-planner-edit allow \
  "{$SID,\"cwd\":\"$(jstr "$OUTSIDE")\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"src/a.ts\",\"content\":\"x\"}}"
check "UNC 形式（存在しないサーバ）は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"\\\\\\\\nonexistent.invalid\\\\share\\\\a.ts\",\"content\":\"x\"}}"
if command -v cygpath >/dev/null 2>&1; then
  WREPO=$(cygpath -w "$REPO")
  check "Windows 形式（C:\\...）の git の中は拒否" guard-planner-edit deny \
    "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$WREPO\\src\\a.ts")\",\"content\":\"x\"}}"
  check "Windows 形式の git の外は許可" guard-planner-edit allow \
    "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$(cygpath -w "$OUTSIDE")\\a.ts")\",\"content\":\"x\"}}"
  check "Windows 形式・/ 区切り（C:/...）の git の中は拒否" guard-planner-edit deny \
    "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$(cygpath -m "$REPO")/src/a.ts")\",\"content\":\"x\"}}"
else
  skip "Windows 形式のパス" "cygpath が無い（Windows 以外）"
fi
mkdir -p "$REPO/日本語フォルダ"
check "日本語パスの .ts（git の中）は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO/日本語フォルダ/計算.ts")\",\"content\":\"x\"}}"
check "日本語パスの .md は許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO/日本語フォルダ/計画.md")\",\"content\":\"x\\ny\\nz\"}}"
check "\\u を含むパス（git の中）は拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO")/src/\\u30c6\\u30b9\\u30c8.ts\",\"content\":\"\\u0041\\nB\\nC\"}}"
check "\\u を含む 2 行 Edit は許可（行数を誤らない）" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TS\",\"old_string\":\"\\u3042\\n\\u3044\",\"new_string\":\"\\u3046\\\\n\\u3048\\n\"}}"
check "制御文字を含むパスも拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$REPO")/src/a\\nb\\u0001c.ts\",\"content\":\"x\"}}"
t "拒否文のパスから改行・制御文字を落とす" '! reason | grep -q "a\\\\nb" && [ "$(reason | grep -o "\\\\n" | wc -l | tr -d " ")" = 2 ]' "$(reason)"
BIG=$(head -c 1000000 /dev/zero | tr '\0' 'a')
S0=$(now)
check "1MB の Write も読めて拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"$BIG\"}}"
t "1MB の入力を 10 秒以内に判定" '[ $(( $(now) - S0 )) -le 10 ]' "$(( $(now) - S0 )) 秒"
unset BIG
# 入力全体を一括で読む（gawk は RS = "^$"。ほかの awk は 1 行ずつ）。改行の多い入力（整形した JSON・CRLF）も同じに読む
t "json-flatten.awk は gawk で入力を一括で読む（RS = \"^\$\"）" 'grep -q "if (\"version\" in PROCINFO) { RS = \"^\\$\"" "$HOOKS/lib/json-flatten.awk"'
PRETTY=$(printf '{\r\n  "tool_name": "Write",\r\n  "tool_input": {\r\n    "file_path": "%s",\r\n    "content": "a\\nb\\nc"\r\n  }\r\n}\r\n' "$TS")
check "整形した JSON（CRLF・複数行）も読めて拒否（3 行）" guard-planner-edit deny "$PRETTY"
t "整形した JSON の行数を正しく数える" 'reason | grep -q "変更 3 行"' "$(reason)"
if awk --version 2>/dev/null | grep -q "GNU Awk"; then
  A1=$(printf '%s' "$PRETTY" | LC_ALL=C awk -f "$HOOKS/lib/json-flatten.awk")
  A2=$(printf '%s' "$PRETTY" | LC_ALL=C awk --posix -f "$HOOKS/lib/json-flatten.awk" 2>/dev/null)
  t "gawk の一括読みと POSIX の 1 行ずつで同じ結果" '[ -n "$A1" ] && [ "$A1" = "$A2" ]' "$A1 / $A2"
fi
# 大きな文字列の速い経路（\\ と \" と \n が混ざっても行数を誤らない）
BIG=$(rep 'ab\\\\c\"d\n' 120000)
S0=$(now)
check "1MB・12 万行の Write も読めて拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"$BIG\"}}"
t "12 万行の行数を正しく数え、10 秒以内" 'reason | grep -q "変更 120000 行" && [ $(( $(now) - S0 )) -le 10 ]' "$(reason | head -c 300) $(( $(now) - S0 )) 秒"
BIG=$(rep 'x\\\\' 70000)
check "末尾が \\\\ の大きな文字列も閉じ引用符を見つける（1 行）" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"$BIG\",\"x\":\"y\"}}"
t "末尾が \\\\ の大きな文字列は 1 行" 'reason | grep -q "変更 1 行"' "$(reason | head -c 300)"
unset BIG
# パスは切り詰めない（512 文字目で .md に見える位置があっても全体で判定）
P512="$REPO/"; P512="$P512$(rep a $(( 509 - ${#P512} ))).md"
check "512 文字で切ると .md に見えるパスも、全体（.ts）で判定して拒否" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$P512/x.ts")\",\"content\":\"x\"}}"
PLONG="$REPO/"; PLONG="$PLONG$(rep a $(( 4093 - ${#PLONG} ))).md"
check "切り詰めたパス（4096 文字超）は文書の例外に入れない" guard-planner-edit deny \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$(jstr "$PLONG/$(rep b 200).ts")\",\"content\":\"x\"}}"
check "文字列の中の生の改行（不正な JSON）は読めないとして許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"a
b\"}}"
t "生の改行は hooks.log に FAIL-JSON" 'tail -n 1 "$HLOG" | grep -q "MITSUISHI-FAIL-JSON"'
check "文字列の中の生のタブ（不正な JSON）は読めないとして許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"a$(printf '\t')b\"}}"
check "生の制御文字（0x01）は読めないとして許可" guard-planner-edit allow \
  "{$SID,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TS\",\"content\":\"a$(printf '\001')b\"}}"
if command -v cygpath >/dev/null 2>&1; then
  OUT=$(printf '%s' "$W" | bash "$(cygpath -w "$HOOKS/guard-planner-edit")" 2>&1)
  t "Windows 形式のパス（C:\\...）で起動しても lib を読んで拒否" 'printf "%s" "$OUT" | grep -q MITSUISHI-EDIT-001' "$OUT"
fi
check "壊れた JSON は許可" guard-planner-edit allow '{"tool_name": "Wri'
t "壊れた JSON は hooks.log に失敗として 1 行" 'tail -n 1 "$HLOG" | grep -q "MITSUISHI-FAIL-JSON"'

# git の判定の失敗
FAKEDUB="$TMP/fake-dubious"; mkdir -p "$FAKEDUB"
cat >"$FAKEDUB/git" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/calls"
echo "fatal: detected dubious ownership in repository at '/x'" >&2
exit 128
EOF
chmod +x "$FAKEDUB/git"
check "rev-parse が失敗（dubious ownership 相当）なら許可" guard-planner-edit allow "$W" PATH="$FAKEDUB:$PATH"
t "その失敗は hooks.log に 1 行（ガードが黙って無効にならない）" 'tail -n 1 "$HLOG" | grep -q "MITSUISHI-FAIL-GIT.*dubious ownership"'
t "git に safe.directory='*' を渡す" 'grep -q "^-c safe.directory=\* -C .* rev-parse --is-inside-work-tree" "$FAKEDUB/calls"' "$(cat "$FAKEDUB/calls" 2>/dev/null)"

# git が無い PATH
NOGIT="$TMP/nogit-bin"; mkdir -p "$NOGIT"
if [ "$IS_WIN" = 1 ]; then
  NOGIT_PATH="/usr/bin"
else
  for f in /usr/local/bin/* /usr/bin/* /bin/*; do
    n="${f##*/}"; [ "$n" = git ] && continue
    [ -e "$NOGIT/$n" ] || ln -s "$f" "$NOGIT/$n" 2>/dev/null
  done
  NOGIT_PATH="$NOGIT"
fi
if PATH="$NOGIT_PATH" command -v git >/dev/null 2>&1; then
  skip "git が無いとき" "git を外した PATH を作れない"
else
  check "git が無いときは許可" guard-planner-edit allow "$W" PATH="$NOGIT_PATH"
  t "git が無いことは hooks.log に 1 行" 'tail -n 1 "$HLOG" | grep -q "MITSUISHI-FAIL-GIT.*git が無い"'
fi

# lib を読めない
mkdir -p "$TMP/nolib/hooks"; cp "$HOOKS/guard-planner-edit" "$HOOKS/guard-subagent" "$TMP/nolib/hooks/"
OUT=$(printf '%s' "$W" | bash "$TMP/nolib/hooks/guard-planner-edit" 2>&1)
t "lib を読めないときは許可" '! printf "%s" "$OUT" | grep -q deny'
t "lib を読めないことは hooks.log に 1 行" 'tail -n 1 "$HLOG" | grep -q "planner-edit	MITSUISHI-FAIL-LIB"'

# 停止
check "MITSUISHI_HOOKS_OFF=1 で全部止まる" guard-planner-edit allow "$W" MITSUISHI_HOOKS_OFF=1
check "MITSUISHI_HOOKS_OFF=all で全部止まる" guard-planner-edit allow "$W" MITSUISHI_HOOKS_OFF=all
check "MITSUISHI_HOOKS_OFF=planner-edit でこのフックが止まる" guard-planner-edit allow "$W" MITSUISHI_HOOKS_OFF=planner-edit
check "MITSUISHI_HOOKS_OFF=' Subagent , Planner-Edit '（空白・大文字）を正規化" guard-planner-edit allow "$W" "MITSUISHI_HOOKS_OFF= Subagent , Planner-Edit "
check "MITSUISHI_HOOKS_OFF=subagent では編集ガードは動く" guard-planner-edit deny "$W" MITSUISHI_HOOKS_OFF=subagent
check "MITSUISHI_HOOKS_OFF=session-start,subagent では編集ガードは動く" guard-planner-edit deny "$W" MITSUISHI_HOOKS_OFF=session-start,subagent
check "MITSUISHI_HOOKS_OFF の未知の値は全部止める" guard-planner-edit allow "$W" MITSUISHI_HOOKS_OFF=yes
check "MITSUISHI_HOOKS_OFF の値に * があっても展開しない（未知として全部止める）" guard-planner-edit allow "$W" "MITSUISHI_HOOKS_OFF=*"
check "MITSUISHI_HOOKS_OFF が空なら動く" guard-planner-edit deny "$W" MITSUISHI_HOOKS_OFF=
for v in 0 false no off none ' OFF ' False; do
  check "MITSUISHI_HOOKS_OFF='$v' は「止めない」" guard-planner-edit deny "$W" "MITSUISHI_HOOKS_OFF=$v"
done
check "MITSUISHI_HOOKS_OFF=none,planner-edit はこのフックを止める" guard-planner-edit allow "$W" MITSUISHI_HOOKS_OFF=none,planner-edit
check "2.1 までの停止の変数（…_ALLOW_PLANNER_EDIT=1）ではもう止まらない" guard-planner-edit deny "$W" "$OLD_VAR=1"

echo "── guard-subagent ──"
A() { printf '{%s,%s"tool_name":"%s","tool_input":{"description":"d","prompt":"p","subagent_type":"%s"%s}}' "$SID" "$1" "$2" "$3" "${4:+,\"model\":\"$4\"}"; }
check "サブエージェント内の Agent は拒否" guard-subagent deny "$(A "$SUB" Agent executor)"
t "再委託の拒否文に識別子・呼んだ側・subagent_type・model" \
  'reason | grep -q "^\[MITSUISHI-AGENT-001\]" && reason | grep -q "呼んだ側 executor → subagent_type executor（model 指定なし）" && [ "$(reason | grep -o "\\\\n" | wc -l | tr -d " ")" = 2 ]' "$(reason)"
check "メインから executor に model=fable は拒否" guard-subagent deny "$(A "" Agent executor fable)"
t "最上位の拒否文に識別子・subagent_type・model・当たった別名" \
  'reason | grep -q "^\[MITSUISHI-AGENT-002\]" && reason | grep -q "subagent_type executor に model fable（MODELS.md の 別名 fable に当たる）" && reason | grep -q "自分で止めずに利用者に相談する" && ! reason | grep -q "MITSUISHI_HOOKS_OFF"' "$(reason)"
t "拒否は hooks.log に 1 行" 'tail -n 1 "$HLOG" | grep -q "subagent	MITSUISHI-AGENT-002	Agent	executor model=fable"'
check "ui-executor に model=fable は拒否" guard-subagent deny "$(A "" Agent ui-executor fable)"
check "mitsuishi-dev:executor に model=best は拒否" guard-subagent deny "$(A "" Agent mitsuishi-dev:executor best)"
check "executor に model=BEST（大文字）は拒否" guard-subagent deny "$(A "" Agent executor BEST)"
check "executor に正式名 claude-fable-5 は拒否（前方一致）" guard-subagent deny "$(A "" Agent executor claude-fable-5)"
t "前方一致の拒否文に当たった前方一致" 'reason | grep -q "前方一致 claude-fable-"' "$(reason)"
check "executor に正式名 Claude-Fable-5-20261101（大文字）は拒否" guard-subagent deny "$(A "" Task executor Claude-Fable-5-20261101)"
check "advisor に model=fable は許可" guard-subagent allow "$(A "" Agent advisor fable)"
check "mitsuishi-dev:advisor（Task）に model=fable は許可" guard-subagent allow "$(A "" Task mitsuishi-dev:advisor fable)"
check "advisor に正式名 claude-fable-5 は許可" guard-subagent allow "$(A "" Agent advisor claude-fable-5)"
check "executor に model=sonnet は許可" guard-subagent allow "$(A "" Agent executor sonnet)"
check "executor に claude-opus-5-5 は許可" guard-subagent allow "$(A "" Agent executor claude-opus-5-5)"
check "model を省いた起動は許可" guard-subagent allow "$(A "" Agent executor)"
check "プロンプトに model=fable の文字があっても許可" guard-subagent allow \
  "{$SID,\"tool_name\":\"Agent\",\"tool_input\":{\"description\":\"d\",\"prompt\":\"\\\"model\\\":\\\"fable\\\"\",\"subagent_type\":\"executor\"}}"
check "MITSUISHI_HOOKS_OFF=subagent で止まる（再委託も通す）" guard-subagent allow "$(A "$SUB" Agent executor)" MITSUISHI_HOOKS_OFF=subagent
check "MITSUISHI_HOOKS_OFF=planner-edit では動く" guard-subagent deny "$(A "" Agent executor fable)" MITSUISHI_HOOKS_OFF=planner-edit
check "MITSUISHI_HOOKS_OFF の未知の値で止まる" guard-subagent allow "$(A "" Agent executor fable)" MITSUISHI_HOOKS_OFF=bogus
check "MITSUISHI_HOOKS_OFF=off では動く" guard-subagent deny "$(A "" Agent executor fable)" MITSUISHI_HOOKS_OFF=off
check "名前空間が違う other:advisor に model=fable は拒否（advisor として通すのは 2 つだけ）" guard-subagent deny "$(A "" Agent other:advisor fable)"
check "my-advisor に model=fable は拒否" guard-subagent deny "$(A "" Agent my-advisor fable)"
# model を省いたときは定義の frontmatter の model を照合する
AC() { printf '{%s,"cwd":"%s","tool_name":"Agent","tool_input":{"description":"d","prompt":"p","subagent_type":"%s"}}' "$SID" "$(jstr "$1")" "$2"; }
PROJ="$OUTSIDE/proj"; mkdir -p "$PROJ/.claude/agents" "$HOME/.claude/agents"
printf -- '---\nname: custom\nmodel: fable\n---\n本文 model: opus\n' >"$PROJ/.claude/agents/custom.md"
printf -- '---\r\nname: quoted\r\nmodel: "Best"\r\n---\r\n' >"$PROJ/.claude/agents/quoted.md"
printf -- '---\nname: plain\nmodel: sonnet\n---\n' >"$PROJ/.claude/agents/plain.md"
printf -- '---\nname: nomodel\n---\nmodel: fable\n' >"$PROJ/.claude/agents/nomodel.md"
printf -- '---\nname: userdef\nmodel: claude-fable-5\n---\n' >"$HOME/.claude/agents/userdef.md"
printf -- '---\nname: evil\nmodel: fable\n---\n' >"$PROJ/evil.md"
check "model 省略・プロジェクトの定義が fable は拒否" guard-subagent deny "$(AC "$PROJ" custom)"
t "定義から当てた拒否文に「定義」と model" 'reason | grep -q "^\[MITSUISHI-AGENT-002\]" && reason | grep -q "定義" && reason | grep -q "fable"' "$(reason)"
check "model 省略・名前空間つき（proj:custom）はそのプラグインの定義だけを探す（無いので許可）" guard-subagent allow "$(AC "$PROJ" proj:custom)"
# 定義は frontmatter の name: で探す（ファイル名・サブフォルダ・~/.claude/plugins/ の下の各プラグイン）
printf -- '---\nname: shadow\nmodel: fable\n---\n' >"$PROJ/.claude/agents/renamed-file.md"
check "model 省略・ファイル名と name が違う定義も name で見つけて拒否" guard-subagent deny "$(AC "$PROJ" shadow)"
printf -- '---\nname: other-name\nmodel: fable\n---\n' >"$PROJ/.claude/agents/decoy.md"
check "model 省略・ファイル名だけ一致して name が違う定義は使わない（許可）" guard-subagent allow "$(AC "$PROJ" decoy)"
mkdir -p "$HOME/.claude/agents/team/deep" "$PROJ/.claude/agents/sub"
printf -- '---\nname: deepuser\nmodel: best\n---\n' >"$HOME/.claude/agents/team/deep/deepuser.md"
check "model 省略・~/.claude/agents のサブフォルダの定義も拒否" guard-subagent deny "$(AC "$PROJ" deepuser)"
printf -- '---\nname: subproj\nmodel: claude-fable-5\n---\n' >"$PROJ/.claude/agents/sub/subproj.md"
check "model 省略・プロジェクトの .claude/agents のサブフォルダの定義も拒否" guard-subagent deny "$(AC "$PROJ" subproj)"
printf -- '---\nname: commented # 名前\nmodel: fable  # c\n---\n' >"$PROJ/.claude/agents/commented.md"
check "model 省略・定義の model: fable  # c（YAML のコメント）も拒否" guard-subagent deny "$(AC "$PROJ" commented)"
printf -- "---\nname: 'sq'\nmodel: 'fable' # x\n---\n" >"$PROJ/.claude/agents/sq.md"
check "model 省略・name と model が単引用符でコメントつきでも拒否" guard-subagent deny "$(AC "$PROJ" sq)"
OP="$HOME/.claude/plugins/cache/mk/otherplug/1.2.0"; mkdir -p "$OP/.claude-plugin" "$OP/agents/x"
printf '{ "name": "otherplug", "version": "1.2.0" }\n' >"$OP/.claude-plugin/plugin.json"
printf -- '---\nname: strong\nmodel: fable\n---\n' >"$OP/agents/x/strong-agent.md"
check "model 省略・名前空間つき otherplug:strong は ~/.claude/plugins/ の下のそのプラグインの定義で拒否" guard-subagent deny "$(AC "$PROJ" otherplug:strong)"
check "model 省略・名前空間が違う wrongns:strong は別のプラグインの定義を使わない（許可）" guard-subagent allow "$(AC "$PROJ" wrongns:strong)"
check "model 省略・名前空間なしの strong は ~/.claude/plugins/ の下の定義も探して拒否" guard-subagent deny "$(AC "$PROJ" strong)"
check "model 省略・定義の model が引用符・大文字・CRLF でも拒否" guard-subagent deny "$(AC "$PROJ" quoted)"
check "model 省略・~/.claude/agents の定義が正式名でも拒否" guard-subagent deny "$(AC "$PROJ" userdef)"
check "model 省略・定義の model が sonnet は許可" guard-subagent allow "$(AC "$PROJ" plain)"
check "model 省略・frontmatter に model が無い（本文にだけある）は許可" guard-subagent allow "$(AC "$PROJ" nomodel)"
check "model 省略・定義が無い名前は許可" guard-subagent allow "$(AC "$PROJ" nothing-here)"
check "model 省略・subagent_type に ../ があっても定義を探さない（許可）" guard-subagent allow "$(AC "$PROJ" ../../evil)"
check "model 省略・advisor（定義は fable）は許可" guard-subagent allow "$(AC "$PROJ" advisor)"
check "model 省略・mitsuishi-dev:executor（プラグインの定義は opus）は許可" guard-subagent allow "$(AC "$PROJ" mitsuishi-dev:executor)"
PCP="$TMP/plugin-agents"; cp -R "$CLAUDE_PLUGIN_ROOT" "$PCP"
printf -- '---\nname: topper\nmodel: best\n---\n' >"$PCP/agents/topper.md"
OUT=$(AC "$PROJ" mitsuishi-dev:topper | env CLAUDE_PLUGIN_ROOT="$PCP" bash "$PCP/hooks/guard-subagent" 2>&1)
t "model 省略・このプラグインの agents/ の定義が best は拒否" 'printf "%s" "$OUT" | grep -q "MITSUISHI-AGENT-002"' "$OUT"
# UTF-8 の BOM 付きの定義（Windows のメモ帳などで保存したもの）も読む
printf '\357\273\277---\r\nname: bomdef\r\nmodel: fable\r\n---\r\n' >"$PROJ/.claude/agents/bomdef.md"
check "model 省略・BOM 付きの定義が fable は拒否" guard-subagent deny "$(AC "$PROJ" bomdef)"
# cwd がサブフォルダでも、git のルートまで上ってプロジェクトの .claude/agents を探す
GPROJ="$TMP/gproj"; "$REAL_GIT" init -q "$GPROJ"; mkdir -p "$GPROJ/.claude/agents" "$GPROJ/src/deep"
printf -- '---\nname: rootdef\nmodel: fable\n---\n' >"$GPROJ/.claude/agents/rootdef.md"
check "model 省略・cwd が git のサブフォルダでもルートの定義で拒否" guard-subagent deny "$(AC "$GPROJ/src/deep" rootdef)"
mkdir -p "$OUTSIDE/nogit/.claude/agents" "$OUTSIDE/nogit/sub"
printf -- '---\nname: nogitdef\nmodel: fable\n---\n' >"$OUTSIDE/nogit/.claude/agents/nogitdef.md"
check "model 省略・git の外では cwd より上を探さない（許可）" guard-subagent allow "$(AC "$OUTSIDE/nogit/sub" nogitdef)"
check "壊れた JSON は許可" guard-subagent allow '{"tool_name":'
OUT=$(A "" Agent executor fable | bash "$TMP/nolib/hooks/guard-subagent" 2>&1)
t "lib を読めないときは許可し hooks.log に 1 行" '! printf "%s" "$OUT" | grep -q deny && tail -n 1 "$HLOG" | grep -q "subagent	MITSUISHI-FAIL-LIB"'

echo "── hooks.log の切り詰め ──"
mkdir -p "$(dirname "$HLOG")"; : >"$HLOG"
for i in $(seq 1 1500); do printf 'old %s\n' "$i"; done >>"$HLOG"
check "（切り詰めの前の拒否）" guard-subagent deny "$(A "" Agent executor fable)"
t "1500 行を超えたら最後の 1000 行に切り詰める" '[ "$(wc -l <"$HLOG" | tr -d " ")" = 1000 ] && tail -n 1 "$HLOG" | grep -q MITSUISHI-AGENT-002 && head -n 1 "$HLOG" | grep -qx "old 502"' "$(wc -l <"$HLOG")"

echo "── session-start（偽の gstack） ──"
# 偽の gstack の中身（checkout でこの中身が作業コピーに入る）
FAKE_SRC="$TMP/fake-src"; mkdir -p "$FAKE_SRC/bin"
cat >"$FAKE_SRC/setup" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/setup.calls"
echo "SETUP-OUTPUT-BODY"
if [ -n "$FAKE_SETUP_GRANDCHILD" ]; then sleep 6171 & echo $! >"$FAKE_LOG/grandchild.pid"; fi
[ -n "$FAKE_SETUP_SLEEP" ] && sleep "$FAKE_SETUP_SLEEP"
[ -n "$FAKE_SETUP_FAIL" ] && exit 1
exit 0
EOF
cat >"$FAKE_SRC/bin/gstack-config" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG/config.calls"
case "$1" in
  get) v=$(grep "^$2=" "$FAKE_LOG/cfg" 2>/dev/null | tail -1); echo "${v#*=}" ;;
  set) echo "$2=$3" >>"$FAKE_LOG/cfg" ;;
esac
EOF
chmod +x "$FAKE_SRC/setup" "$FAKE_SRC/bin/gstack-config"
# 偽の git（gstack の操作だけ真似る。git の判定 -c safe.directory=... は本物へ）と偽の bun
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-c" ] && exec "$REAL_GIT" "$@"
echo "$*" >>"$FAKE_LOG/git.calls"
D=""; [ "$1" = "-C" ] && { D="$2"; shift 2; }
case "$1" in
  init) shift; [ "$1" = -q ] && shift; mkdir -p "$1/.git"; exit 0 ;;
  fetch) [ -n "$FAKE_GIT_FAIL" ] && { echo "fatal: 偽の fetch 失敗" >&2; exit 1; }; exit 0 ;;
  checkout) sha="${*: -1}"; cp -R "$FAKE_SRC/." "$D/" && echo "$sha" >"$D/.git/HEADSHA"; exit $? ;;
  rev-parse)
    case "$2" in
      HEAD) cat "$D/.git/HEADSHA" 2>/dev/null || exit 128 ;;
      --git-dir) [ -d "$D/.git" ] && echo .git || exit 128 ;;
      *) exit 128 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/bun"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/node"
# 偽の mv（FAKE_MV_FAIL があれば状態ファイルの置き換えだけ失敗させる）
REAL_MV=$(command -v mv); export REAL_MV
cat >"$FAKEBIN/mv" <<'EOF'
#!/usr/bin/env bash
case "$*" in *state.tmp.*) [ -n "$FAKE_MV_FAIL" ] && { echo "$*" >>"$FAKE_LOG/mv.calls"; echo "mv: 偽の失敗" >&2; exit 1; } ;; esac
exec "$REAL_MV" "$@"
EOF
# 偽の setsid（呼ばれたことを記録して、そのまま実行する）は別のフォルダに置き、使うテストだけ PATH に足す
FAKESID="$TMP/fakesid"; mkdir -p "$FAKESID"
printf '#!/usr/bin/env bash\necho "$*" >>"$FAKE_LOG/setsid.calls"\nexec "$@"\n' >"$FAKESID/setsid"
chmod +x "$FAKEBIN/git" "$FAKEBIN/bun" "$FAKEBIN/node" "$FAKEBIN/mv" "$FAKESID/setsid"
export FAKE_SRC

N=0
# fresh: 新しい一時 HOME と偽の gstack の置き場（既定は GSTACK_DIR=$HOME/gs）
fresh() {
  N=$((N + 1))
  SH="$TMP/s$N"; mkdir -p "$SH"
  export FAKE_LOG="$SH/fake"; mkdir -p "$FAKE_LOG"
  printf 'telemetry=off\n' >"$FAKE_LOG/cfg"
  GD="$SH/gs"; SD="$SH/.claude/mitsuishi-dev"
}
# ss [環境変数=値 ...] : session-start を走らせて SS_OUT に。cwd は SS_CWD（既定は git の中）
ss() {
  SS_OUT=$(printf '{"session_id":"t","hook_event_name":"SessionStart","cwd":"%s"}' "$(jstr "${SS_CWD:-$REPO}")" \
    | env HOME="$SH" PATH="$FAKEBIN:$PATH" GSTACK_DIR="$GD" "$@" bash "$HOOKS/session-start" 2>&1)
}
bgrun() { env HOME="$SH" PATH="$FAKEBIN:$PATH" GSTACK_DIR="$GD" "$@" bash "$HOOKS/lib/gstack-bg.sh" run; }
# wait_for <条件> : 最大 30 秒（CI や負荷の高い PC でも揺れないように）、0.2 秒ごとに見る
wait_for() { local i=0; while [ $i -lt 150 ]; do eval "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
bg_done() { [ -f "$SD/state" ] && [ ! -d "$SD/gstack.lock" ] && grep -q "^last_attempt=[1-9]" "$SD/state"; }
st() { sed -n "s/^$1=//p" "$SD/state" 2>/dev/null; }
calls() { cat "$FAKE_LOG/$1.calls" 2>/dev/null; }
ctx_has() { printf '%s' "$SS_OUT" | grep -q -- "$1"; }
# sysmsg: SS_OUT を JSON.parse して最上位の systemMessage を出す（無ければ空。JSON が壊れていれば PARSE-ERROR）
sysmsg() {
  printf '%s' "$SS_OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(j.systemMessage||"")}catch(e){process.stdout.write("PARSE-ERROR")}})'
}
HAS_NODE=0; command -v node >/dev/null 2>&1 && HAS_NODE=1

# 初回
fresh
S0=$(now)
ss FAKE_SETUP_SLEEP=8
EL=$(( $(now) - S0 ))
t "初回: setup が 8 秒かかっても session-start は待たない（6 秒未満）" '[ "$EL" -lt 6 ]' "$EL 秒"
t "初回: JSON の形（SessionStart と additionalContext）" \
  'ctx_has "\"hookEventName\": \"SessionStart\"" && ctx_has "\"additionalContext\": \"<mitsuishi-dev>"'
t "初回: 生の改行が文字列の中に無い（1 行の JSON 文字列）" \
  '[ "$(printf "%s\n" "$SS_OUT" | grep -c additionalContext)" = 1 ] && printf "%s" "$SS_OUT" | grep additionalContext | grep -q "</mitsuishi-dev>\"$"'
t "初回: 案内 3 行（役目・止められたら利用者に相談・README の URL）" \
  'ctx_has "このプラグイン（mitsuishi-dev）は" && ctx_has "自分で止めずに利用者に相談する" && ctx_has "説明: https://github.com/"'
t "初回: 注入文に止め方（環境変数）を書かない" '! ctx_has "MITSUISHI_HOOKS_OFF"' "$SS_OUT"
t "初回: ルール・MODELS.md を注入" 'ctx_has "社内標準 開発ワークフロー" && ctx_has "TOP_ALIASES" && ctx_has "TOP_PREFIXES"'
t "初回: 状態は「導入中」" 'ctx_has "gstack: 導入中"' "$SS_OUT"
t "初回（導入中）: 利用者向けの 1 行（systemMessage）は出さない" '! ctx_has "systemMessage"' "$SS_OUT"
if command -v node >/dev/null 2>&1; then
  t "初回: node で JSON.parse できる" \
    'printf "%s" "$SS_OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const j=JSON.parse(s);process.exit(j.hookSpecificOutput.additionalContext.includes(\"TOP_ALIASES\")?0:1)})"'
else
  skip "node で JSON.parse" "node が無い"
fi
t "初回: 裏の導入が 15 秒以内に終わり状態ファイルに書かれる" 'wait_for bg_done && [ "$(st last_success)" -gt 0 ] && [ "$(st fail_count)" = 0 ]' "$(cat "$SD/state" 2>/dev/null)"
t "初回: pins.json の sha を fetch して checkout" \
  'calls git | grep -q "fetch -q --depth 1 https://github.com/garrytan/gstack.git $PIN" && calls git | grep -q "checkout -q --detach $PIN" && [ "$(st head)" = "$PIN" ]' "$(calls git)"
t "初回: setup -q --no-plan-tune-hooks を 1 回" '[ "$(calls setup)" = "-q --no-plan-tune-hooks" ]' "$(calls setup)"
t "初回: 設定は違う 2 つだけ set（auto_upgrade=false・codex_reviews=disabled）、同じ telemetry は書かない" \
  'calls config | grep -qx "set auto_upgrade false" && calls config | grep -qx "set codex_reviews disabled" && ! calls config | grep -q "^set telemetry"' "$(calls config)"
t "初回: gstack の出力本文はログだけ（注入文に出さない）" 'grep -q SETUP-OUTPUT-BODY "$SD/gstack.log" && ! ctx_has SETUP-OUTPUT-BODY'
t "gstack-upgrade を呼ばない（コードに無い）" '! grep -v "^[[:space:]]*#" "$HOOKS/session-start" "$HOOKS/lib/gstack-bg.sh" | grep -q "gstack-upgrade"'

# 2 回目（印が新しい）
: >"$FAKE_LOG/git.calls"; : >"$FAKE_LOG/setup.calls"
ss
t "2 回目: 状態は「導入済」と最終更新日" 'ctx_has "gstack: 導入済（最終更新 [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]）。"' "$SS_OUT"
sleep 1
t "2 回目: 印が新しいときは更新しない（fetch・setup を呼ばない）" '! calls git | grep -q fetch && [ -z "$(calls setup)" ]' "$(calls git)"

# 印が未来
printf 'last_success=%s\nhead=%s\nfail_count=0\nlast_attempt=%s\n' $(( $(now) + 999999 )) "$PIN" $(( $(now) + 999999 )) >"$SD/state"
: >"$FAKE_LOG/git.calls"
ss
# 待ち条件: bg_done を見た後に st を読むまでの間に、裏の処理がロックを取って途中の状態（last_success=0）を書くことがある。
# 完了の印は last_success が 0 より大きく今以下で、読んだ後もロックが無いこと
t "印が未来: 古いとみなして裏で更新する" 'wait_for "bg_done && _s=\$(st last_success) && [ \"\$_s\" -gt 0 ] && [ \"\$_s\" -le \"\$(now)\" ] && [ ! -d \"\$SD/gstack.lock\" ]" && calls git | grep -q fetch' "$(cat "$SD/state")"

# 状態ファイルが壊れている
printf 'garbage\n\001\002last_success=abc\nhead=xyz\n' >"$SD/state"
: >"$FAKE_LOG/git.calls"
ss
t "状態ファイルが壊れている: 古いとみなして裏で更新し、書き直す" 'wait_for bg_done && calls git | grep -q fetch && [ "$(st head)" = "$PIN" ]' "$(cat "$SD/state")"

# HEAD 不一致（前回は未完了）
printf 'last_success=%s\nhead=%s\nfail_count=0\nlast_attempt=%s\n' "$(now)" "1111111111111111111111111111111111111111" "$(now)" >"$SD/state"
: >"$FAKE_LOG/git.calls"
ss
t "HEAD 不一致: 前回は未完了とみなして裏で更新する" 'wait_for "bg_done && [ \"\$(st head)\" = \"$PIN\" ]" && calls git | grep -q fetch' "$(cat "$SD/state")"

# 今の HEAD はキャッシュする（状態の判定で git rev-parse HEAD は 1 回まで）
: >"$FAKE_LOG/git.calls"
ss
t "状態の判定で git rev-parse HEAD は 1 回まで" '[ "$(calls git | grep -c "rev-parse HEAD")" -le 1 ] && ctx_has "gstack: 導入済"' "$(calls git)"

# 固定が上がった（今の HEAD が pins.json と違う）なら、前回の成功が新しくてもすぐ走らせる
OLDSHA=2222222222222222222222222222222222222222
echo "$OLDSHA" >"$GD/.git/HEADSHA"
printf 'last_success=%s\nhead=%s\nfail_count=0\nlast_attempt=%s\n' "$(now)" "$OLDSHA" "$(now)" >"$SD/state"
: >"$FAKE_LOG/git.calls"; : >"$FAKE_LOG/setup.calls"
ss
t "固定が上がった: 成功から 24 時間未満でもすぐ fetch・setup する" 'wait_for "bg_done && [ \"\$(st head)\" = \"$PIN\" ]" && calls git | grep -q fetch && [ -n "$(calls setup)" ]' "$(cat "$SD/state"; calls git)"
t "固定が上がった: 自分で入れた版ではないので上書きの知らせは出さない" '[ ! -e "$SD/gstack-overwrote" ]'

# HEAD が固定と同じなら、24 時間ごとに設定をそろえるだけ（fetch・setup はしない）
printf 'last_success=%s\nhead=%s\nfail_count=0\nlast_attempt=%s\n' $(( $(now) - 90000 )) "$PIN" $(( $(now) - 90000 )) >"$SD/state"
: >"$FAKE_LOG/git.calls"; : >"$FAKE_LOG/setup.calls"; : >"$FAKE_LOG/config.calls"
ss
t "24 時間たった・HEAD は固定と同じ: 設定をそろえるだけ" \
  'wait_for "bg_done && [ \"\$(st last_success)\" -gt $(( $(now) - 100 )) ]" && ! calls git | grep -q fetch && ! calls git | grep -q checkout && [ -z "$(calls setup)" ] && calls config | grep -q "^get auto_upgrade"' "$(cat "$SD/state"; calls git; calls config)"

# 利用者が自分で入れた gstack（HEAD が固定と違い、状態にも無い）を上書きした日は一度だけ知らせる
fresh
mkdir -p "$GD/.git"; echo 3333333333333333333333333333333333333333 >"$GD/.git/HEADSHA"
bgrun
t "自分で入れた gstack を固定の版に上書きした" '[ "$(st head)" = "$PIN" ] && [ -e "$SD/gstack-overwrote" ]' "$(cat "$SD/state"; ls "$SD")"
ss
t "上書きした日は状態の 1 行で知らせる（--depth 1 で浅い取得になったことも）" 'ctx_has "固定の版に置き換えた" && ctx_has "3333333" && ctx_has "depth 1" && ctx_has "shallow"' "$SS_OUT"
ss
t "上書きの知らせは一度だけ" '! ctx_has "固定の版に置き換えた"' "$SS_OUT"
t "導入済（正常）: 利用者向けの 1 行（systemMessage）は出さない" 'ctx_has "gstack: 導入済" && ! ctx_has "systemMessage"' "$SS_OUT"

# 失敗
fresh
ss FAKE_GIT_FAIL=1
t "失敗: 連続失敗回数が 1 になる" 'wait_for "bg_done && [ \"\$(st fail_count)\" = 1 ]"' "$(cat "$SD/state" 2>/dev/null)"
t "失敗: ログに手で直す手順" 'grep -q "手で直す: cd .* git fetch --depth 1 .* ./setup -q --no-plan-tune-hooks" "$SD/gstack.log"'
t "失敗: 手で直す手順に index.lock の片付けと git stash -u" 'grep "手で直す:" "$SD/gstack.log" | grep -q "rm -f .git/index.lock" && grep "手で直す:" "$SD/gstack.log" | grep -q "git stash -u"' "$(grep "手で直す:" "$SD/gstack.log")"
: >"$FAKE_LOG/git.calls"
ss
sleep 1
t "失敗から 1 時間未満は何もしない" '! calls git | grep -q fetch && ctx_has "未導入（前回の導入に失敗"' "$SS_OUT"
if [ "$HAS_NODE" = 1 ]; then
  t "前回の導入に失敗: 利用者向けの 1 行（systemMessage）にログのパス、JSON は正しいまま" \
    'M=$(sysmsg); [[ $M == "gstack の導入・更新に失敗しています。ログ: "*gstack.log ]] && [ "$(printf "%s\n" "$M" | wc -l | tr -d " ")" = 1 ]' "$(sysmsg)"
else
  skip "前回の導入に失敗: systemMessage" "node が無い"
fi
printf 'last_success=0\nhead=\nfail_count=1\nlast_attempt=%s\n' $(( $(now) - 3700 )) >"$SD/state"
ss
t "失敗から 1 時間たてば再試行して成功で 0 に戻す" 'wait_for "bg_done && [ \"\$(st fail_count)\" = 0 ]" && calls git | grep -q fetch' "$(cat "$SD/state")"
printf 'last_success=0\nhead=\nfail_count=3\nlast_attempt=%s\n' "$(now)" >"$SD/state"
ss
t "3 回続けて失敗: 状態行にログのパスと手で直す手順" \
  'ctx_has "【注意】gstack の更新に 3 回続けて失敗" && ctx_has "gstack.log" && ctx_has "./setup -q --no-plan-tune-hooks"' "$SS_OUT"
if [ "$HAS_NODE" = 1 ]; then
  t "3 回続けて失敗: 利用者向けの 1 行（systemMessage）にログのパス、JSON は正しいまま" \
    'M=$(sysmsg); [[ $M == "gstack の導入・更新に失敗しています。ログ: "*gstack.log ]]' "$(sysmsg)"
else
  skip "3 回続けて失敗: systemMessage" "node が無い"
fi

# ロック（持ち主の PID が生きていれば古くない。死んでいれば古い。生きていても打ち切り時間 + 300 秒を過ぎれば古い）
sleep 600 >/dev/null 2>&1 & LIVE=$!
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
fresh
mkdir -p "$SD/gstack.lock"; printf '%s %s\n' "$LIVE" "$(now)" >"$SD/gstack.lock/info"
ss
sleep 1
t "新しいロック（持ち主が生きている）があれば走らせず「導入中」" 'ctx_has "gstack: 導入中（裏で作業中" && [ -z "$(calls git)" ]' "$SS_OUT"
printf '%s %s\n' "$LIVE" $(( $(now) - 700 )) >"$SD/gstack.lock/info"
ss
sleep 1
t "打ち切り時間が書かれていないロックは 900 + 300 秒まで新しいとみなす（700 秒前は走らせない）" 'ctx_has "gstack: 導入中（裏で作業中" && [ -z "$(calls git)" ]' "$SS_OUT"
printf '%s %s 300\n' "$LIVE" $(( $(now) - 700 )) >"$SD/gstack.lock/info"
ss
t "打ち切り 300 秒のロックは、持ち主が生きていても 600 秒より古ければ取り直して走らせる" 'wait_for bg_done && calls setup | grep -q no-plan-tune-hooks' "$(cat "$SD/gstack.log" 2>/dev/null)"
fresh
mkdir -p "$SD/gstack.lock"; printf '99999 %s\n' $(( $(now) - 1300 )) >"$SD/gstack.lock/info"
ss
t "打ち切り時間が書かれていないロックも 1200 秒より古ければ取り直す" 'wait_for bg_done && calls setup | grep -q no-plan-tune-hooks' "$(cat "$SD/gstack.log" 2>/dev/null)"
fresh
mkdir -p "$SD/gstack.lock"; printf '%s %s 300\n' "$DEAD" "$(now)" >"$SD/gstack.lock/info"
ss
t "持ち主の PID が死んでいるロックは、時刻が新しくても取り直して走らせる" 'wait_for bg_done && calls setup | grep -q no-plan-tune-hooks' "$(cat "$SD/gstack.log" 2>/dev/null)"
t "状態はロックを取った後に読み直す（cmd_run で state_read は lock_take より後）" \
  'awk "/^cmd_run\\(\\) \\{/{f=1} f&&/state_read/&&!s{s=NR} f&&/lock_take/&&!l{l=NR} f&&/^}/{exit} END{exit !(l&&s&&l<s)}" "$HOOKS/lib/gstack-bg.sh"'
kill "$LIVE" 2>/dev/null
# 裏の処理は setsid があれば別のセッションで起動する
fresh
ss PATH="$FAKESID:$FAKEBIN:$PATH"
t "setsid があれば裏の処理を setsid で起動する" 'wait_for bg_done && grep -q "gstack-bg.sh run" "$FAKE_LOG/setsid.calls"' "$(cat "$FAKE_LOG/setsid.calls" 2>/dev/null)"
# 状態ファイルの書き込み（mv）に失敗したら数回やり直してログに残す
fresh
bgrun FAKE_MV_FAIL=1
t "状態ファイルの mv の失敗は 5 回やり直してログに残す" '[ "$(grep -c . "$FAKE_LOG/mv.calls" 2>/dev/null)" -ge 5 ] && grep -q "状態ファイルを書けない" "$SD/gstack.log"' "$(cat "$FAKE_LOG/mv.calls" 2>/dev/null; tail -n 3 "$SD/gstack.log")"
# .git の古いロックの片付けは、ロックを確かに持っているときだけ
fresh
mkdir -p "$GD/.git"; touch -d "@$(( $(now) - 7200 ))" "$GD/.git/index.lock"
( export HOME="$SH" GSTACK_DIR="$GD"; . "$HOOKS/lib/gstack-bg.sh"; BG_TIMEOUT=300; clean_git_locks )
t "ロックを持っていなければ .git の古いロックを片付けない" '[ -e "$GD/.git/index.lock" ]'

fresh
bgrun FAKE_SETUP_SLEEP=2 & P1=$!
bgrun FAKE_SETUP_SLEEP=2 & P2=$!
bgrun FAKE_SETUP_SLEEP=2 & P3=$!
wait $P1 $P2 $P3
t "同時に 3 本起動してもロックで 1 本だけ（setup 1 回）" '[ "$(calls setup | wc -l | tr -d " ")" = 1 ] && [ ! -d "$SD/gstack.lock" ]' "$(calls setup)"
fresh
mkdir -p "$SD/gstack.lock"; printf '99999 %s\n' $(( $(now) - 5000 )) >"$SD/gstack.lock/info"
bgrun FAKE_SETUP_SLEEP=2 & P1=$!
bgrun FAKE_SETUP_SLEEP=2 & P2=$!
bgrun FAKE_SETUP_SLEEP=2 & P3=$!
bgrun FAKE_SETUP_SLEEP=2 & P4=$!
wait $P1 $P2 $P3 $P4
t "古いロックを同時に 4 本が取り直しても 1 本だけ（setup 1 回）" '[ "$(calls setup | wc -l | tr -d " ")" = 1 ] && [ ! -d "$SD/gstack.lock" ] && ! ls -d "$SD"/gstack.lock.* >/dev/null 2>&1' "$(calls setup; ls -a "$SD")"

# 打ち切り時間（初回の導入 900 秒・更新 300 秒）はロックに書く
fresh
bgrun FAKE_SETUP_SLEEP=3 & P1=$!
wait_for '[ -f "$SD/gstack.lock/info" ]'
t "初回の導入の打ち切りは 900 秒" '[ "$(awk "{print \$3}" "$SD/gstack.lock/info" 2>/dev/null)" = 900 ]' "$(cat "$SD/gstack.lock/info" 2>/dev/null)"
wait $P1
echo 4444444444444444444444444444444444444444 >"$GD/.git/HEADSHA"
bgrun FAKE_SETUP_SLEEP=3 & P1=$!
wait_for '[ -f "$SD/gstack.lock/info" ]'
t "更新の打ち切りは 300 秒" '[ "$(awk "{print \$3}" "$SD/gstack.lock/info" 2>/dev/null)" = 300 ]' "$(cat "$SD/gstack.lock/info" 2>/dev/null)"
wait $P1
t "待機ループの間隔は 1 秒（0.5 秒の sleep を使わない）" '! grep -q "sleep 0\.5" "$HOOKS/lib/gstack-bg.sh"'

# gstack の .git に残った古い *.lock を作業の前に片付ける（新しいものは残す）
touch -d "@$(( $(now) - 7200 ))" "$GD/.git/index.lock"
mkdir -p "$GD/.git/refs"; touch "$GD/.git/refs/new.lock"
echo 5555555555555555555555555555555555555555 >"$GD/.git/HEADSHA"
bgrun
t "古い .git/index.lock を片付け、新しい *.lock は残す" '[ ! -e "$GD/.git/index.lock" ] && [ -e "$GD/.git/refs/new.lock" ] && grep -q "古いロック" "$SD/gstack.log"' "$(ls -la "$GD/.git" "$GD/.git/refs"; tail -n 5 "$SD/gstack.log")"

# 打ち切り
fresh
S0=$(now)
bgrun MITSUISHI_GSTACK_TIMEOUT=2 FAKE_SETUP_SLEEP=30 FAKE_SETUP_GRANDCHILD=1
EL=$(( $(now) - S0 ))
t "打ち切り: 2 秒の打ち切りで 10 秒以内に戻る" '[ "$EL" -lt 10 ]' "$EL 秒"
t "打ち切り: 失敗として数え、ログに残す" '[ "$(st fail_count)" = 1 ] && grep -q "打ち切り" "$SD/gstack.log"' "$(cat "$SD/state")"
GC=$(cat "$FAKE_LOG/grandchild.pid" 2>/dev/null)
sleep 1
t "打ち切り: 偽 setup の孫プロセス（PID を記録）が残らない" '[ -n "$GC" ] && ! kill -0 "$GC" 2>/dev/null' "孫 PID=${GC:-記録なし}"
[ -n "$GC" ] && kill -9 "$GC" 2>/dev/null
# 打ち切り時間の環境変数が正の整数でなければ既定に戻す
for v in abc 0 -5 '3 4'; do
  fresh
  bgrun "MITSUISHI_GSTACK_TIMEOUT=$v" FAKE_SETUP_SLEEP=2 & P1=$!
  wait_for '[ -f "$SD/gstack.lock/info" ]'
  t "MITSUISHI_GSTACK_TIMEOUT=$v は既定の 900 秒に戻す" '[ "$(awk "{print \$3}" "$SD/gstack.lock/info" 2>/dev/null)" = 900 ]' "$(cat "$SD/gstack.lock/info" 2>/dev/null)"
  wait $P1
  t "MITSUISHI_GSTACK_TIMEOUT=$v でも導入は成功する" '[ "$(st fail_count)" = 0 ] && [ "$(st last_success)" -gt 0 ]' "$(cat "$SD/state" 2>/dev/null; tail -n 3 "$SD/gstack.log" 2>/dev/null)"
done

# 作業コピーの扱い
fresh
mkdir -p "$SH/.claude/skills/gstack"; echo keep >"$SH/.claude/skills/gstack/junk"
env HOME="$SH" PATH="$FAKEBIN:$PATH" bash "$HOOKS/lib/gstack-bg.sh" run
t "既定の場所で .git を読めないときは日時つきの名前に退避して入れ直す" \
  'ls -d "$SH/.claude/skills/gstack.bak-"* >/dev/null 2>&1 && grep -q keep "$SH"/.claude/skills/gstack.bak-*/junk && [ -e "$SH/.claude/skills/gstack/.git" ] && [ "$(st fail_count)" = 0 ]' "$(ls -a "$SH/.claude/skills" 2>&1)"
fresh
mkdir -p "$GD"; echo keep >"$GD/junk"
bgrun
t "既定でない場所の異常は消さず・退避せず、失敗として数える" \
  '[ -f "$GD/junk" ] && [ ! -e "$GD/.git" ] && ! ls -d "$GD".bak-* >/dev/null 2>&1 && [ "$(st fail_count)" = 1 ] && grep -q "git の作業コピーではない" "$SD/gstack.log"'

# git の外・git が無い・停止
fresh
SS_CWD="$OUTSIDE" ss
sleep 1
t "git のリポジトリの外で始めても gstack の導入を裏で始める（BG_ACTION=run 相当）" 'ctx_has "gstack: 導入中（裏で導入を始めた" && ! ctx_has "リポジトリの外" && wait_for bg_done && [ "$(st fail_count)" = 0 ] && [ -n "$(calls git)" ]' "$SS_OUT"
if PATH="$NOGIT_PATH" command -v git >/dev/null 2>&1; then
  skip "git が無いときの状態行" "git を外した PATH を作れない"
else
  SS_OUT=$(printf '{"cwd":"%s"}' "$(jstr "$REPO")" | env HOME="$SH" PATH="$NOGIT_PATH" bash "$HOOKS/session-start" 2>&1)
  t "git が無い: 状態行は「編集ガード無効（git なし）」" 'ctx_has "編集ガード無効（git なし）"' "$SS_OUT"
  t "git が無い: 利用者向けの 1 行（systemMessage）で Git を入れるよう伝える" 'ctx_has "\"systemMessage\": \"Git が見つからない"' "$SS_OUT"
fi
ss MITSUISHI_HOOKS_OFF=session-start
t "MITSUISHI_HOOKS_OFF=session-start: 何も出さない" '[ -z "$SS_OUT" ]' "$SS_OUT"
ss MITSUISHI_HOOKS_OFF=1
t "MITSUISHI_HOOKS_OFF=1: 何も出さない" '[ -z "$SS_OUT" ]'
SS_CWD="$OUTSIDE" ss MITSUISHI_HOOKS_OFF=planner-edit
t "MITSUISHI_HOOKS_OFF=planner-edit: session-start は動く" 'ctx_has "<mitsuishi-dev>"'

# 制御文字を落とす
CP="$TMP/plugin-copy"; cp -R "$CLAUDE_PLUGIN_ROOT" "$CP"
printf 'ベル\007エスケープ\033[31m赤\033[0m CR\r\n' >>"$CP/MODELS.md"
SS_OUT=$(printf '{"cwd":"%s"}' "$(jstr "$OUTSIDE")" | env HOME="$SH" CLAUDE_PLUGIN_ROOT="$CP" bash "$CP/hooks/session-start" 2>&1)
ESC=$(printf '\033'); BEL=$(printf '\007')
t "注入文から制御文字を落とす" 'ctx_has "ベルエスケープ\[31m赤" && ! printf "%s" "$SS_OUT" | LC_ALL=C grep -q "[$ESC$BEL]"' "$SS_OUT"
if command -v node >/dev/null 2>&1; then
  t "制御文字を入れても node で JSON.parse でき、制御文字が残らない" \
    'printf "%s" "$SS_OUT" | node -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{const c=JSON.parse(s).hookSpecificOutput.additionalContext;process.exit(/[\u0000-\u0008\u000b-\u001f\u007f]/.test(c)?1:0)})"'
fi

echo "── CI のスクリプト ──"
if command -v node >/dev/null 2>&1; then
  # 一時リポジトリに今の中身を写し、基準のコミットを作る
  CR="$TMP/ci-repo"; mkdir -p "$CR"
  (cd "$ROOT" && tar cf - --exclude=.git --exclude=.gstack .) | (cd "$CR" && tar xf -)
  (cd "$CR" && "$REAL_GIT" init -q && "$REAL_GIT" checkout -q -B main \
    && "$REAL_GIT" add -A && "$REAL_GIT" -c user.email=t@example.invalid -c user.name=t commit -q -m base)
  cv() { (cd "$CR" && node scripts/check-version.mjs "$@" 2>&1); }
  OUT=$(cv main); RC=$?
  t "版の検査: 変更なしは成功" '[ $RC = 0 ] && printf "%s" "$OUT" | grep -q "版の検査: 成功"' "$OUT"
  echo "# x" >>"$CR/plugins/mitsuishi-dev/hooks/session-start"
  OUT=$(cv main); RC=$?
  t "版の検査: plugins を変えて版を上げ忘れると失敗（ファイル・版・直し方を出す）" \
    '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "::error::.*hooks/session-start.*今の版 .*基準（main）の版 .*直し方"' "$OUT"
  V=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$CR/plugins/mitsuishi-dev/.claude-plugin/plugin.json")
  NV=$(echo "$V" | awk -F. '{print $1"."$2"."$3+1}')
  sed -i.bak "s/\"version\": \"$V\"/\"version\": \"$NV\"/" "$CR/plugins/mitsuishi-dev/.claude-plugin/plugin.json"; rm -f "$CR"/plugins/mitsuishi-dev/.claude-plugin/plugin.json.bak
  OUT=$(cv main); RC=$?
  t "版の検査: 1 か所だけ上げると 3 か所の不一致で失敗" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "3 か所で一致しない"' "$OUT"
  sed -i.bak "s/\"version\": \"$V\"/\"version\": \"$NV\"/" "$CR/.claude-plugin/marketplace.json"; rm -f "$CR/.claude-plugin/marketplace.json.bak"
  sed -i.bak "s/^- $V /- $NV (2026-01-01) テスト\n- $V /" "$CR/CHANGELOG.md"; rm -f "$CR/CHANGELOG.md.bak"
  OUT=$(cv main); RC=$?
  t "版の検査: 3 か所そろえて上げれば成功" '[ $RC = 0 ]' "$OUT"
  OUT=$(cv 0000000000000000000000000000000000000000); RC=$?
  t "版の検査: 基準が 0（新ブランチ）なら main と比べる" '[ $RC = 0 ] && printf "%s" "$OUT" | grep -q "基準 main"' "$OUT"
  sed -i.bak "s/\"version\": \"$NV\"/\"version\": \"$V\"/g" "$CR/.claude-plugin/marketplace.json" "$CR/plugins/mitsuishi-dev/.claude-plugin/plugin.json"
  sed -i.bak "s/^- $NV (2026-01-01) テスト/- 0.9.0 (2026-01-01) テスト/" "$CR/CHANGELOG.md"
  sed -i.bak "s/\"version\": \"$V\"/\"version\": \"0.9.0\"/g" "$CR/.claude-plugin/marketplace.json" "$CR/plugins/mitsuishi-dev/.claude-plugin/plugin.json"
  OUT=$(cv main); RC=$?
  t "版の検査: 版を下げると失敗（semver で比較）" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "版が上がっていない"' "$OUT"
  sed -i.bak "s/\"version\": \"0.9.0\"/\"version\": \"$V-rc.1\"/g" "$CR/.claude-plugin/marketplace.json" "$CR/plugins/mitsuishi-dev/.claude-plugin/plugin.json"
  sed -i.bak "s/^- 0.9.0 /- $V-rc.1 /" "$CR/CHANGELOG.md"
  OUT=$(cv main); RC=$?
  t "版の検査: 同じ版の rc は小さいとみなして失敗" '[ $RC != 0 ]' "$OUT"
  (cd "$CR" && "$REAL_GIT" checkout -q -- . && "$REAL_GIT" clean -qfd)
  sed -i.bak '/^TOP_ALIASES:/d' "$CR/plugins/mitsuishi-dev/MODELS.md"
  OUT=$(cv main); RC=$?
  t "版の検査: MODELS.md に TOP_ALIASES の行が無いと失敗" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "TOP_ALIASES"' "$OUT"
  (cd "$CR" && "$REAL_GIT" checkout -q -- . && "$REAL_GIT" clean -qfd)

  OUT=$(cd "$CR" && env -u FORBIDDEN_WORDS node scripts/check-forbidden.mjs 2>&1); RC=$?
  t "禁止語: 未設定なら飛ばして ::notice::" '[ $RC = 0 ] && printf "%s" "$OUT" | grep -q "::notice::"' "$OUT"
  echo "この行に ZzSecretWordZz がある" >"$CR/note.txt"
  OUT=$(cd "$CR" && FORBIDDEN_WORDS=$'foo-not-here\nzzsecretwordzz' node scripts/check-forbidden.mjs 2>&1); RC=$?
  t "禁止語: 当たれば失敗し、場所だけ出して語は出さない" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "file=note.txt,line=1" && ! printf "%s" "$OUT" | grep -qi zzsecretwordzz' "$OUT"
  UW="zzup""streamzz"   # このファイル自体に当たらないよう分けて書く
  rm -f "$CR/note.txt"; echo "$UW" >"$CR/plugins/superpowers/note.txt"
  OUT=$(cd "$CR" && FORBIDDEN_WORDS="$UW" node scripts/check-forbidden.mjs 2>&1); RC=$?
  t "禁止語: 上流の写し（plugins/superpowers/）は見ない" '[ $RC = 0 ]' "$OUT"
  rm -f "$CR/note.txt" "$CR/plugins/superpowers/note.txt"

  OUT=$(cd "$CR" && HOME="$TMP/home" node scripts/check-json.mjs 2>&1); RC=$?
  t "JSON の検査と注入 JSON の parse が成功" '[ $RC = 0 ]' "$OUT"
  echo '{ "a": ' >"$CR/broken.json"
  OUT=$(cd "$CR" && HOME="$TMP/home" node scripts/check-json.mjs 2>&1); RC=$?
  t "JSON の構文の誤りで失敗" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "broken.json"' "$OUT"
  rm -f "$CR/broken.json"

  # 上流の固定を上げる（ls-remote の代わりに BUMP_HEADS、superpowers の中身の取得の代わりに BUMP_SUPERPOWERS_SRC。ネットワークに出ない）
  GA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; SB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  UP="$CR/upstream-pins.json"; SPD="$CR/plugins/superpowers"
  OLDS=$(sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' "$UP")
  SPV=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SPD/.claude-plugin/plugin.json")
  MK="$CR/.claude-plugin/marketplace.json"; PJ="$CR/plugins/mitsuishi-dev/.claude-plugin/plugin.json"; PN="$CR/plugins/mitsuishi-dev/pins.json"
  # 偽の上流の中身 <フォルダ> <version>: 今の写しに無いファイルと .git を持ち、今の写しのファイルは持たない
  mksp() { rm -rf "$1"; mkdir -p "$1/.claude-plugin" "$1/.git" "$1/skills/new-skill"; printf '{"name":"superpowers","version":"%s"}\n' "$2" >"$1/.claude-plugin/plugin.json"; echo MIT >"$1/LICENSE"; echo new >"$1/skills/new-skill/SKILL.md"; echo x >"$1/.git/HEAD"; }
  NEWSP="$TMP/sp-new"; mksp "$NEWSP" 99.0.0
  SAMESP="$TMP/sp-same"; mksp "$SAMESP" "$SPV"
  OLDSP="$TMP/sp-old"; mksp "$OLDSP" 0.0.1
  NOLIC="$TMP/sp-nolic"; mksp "$NOLIC" 99.0.0; rm -f "$NOLIC/LICENSE"
  spold() { [ -f "$SPD/LICENSE" ] && [ -f "$SPD/skills/test-driven-development/SKILL.md" ] && [ ! -e "$SPD/skills/new-skill" ] && grep -q "\"sha\": \"$OLDS\"" "$UP"; }
  breset() { (cd "$CR" && "$REAL_GIT" checkout -q -- . && "$REAL_GIT" clean -qfd); : >"$TMP/gh-out"; }
  # bump <gstack の sha> <superpowers の sha> [環境変数=値 ...]（中身の既定は NEWSP。後の環境変数が勝つ）
  bump() { local g="$1" s="$2"; shift 2; OUT=$(cd "$CR" && env BUMP_HEADS="{\"gstack\":\"$g\",\"superpowers\":\"$s\"}" BUMP_SUPERPOWERS_SRC="$NEWSP" GITHUB_OUTPUT="$TMP/gh-out" "$@" node scripts/bump-upstream.mjs 2>&1); RC=$?; }
  ghout() { cat "$TMP/gh-out" 2>/dev/null; }
  t "上流の写し: marketplace.json の superpowers は相対パス・LICENSE がある・固定の sha は upstream-pins.json" \
    'grep -q "\"source\": \"./plugins/superpowers\"" "$MK" && [ -f "$ROOT/plugins/superpowers/LICENSE" ] && [ -n "$OLDS" ] && [ -n "$SPV" ]'
  breset
  bump "$GA" "$SB"
  t "上流の固定を上げる: pins.json・upstream-pins.json の sha・版の patch・CHANGELOG を書き換える" \
    '[ $RC = 0 ] && grep -q "$GA" "$PN" && grep -q "\"sha\": \"$SB\"" "$UP" && grep -q "\"version\": \"$NV\"" "$PJ" && head -n 6 "$CR/CHANGELOG.md" | grep -q "^- $NV .*上流の固定を上げる" && ghout | grep -q "^changed<<"' "$OUT"
  t "superpowers の上流の版が大きければ plugins/superpowers/ を丸ごと置き換える（消えたファイルも消し、.git は写さない）" \
    '[ -f "$SPD/skills/new-skill/SKILL.md" ] && [ ! -e "$SPD/skills/test-driven-development" ] && [ ! -e "$SPD/.git" ] && grep -q "99.0.0" "$SPD/.claude-plugin/plugin.json" && [ -f "$SPD/LICENSE" ]' "$(ls -a "$SPD")"
  t "PR の本文に上流ごとの compare のリンク" \
    'ghout | grep -q "https://github.com/garrytan/gstack/compare/$PIN\.\.\.$GA" && ghout | grep -q "https://github.com/obra/superpowers/compare/$OLDS\.\.\.$SB" && ghout | grep -q "superpowers の version: $SPV → 99.0.0"' "$(ghout)"
  OUT=$(cd "$CR" && node scripts/check-version.mjs main 2>&1); RC=$?
  t "上流の固定を上げた後も版の検査が成功" '[ $RC = 0 ]' "$OUT"
  bump "$GA" "$SB"
  t "上流の固定を上げる: 変わっていなければ何もしない" '[ $RC = 0 ] && printf "%s" "$OUT" | grep -q "変わっていない" && grep -q "\"version\": \"$NV\"" "$PJ" && ghout | grep -A1 "^changed<<" | grep -qx false' "$OUT"
  breset
  bump "$PIN" "$SB" BUMP_SUPERPOWERS_SRC="$SAMESP"
  t "superpowers だけ変わり version が同じ: 中身も sha も変えず changed=false" \
    '[ $RC = 0 ] && spold && grep -q "\"version\": \"$V\"" "$PJ" && ghout | grep -A1 "^changed<<" | grep -qx false && printf "%s" "$OUT" | grep -q "version が同じ"' "$OUT"
  breset
  bump "$PIN" "$SB" BUMP_SUPERPOWERS_SRC="$OLDSP"
  t "superpowers の上流の版が今の写しより小さい: 中身も sha も変えず changed=false" \
    '[ $RC = 0 ] && spold && ghout | grep -A1 "^changed<<" | grep -qx false && printf "%s" "$OUT" | grep -q "より小さい"' "$OUT"
  breset
  bump "$PIN" "$SB" 'BUMP_VERSIONS={"old":null,"new":"5.1.0"}'
  t "superpowers だけ変わり version を確かめられない: 中身も sha も変えず changed=false" \
    '[ $RC = 0 ] && spold && ghout | grep -A1 "^changed<<" | grep -qx false && printf "%s" "$OUT" | grep -q "確かめられない"' "$OUT"
  breset
  bump "$PIN" "$SB" BUMP_SUPERPOWERS_SRC= BUMP_OFFLINE=1
  t "superpowers だけ変わり BUMP_OFFLINE=1（中身を取得しない）: 中身も sha も変えない" \
    '[ $RC = 0 ] && spold && ghout | grep -A1 "^changed<<" | grep -qx false' "$OUT"
  breset
  bump "$PIN" "$SB"
  t "superpowers だけ変わり version が上がった: superpowers だけ置き換える" \
    '[ $RC = 0 ] && grep -q "\"sha\": \"$SB\"" "$UP" && [ -f "$SPD/skills/new-skill/SKILL.md" ] && grep -q "$PIN" "$PN" && grep -q "\"version\": \"$NV\"" "$PJ" && ! ghout | grep -q "garrytan/gstack/compare"' "$OUT"
  breset
  bump "$PIN" "$SB" 'BUMP_VERSIONS={"old":"5.0.0","new":"5.1.0"}'
  t "BUMP_VERSIONS で version の読み取りを差し替えられる" '[ $RC = 0 ] && ghout | grep -q "superpowers の version: 5.0.0 → 5.1.0"' "$(ghout)"
  breset
  bump "$PIN" "$SB" BUMP_SUPERPOWERS_SRC="$NOLIC"
  t "上流の中身に LICENSE が無ければ止める（書き換えない）" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "LICENSE が無い" && spold && grep -q "\"version\": \"$V\"" "$PJ"' "$OUT"
  breset
  bump "$GA" "$OLDS"
  t "gstack だけ変わった: pins.json だけ書き換え、superpowers は見ない" \
    '[ $RC = 0 ] && grep -q "$GA" "$PN" && spold && ghout | grep -q "garrytan/gstack/compare" && ! ghout | grep -q "obra/superpowers/compare"' "$OUT"
  breset
  bump "$GA" "$SB" BUMP_SUPERPOWERS_SRC="$SAMESP"
  t "gstack が変わり superpowers は version が同じ: gstack だけ上げ、本文に superpowers を見送った理由" \
    '[ $RC = 0 ] && grep -q "$GA" "$PN" && spold && ghout | grep -q "superpowers.*見送った"' "$(ghout)"
  breset
  sed -i.bak "s/\"version\": \"$V\"/\"version\": \"$V-rc.1\"/" "$PJ" "$MK"; rm -f "$PJ.bak" "$MK.bak"
  bump "$GA" "$OLDS"
  t "版が厳密な semver（x.y.z）でなければ止める" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "x.y.z" && grep -q "$PIN" "$PN"' "$OUT"
  breset
  sed -i.bak "s/\"version\": \"$V\"/\"version\":\"$V\"/" "$MK"; rm -f "$MK.bak"
  bump "$GA" "$OLDS"
  t "置き換えが値を変えなければ止める（書き換えない）" '[ $RC != 0 ] && printf "%s" "$OUT" | grep -q "置き換えられない" && grep -q "$PIN" "$PN"' "$OUT"
  breset

  # CI の定義（action は sha で固定・gitleaks は本体を直接・BUMP_TOKEN が無ければ失敗）
  WF="$ROOT/.github/workflows"
  t "workflow の action はすべてコミットの sha で固定し、タグをコメントに残す" \
    '[ -z "$(grep -h "uses:" "$WF"/*.yml | grep -vE "uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]")" ]' "$(grep -h "uses:" "$WF"/*.yml)"
  t "gitleaks は action を使わず v8.30.1 の本体をチェックサムで確かめて実行（ライセンスキー不要）" \
    '! grep -q "gitleaks-action" "$WF/ci.yml" && ! grep -q "GITLEAKS_LICENSE" "$WF/ci.yml" && grep -q "gitleaks_8.30.1_linux_x64.tar.gz" "$WF/ci.yml" && grep -q "sha256sum -c" "$WF/ci.yml"'
  t "上流の固定を上げる PR は BUMP_TOKEN だけで作り、無ければ失敗する" \
    '! grep -q "github.token" "$WF/bump-upstream.yml" && grep -q "token: \${{ secrets.BUMP_TOKEN }}" "$WF/bump-upstream.yml" && grep -q "exit 1" "$WF/bump-upstream.yml"'
  t "管理設定の env で CLAUDE_CODE_SUBAGENT_MODEL=opus（FORCE は使わない）" \
    'node -e "const j=require(process.argv[1]);process.exit(j.env&&j.env.CLAUDE_CODE_SUBAGENT_MODEL===\"opus\"&&!(\"CLAUDE_CODE_SUBAGENT_MODEL_FORCE\" in j.env)?0:1)" "$ROOT/admin/managed-settings.json"'

  # hooks.json の matcher と timeout
  t "hooks.json: SessionStart（startup|clear|compact・30 秒）・編集（10 秒）・Agent|Task（10 秒）" \
    'node -e "
      const h=require(process.argv[1]).hooks;
      const one=(ev,m,cmd,to)=>{const e=(h[ev]||[]).filter(x=>x.matcher===m);return e.length===1&&e[0].hooks.length===1&&e[0].hooks[0].command.includes(cmd)&&e[0].hooks[0].timeout===to&&e[0].hooks[0].shell===\"bash\";};
      process.exit(one(\"SessionStart\",\"startup|clear|compact\",\"hooks/session-start\",30)&&one(\"PreToolUse\",\"Edit|Write|MultiEdit|NotebookEdit\",\"hooks/guard-planner-edit\",10)&&one(\"PreToolUse\",\"Agent|Task\",\"hooks/guard-subagent\",10)&&Object.keys(h).length===2&&h.PreToolUse.length===2?0:1)" "$CLAUDE_PLUGIN_ROOT/hooks/hooks.json"'
else
  skip "CI のスクリプト" "node が無い"
fi

echo "── エージェント定義 ──"
AGD="$CLAUDE_PLUGIN_ROOT/agents"
# fm <ファイル> : frontmatter（最初の --- と次の --- の間）
fm() { awk 'NR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next } /^---[[:space:]]*$/ { exit } { print }' "$1" | tr -d '\r'; }
# fmlist <ファイル> <キー> : 1 行（a, b）と YAML の箇条書き（- a）の両方を 1 行 1 つに
fmlist() { fm "$1" | awk -v k="$2" '
  $0 ~ "^" k ":" { inl = 1; v = $0; sub("^" k ":[[:space:]]*", "", v); n = split(v, a, /[[:space:]]*,[[:space:]]*/); for (j = 1; j <= n; j++) if (a[j] != "") print a[j]; next }
  inl && /^[[:space:]]*-[[:space:]]/ { v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); print v; next }
  { inl = 0 }'; }
for a in executor ui-executor; do
  t "$a: disallowedTools に Agent（再委託しない）" 'fmlist "$AGD/$a.md" disallowedTools | grep -qx Agent' "$(fm "$AGD/$a.md")"
  t "$a: model は opus" 'fm "$AGD/$a.md" | grep -qx "model: opus"'
done
for a in advisor outside-voice; do
  t "$a: tools を持ち（省くと全部使える）、Edit・Write・Agent が無い" \
    '[ -n "$(fmlist "$AGD/$a.md" tools)" ] && ! fmlist "$AGD/$a.md" tools | grep -qxE "Edit|Write|Agent|Task|MultiEdit|NotebookEdit"' "$(fm "$AGD/$a.md")"
done
t "advisor: model は fable（最上位）" 'fm "$AGD/advisor.md" | grep -qx "model: fable"'
t "outside-voice: model は opus" 'fm "$AGD/outside-voice.md" | grep -qx "model: opus"'
t "ui-executor: skills に frontend-design" 'fmlist "$AGD/ui-executor.md" skills | grep -qE "^(frontend-design:)?frontend-design$"' "$(fm "$AGD/ui-executor.md")"

# 打ち切りのテストの残り（念のため）
for p in $(ps -ef 2>/dev/null | grep "sleep 6171" | grep -v grep | awk '{print $2}'); do kill -9 "$p" 2>/dev/null; done

printf '\n合計 %d 件: 成功 %d / 失敗 %d / 飛ばした %d\n' $((PASS + FAIL)) "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
