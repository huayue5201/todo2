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

print("")
if failures == 0 then
	print("ALL PASS (" .. checks .. " checks)")
else
	print(failures .. " FAILED of " .. checks)
	os.exit(1)
end
