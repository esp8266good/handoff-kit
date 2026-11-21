#!/usr/bin/env bash
# install.sh 的測試：在拋棄式 HOME 裡裝、重裝、跟既有 hook 共存、移除
# 用法：bash tests/install.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
pass=0 fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  ❌ $1"; fi; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
export HOME="$t"
unset CLAUDE_CONFIG_DIR
C="$t/.claude"
S="$C/skills/handing-off-long-running-work"
count() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum("context_tokens.sh" in h.get("command","") for e in d.get("hooks",{}).values() for g in e for h in g.get("hooks",[])))' "$C/settings.json"; }

# 既有的設定：別的 Stop hook 和別的欄位要原樣留著
mkdir -p "$C/skills/other-skill"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$C/settings.json"

bash "$REPO/install.sh" > "$t/out1" 2>&1
check "第一次安裝成功" '[ $? -eq 0 ] || true; [ -f "$S/SKILL.md" ] && [ -f "$C/commands/handoff.md" ]'
check "script 都可以執行" '[ -x "$S/preflight.sh" ] && [ -x "$S/context_tokens.sh" ]'
check "加了兩個 hook" '[ "$(count)" = 2 ]'
check "既有的 Stop hook 和 model 還在" 'grep -q "echo mine" "$C/settings.json" && grep -q "\"opus\"" "$C/settings.json"'
check "別的 skill 沒被動到" '[ -d "$C/skills/other-skill" ]'

bash "$REPO/install.sh" > "$t/out2" 2>&1
check "重跑：hook 不會變兩份" '[ "$(count)" = 2 ]'
check "重跑：settings.json 不用改" 'grep -q "不用改" "$t/out2"'
check "重跑：自己裝的不備份" '[ ! -d "$C/handoff-kit-backup" ]'

bash "$REPO/install.sh" --uninstall > "$t/out3" 2>&1
check "移除：skill 和指令不見了" '[ ! -e "$S" ] && [ ! -e "$C/commands/handoff.md" ]'
check "移除：hook 拿掉、別人的留著" '[ "$(count)" = 0 ] && grep -q "echo mine" "$C/settings.json"'

# 已經有一個不是 kit 裝的同名 skill：搬到 skills/ 外面備份，不能留在 skills/ 裡變成第二個同名 skill
mkdir -p "$S"; echo "別人的版本" > "$S/SKILL.md"
bash "$REPO/install.sh" --no-hooks > "$t/out4" 2>&1
check "--no-hooks：沒加 hook" '[ "$(count)" = 0 ]'
check "別人的同名 skill 搬到備份目錄" 'grep -rq "別人的版本" "$C/handoff-kit-backup"'
check "skills/ 底下沒有多出 .bak 目錄" '[ "$(ls "$C/skills" | wc -l)" = 2 ]'

# settings.json 壞掉：不能覆寫它
bash "$REPO/install.sh" --uninstall > /dev/null 2>&1
echo '{ broken' > "$C/settings.json"
bash "$REPO/install.sh" > "$t/out5" 2>&1; rc=$?
check "settings.json 壞掉：非 0 結束" '[ $rc -ne 0 ]'
check "settings.json 壞掉：原檔沒被動" '[ "$(cat "$C/settings.json")" = "{ broken" ]'

# 沒有 settings.json：建一個新的
rm -f "$C/settings.json"
bash "$REPO/install.sh" > /dev/null 2>&1
check "沒有 settings.json：建一個新的、有兩個 hook" '[ "$(count)" = 2 ]'

echo "install：$pass 過、$fail 失敗"
[ "$fail" -eq 0 ]
