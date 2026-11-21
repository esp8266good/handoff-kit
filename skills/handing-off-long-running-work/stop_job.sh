#!/usr/bin/env bash
# stop_job.sh —— 停掉背景工作,而且**不會殺到自己**。
#
# ## 為什麼需要這支
#
# `pkill -f <pattern>` 幾乎每次都會殺掉執行它的那個 shell。機制:
# agent 的指令會被包成 `zsh -c 'eval ... pkill -f "myjob" ...'`,
# 那個 wrapper 的**命令列本身含有 pattern 字串**,而 `-f` 比對的正是完整命令列
# → pkill 匹配到自己 → 整個工具呼叫以 exit 143/144 中止,
#   而且**你不會知道目標到底停了沒**。
#
# 這支的作法:先把自己與所有祖先 PID 收集起來,從候選名單裡剔除,再殺。
# 不管 wrapper 怎麼包裝命令列,自己這一條 process 鏈永遠是安全的。
#
# ## 用法
#
#   bash stop_job.sh <pattern>              # 停掉,並回報結果
#   bash stop_job.sh <pattern> --dry-run    # 只列出會殺什麼,不動手
#   bash stop_job.sh <pattern> --term       # 用 SIGTERM(預設 SIGKILL)
#
# pattern 就是你會傳給 `pgrep -f` 的那個,通常是腳本檔名:
#   bash stop_job.sh run_sweep.sh
#
# ## 為什麼殺 process group 而不是單一 PID
#
# 背景 job 通常是 `bash wrapper.sh` 再 spawn `python train.py`。
# 只殺 wrapper 會留下真正在燒 GPU 的那個孤兒。`setsid` 起的 job 自成一個
# process group,所以殺 PGID 才會連子孫一起收掉。
set -u

PATTERN=${1:-}
[ -n "$PATTERN" ] || { echo "用法:bash stop_job.sh <pattern> [--dry-run] [--term]"; exit 2; }
shift
DRY=0; SIG=KILL
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --term)    SIG=TERM ;;
        *) echo "不認得的選項:$a"; exit 2 ;;
    esac
done

# ── 「自己」的定義:同一個 session(SID)裡的所有程序。這是整支腳本的重點。
#
# 為什麼是 SID 而不是「自己 + 祖先」:`$(pgrep ...)` 這種 command substitution
# 會 fork 一個 subshell,它**繼承父 shell 的完整命令列**(所以含 pattern),
# 而它是自己的**子**程序不是祖先 —— 用祖先鏈排不掉它,於是腳本會把自己
# fork 出來的 subshell 當成「殘留的目標」。2026-08-22 實測踩過。
#
# SID 這條線切得乾淨:自己、祖先、自己 fork 的 subshell 全都共用一個 SID;
# 而 detached job 是用 `setsid` 起的,**有自己的 SID**。
# (這也是為什麼交接一律要求 `setsid`:沒有它,目標與呼叫者在機器上無法區分。)
# macOS 的 ps 沒有 sid 這個欄位，改問 getsid
sid_of() {
    local s
    s=$(ps -o sid= -p "$1" 2>/dev/null | tr -dc '0-9')
    [ -n "$s" ] || s=$(python3 -I -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' "$1" 2>/dev/null)
    echo "$s"
}
MY_SID=$(sid_of $$)
[ -n "$MY_SID" ] || { echo "拿不到自己的 SID,不敢動手。"; exit 3; }

# ── 候選:pgrep -f 的結果扣掉自己這個 session
CANDIDATES=""
SAME_SID=""
for pid in $(pgrep -f -- "$PATTERN" 2>/dev/null); do
    sid=$(sid_of "$pid")
    # ⚠️ 空的 SID = 這個 PID 在 pgrep 抓到之後、我們查它之前就消失了。
    #    那幾乎一定是短命的 subshell(每個 $(...) 都會 fork 一個,而它繼承
    #    父 shell 的完整命令列,所以也含 pattern)。把「查不到」當成
    #    「不同 session」會讓腳本追殺自己的幽靈。2026-08-22 實測踩過:
    #    pattern 完全不存在時,腳本仍宣稱找到候選。
    [ -z "$sid" ] && continue
    if [ "$sid" = "$MY_SID" ]; then
        SAME_SID="$SAME_SID $pid"
        continue
    fi
    CANDIDATES="$CANDIDATES $pid"
done
CANDIDATES=$(echo "$CANDIDATES" | tr -s ' ' '\n' | grep -v '^$' || true)

if [ -z "$CANDIDATES" ]; then
    echo "沒有符合 '$PATTERN' 的背景程序。"
    # 誠實的邊界:若 pattern 只匹配到同 session 的東西,那可能是呼叫者自己
    # (正常),也可能是目標**沒有用 setsid 起**、跟呼叫者在同一個 session
    # (這種在機器上無法安全區分,不能盲殺)。
    if [ -n "$(echo "$SAME_SID" | tr -d ' ')" ]; then
        echo "  (有$(echo "$SAME_SID" | wc -w) 個同 session 的程序符合,已略過 ——"
        echo "   那通常是這支腳本自己的 shell。若目標**沒有用 setsid** 起,"
        echo "   它會跟呼叫者共用 session,無法安全區分:請改用 PID 直接 kill。)"
    fi
    exit 0
fi

echo "符合 '$PATTERN' 的程序:"
for pid in $CANDIDATES; do
    ps -o pid= -o pgid= -o etime= -o args= -p "$pid" 2>/dev/null | cut -c1-160
done

if [ "$DRY" -eq 1 ]; then
    echo "--dry-run:沒有動手。"
    exit 0
fi

# ── 殺 process group;PGID 等於自己這條鏈裡任何一個時退回殺單一 PID
PGIDS=$(for pid in $CANDIDATES; do ps -o pgid= -p "$pid" 2>/dev/null | tr -dc '0-9'; echo; done \
        | grep -v '^$' | sort -u)
for pgid in $PGIDS; do
    kill -"$SIG" -- -"$pgid" 2>/dev/null && echo "  已送 SIG$SIG 給 process group $pgid"
done

# ── 驗收:沒有驗證的「已停止」不是停止
#
# 兩個坑都在這裡:
#   1. 剛被 SIGKILL 的程序會短暫變成 zombie(state Z),pgrep 仍看得到 ——
#      直接判定會誤報「還有殘留」。要用 state 過濾掉。
#   2. 收屍需要一點時間,單次檢查會撞上競態。重試三次。
survivors() {
    local out="" pid st
    for pid in $(pgrep -f -- "$PATTERN" 2>/dev/null); do
        [ "$(sid_of "$pid")" = "$MY_SID" ] && continue
        st=$(ps -o stat= -p "$pid" 2>/dev/null | tr -dc 'A-Za-z' | cut -c1)
        [ "$st" = "Z" ] && continue          # zombie:已經死了,只是還沒被收屍
        [ -z "$st" ] && continue             # 已經不存在
        out="$out $pid"
    done
    echo "$out" | tr -s ' ' '\n' | grep -v '^$' || true
}

LEFT=""
for _ in 1 2 3; do
    sleep 1
    LEFT=$(survivors)
    [ -z "$LEFT" ] && break
done

if [ -z "$LEFT" ]; then
    echo "✓ 已全部停止(已排除自己這個 session 與 zombie)。"
else
    echo "⚠ 還有殘留:"
    for pid in $LEFT; do
        ps -o pid= -o pgid= -o stat= -o args= -p "$pid" 2>/dev/null | cut -c1-160
    done
    [ "$SIG" = "TERM" ] && echo "  這是 --term,改用預設的 SIGKILL 再跑一次。"
    exit 1
fi
