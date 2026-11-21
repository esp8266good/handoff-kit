#!/usr/bin/env bash
# 進度自檢模板：複製到專案後改四個地方：
#   1. cd 到專案根目錄
#   2. 「還活著嗎」：UNITS（systemd scope 的名稱 pattern）或 pgrep pattern
#   3. JOBS 清單：(標籤, 輸出檔, 目標筆數) 和有效性判準
#   4. 第 3 節的產出健檢
#
# 一支回答三個問題：還活著嗎／到哪了／有沒有東西壞掉。
# 人不必讀 log，agent 接手時也先跑這支，不信文件裡的數字。
#
# 預設只印「還沒做完或有問題」的，做完的只算個數；--full 才逐項列出。
# 為什麼：每多一批就往後加一節的狀態腳本，接手的人每次都要讀完十幾行已完成的東西（2026-10-05）。
#
# ★ 接手時先看第 3 節。log 裡的 DONE／ALLDONE 不算完成：OOM 之後外層 shell 照樣會印
#   （2026-10-08～10-09 四次）。完成＝有效產出數等於目標數。
set -u
cd "/path/to/project" || exit 1
FULL=0; [ "${1:-}" = --full ] && FULL=1

hr() { printf '%.0s─' {1..72}; echo; }

hr; echo "1. 還活著嗎"; hr
# 工作是用 systemd-run --user --scope 開的：列 unit 名稱的 pattern（空白分隔），看 scope 在不在。
# 不是的話用 pgrep。⚠ pattern 要能比對到 interpreter，否則 pgrep 會比對到這支腳本自己，
# 永遠顯示「還在跑」。
UNITS=""
ALIVE=0
if [ -n "$UNITS" ]; then
    for u in $UNITS; do
        m=$(systemctl --user list-units --type=scope --no-pager 2>/dev/null | grep -o -- "$u[^ ]*" | tr '\n' ' ')
        [ -n "$m" ] && { ALIVE=1; echo "  ✅ scope 在跑：$m"; }
    done
elif pgrep -f "bash .*run_queue" >/dev/null; then
    ALIVE=1; P=$(pgrep -f "bash .*run_queue" | head -1)
    echo "  ✅ 運行中（PID=${P}，已跑 $(ps -o etime= -p "$P" | tr -d ' ')）"
fi
if [ "$ALIVE" = 0 ]; then
    echo "  ⚠️ 沒在跑：是做完了還是中斷了？看下面的進度數字，不要看 log 最後一行。"
    # macOS 沒有 setsid
    echo "     續跑：$(command -v setsid >/dev/null && echo 'setsid ')nohup bash <佇列腳本> > tmp/queue.log 2>&1 < /dev/null &"
fi

hr; echo "2. 進度（只算「有輸出且無 error」的有效筆數）"; hr
# ★ 不能用 wc -l：失敗的 job 通常也會寫一筆記錄，行數會虛胖到目標值，
#   讓不完整的資料看起來像跑完了，而缺的往往不是隨機樣本。
# ★ 目標筆數寫「這次要跑的總數」，從工作清單算，不要抄別次 run 的有效數。
python3 - "$FULL" "$ALIVE" <<'PYEOF'
import json, os, sys, time
full, alive = sys.argv[1] == "1", sys.argv[2] == "1"
STALE_MIN = 20      # 行程在、輸出檔卻這麼久沒動就警告（卡住，或在白打 API）
JOBS = [
    ("job A", "tmp/out_a.jsonl", 636),
    ("job B", "tmp/out_b.jsonl", 1272),
]
done = valid_total = 0
for label, path, total in JOBS:
    n, exists = 0, os.path.exists(path)
    if exists:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("code") and not d.get("error"):     # ← 改成你的有效性判準
                n += 1
    valid_total += n
    if n >= total:
        done += 1
        if not full:
            continue
    notes = []
    if exists:
        age = int((time.time() - os.path.getmtime(path)) / 60)
        notes.append(f"{age} 分鐘前更新")
        if n == 0:
            notes.append("⚠ 檔案在但 0 筆有效：路徑、有效性判準、還是上游沒給輸入？")
        if alive and n < total and age > STALE_MIN:
            notes.append("⚠ 行程在但輸出沒動")
    else:
        notes.append("還沒有輸出檔")
    if not alive and n < total:
        notes.append("❌ 沒在跑也沒做完，先看這個 job 自己的 log，不要照上次的原因猜")
    pct = n / total * 100
    bar = "█" * int(pct / 5) + "·" * (20 - int(pct / 5))
    mark = "✅" if n >= total else "  "
    print(f"  {mark} {label:20s} {bar} {n:5d}/{total}  {pct:5.1f}%  {'；'.join(notes)}")
print(f"  做完 {done}/{len(JOBS)}" + ("" if full else "（做完的沒列，--full 逐項列出）"))
if valid_total == 0:
    print("  ⚠ 全部 0 筆有效結果：這不是「還沒跑」的樣子就是路徑或判準錯了，確認後再相信上面的表")
PYEOF

hr; echo "3. 產出健檢（跑完 ≠ 正確）"; hr
# 當掉的分析 script 也會留下檔案。只看「檔案存在」會把 traceback 當成結果。
found=0; ok=0
for t in tmp/analysis_*.txt; do
    [ -e "$t" ] || continue
    found=1
    if grep -q "Traceback (most recent call last)" "$t"; then
        echo "  ❌ $(basename "$t")：當掉了，別用它的數字"
    else
        ok=$((ok + 1)); [ "$FULL" = 1 ] && echo "  ✅ $(basename "$t")"
    fi
done
[ "$found" = 0 ] && echo "  ⚠ 0 個產出（還沒跑到，或 glob 寫錯）" || echo "  健檢 ✅ $ok 個"

hr; echo "4. 最近事件"; hr
tail -6 tmp/queue.log 2>/dev/null || echo "  （沒有 log）"
