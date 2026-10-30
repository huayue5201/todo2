-- 抽屉里的日历入口（C）：定位到当前任务的到期日；无到期日/文件头 → 今天。
-- 运行：XDG_DATA_HOME=/tmp/todo2-drawer-cal-xdg nvim --headless -u NONE -l test/drawer_calendar.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-drawer-cal-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-drawer-cal-proj"), "rf")

require("todo2").setup({})

local actions = require("todo2.ai.actions")
local drawer = require("todo2.ui.drawer")
local calendar = require("todo2.ui.calendar")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

-- 到期日取「下个月 15 号」，无论今天几号都跨月，能验证是不是真定位了
local today = require("todo2.utils.due").today()
local ty, tm = tonumber(today:sub(1, 4)), tonumber(today:sub(6, 7))
local dy, dm = tm == 12 and ty + 1 or ty, tm == 12 and 1 or tm + 1
local due = string.format("%04d-%02d-15", dy, dm)
local due_label = os.date("%B %Y", os.time({ year = dy, month = dm, day = 15, hour = 12 }))

local f = actions.create_todo_file("drawer")
local a = actions.create_task({ content = "带到期日的任务", path = f.path })
local b = actions.create_task({ content = "没有到期日的任务", path = f.path })
check("create tasks", a and a.id and b and b.id)
do
	local r, err = actions.set_due(a.id, due)
	check("set due", r ~= nil and r.due == due, err)
end

local function calendar_buf()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "todo2calendar" then
			return buf
		end
	end
	return nil
end

local function drawer_shown()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "todo2drawer" then
			return true
		end
	end
	return false
end

local function cal_text()
	local buf = calendar_buf()
	if not buf then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function line_of(needle)
	for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if l:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function open_drawer_on(needle)
	drawer.toggle()
	vim.wait(300, function()
		return false
	end)
	local l = line_of(needle)
	if not l then
		return false
	end
	vim.api.nvim_win_set_cursor(0, { l, 0 })
	return true
end

-- 1) C 在有 due 的任务上 → 日历开着，且月份是 due 所在月
check("drawer open on due task", open_drawer_on("带到期日的任务"))
vim.api.nvim_feedkeys("C", "x", false)
vim.wait(800, function()
	return calendar_buf() ~= nil
end)
check("C opens the calendar", calendar_buf() ~= nil)
check("C closes the drawer", not drawer_shown())
check("calendar lands on the due month", cal_text():find(due_label, 1, true) ~= nil, cal_text():match("[A-Z][a-z]+ %d%d%d%d"))

-- 2) 选中的日期就是 due 那天：<CR> 进当日列表能看到该任务
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
vim.wait(300, function()
	return cal_text():find("带到期日的任务", 1, true) ~= nil
end)
check("selected day is the due day", cal_text():find("带到期日的任务", 1, true) ~= nil)

calendar.close()
vim.wait(300, function()
	return false
end)

-- 3) 没有 due 的任务 → 今天
check("drawer open on plain task", open_drawer_on("没有到期日的任务"))
vim.api.nvim_feedkeys("C", "x", false)
vim.wait(800, function()
	return calendar_buf() ~= nil
end)
local today_label = os.date("%B %Y", os.time({ year = ty, month = tm, day = 15, hour = 12 }))
check("no due falls back to today", cal_text():find(today_label, 1, true) ~= nil, cal_text():match("[A-Z][a-z]+ %d%d%d%d"))

-- 4) 文件头（不是任务行）→ 也不报错，落到今天
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
vim.wait(200, function()
	return false
end)
drawer.toggle()
vim.wait(300, function()
	return false
end)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("C", "x", false)
vim.wait(800, function()
	return calendar_buf() ~= nil
end)
check("file header opens the calendar too", calendar_buf() ~= nil)
check("file header → current month", cal_text():find(today_label, 1, true) ~= nil)

calendar.close()
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-drawer-cal-proj"), "rf")
vim.fn.delete(projdir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
