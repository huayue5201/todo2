#!/bin/sh
# 一条命令完成「提交 + 同步运行时副本」。
#   ./sync.sh "feat: xxx"      # 全部改动一起提交
#   ./sync.sh                  # 自动用 "chore: sync <时间>" 当消息
#
# 同步由 .githooks/post-commit 完成（git config core.hooksPath .githooks）。

set -e

cd "$(dirname "$0")"

if [ "$(git config core.hooksPath 2>/dev/null)" != ".githooks" ]; then
	git config core.hooksPath .githooks
	echo "[todo2] 已启用 git hooks（core.hooksPath=.githooks）"
fi

if [ -z "$(git status --porcelain)" ]; then
	echo "[todo2] 没有需要提交的改动"
	exit 0
fi

msg="$*"
[ -n "$msg" ] || msg="chore: sync $(date '+%Y-%m-%d %H:%M')"

git add -A
git commit -q -m "$msg"
git --no-pager log --oneline -1
