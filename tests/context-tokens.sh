#!/usr/bin/env bash
# context_tokens.sh --hook 的測試：用假的 transcript 餵 Stop 事件，看印不印收尾提醒
# 用法：bash tests/context-tokens.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
CT="$REPO/skills/handing-off-long-running-work/context_tokens.sh"
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  ❌ $1"; fi; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
export TMPDIR="$t" HOME="$t"   # stamp 和 handoff-nudge.log 都落在拋棄式目錄
mkdir -p "$t/.claude"

# 一則主線 assistant 訊息，context = $1 token；$2 是 content（JSON 陣列），預設一段文字
TEXT='[{"type":"text","text":"好"}]'
turn() { printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":%s,"usage":{"input_tokens":10,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "${2:-$TEXT}" "$1"; }
bash_use() { printf '[{"type":"tool_use","name":"Bash","input":{"command":%s}}]' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")"; }
write_use() { printf '[{"type":"tool_use","name":"Write","input":{"file_path":"%s","content":"x"}}]' "$1"; }
compact() { echo '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}'; }
human() { printf '{"type":"user","isSidechain":false,"origin":{"kind":"human"},"promptSource":"typed","message":{"role":"user","content":"%s"}}\n' "$1"; }
# hook <session 名>：transcript 從 stdin 來，印 hook 的輸出
hook() {
  cat > "$t/$1.jsonl"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$t/$1.jsonl" | bash "$CT" --hook
}

out=$( { turn 100000; } | hook below )
check "control：還沒到第一層，不提醒" '[ -z "$out" ]'

out=$( { turn 200000; } | hook plain )
check "沒 handoff、超過第一層：提醒" 'grep -q "該收尾了" <<<"$out"'

out=$( { turn 200000; turn 200100; } | hook plain )
check "同一層已經提醒過：不再提醒" '[ -z "$out" ]'

# Windows：PATH 上第一支 python3 是 Microsoft Store 的空殼（rc=49），提醒不能安靜消失
mkdir -p "$t/WindowsApps"
printf '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n' > "$t/WindowsApps/python3"; chmod +x "$t/WindowsApps/python3"
out=$( { turn 200000; } | PATH="$t/WindowsApps:$PATH" hook stub )
check "python3 是 Store 空殼：跳過它，照舊提醒" 'grep -q "該收尾了" <<<"$out"'

out=$( { turn 350000; } | hook plain2 )
check "沒 handoff、超過第二層：提醒" 'grep -q "已經很貴" <<<"$out"'

out=$( { turn 200000 "$(bash_use "cat > /p/handoff_prompt.txt <<'EOF'
# 寫於 x
EOF")"; turn 200100; } | hook heredoc )
check "Bash heredoc 寫了 handoff_prompt.txt 之後不提醒" '[ -z "$out" ]'

out=$( { turn 200000 "$(bash_use "cat > \"/p/my project/handoff_prompt.txt\" <<'EOF'
x
EOF")"; turn 200100; } | hook spaced )
check "路徑有空白（加引號）也認得出是 handoff" '[ -z "$out" ]'

out=$( { turn 120000 "$(write_use /p/handoff_prompt.txt)"; turn 350000; } | hook write )
check "Write 寫了 handoff_prompt.txt 之後，到第二層也不提醒" '[ -z "$out" ]'

out=$( { turn 200000 "$(write_use /p/.handoff/old-task.txt)"; turn 200100; } | hook parked )
check "停放到 .handoff/<名字>.txt 也算 handoff" '[ -z "$out" ]'

out=$( { turn 200000 "$(bash_use 'cat /p/handoff_prompt.txt')"; turn 200100; } | hook readonly )
check "只是讀 handoff_prompt.txt 不算 handoff，照舊提醒" 'grep -q "該收尾了" <<<"$out"'

out=$( { turn 200000 "$(write_use /p/.handoff/auto_analyze)"; turn 200100; } | hook switchfile )
check ".handoff/ 底下不是 .txt 的開關檔不算 handoff" 'grep -q "該收尾了" <<<"$out"'

out=$( { turn 200000 "$(write_use /p/handoff_prompt.txt)"; compact; turn 160000; } | hook aftercompact )
check "handoff 之後 compact 又漲回來：重新算，照舊提醒" 'grep -q "該收尾了" <<<"$out"'

out=$( { human "照 @/p/handoff_prompt.txt 接手"; turn 350000; } | CC_RELAY_GEN=1 hook relayenv )
check "環境裡有 CC_RELAY_GEN 也照舊提醒（這個版本沒有 relay）" 'grep -q "已經很貴" <<<"$out"'

echo '{"session_id":"plain","transcript_path":"/nonexistent"}' | bash "$CT" --reset
out=$( { turn 200000; } | hook plain )
check "--reset 之後同一層會再提醒一次" 'grep -q "該收尾了" <<<"$out"'

echo "context-tokens：$pass 過、$fail 失敗"
[ "$fail" -eq 0 ]
