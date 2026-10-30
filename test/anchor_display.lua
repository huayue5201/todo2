-- test/anchor_display.lua —— 锚点状态的显示口径：只区分「可信」与「需要处理」
-- stale（未校验）是「还没去看」，不属于需要用户处理的异常，因此不产生徽章。
-- 运行：nvim --headless -u NONE -l test/anchor_display.lua

local failures, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if cond then
		print("PASS " .. msg)
	else
		failures = failures + 1
		print("FAIL " .. msg)
	end
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/../nvim-store3")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.cmd("cd " .. dir)
require("todo2").setup()

local viewer = require("todo2.task.viewer")
local core = require("todo2.store.task.core")

local function task(state)
	return { id = "x", core = { content = "t" }, verification = state and { state = state } or nil }
end

check(viewer.anchor_badge(task(nil)) == "", "no verification record -> no badge")
check(viewer.anchor_badge(task(core.ANCHOR.STALE)) == "", "stale (not verified yet) -> no badge")
check(viewer.anchor_badge(task(core.ANCHOR.OK)) == "", "ok -> no badge")
check(viewer.anchor_badge(task(core.ANCHOR.LOST)) == "  ⚠ anchor lost", "lost -> warning badge")

-- 展示口径必须与 code_render / drawer 使用同一个判断入口
check(core.is_anchor_lost(task(core.ANCHOR.LOST)) == true, "is_anchor_lost is the single judgment entry")
check(core.is_anchor_lost(task(core.ANCHOR.STALE)) == false, "stale is not treated as lost")

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
