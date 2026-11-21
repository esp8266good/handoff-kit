#!/usr/bin/env bash
# 這個 session 目前佔了多少 context,以及該不該提醒人類收尾。
#
# ⛔ 這支腳本不會叫你去交接。它只產生一行「轉述給人類」的提醒,
#    要不要收尾是人類決定的 —— 自動進 skill 會在人類正需要連貫性的時候把你拉走。
#
# 為什麼要一支腳本而不是靠感覺:agent 對「我用了多少 token」沒有直接的觀測,
# 憑印象估會系統性低估(工具輸出比對話長得多),於是門檻永遠不會觸發。
# transcript 裡每則 assistant 訊息都帶 usage,最後一則的
#   input + cache_read + cache_creation
# 就是當下送進模型的 context 大小,是精確值而非估計。
#
# ⚠ 沒有官方 API 可以問「我現在用了多少 token」。`/context` 是 CLI 內建命令,
#   agent 呼叫不到;環境變數裡也沒有(2026-08 查證,Claude Code 2.1.239)。
#   所以只能讀 transcript。
#
# ## 怎麼找到 transcript(★ 不要猜路徑編碼)
#
# 舊版用 `pwd | sed 's#/#-#g'` 拼出 ~/.claude/projects/ 下的目錄名。**那是錯的**:
# Claude Code 把路徑裡**所有非英數字元**都換成 `-`,不只是斜線。
# 專案路徑含空格、`[]`、`.` 之類的字元時就對不上,腳本靜默失敗,
# 交接門檻於是永遠不會觸發。2026-08-22 在
# `[research] <專案名>` 這種目錄上實際踩過。
#
# 這版不猜:transcript 的每一行都有 `cwd` 欄位,直接拿它跟目前的工作目錄比對。
# 編碼規則只當**加速用的第一猜**,猜不中就退回掃描,所以 Claude Code 改版也不會壞。
#
# 用法:
#   bash context_tokens.sh                  # 目前工作目錄對應的最新 session
#   bash context_tokens.sh <session-id>     # 指定 session(scratchpad 路徑的最後一段)
#   bash context_tokens.sh --hook           # Stop hook 用,stdin 吃事件 JSON,吐 systemMessage
#   bash context_tokens.sh --reset          # PostCompact hook 用,清掉提醒過的紀錄
#
# 上面兩種是給人手動查的,下面兩種是 hook 在跑的 —— 平常不會有人打。
set -u

# Windows 的 Git Bash 裡，PATH 上第一支 python3 常是 Microsoft Store 的空殼
# （WindowsApps\python3.exe，只會叫你去商店裝，Windows 11 實測 rc=49）。hook 的錯誤導到 log、
# 又永遠 exit 0，這裡不跳過的話提醒會安靜地消失。Linux 上第一支就是真的，行為不變。
# ⚠ 先找路徑、迴圈外才執行：在 while read 裡執行的話，Python 的 stdin 會是 type 的輸出，吃不到 heredoc
python3() {
  local n p found=""
  for n in python3 python; do
    while IFS= read -r p; do
      case "$p" in */WindowsApps/*) continue ;; esac
      found="$p"; break
    done < <(type -aP "$n" 2>/dev/null)
    [ -n "$found" ] && break
  done
  [ -n "$found" ] || { echo "context_tokens.sh：找不到 Python" >&2; return 127; }
  "$found" "$@"
}

NUDGE1=${NUDGE1:-150000}   # 「可以考慮換新 session 了」
NUDGE2=${NUDGE2:-300000}   # 「這個 session 現在是專案裡最貴的東西」
ROOT="$HOME/.claude/projects"
MODE="${1:-}"
if [ "$MODE" = "--hook" ] || [ "$MODE" = "--reset" ]; then
  # ## hook 模式（給 Stop / PostCompact 用，人不會手動跑這條）
  #
  # stdin 是 Claude Code 餵進來的事件 JSON，裡面直接有 transcript_path，
  # 所以上面那整套「猜路徑再退回掃描」在這條路徑上完全用不到。
  #
  # ⛔ 這條路徑永遠 exit 0，而且只印 {"systemMessage": ...}：
  #    Stop hook 只要 exit 非 0，stderr 就會被餵進 agent 的 context，
  #    exit 2 甚至會擋住 agent 停下來。實測（2026-09-20，Claude Code 2.1.278）：
  #    systemMessage 在 transcript 裡是 rendered=False 的 attachment，只給人看，
  #    不進 messages。⛔ 不要改成 additionalContext，那個會進 context。
  # ⚠ 先把 stdin 讀進變數再交給 python：`python3 - <<'HOOKPY'` 的 stdin 就是
  #    那份 heredoc 腳本本身,事件 JSON 進不去(踩過一次)。
  EVENT_JSON="$(cat)"
  MODE="$MODE" NUDGE1="$NUDGE1" NUDGE2="$NUDGE2" EVENT_JSON="$EVENT_JSON" \
    python3 - <<'HOOKPY' 2>>"$HOME/.claude/handoff-nudge.log"
import json, os, sys, time

LOG = os.path.expanduser("~/.claude/handoff-nudge.log")


def log(msg):
    """靜默失敗是這支腳本歷史上最貴的 bug：上一版猜錯路徑編碼，門檻從此
    永遠不觸發，而且沒有人發現。搬進 hook 之後連 Bash 區塊都不會出現在
    人眼前，壞掉跟「還沒到門檻」長得一模一樣，所以一定要留下痕跡。"""
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


try:
    ev = json.loads(os.environ.get("EVENT_JSON") or "")
except Exception as e:
    log(f"事件 JSON 讀不到或不合法：{e}")
    sys.exit(0)

sid = ev.get("session_id") or ""
stamp = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"handoff-nudge-{sid}")

# PostCompact：compact 把 context 砍回去了，水位會重新漲上來，
# 那時候再講一次不是回音，是新的事實。
if os.environ["MODE"] == "--reset":
    try:
        os.remove(stamp)
    except FileNotFoundError:
        pass
    except OSError as e:
        log(f"reset 刪不掉 {stamp}：{e}")
    sys.exit(0)

path = ev.get("transcript_path") or ""
if not path or not os.path.exists(path):
    log(f"transcript_path 不存在：{path!r}（session {sid[:8]}）")
    sys.exit(0)

# 這個 session 已經 handoff 過（寫了 handoff_prompt.txt 或停放到 .handoff/<名字>.txt）就不再提醒：
# 實際發生過：剛寫完 handoff，同一個 Stop 又印「該收尾了」。
# compact 之後重新算：context 砍回去又漲上來，那時候再講一次是新的事實（跟 --reset 刪 stamp 同一個理由）。
import re
PROMPT_PATH = r"""(handoff_prompt|\.handoff/[^\s'"<>|;&/]+)\.txt"""
WRITES_PROMPT = re.compile(r"""(>|\btee\s+(-a\s+)?)\s*("[^"\n]*""" + PROMPT_PATH + r'''"|'[^'\n]*''' + PROMPT_PATH
                           + r"""'|[^\s'"<>|;&]*""" + PROMPT_PATH + r"\b)")
WRITE_PATH = re.compile(r"(^|/)" + PROMPT_PATH + "$")


def wrote_prompt(msg):
    for b in msg.get("content") or []:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        i = b.get("input") or {}
        if b.get("name") == "Bash" and WRITES_PROMPT.search(i.get("command") or ""):
            return True
        if b.get("name") == "Write" and WRITE_PATH.search(i.get("file_path") or ""):
            return True
    return False


last = None
handed = False
humans = 0  # 人打的 prompt 數（終端機或 remote-control 都是 origin.kind human）
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            # 先用字串篩：Stop hook 每一次回答結束都會跑，整份 json.loads 太貴。
            hint = ".txt" in line and ("handoff_prompt" in line or ".handoff/" in line)
            if '"kind":"human"' in line and '"type":"user"' in line:
                humans += 1
                continue
            if '"usage"' not in line and not hint and "compact_boundary" not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("isSidechain"):  # subagent 有自己的 context，算進來會嚴重低估
                continue
            if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
                handed = False
                continue
            m = d.get("message") or {}
            if hint and d.get("type") == "assistant" and wrote_prompt(m):
                handed = True
            u = m.get("usage")
            if u:
                last = u
except OSError as e:
    log(f"讀不到 transcript：{e}")
    sys.exit(0)

if handed:
    sys.exit(0)

if not last:
    # 實測（2026-09-21）：Stop 觸發的當下,這一輪的 usage 還沒寫進 transcript,
    # 所以全新 session 的第一輪算不出數字。這裡靜默放過,不記 log:
    # 門檻在 150K,到得了那裡的 session 早就有前幾輪的紀錄可以算,
    # 代價只是提醒晚一輪,而那一輪的差距遠小於門檻本身。
    sys.exit(0)

ctx = (last.get("input_tokens", 0)
       + last.get("cache_read_input_tokens", 0)
       + last.get("cache_creation_input_tokens", 0))
n1 = int(os.environ["NUDGE1"])
n2 = int(os.environ["NUDGE2"])
tier = 2 if ctx > n2 else 1 if ctx > n1 else 0
if not tier:
    sys.exit(0)

try:
    done = int(open(stamp).read().strip())
except Exception:
    done = 0
if tier <= done:
    sys.exit(0)

try:
    with open(stamp, "w") as fh:
        fh.write(str(tier))
except OSError as e:
    log(f"stamp 寫不進去，這一層下次會再提醒一次：{e}")

# ⛔ 訊息裡不放數字：要看數字跑 `bash context_tokens.sh`，或在 Claude Code 裡打 /context。
#    這句話唯一的工作是給出動詞和時機。
msg = ("⛔ 這個 session 已經很貴，現在收尾 → /handoff" if tier == 2
       else "⚠ 這個 session 該收尾了 → /handoff")
print(json.dumps({"systemMessage": msg}, ensure_ascii=False))
HOOKPY
  exit 0
fi

[ -d "$ROOT" ] || { echo "找不到 $ROOT —— 這不是 Claude Code 環境?"; exit 1; }

NUDGE1="$NUDGE1" NUDGE2="$NUDGE2" PEEK="${PEEK:-}" ROOT="$ROOT" WANT_CWD="$(pwd)" python3 - "${1:-}" <<'PY'
import json, os, sys, time

want_sid = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
root = os.environ["ROOT"]
want_cwd = os.environ["WANT_CWD"]
n1 = int(os.environ["NUDGE1"])
n2 = int(os.environ["NUDGE2"])
peek = bool(os.environ.get("PEEK"))


def cwd_of(path, max_lines=40):
    """讀前幾行拿 cwd。整份讀完很慢,而 cwd 在開頭就會出現。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("cwd"):
                    return d["cwd"]
    except OSError:
        pass
    return None


def candidates():
    """(mtime, path) 清單,只留 cwd 對得上的。"""
    # 第一猜:目前 Claude Code 的編碼規則(所有非英數 → '-')。猜中就省下全掃。
    slug = "".join(c if c.isalnum() else "-" for c in want_cwd)
    guesses = [os.path.join(root, slug)]
    dirs = [d for d in guesses if os.path.isdir(d)]
    if not dirs:
        dirs = [os.path.join(root, d) for d in os.listdir(root)
                if os.path.isdir(os.path.join(root, d))]
    out = []
    for d in dirs:
        for name in os.listdir(d):
            if not name.endswith(".jsonl"):
                continue
            p = os.path.join(d, name)
            if want_sid and name[:-6] != want_sid:
                continue
            if cwd_of(p) != want_cwd:
                continue
            try:
                out.append((os.path.getmtime(p), p))
            except OSError:
                continue
    return sorted(out, reverse=True)


cands = candidates()
if not cands:
    print(f"找不到 cwd = {want_cwd} 的 transcript。")
    print(f"  掃過:{root}")
    print("  若這個 session 剛開始,transcript 可能還沒寫入。")
    sys.exit(1)

mtime, path = cands[0]
stale_min = (time.time() - mtime) / 60
stem = os.path.basename(path)[:-6]

last = None
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except Exception:
        continue
    # subagent 的訊息也寫在同一個檔案裡,但它有自己的 context,
    # 拿它的 usage 會回報成一個遠小於真實值的數字。
    if d.get("isSidechain"):
        continue
    if d.get("sessionId") not in (None, stem):
        continue
    u = (d.get("message") or {}).get("usage")
    if u:
        last = u

if not last:
    print("這個 transcript 還沒有 usage 紀錄(session 剛開始)")
    sys.exit(1)

ctx = (last.get("input_tokens", 0)
       + last.get("cache_read_input_tokens", 0)
       + last.get("cache_creation_input_tokens", 0))
tier = 2 if ctx > n2 else 1 if ctx > n1 else 0

# 每個門檻只提醒一次。第二次講同一句話,只是在教人類忽略它。
# 狀態記在 /tmp,跟著 session 的 transcript id 走,機器重開就清掉,這樣才對。
stamp = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"handoff-nudge-{stem}")
try:
    done = int(open(stamp).read().strip())
except Exception:
    done = 0

print(f"context {ctx:,} tokens (門檻 {n1:,} / {n2:,})")
if tier > done:
    kb = ctx // 1000
    if tier == 2:
        print(f"  → ⛔ 轉述這一行給人類:「context 已經 {kb}K,這個 session 之後每一次 "
              f"call 都重讀這麼多。要收尾就打 /handoff。」然後繼續做事")
    else:
        print(f"  → ⚠ 轉述這一行給人類:「context {kb}K,換一個新 session 會便宜很多。"
              f"要收尾就打 /handoff。」然後繼續做事")
    print("     ⛔ 不要因為這個數字自己進 handing-off skill,決定權在人類")
    if not peek:
        try:
            open(stamp, "w").write(str(tier))
        except OSError:
            print("     ⚠ 寫不進 stamp,這個門檻下次會再提醒一次")
elif tier:
    print(f"  → 第 {tier} 級門檻已經提醒過了,不要再講第二次")
else:
    print("  → 還不用提醒,繼續做事")
if len(cands) > 1 and not want_sid:
    print(f"  ⚠ 同一個目錄有 {len(cands)} 份 transcript 的 cwd 都對得上,"
          f"取的是最近寫入的 {stem[:8]}…")
if stale_min > 5:
    print(f"  ⚠ 這份 transcript 已經 {stale_min:.0f} 分鐘沒有寫入 —— "
          f"可能不是目前這個 session。傳 session-id 參數可以指定。")
PY
