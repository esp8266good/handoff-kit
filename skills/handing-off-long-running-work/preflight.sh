#!/usr/bin/env bash
# handoff 一開始跑一次，把所有唯讀檢查塞進同一個 tool call。
# 為什麼：handoff 的成本 ≈ context 大小 × call 數（445K × 21 call ≈ 9.8M input token，2026-10-07），
# 字數不是重點，call 數才是。
# 唯一會寫的東西：handoff_prompt.txt 和 .handoff/ 沒被 ignore 時補進專案的 .gitignore。
# 用法：bash <skill-dir>/preflight.sh [project root，預設 git root 或 pwd]
set -u
root=${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
cd "$root" || exit 1

echo "now: $(date '+%F %H:%M')   root: $root"

if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "git: $(git branch --show-current 2>/dev/null || echo detached) @ $(git log -1 --format=%h 2>/dev/null || echo no-commit)   stash: $(git stash list | wc -l | tr -d " ")"
  # push 到哪裡以這行為準，不照使用者說的「pushed」推算（9a9928b6 把 21:45 推的 02f831d 寫成「已 push 到 129d704」）
  if up=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
    echo "upstream: $up @ $(git log -1 --format=%h "$up")，還沒 push 的 commit $(git rev-list --count "$up"..HEAD) 個"
  else
    echo "upstream: 沒有"
  fi
  st=$(git status --short)
  n=$(printf '%s' "$st" | grep -c . || true)
  echo "status: $n 個檔有變動"
  [ "$n" -gt 0 ] && printf '%s\n' "$st" | head -30
  [ "$n" -gt 30 ] && echo "  …還有 $((n-30)) 個"
  for p in handoff_prompt.txt .handoff/; do
    if ! git -c core.excludesFile=/dev/null check-ignore -q "$p"; then  # 全域 ignore 不會跟到別台機器
      [ -s .gitignore ] && [ -n "$(tail -c1 .gitignore)" ] && echo >> .gitignore
      echo "$p" >> .gitignore
      echo "ignore: $p 原本沒被 ignore，已加進 .gitignore"
    fi
  done
else
  echo "git: 不是 git repo"
fi

if [ -f handoff_prompt.txt ]; then
  echo "prompt（前 5 行）:"; head -5 handoff_prompt.txt | sed 's/^/  /'
else
  echo "prompt: 沒有"
fi
if compgen -G '.handoff/*.txt' >/dev/null; then
  echo "parked:"
  for f in .handoff/*.txt; do echo "  $f  $(head -1 "$f")"; done
fi

docs=$(ls -d NEXT.md STATUS.md HANDOFF.md TODO.md docs/NEXT.md docs/STATUS.md 2>/dev/null | tr '\n' ' ')
echo "tracking doc: ${docs:-沒有}"
# todo/ 是資料夾：只報資料夾名，agent 會自己挑或另開新檔（pig-agri，2026-10-18），所以逐檔列出
if [ -d todo ]; then
  echo "todo/（新的在前）:"
  ls -t todo/*.md 2>/dev/null | head -8 | while read -r f; do
    echo "  $f  $(wc -l < "$f" | tr -d ' ') 行  $(date -r "$f" '+%m-%d %H:%M')"
  done
fi
# 一次交接一份新檔（docs/handoff-日期.md）的前例會被照抄：pig-agri 兩個月累積 14 份，一天開 4 份
dated=$(ls -t docs/handoff-*.md docs/handoff/*.md handoff-*.md HANDOFF-*.md docs/*-handoff*.md 2>/dev/null)
nd=$(printf '%s' "$dated" | grep -c . || true)
if [ "$nd" -ge 2 ]; then
  echo "⚠ 一次一檔的交接文件 $nd 份，最新：$(printf '%s\n' "$dated" | head -3 | tr '\n' ' ')"
  echo "  ⛔ 不要再開新的。這次改寫最新那份，或併進上面的 tracking doc；被取代的舊檔 git rm"
fi
if [ -f CLAUDE.md ]; then
  grep -nE '驗證[:：]|todo/|交接|tracking|不要進 ?git' CLAUDE.md | head -8 | sed 's/^/  CLAUDE.md:/'
fi

declared=$(grep -hE '^\s*[-*]?\s*驗證[:：]' CLAUDE.md 2>/dev/null | head -1)
if [ -n "$declared" ]; then
  echo "self-test（宣告的）: $declared"
else
  cand=""
  for f in test.sh selftest.sh scripts/test.sh; do [ -f "$f" ] && cand+="./$f "; done
  grep -qE '^test:' Makefile 2>/dev/null && cand+="make test "
  grep -q '"test"' package.json 2>/dev/null && cand+="npm test "
  { [ -f pytest.ini ] || grep -qs '\[tool.pytest' pyproject.toml || compgen -G 'tests/test_*.py' >/dev/null; } && \
    cand+="$([ -x .venv/bin/python ] && echo .venv/bin/python || echo python3) -m pytest "
  compgen -G 'tests/*.sh' >/dev/null && cand+="$(ls tests/*.sh | tr '\n' ' ')"
  echo "self-test（沒宣告，偵測到）: ${cand:-沒有}"
fi

live=$(find . -maxdepth 3 -name '*.log' -mmin -10 -not -path './.git/*' 2>/dev/null | head -5 | tr '\n' ' ')
echo "10 分鐘內有寫入的 log: ${live:-沒有}"
[ -f check_progress.sh ] && echo "有 check_progress.sh（Running 模式的狀態腳本）"
exit 0
