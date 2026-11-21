# Running mode: a job outlives the session

Everything here is in addition to the core steps in `SKILL.md`, and **only** for Running mode. In Wrap-up mode you send nothing: no ntfy, no watcher, no `check_progress.sh`. A push notification for a session that is simply ending is noise, and the human is right there reading your final message. The human cannot see a detached job; these artifacts are how they know when to come back.

## Before you leave

1. **Detach.** `setsid nohup <cmd> > <proj>/logs/x.log 2>&1 < /dev/null &` (macOS has no `setsid`: use `perl -e 'use POSIX; POSIX::setsid(); exec { $ARGV[0] } @ARGV or die "exec: $!"'` in its place, and no `sid` column in `ps`, so check `python3 -c 'import os; print(os.getsid(<pid>))'` instead). Verify with `ps -o pid,sid,tty,etime -p <pid>`: detached means `SID == PID` and `TTY = ?`. (PPID will not be 1 on systemd machines; orphans go to `systemd --user`.) Logs live in the project, never a session scratch dir. On a machine with systemd-oomd or a per-user memory limit, `setsid nohup` is not enough: launch each job in its own `systemd-run --user --scope`, and liveness becomes `systemctl --user list-units --type=scope`.
2. **Resume skips finished work.** Re-run the launch command now and watch it skip what is done.
3. **`check_progress.sh`.** Copy `check_progress_template.sh` into the project; one screen answering *alive / how far / anything broken*, with the validity check kept in section 3. By default it prints only what is unfinished or broken and counts the rest (`--full` lists everything); a script that grows a section per batch makes every later session read the finished ones. A session taking over reads section 3 before believing any completion marker.
4. **Watcher.** Copy `notify_watch_template.sh` and adapt its marked spots.
   - **Dry-run it before launch**: copy it into a `mktemp -d`, put a fake probe next to it that walks through running → one done → unreachable → all done, and run with `DRY=1 POLL=1` (prints the pushes instead of sending them). 2026-10-08 this caught a verdict that would have told the human to replace a healthy disk; an 18-hour wait is the wrong place to find that.
   - **It counts what `check_progress.sh` counts**: valid output files over the total number of units in the job list. Never a `DONE` / `ALLDONE` line, never a log-name glob, never a denominator copied from another run (see Traps).
   - **It also relays**: fill `on_all_done` with the next step that needs no human (labelling, sync, summary), so the hours before anyone returns are not wasted. Only commands that skip finished work.
   - **Auto-analysis is the human's switch**: `auto_analyze` (a headless `claude -p` that writes a verdict against the pre-registered thresholds) stays off by default; leave it off and never `touch` its flag yourself. Put both toggle lines (`touch .handoff/auto_analyze` / `rm .handoff/auto_analyze`) in the tracking doc and the final message, since the human may decide mid-run.
   - **Launch with `bash`**: `setsid nohup bash ./notify_watch.sh >> logs/notify_watch.log 2>&1 < /dev/null &`. `./notify_watch.sh` fails on a missing exec bit and only the log says so.
   - Done when its startup push has arrived (the log shows HTTP 200): a dead watcher is as silent as a quiet job.
5. **The startup push names a deadline**: "最晚 <time> 會再收到通知；沒收到就是 watcher 死了，跑 `./check_progress.sh`". If this machine reboots, the watcher dies with no message at all; the deadline is the only thing that tells the human.
6. **Commit** `check_progress.sh` and the watcher with the tracking doc (core step 4).

## Jobs that are not a local process

A SMART test inside a disk, a job on another host, a cloud run: there is no console log to watch and `pgrep` means nothing. Write one `probe.sh` that reads the remote state and prints one parseable line per unit; `check_progress.sh` and the watcher both call it, so they can never disagree. Liveness becomes "the progress value moved within N × the expected interval", not log mtime. Scripts that poll a remote host source `ssh_mux.sh` (one shared connection, plus `retry`) and exit when a key output is missing: several orchestrators each opening an ssh per minute got `Connection reset`, and a script without that check carried on with missing files (two cells wasted, 2026-10-07). Time one real unit of progress before quoting a finish time: the first estimate on 2026-10-08 was 14–18 h, the first real tick said 10 h.

## ntfy

Endpoint: `$NTFY`, a full topic URL such as `https://ntfy.sh/<hard-to-guess-topic>` or one on the human's own server. If `$NTFY` is unset and the human has not named one, ask once; without an endpoint, skip the watcher's pushes and say so in the final message. Anyone who guesses the topic can read it, so host aliases and private IPs are fine in messages; secrets, passwords, and tokens are not.

| Event | Priority | Carries |
|---|---|---|
| one job finished | `default` | That job's own numbers, not a mixed average |
| all done | `urgent` | Summary, the thresholds, **and the handoff prompt**, so the phone alone is enough to start the next session |
| died early | `urgent` | Which job and the last log lines. A queue stopped at 3/5 otherwise looks like one still working |

## Add to the handoff prompt

- **Meaning, not just progress**: which result makes it worth waiting, which makes it worth killing.
- **How to trim**: which parts of the queue can be dropped, with the exact relaunch command.

The watcher reads `handoff_prompt.txt` at send time (the template does), so you may refine the prompt after launching the watcher without restarting it.

## Traps

| Trap | Fix |
|---|---|
| `pkill -f <pattern>` kills the harness shell running it (its `sh -c` line contains the pattern), exit 143/144 | `bash <skill-dir>/stop_job.sh <pattern>`: it excludes your own session by SID |
| `pgrep -f name` for liveness matches wrappers, editors, the watcher | Judge liveness by the mtime of a continuously written console log |
| Queue log for liveness: one line per job, so it is stale mid-job | Watch the per-job console |
| Counting lines or `.done` files: failed jobs leave markers too | Count *valid* units (ran to the last step, metric present) |
| Trusting `DONE` / `ALLDONE` in a log: the outer shell prints it after an OOM or CUDA error because the loop never checks the exit code (four times in 2026-10-08/09: 1192/1867, 1968/2000, 17 of 55 runs missing, each marked ALLDONE) | Completion = the number of valid output files equals the total. The watcher alerts on "process gone, count short" |
| Reading a marker from an appended log: the first line still held another run's `ALLDONE`, and a new watcher announced completion on start | If a marker must be read, read only after the last launch line (`since_launch` in the watcher template) |
| Counting by log-file glob: two runs finished under an older file name, the count stayed at 58/60 and the follow-up step never fired | Count the output files themselves |
| One job split into two scopes, watcher treats "scope gone" as dead: the first half finishing raised an urgent alert | Dead = every listed unit gone and the count short (`UNITS` in the template) |
| A summary that prints nothing for a group with 0 results looks like "not run" | Print a warning line for 0 results; the template does |
| `with ThreadPoolExecutor() as ex:` around paid API calls: after an error `__exit__` runs every queued call before raising, for hours, with nothing collecting the output | `try/except` around the loop and `ex.shutdown(cancel_futures=True)`; the status script shows how many minutes ago each output file changed |
| A missing output explained by the last known cause ("OOM, re-running") when it was a float32 overflow that re-running repeats | Read that job's own log before writing a cause into the status or the doc |
| `cut -c` on Chinese log lines cuts bytes and prints garbage | Truncate with python, or not at all |
| `\| tail` / `\| head` on a running job: log stays empty | Redirect straight to a file; `python -u` |
| `find -newermt "-20 minutes"`: bfs rejects relative times, live jobs read as stalled | `stat -c %Y` against `date +%s` |
| Editing a running bash script: bash reads it incrementally | Stop, edit, relaunch (resume makes this safe) |
| Quoting a finish time from a toy input | Time one real unit first |
| Relying on in-session monitors | They die with the session; detached job + watcher + `check_progress.sh` is the contract |
| Editing source while a chained script runs: each later step is a fresh process that imports the half-edited code, so a "before" run silently measures "after" | Run baselines from a `git worktree` of the old commit, or let the chain finish before editing |
| A new worktree lacks gitignored files (`.env`, local config) and fails on first use | Symlink or copy them in when creating it; list the worktree as machine-local state |
