---
name: handing-off-long-running-work
description: Use when a session's work must continue somewhere else - wrapping up a session so a fresh one can pick it up (the `/handoff` command), background jobs (training, sweeps, batch eval, long test suites) that will outlive this session, or unfinished tasks the human asks to hand off. Also before launching a job detached, when the human is leaving a running job they will not wait on, or asks how to check progress themselves. Not for commands, edits, or scripts that finish in the session - never assess those for duration. Not for a job this session will stay and wait on, even a long one.
---

# Handing Off Work

The next session starts from git, not from this conversation. A handoff succeeds when that session can act within minutes without re-deriving anything. For every result, record the check that proves it is *good*, not just that it exists.

## Start here: one call, then few

```bash
bash ~/.claude/skills/handing-off-long-running-work/preflight.sh
```

It prints, in one call: time, branch, sha, `git status`, the existing prompt's stamp, parked prompts, tracking-doc candidates, the declared or detected self-test, and logs written in the last 10 minutes. It also gitignores `handoff_prompt.txt` and `.handoff/` if they are not. Do not re-run its checks by hand. Cost is context size × call count (21 calls at 445K ≈ 9.8M input tokens, 2026-10-07), so after it: write each file in one Write, and aim for 8 calls total.

## Modes

| Mode | Condition | Do |
|---|---|---|
| **Wrap-up** (default) | Nothing is running | The core steps. ⛔ No watcher, no ntfy, no `check_progress.sh` |
| **Running** | A job is running, or you are about to detach one | The core steps, plus [`RUNNING.md`](RUNNING.md) |

`/handoff` enters Wrap-up; decide from preflight's log line and the jobs you launched whether Running also applies, without asking. A free-text argument is the thing most likely to be missing: it goes in the tracking doc's first paragraph, in the human's words. If it says what the next session is for, keep the reasoning that bears on that task and turn the rest into pointers.

Enter this skill when the human asks, and (Running) before you detach a job, in the same turn. A large context is the human's call: a Stop hook tells them.

## Core steps

1. **Fold findings into the tracking doc**: the project's existing one, or the place its `CLAUDE.md` names (a gitignored `todo/` wins over committing). One doc per workstream, rewritten in place: never a new dated file per handoff. If preflight shows several candidates or the ⚠ dated-files line and `CLAUDE.md` names none, fold into the newest, `git rm` what it supersedes, and propose the `CLAUDE.md` line naming it. Include what was ruled out and why; delete what this session made stale. A fix you write down is applied in the same session: a noted batch-size fix left out of the runner ended another generation at 1644/1867 (2026-10-08).
2. **Run the self-test** from preflight. If it was only detected, say which you ran; once the human confirms, add `驗證：<command>` to `CLAUDE.md`. A state script answers *how far*, not *is it good*: do not pass one off as the other. A failure does not block the handoff: its command and ≤10 output lines go at the top of the doc, fixing it is the prompt's first action. Before calling it pre-existing, check it is not your own uncommitted edit.
3. **List machine-local state**: gitignored scripts, worktrees, data the resume uses, with keep or delete. A keep item must not stay under `/tmp`: a reboot clears it (2026-11-03 lost a replay comparator and two mutation scripts marked keep). Move it into the repo, or a gitignored dir in it, before listing it.
4. **Settle git**: one new commit with the doc, the tracked scripts the resume uses, and any `.gitignore` line preflight added (never `--amend`); or, if mid-change, paste `git status --short` into the doc. ⛔ Never neither.
5. **Check the doc against live state**: every "running / not running" line true now; every claim about what a script does or a repo lacks grepped first (a warning copied from the wrong script sent the next session building around it, 2026-10-09). Every "X is done / works / does not exist" line ends with `✅ <command that showed it>` or `⚠ 沒驗`.
6. **Write `handoff_prompt.txt`**, then stop. Do not start new work in this session.

## The prompt file

- First line `# 寫於 <preflight's now>，commit <sha>`, the sha taken with `git log -1 --format=%h` after step 4's commit, so it names the commit that contains the doc. Overwrite, never append, with Bash `cat > "<absolute path>/handoff_prompt.txt" <<'EOF'`, the path written out literally (double quotes keep a path with spaces in one piece): the Write tool refuses an existing file this session has not Read (a Read + second Write in 2 of 15 handoffs, 2026-10-16～18). Never print it in the terminal.
- **Park, don't overwrite, a prompt that is not yours**: if its stamp differs from this session's first message and this session did not carry out its tasks, move it to `.handoff/<its YYYYMMDD-HHMM>-<2–4 word slug>.txt`, adding under the stamp `# 已停放於 <now>；先跑 git log --oneline <its sha>..HEAD，內容可能過時`. If this session started from a parked file, delete it. This is the stash for "switched to a bug while the prompt still describes the old task".
- **Redact**: it is the next session's input and may go through public ntfy. Aliases and private IPs are fine; keys, tokens, passwords, personal data are not; name where a secret lives, never its value.
- **Final message**: the absolute path, `claude '照 @"<absolute path>" 接手'`, and one line per parked prompt with its own resume command. The double quotes after `@` are required: an unquoted `@` path stops at the first space, and the file is not attached (a `[research] <name>` directory, 4 of 4 takeovers, 2026-11-11～13). Nothing of the content. Not `$(cat …)`: that pastes the whole prompt into Claude Code's input history, and the `@` mention costs the same tokens (inlined at submit, no extra Read). Absolute, because `@` resolves against the cwd the new session starts in.

Contents, in order, as an entry point rather than a state dump:

1. **Where**: repo, branch, sha (or "uncommitted, see the doc"). Push state comes from preflight's `upstream:` line, not from the human saying "pushed": that word can predate this session's last commits (2026-11-03).
2. **First action**: the failing self-test, else the state check ("trust its output over the doc's numbers; do what does not depend on the difference, do not stop to ask").
3. **Now**: the next task and its acceptance bar; in Running, what runs and when it ends.
4. **Read only this**: at most 5 named units, not files (`grep -n '^## ' ROADMAP.md`，只讀 `## Round 3`; `store.py` 的 `add_answer`), each with why it cannot be skipped. End with: 讀完這些就開始做，不要先掃整個 repo。
5. **Thresholds**: pre-registered pass/fail or keep/kill numbers, spelled out.
6. **Hands off**: what must not be touched or re-run, and every pitfall hit this session as a ⛔ line with the working command (a quirk left only in notes killed 5 runners the next session, 2026-10-06). End each ⛔ line with its source: `（使用者原話）` only for what the human actually said, else `（經驗）`. The next session treats `（經驗）` lines as overridable defaults.
7. **Suggested skills**: which to invoke first and when; omit if none.

When the human is away for the next session, quote their authorization verbatim in **Where**, including any action they pre-authorized (restarting a production service, an irreversible decision) with its exact scope, and add no limits on deciding: a line like 「只寫建議，不能替使用者決定」 that they did not say turned 「完成所有能自主完成的實驗和決策」 into five undecided items and a session that stopped after one hour (2026-10-25).

## Traps

| Trap | Fix |
|---|---|
| "I'll commit after I see the result" | Commit before leaving; the result goes in the next commit |
| Waiting for a tidy stopping point | Wrap up at the first task boundary after the human asks; record what is half-done and which test proves it |
| Carrying on after writing the prompt | The handoff only pays off if this session ends |
