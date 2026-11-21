# handoff-kit：Claude Code 的 `/handoff`

一個 session 做到一半要換手（context 太大、要下班、背景 job 會跑好幾個小時）時，打 `/handoff`。
Claude 會把進度整理進專案的追蹤文件、跑 self-test、commit，最後寫一份 `handoff_prompt.txt`。
下一個 session 讀那一份就能直接開工，不用從頭摸索 repo。

## 裝了什麼

| 東西 | 位置 | 做什麼 |
|---|---|---|
| `/handoff` 指令 | `~/.claude/commands/handoff.md` | 收尾的入口，可以帶一句話：`/handoff 下次先修登入` |
| `handing-off-long-running-work` skill | `~/.claude/skills/handing-off-long-running-work/` | 收尾的規則，加上幾支 script：`preflight.sh`（一次印出 git 狀態、既有的交接檔、self-test）、背景 job 用的 `check_progress` / `notify_watch` 模板、`stop_job.sh` |
| 兩個 hook | `~/.claude/settings.json` 的 `Stop`、`PostCompact` | context 超過 150K token 提醒「該收尾了」，超過 300K 提醒「已經很貴」；寫過 handoff 或 compact 之後重新算 |

hook 只提醒，不會自己收尾：要不要換 session 由你決定。

## 安裝（Ubuntu）

需要 `bash`、`git`、`python3`（Ubuntu 預設都有）。

```bash
git clone <這個 repo 的網址> ~/handoff-kit
bash ~/handoff-kit/install.sh
```

- 重跑一次就是更新，跑幾次結果都一樣。
- 不想動 `settings.json`：`bash install.sh --no-hooks`。
- 移除：`bash install.sh --uninstall`（`settings.json` 只拿掉這裡加的兩個 hook，你自己的設定不動）。
- 改 `settings.json` 前會先備份成 `settings.json.bak-<時間>`。原本就有同名的 skill 或指令，會搬到 `~/.claude/handoff-kit-backup/<時間>/`。

裝完要**重開** Claude Code：CLI 開新的 session；VS Code 關掉 Claude 分頁再開。

## CLI 和 VS Code extension

兩邊讀的都是 `~/.claude`，所以裝一次兩邊都有。

| 功能 | CLI | VS Code extension |
|---|---|---|
| hook（收尾提醒） | ✅ | ✅ 官方文件寫 `~/.claude/settings.json`（含 hooks）由 extension 和 CLI 共用 |
| `/handoff` 指令和 skill | ✅ | ⚠ 文件沒寫清楚 extension 是否載入 `~/.claude/commands`、`~/.claude/skills` 裡的自訂項目，請照下面驗證 |
| 接手 | `claude '照 @"<路徑>/handoff_prompt.txt" 接手'` | 開新對話，輸入 `照 @"<路徑>/handoff_prompt.txt" 接手` |

**在 VS Code 驗證一次（1 分鐘）**：在 Claude 面板輸入 `/`，看清單裡有沒有 `handoff`。

- 有：照常用。
- 沒有：改打「用 handing-off-long-running-work skill 收尾」，效果一樣；或在 VS Code 的終端機裡跑 `claude`，CLI 一定有。

## 用法

```text
/handoff
/handoff 下次先把 flaky 的 test_upload 修掉
```

收尾完 Claude 會給你一行接手指令，複製到新的 session 就好。

- 專案裡的 `handoff_prompt.txt` 和 `.handoff/` 會自動加進 `.gitignore`。
- 舊的交接檔還沒處理完又要交接時，舊的會停放在 `.handoff/` 底下，不會被覆蓋。

### 背景 job（訓練、sweep、長測試）

job 會在 session 結束後繼續跑時，skill 會多做幾件事：

- 確認 job 真的脫離 session 在跑
- 在專案裡放一支 `check_progress.sh` 讓你自己查進度
- 可以放一個 watcher，跑完或掛掉時推通知到手機

推通知用 [ntfy](https://ntfy.sh)：

1. 手機裝 ntfy app，訂閱一個別人猜不到的 topic。
2. 把 `export NTFY=https://ntfy.sh/<你的 topic>` 加進 `~/.bashrc`。

沒設 `NTFY` 的話，Claude 會先問你，或略過推播。topic 是公開的，知道網址的人都讀得到，所以訊息裡不會放密碼和 token。

### 調整提醒門檻

script 讀環境變數 `NUDGE1`、`NUDGE2`（預設 150000、300000）。最穩的改法是直接改 hook 那一行：

```json
"command": "NUDGE1=200000 NUDGE2=400000 bash ~/.claude/skills/handing-off-long-running-work/context_tokens.sh --hook 2>/dev/null || true"
```

重跑 `install.sh` 不會蓋掉你改過的這一行：已經有這個 hook 就不會再加。

## 測試

```bash
bash tests/context-tokens.sh   # 收尾提醒的 hook
bash tests/install.sh          # 安裝、重裝、移除，都在拋棄式 HOME 裡跑，不碰你的 ~/.claude
```

## 文字為什麼中英混

skill 本體是英文（給模型讀），它叫 Claude 寫的戳記和提醒是中文（給人讀）。
規則後面括號裡的日期，是那條規則當初是在哪次出事後加的，留著讓你判斷那條規則還適不適用。

## License

MIT，見 `LICENSE`。
