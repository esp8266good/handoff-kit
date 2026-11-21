# source 這支：同一台機器的 ssh／scp／rsync 共用一條連線，另外給一個 retry。
# 為什麼：幾支背景腳本各自每分鐘 ssh 一次，對方的 sshd 會開始 Connection reset；
# 沒有檢查的腳本就拿著缺的檔案往下跑（2026-10-07 白跑兩格）。
# 只在 source 這支的腳本裡生效，不改 ~/.ssh/config。
SSH_MUX_OPTS=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%C" -o ControlPersist=15m -o ConnectTimeout=20)
ssh() { command ssh "${SSH_MUX_OPTS[@]}" "$@"; }
scp() { command scp "${SSH_MUX_OPTS[@]}" "$@"; }
rsync() { command rsync -e "ssh ${SSH_MUX_OPTS[*]}" "$@"; }
# retry <指令…>：失敗就等一下再試，最多 RETRY_N 次（預設 5）。全部失敗回 1，呼叫的人要自己 exit：
#   retry rsync -a host:out/labels.jsonl tmp/ || exit 1
#   [ "$(wc -l < tmp/labels.jsonl)" -ge "$N" ] || { echo "標籤檔行數不夠"; exit 1; }
retry() {
    # 區域變數加底線：bash 是動態作用域，被 retry 呼叫的 function 看得到這裡的 local。
    local _i _n=${RETRY_N:-5} _w=${RETRY_WAIT:-10}
    for _i in $(seq 1 "$_n"); do
        "$@" && return 0
        echo "[$(date '+%F %T')] 第 $_i/$_n 次失敗：$*" >&2
        [ "$_i" -lt "$_n" ] && sleep $((_i * _w))
    done
    return 1
}
