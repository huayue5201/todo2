#!/usr/bin/env bash
# 跑 test/ 下的全部 headless 测试。
#
# 每个测试都用独立的 XDG_DATA_HOME / XDG_STATE_HOME / XDG_CACHE_HOME，
# 否则 store 里的残留事实会让测试互相污染（会看到「偶发失败」）。
#
# 用法：
#   ./scripts/test.sh              # 全部
#   ./scripts/test.sh calendar due # 只跑名字里含 calendar / due 的
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

NVIM_BIN="${NVIM_BIN:-nvim}"
TMP_ROOT="${TMPDIR:-/tmp}/todo2-test"
rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

# nvim-store3 的位置：环境变量 > dev 兄弟目录 > pack 目录里已安装的副本
store3="${TODO2_STORE3_DIR:-}"
if [ -z "$store3" ]; then
	for cand in "../nvim-store3" $HOME/.local/share/nvim/site/pack/*/*/nvim-store3; do
		if [ -d "$cand" ]; then store3="$cand"; break; fi
	done
fi
rtp_args=()
if [ -n "$store3" ]; then
	rtp_args+=(--cmd "set runtimepath^=$(cd "$store3" && pwd)")
else
	echo "warning: nvim-store3 not found; set TODO2_STORE3_DIR to point at it" >&2
fi

files=()
if [ "$#" -gt 0 ]; then
	for pattern in "$@"; do
		while IFS= read -r f; do files+=("$f"); done < <(ls test/*"$pattern"*.lua 2>/dev/null)
	done
else
	while IFS= read -r f; do files+=("$f"); done < <(ls test/*.lua 2>/dev/null)
fi

if [ "${#files[@]}" -eq 0 ]; then
	echo "no test files matched: $*" >&2
	exit 1
fi

pass=0
failed=()

for f in "${files[@]}"; do
	name="$(basename "$f" .lua)"
	xdg="$TMP_ROOT/$name"
	mkdir -p "$xdg/cache" "$xdg/state" "$xdg/data"

	out=$(XDG_DATA_HOME="$xdg/data" \
		XDG_STATE_HOME="$xdg/state" \
		XDG_CACHE_HOME="$xdg/cache" \
		"$NVIM_BIN" --headless "${rtp_args[@]}" -u NONE -l "$f" 2>&1)
	code=$?

	if [ "$code" -eq 0 ]; then
		pass=$((pass + 1))
		printf '  ok   %s\n' "$name"
	else
		failed+=("$name")
		printf '  FAIL %s (exit %d)\n' "$name" "$code"
		printf '%s\n' "$out" | tail -12 | sed 's/^/       /'
	fi
done

printf '\n%d passed, %d failed, %d total\n' "$pass" "${#failed[@]}" "${#files[@]}"
if [ "${#failed[@]}" -gt 0 ]; then
	printf 'failed: %s\n' "${failed[*]}"
	exit 1
fi
