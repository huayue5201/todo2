-- test/entry.lua —— `:Todo` 统一入口（抽屉 / help / 子命令转发 / 补全）
-- 运行：nvim --headless -u NONE -l test/entry.lua

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
vim.fn.writefile({ "## Active", "- [ ] task one", "- [ ] task two", "- [ ] task three" }, dir .. "/a.todo.md")
require("todo2").setup({ todo_files = { pattern = "*.todo.md" } })

local function drawer_open()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "todo2drawer" then
			return true
		end
	end
	return false
end

-- 1. 无参数 → 抽屉；再执行一次关闭
check(pcall(vim.cmd, "Todo") and drawer_open(), "`:Todo` opens the drawer")
check(pcall(vim.cmd, "Todo") and not drawer_open(), "`:Todo` again closes the drawer")

-- 2. help
check(pcall(vim.cmd, "Todo help") and vim.bo.filetype == "help", "`:Todo help` opens :h todo2")
vim.cmd("helpclose")

-- 3. 子命令转发（带参数）
check(pcall(vim.cmd, "Todo calendar 2026-11") and vim.bo.filetype == "todo2calendar",
	"`:Todo calendar 2026-11` dispatches to :TodoCalendar")
vim.cmd("close")

-- 4. 子命令转发保留行范围
vim.cmd("edit " .. dir .. "/a.todo.md")
local ok_range = pcall(vim.cmd, "2,3Todo del")
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
check(ok_range and #lines == 2 and lines[2]:match("task three") ~= nil, "`:Todo del` forwards a line range")

-- 5. 未知子命令报错
check(not pcall(vim.cmd, "Todo nosuch"), "unknown subcommand is rejected")

-- 6. 补全来自已注册命令，且含 help
local comp = vim.fn.getcompletion("Todo ", "cmdline")
local has_del, has_help, has_calendar = false, false, false
for _, item in ipairs(comp) do
	if item == "del" then
		has_del = true
	elseif item == "help" then
		has_help = true
	elseif item == "calendar" then
		has_calendar = true
	end
end
check(has_del and has_help and has_calendar, "completion lists subcommands and `help`")

-- 7. 分组命令已注册，且 deprecated 旧名不进补全
local all = vim.api.nvim_get_commands({})
check(all.TodoFile and all.TodoView and all.TodoTask and all.TodoGit, "group commands are registered")
local hidden = 0
for _, item in ipairs(comp) do
	if item == "new" or item == "float" or item == "cycle" or item == "reconcile" then
		hidden = hidden + 1
	end
end
check(hidden == 0, "group members are not listed as `:Todo` subcommands")
local legacy_commands = { "TodoNew", "TodoCycle", "TodoReconcile", "TodoFloat", "SmartPreview", "TodoPromote", "TodoToggleSel" }
local still_there = {}
for _, name in ipairs(legacy_commands) do
	if all[name] then
		still_there[#still_there + 1] = name
	end
end
check(#still_there == 0, "removed flat commands are gone: " .. table.concat(still_there, ", "))

-- 8. 分组二级补全与用法提示
local sub_comp = vim.fn.getcompletion("Todo file ", "cmdline")
check(vim.tbl_contains(sub_comp, "new") and vim.tbl_contains(sub_comp, "delete"), "group completion lists subcommands")

local notes = {}
vim.notify = function(msg)
	notes[#notes + 1] = tostring(msg)
end
vim.cmd("TodoView")
check(#notes == 1 and notes[1]:find("usage", 1, true) ~= nil, "group without a subcommand prints usage")
notes = {}
vim.cmd("TodoView nope")
check(#notes == 1 and notes[1]:find("no such subcommand", 1, true) ~= nil, "group rejects unknown subcommands")

-- 9. 嵌套转发：:Todo view preview → 浮动 TODO 视图
vim.cmd("silent! edit! " .. dir .. "/a.todo.md")
check(pcall(vim.cmd, "Todo view preview"), "`:Todo view preview` dispatches to the nested command")
vim.cmd("silent! close")

-- 10. bang 合并：:TodoStatus! 等同于 :TodoCycle
local core = require("todo2.store.task.core")
vim.fn.writefile({ "## Active", "- [ ] todo:aaa111 task one", "- [ ] todo:bbb222 task two" }, dir .. "/c.todo.md")
vim.cmd("silent! edit! " .. dir .. "/c.todo.md")
vim.cmd("TodoSync")
vim.fn.cursor(2, 1)
local status_before = core.get_task("aaa111").core.status
vim.cmd("TodoStatus!")
local status_after = core.get_task("aaa111").core.status
check(status_after ~= status_before, "`:TodoStatus!` cycles the status (" .. status_before .. " → " .. status_after .. ")")

-- 11. 行范围合并：:TodoToggle 批量切换
vim.fn.writefile({ "## Active", "- [ ] todo:ccc333 a one", "- [ ] todo:ddd444 a two", "- [ ] todo:eee555 a three" }, dir .. "/b.todo.md")
vim.cmd("silent! edit! " .. dir .. "/b.todo.md")
vim.cmd("TodoSync")
vim.cmd("2,3TodoToggle")
local t1, t2, t3 = core.get_task("ccc333"), core.get_task("ddd444"), core.get_task("eee555")
local one = (t1 and t1.core.status) or "nil"
local two = (t2 and t2.core.status) or "nil"
local three = (t3 and t3.core.status) or "nil"
check(
	one == "completed" and two == "completed" and three == "todo",
	"`:TodoToggle` honors a line range"
)

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
