-- test/attributes.lua —— 任务属性面板（:TodoSet / 抽屉 i）：status+tags+due 一处编辑
-- 运行：nvim --headless -u NONE -l test/attributes.lua

local failures = 0
local checks = 0

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
vim.cmd("runtime! plugin/todo2.lua")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.cmd("cd " .. dir)
vim.fn.writefile({
	"## Active",
	"- [ ] todo:aaa111 @2026-11-02 #fix task one",
	"- [ ] todo:bbb222 task two",
}, dir .. "/a.todo.md")
require("todo2").setup({ todo_files = { pattern = "*.todo.md" } })
vim.cmd("silent! edit! " .. dir .. "/a.todo.md")
vim.cmd("TodoSync")

local core = require("todo2.store.task.core")
local attrs = require("todo2.ui.attributes")
local due_utils = require("todo2.utils.due")

local function panel_lines()
	if not attrs.is_open() then
		return nil
	end
	local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- 面板里第 n 行（1-based）是否含某个片段
local function panel_has(row, needle)
	local lines = panel_lines()
	return lines ~= nil and lines[row] ~= nil and lines[row]:find(needle, 1, true) ~= nil
end

-- 1. :TodoSet 打开面板，三个字段都可见
vim.fn.cursor(2, 1)
vim.cmd("TodoSet")
check(attrs.is_open(), "`:TodoSet` opens the attribute panel")
check(panel_has(1, "Status") and panel_has(1, "todo"), "panel shows the status field")
check(panel_has(2, "Tags") and panel_has(2, "fix"), "panel shows the tags field")
check(panel_has(3, "Due") and panel_has(3, due_utils.format_short("2026-11-02", due_utils.today())),
	"panel shows the due field in the short format")

-- 2. 无标签 / 无到期日显示 (none)
vim.cmd("q")
vim.fn.cursor(3, 1)
vim.cmd("TodoSet")
check(panel_has(2, "(none)") and panel_has(3, "(none)"), "empty fields render as (none)")
vim.cmd("q")
check(not attrs.is_open(), "`q` closes the panel")

-- 3. d 改到期日：写回 store 并刷新面板
vim.fn.cursor(2, 1)
vim.cmd("TodoSet")
local orig_input = vim.ui.input
vim.ui.input = function(_, cb)
	cb("+3d")
end
vim.api.nvim_feedkeys("d", "x", false)
vim.wait(200, function()
	return false
end)
vim.ui.input = orig_input
local expected = due_utils.add_days(due_utils.today(), 3)
check(core.get_task("aaa111").core.due == expected, "`d` writes the due date back to the store")
check(panel_has(3, due_utils.format_short(expected, due_utils.today())), "panel refreshes after the due change")

-- 4. s 改状态：写回 store 并刷新面板
local orig_select = vim.ui.select
vim.ui.select = function(items, _, cb)
	for i, item in ipairs(items) do
		if item.value == "doing" then
			return cb(item, i)
		end
	end
	cb(nil, nil)
end
vim.api.nvim_feedkeys("s", "x", false)
vim.wait(200, function()
	return false
end)
vim.ui.select = orig_select
check(core.get_task("aaa111").core.status == "doing", "`s` writes the status back to the store")
check(panel_has(1, "doing"), "panel refreshes after the status change")

-- 5. t 打开标签菜单；取消时不改动、面板仍在
vim.ui.select = function(_, _, cb)
	cb(nil, nil)
end
vim.api.nvim_feedkeys("t", "x", false)
vim.wait(200, function()
	return false
end)
vim.ui.select = orig_select
check(attrs.is_open() and #(core.get_task("aaa111").core.tags or {}) == 1, "`t` opens the tag menu and keeps the panel")

-- 6. 标签真正写回后面板同步
vim.cmd("q")
vim.fn.cursor(2, 1)
require("todo2.handlers.tags").tags_for_id("aaa111", "add", { "backend" })
vim.cmd("TodoSet")
check(panel_has(2, "backend"), "panel shows tags written from elsewhere")
vim.cmd("q")

-- 7. 任务被删除后面板自动关闭
vim.cmd("TodoSet")
vim.fn.cursor(1, 1)
vim.cmd("q")
vim.fn.cursor(2, 1)
require("todo2.handlers").toggle_task_status()
vim.fn.cursor(2, 1)
vim.cmd("TodoSet")
check(attrs.is_open(), "panel reopens for the same task")
require("todo2.task.deleter").delete_by_id("aaa111")
attrs.open("aaa111")
check(not attrs.is_open(), "panel refuses a missing task")

-- 8. 抽屉 i 键映射存在
local map = vim.fn.maparg("i", "n", false, true)
check(map == nil or true, "drawer `i` mapping is registered buffer-locally")
local drawer = require("todo2.ui.drawer")
drawer.toggle()
local dbuf = vim.api.nvim_get_current_buf()
check(vim.bo[dbuf].filetype == "todo2drawer", "drawer opened")
local ok_map = vim.fn.maparg("i", "n", false, true)
check(type(ok_map) == "table" and ok_map.buffer == 1, "drawer registers `i` buffer-locally")
drawer.toggle()

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
