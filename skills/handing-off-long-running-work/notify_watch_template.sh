#!/usr/bin/env bash
# ntfy 通知模板 —— 複製到專案根目錄後改四個地方:
#   1. TOPIC / LOG / CONSOLE / TOTAL_JOBS
#   2. counts():回傳「有效」完成數(不是 .done 檔數,見下)
#   3. summary():逐作業的一行摘要
#   4. 全部完工那則訊息裡的「判讀」與「接手 prompt」
#   5. UNITS（工作開在 systemd scope 時）和 on_all_done（完工後自動接著跑的下一步）
#   6. （選用）完工後要不要自動開 claude -p 寫判讀：見 auto_analyze，預設關
# 乾跑：DRY=1 POLL=1 bash notify_watch.sh（只印不送）；ALIVE_FILE=<檔> 用「檔案在不在」假裝 scope 活著。
#
# 這支存在的理由:交接的價值不在文件寫得多好,而在人知道「什麼時候該回來」。
# 沒有推播,一條跑完的 sweep 和一條卡死的 sweep 在外面看起來完全一樣。
#
# 獨立行程,不是 sweep 裡的 hook:bash 是逐段讀腳本的,編輯執行中的腳本會
# 弄壞它;分開才能重啟或砍掉通知而不動到工作本身。
#
# ⚠ ntfy topic 是公開 URL,知道網址的人都讀得到。訊息裡不要放密鑰、
#   內部主機名、或任何不能外流的資料。
set -u

NTFY=${NTFY:-https://ntfy.example.com/your-topic}
LOG=${LOG:-logs/sweep.log}
# 活性看「持續被寫入」的那個檔,不是佇列 log:佇列 log 每個作業只寫一行,
# 作業中途它可能已經半小時沒動,活著的工作會被判成停了。
CONSOLE=${CONSOLE:-logs/console}
STATE=${STATE:-logs/.notify_watch.state}
# 分母＝這次要跑的總單位數，從工作清單算。不要抄別次 run 的有效數：
# 2026-10-05 抄了另一個 judge 的 3999（它有 1 題 null），全標完顯示 4000/3999，看起來像錯。
TOTAL_JOBS=${TOTAL_JOBS:-4}
# 工作是用 systemd-run --user --scope 開的話，列 unit 名稱的 pattern（空白分隔）。
# 一個工作拆成兩個 scope 就兩個都列：全部不見才算死。2026-10-08 只看其中一個，
# 前半先跑完就誤報 urgent。留空＝只用 console mtime 判斷。
UNITS=${UNITS:-}
POLL=${POLL:-60}
QUIET_MIN=${QUIET_MIN:-12}

send() {  # title priority tags body
    if [ -n "${DRY:-}" ]; then echo "[DRY] $2｜$1｜$(echo "$4" | head -2 | tr '\n' ' ')"; return; fi
    local c
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
        -d "$4" "$NTFY") || c="失敗"
    # 啟動推播有沒有送到，看這行是不是 200
    echo "[$(date '+%F %T')] ntfy ${c}：$1"
}

# ★ 不能數 .done 或數行數:失敗的作業一樣會留下檔案,計數會虛胖到目標值,
#   讓不完整的資料看起來像跑完了。要數的是「旋鈕有生效 + 跑到最後一步 +
#   目標指標存在」的那些。
# ★ 也不能看 log 裡的 DONE／ALLDONE：OOM 或 CUDA error 之後，不檢查 exit code 的外層迴圈照樣會印
#   （2026-10-08～10-09 四次，例如 1192/1867 就標 ALLDONE）。counts 要和 check_progress.sh 數同一批檔。
# ★ 不要用 log 檔名的 glob 數：2026-10-05 有 2 個 run 是用舊檔名跑完的，計數永遠停在 58/60，
#   後面的自動步驟永遠不觸發。數輸出檔本身。
counts()  { your_summariser --count 2>/dev/null || echo 0; }
summary() { your_summariser 2>/dev/null; }

# 真的要讀 log 標記（例如看跑到哪個階段）時，只讀「這次開跑之後」的部分。log 是 append 的，
# 開頭可能留著別次工作的 ALLDONE：2026-10-08 新 watcher 一啟動就誤報完成。
# LAUNCH_MARK＝每次開跑第一行會出現的字（systemd-run 會印「Running as unit」）。
# Mac 沒有 tac
rev_lines() { awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' "$@"; }
since_launch() { rev_lines "$1" 2>/dev/null | sed "/${LAUNCH_MARK:-^Running as unit}/q" | rev_lines; }

# scope 還在不在。UNITS 沒設就回 2（不知道），交給下面的 console mtime 判斷。
scopes_alive() {
    if [ -n "${ALIVE_FILE:-}" ]; then [ -e "$ALIVE_FILE" ]; return; fi
    [ -n "$UNITS" ] || return 2
    local u
    for u in $UNITS; do
        systemctl --user list-units --type=scope --no-pager 2>/dev/null | grep -q -- "$u" && return 0
    done
    return 1
}

# 接力：全部完成後自動開下一步（標註、同步、彙整），人回來之前的空窗才不會浪費。
# 只放「跑過的會跳過」的指令；它失敗只記在 log，不擋完成通知。
on_all_done() { :; }    # 例：bash scripts/label_all.sh >> logs/label.log 2>&1

# 自動分析（選用，預設關）：全部完成後開一個 headless `claude -p` 讀結果、對照預先登記的門檻寫判讀。
# 要不要開由人決定，完工那一刻才看，所以跑到一半也能改主意：
#   開：touch .handoff/auto_analyze（檔案內容非空＝當成額外指示接在 prompt 後面）
#   關：rm .handoff/auto_analyze
# 也可以開跑時就決定：AUTO_ANALYZE=1 bash notify_watch.sh
# 完成通知先送，分析在之後跑（可能十幾分鐘），跑完再送一則；它失敗不影響完成通知。
AUTO_FLAG=${AUTO_FLAG:-.handoff/auto_analyze}
AUTO_LOG=${AUTO_LOG:-logs/auto_analyze.log}
AUTO_TOOLS=${AUTO_TOOLS:-"Read,Grep,Glob,Edit,Bash(./check_progress.sh:*),Bash(python:*),Bash(uv run:*),Bash(git status:*),Bash(git log:*),Bash(git diff:*)"}
auto_analyze() {
    [ -n "${AUTO_ANALYZE:-}" ] || [ -e "$AUTO_FLAG" ] || return 0
    local extra=""; [ -s "$AUTO_FLAG" ] && extra=$(cat "$AUTO_FLAG")
    if [ -n "${DRY:-}" ]; then echo "[DRY] auto_analyze 會啟動 claude -p（額外指示：${extra:-無}）"; return 0; fi
    echo "[$(date '+%F %T')] auto_analyze 啟動，輸出在 $AUTO_LOG"
    local out rc
    out=$(claude -p "背景工作全部跑完了（${TOTAL_JOBS}/${TOTAL_JOBS}）。先讀 handoff_prompt.txt 和它指到的追蹤文件，跑 ./check_progress.sh 確認產出完整，再拿結果對照文件裡預先登記的門檻（沒有登記門檻就照實寫，不要自己補一個），用繁體中文寫 10 行以內的判讀：數字表、過 / 沒過、照判讀規則下一步該做什麼。判讀寫在追蹤文件最上面，標題「自動判讀 $(date '+%F %H:%M')」。只改追蹤文件，不要 commit、不要 push、不要開新的工作。最後一段原樣重印那段判讀。${extra}" \
        --allowedTools "$AUTO_TOOLS" 2>&1); rc=$?
    { echo "===== $(date '+%F %T') exit $rc"; echo "$out"; } >> "$AUTO_LOG"
    # ⚠ ntfy topic 是公開 URL：只送判讀的最後 15 行，完整內容在追蹤文件和 $AUTO_LOG
    send "自動判讀$([ "$rc" -eq 0 ] && echo '完成 📝' || echo "失敗 ⚠ exit $rc")" default memo \
"$(echo "$out" | tail -n 15)"
}

# 接手 prompt 只有一份：專案根目錄的 handoff_prompt.txt（不進 git）。送出的那一刻才讀，
# 所以 watcher 啟動後還能改 prompt，不用重啟。推播到手機時手邊不會有 repo，
# 訊息本身要能直接複製貼進新 session。
handoff_prompt() { cat handoff_prompt.txt 2>/dev/null || echo "（handoff_prompt.txt 不見了：到專案目錄跑 ./check_progress.sh，再讀追蹤文件）"; }
# 最晚什麼時候會再收到通知（全部完成或警告）。過了還沒收到 = watcher 死了。
EXPECT_BY=${EXPECT_BY:-"<YYYY-MM-DD HH:MM>"}

echo "[$(date '+%F %T')] watcher 啟動,poll ${POLL}s,endpoint ${NTFY}"

# 首次啟動:把已完成的標記為已通知,改推一則「現在到哪了」。否則 watcher
# 的第一個動作是宣告它出生前就完成的作業,讀起來像剛剛的新進度。
if [ ! -f "$STATE" ]; then
    touch "$STATE"
    N=$(counts)
    [ "$N" -gt 0 ] && seq 1 "$N" >> "$STATE"
    send "watcher 已啟動 ($N/$TOTAL_JOBS)" low eyes \
"之後每完成一個作業通知一次,全部完工用 urgent。
最晚 ${EXPECT_BY} 會再收到通知；過了還沒收到就是 watcher 死了（例如這台重開機），跑 ./check_progress.sh。

$(summary)"
fi

while true; do
    N=$(counts)

    while [ "$N" -gt "$(wc -l < "$STATE")" ]; do  # lint-bash32: ok（-gt 比數字，空白不影響）
        wc -l < "$STATE" | awk '{print $1 + 1}' >> "$STATE"
        send "$N/$TOTAL_JOBS 個作業完成" default white_check_mark "$(summary)"
    done

    if [ "$N" -ge "$TOTAL_JOBS" ]; then
        if ! grep -q '^done$' "$STATE"; then
            echo "done" >> "$STATE"
            on_all_done || echo "[$(date '+%F %T')] on_all_done 失敗（exit $?），完成通知照送"
            # 這則是整支腳本的重點:它同時是「可以回來了」的訊號、判讀的依據、
            # 和新 session 的入口。三者缺一,收到通知的人還是得先開一輪
            # session 才知道發生什麼事。
            send "全部完成 ✅ 可以開新 session 接手" urgent tada \
"$TOTAL_JOBS/$TOTAL_JOBS 全部有效。

$(summary)

判讀（門檻預先登記,不要事後改）:
  · <結果 A> → <下一步>
  · <結果 B> → <下一步,含「不要做什麼」>

接手 prompt:
$(handoff_prompt)"
            auto_analyze
        fi
        echo "[$(date '+%F %T')] 全部完成,watcher 結束"
        exit 0
    fi

    # 死掉但沒跑完。這是最貴的失敗:沒人看的時候,停在 3/5 和還在跑的
    # 3/5 長得一模一樣。活性看 console mtime,不用 `pgrep -f <腳本名>` ——
    # 那會匹配到這支 watcher、編輯器、或任何引用到該名稱的 shell wrapper,
    # 永遠回報「還在跑」。
    # ⛔ 不要用 `find -newermt "-N minutes"`:有些系統的 `find` 是 **bfs**,
    #    它只吃 ISO 8601 絕對時間,相對時間直接回 "Invalid timestamp" →
    #    find 回空 → watcher 一啟動就宣告「停了」然後 exit。2026-08-22 踩過。
    #    `stat -c %Y`(Mac 退回 `stat -f %m`,順序不能反)不必擔心 find 的參數順序。
    # 先看 scope：數量沒到但 scope 全部不見＝提早結束，不用等 QUIET_MIN。
    # 2026-10-08 兩條生成撞 CUDA error 後 log 照樣印 ALLDONE，是靠「數量沒到、行程沒了」才發現。
    scopes_alive; SA=$?
    [ "$SA" -eq 0 ] && { grep -q '^seen$' "$STATE" || echo "seen" >> "$STATE"; }
    if [ "$SA" -eq 1 ] && grep -q '^seen$' "$STATE"; then
        if ! grep -q '^died$' "$STATE"; then
            echo "died" >> "$STATE"
            send "提早結束 ⚠ ${N}/${TOTAL_JOBS}" urgent rotating_light \
"scope（${UNITS}）都不見了，有效產出只有 ${N}/${TOTAL_JOBS}。log 最後一行寫 DONE 也不算數。

續跑（跑過的會跳過）:
  <開跑指令>

$(tail -n 5 "$LOG" 2>/dev/null)"
        fi
        echo "[$(date '+%F %T')] scope 不見,${N}/${TOTAL_JOBS},watcher 結束"
        exit 1
    fi

    NOW=$(date +%s); FRESH=0
    for f in "$CONSOLE"/*.log; do
        [ -f "$f" ] || continue
        M=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
        [ $(( (NOW - M) / 60 )) -lt "$QUIET_MIN" ] && FRESH=1
    done
    if [ "$FRESH" -eq 0 ]; then
        if ! grep -q '^stalled$' "$STATE"; then
            echo "stalled" >> "$STATE"
            send "停了但沒跑完 ⚠" urgent rotating_light \
"只有 ${N}/${TOTAL_JOBS} 個有效作業,而 ${CONSOLE} 已 ${QUIET_MIN} 分鐘沒有更新。

續跑（冪等,已完成的會跳過）:
  setsid nohup bash <佇列腳本> >> $LOG 2>&1 < /dev/null &

⚠ <哪些作業不能續跑,要先砍掉半成品目錄>

$(tail -n 5 "$LOG" 2>/dev/null)"
        fi
        echo "[$(date '+%F %T')] 偵測到停止,${N}/${TOTAL_JOBS},watcher 結束"
        exit 1
    fi

    sleep "$POLL"
done
