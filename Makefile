# todo2.nvim —— 开发用快捷命令（不参与运行时）
#
#   make test           跑全部测试
#   make test calendar  只跑名字匹配的测试
#   make lint           luacheck
#   make check          测试 + lint（CI 跑的就是这个）
#   make docs           重新生成 doc/tags

NVIM ?= nvim
LUACHECK ?= luacheck
PATTERNS := $(filter-out $@,$(MAKECMDGOALS))

.PHONY: test lint check docs helptags

test:
	@./scripts/test.sh $(PATTERNS)

lint:
	@$(LUACHECK) lua plugin test mcp examples

check: lint test

docs:
	@$(NVIM) --headless -u NONE -c "set rtp+=$(CURDIR)" -c "helptags doc" -c q
	@echo "doc/tags regenerated"

%:
	@:
