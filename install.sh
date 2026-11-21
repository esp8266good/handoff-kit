#!/usr/bin/env bash
# 把 /handoff 裝進 ~/.claude：skill、slash command、兩個 hook（context 太大時提醒收尾）。
# Claude Code CLI 和 VS Code extension 讀的都是 ~/.claude，所以裝一次兩邊都有。
#
# 用法：
#   bash install.sh               # 安裝或更新（重複執行結果一樣）
#   bash install.sh --no-hooks    # 只裝 skill 和 /handoff，不碰 settings.json
#   bash install.sh --uninstall   # 移除這三樣，settings.json 只拿掉這裡加的 hook
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
CLAUDE="$HOME/.claude"
NAME=handing-off-long-running-work
SKILL_DST="$CLAUDE/skills/$NAME"
CMD_DST="$CLAUDE/commands/handoff.md"
SETTINGS="$CLAUDE/settings.json"
STAMP=$(date +%Y%m%d-%H%M%S)

mode=install hooks=1
for a in "$@"; do
  case "$a" in
    --no-hooks) hooks=0 ;;
    --uninstall) mode=uninstall ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "不認得的參數：$a" >&2; exit 2 ;;
  esac
done

for c in python3 git; do
  command -v "$c" >/dev/null || { echo "缺 $c，先裝好再跑（Ubuntu：sudo apt install $c）" >&2; exit 1; }
done

if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$(cd "$CLAUDE_CONFIG_DIR" 2>/dev/null && pwd)" != "$(cd "$CLAUDE" 2>/dev/null && pwd)" ]; then
  echo "⚠ 你設了 CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR，但 skill 裡的路徑寫死 ~/.claude/skills/...；" >&2
  echo "  這個安裝只支援預設的 ~/.claude。" >&2
  exit 1
fi

# 改 settings.json：add 加上 hook（已經有就不加），remove 拿掉這裡加的
edit_settings() {
  python3 -I - "$1" "$SETTINGS" "$STAMP" <<'PY'
import json, os, shutil, sys

action, path, stamp = sys.argv[1:4]
MARK = "handing-off-long-running-work/context_tokens.sh"
WANT = {
    "Stop": "bash ~/.claude/skills/handing-off-long-running-work/context_tokens.sh --hook 2>/dev/null || true",
    "PostCompact": "bash ~/.claude/skills/handing-off-long-running-work/context_tokens.sh --reset 2>/dev/null || true",
}

if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except ValueError as e:
        sys.exit(f"{path} 不是合法的 JSON（{e}），hook 沒裝。修好後重跑，或用 --no-hooks。")
else:
    if action == "remove":
        sys.exit(0)
    data = {}

hooks = data.setdefault("hooks", {})
changed = False

def ours(h):
    return MARK in (h.get("command") or "")

for event, cmd in WANT.items():
    groups = hooks.get(event, [])
    if action == "add":
        if any(ours(h) for g in groups for h in g.get("hooks", [])):
            continue
        groups.append({"hooks": [{"type": "command", "command": cmd}]})
        hooks[event] = groups
        changed = True
    else:
        kept = []
        for g in groups:
            hs = [h for h in g.get("hooks", []) if not ours(h)]
            if len(hs) != len(g.get("hooks", [])):
                changed = True
            if hs:
                g["hooks"] = hs
                kept.append(g)
        if event in hooks:
            if kept:
                hooks[event] = kept
            else:
                del hooks[event]
if not hooks:
    data.pop("hooks", None)

if not changed:
    print("settings.json：不用改")
    sys.exit(0)
if os.path.exists(path):
    shutil.copy2(path, f"{path}.bak-{stamp}")
    print(f"settings.json：舊的備份在 {path}.bak-{stamp}")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print("settings.json：" + ("加上 Stop / PostCompact hook" if action == "add" else "拿掉 Stop / PostCompact hook"))
PY
}

# 目的地已經有別人的東西（不是這個 kit 裝的）：先搬到備份目錄再蓋。
# 備份不能留在 skills/ 底下，不然會被當成第二個同名 skill 載入。
BACKUP="$CLAUDE/handoff-kit-backup/$STAMP"
MARKER=.installed-by-handoff-kit
backup_if_foreign() {
  local dst=$1 owned=$2
  [ -e "$dst" ] || return 0
  [ "$owned" = 1 ] && return 0
  mkdir -p "$BACKUP"
  mv "$dst" "$BACKUP/"
  echo "原本的 $dst 不是這個 kit 裝的，搬到 $BACKUP/"
}

if [ "$mode" = uninstall ]; then
  if [ -e "$SKILL_DST/$MARKER" ]; then rm -rf "$SKILL_DST" && echo "移除 $SKILL_DST"
  elif [ -e "$SKILL_DST" ]; then echo "⚠ $SKILL_DST 不是這個 kit 裝的，沒動"; fi
  if [ -f "$CMD_DST" ] && grep -q "handoff-kit" "$CMD_DST"; then rm -f "$CMD_DST" && echo "移除 $CMD_DST"
  elif [ -e "$CMD_DST" ]; then echo "⚠ $CMD_DST 不是這個 kit 裝的，沒動"; fi
  edit_settings remove
  echo "完成。重開 Claude Code（VS Code 要重新開那個 Claude 分頁）後生效。"
  exit 0
fi

mkdir -p "$CLAUDE/skills" "$CLAUDE/commands"
owned=0; [ -e "$SKILL_DST/$MARKER" ] && owned=1
backup_if_foreign "$SKILL_DST" "$owned"
rm -rf "$SKILL_DST"
cp -R "$SRC/skills/$NAME" "$SKILL_DST"
chmod +x "$SKILL_DST"/*.sh
git -C "$SRC" log -1 --format='%h %cs' > "$SKILL_DST/$MARKER" 2>/dev/null || echo unknown > "$SKILL_DST/$MARKER"
echo "skill：$SKILL_DST"

owned=0; [ -f "$CMD_DST" ] && grep -q "handoff-kit" "$CMD_DST" && owned=1
backup_if_foreign "$CMD_DST" "$owned"
cp "$SRC/commands/handoff.md" "$CMD_DST"
echo "指令：$CMD_DST（/handoff）"

if [ "$hooks" = 1 ]; then
  edit_settings add
else
  echo "settings.json：沒碰（--no-hooks）"
fi

echo "完成。新開的 Claude Code session 就有 /handoff；已經開著的要重開（VS Code 要重新開那個 Claude 分頁）。"
