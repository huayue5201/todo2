-- 抽屉里的日期入口：C = 月历浮窗点日期写入截止日；u = 三格面板贴抽屉底部。
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
local due_utils = require("todo2.utils.due")
local core = require("todo2.store.task.core")

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
local today = due_utils.today()
local ty, tm = tonumber(today:sub(1, 4)), tonumber(today:sub(6, 7))
local dy, dm = tm == 12 and ty + 1 or ty, tm == 12 and 1 or tm + 1
local due = string.format("%04d-%02d-15", dy, dm)
local due_label = os.date("%B %Y", os.time({ year = dy, month = dm, day = 15, hour = 12 }))
local today_label = os.date("%B %Y", os.time({ year = ty, month = tm, day = 15, hour = 12 }))

local f = actions.create_todo_file("drawer")
local a = actions.create_task({ content = "带到期日的任务", path = f.path })
local b = actions.create_task({ content = "没有到期日的任务", path = f.path })
check("create tasks", a and a.id and b and b.id)
do
	local r, err = actions.set_due(a.id, due)
	check("set due", r ~= nil and r.due == due, err)
end

local function buf_of(filetype)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == filetype then
			return buf
		end
	end
	return nil
end

local function win_of(filetype)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == filetype then
			return win
		end
	end
	return nil
end

local function text_of(buf)
	if not buf then
		return ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function line_of(needle)
	local w = win_of("todo2drawer")
	local buf = w and vim.api.nvim_win_get_buf(w) or 0
	for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if l:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function close_drawer()
	if win_of("todo2drawer") then
		drawer.toggle()
		vim.wait(300, function()
			return false
		end)
	end
end

local function open_drawer_on(needle)
	close_drawer()
	drawer.toggle()
	vim.wait(300, function()
		return false
	end)
	local l = line_of(needle)
	if not l then
		return false
	end
	vim.api.nvim_win_set_cursor(win_of("todo2drawer"), { l, 0 })
	return true
end

local function stored_due(id)
	local task = core.get_task(id)
	return task and task.core and task.core.due or nil
end

-- 1) C 在有 due 的任务上 → 月历浮窗，落在 due 所在月
check("drawer open on due task", open_drawer_on("带到期日的任务"))
feed("C")
vim.wait(800, function()
	return buf_of("todo2duepicker") ~= nil
end)
local picker = buf_of("todo2duepicker")
check("C opens the date picker", picker ~= nil)
check("picker shows the due month", text_of(picker):find(due_label, 1, true) ~= nil, text_of(picker):match("‹.-›"))
check("picker previews the due date", text_of(picker):find("→  " .. due, 1, true) ~= nil)

-- 2) <CR> 不改动已有 due，直接写回同一个值并关闭
feed("<CR>")
vim.wait(500, function()
	return buf_of("todo2duepicker") == nil
end)
check("CR closes the picker", buf_of("todo2duepicker") == nil)
check("CR keeps the same due", stored_due(a.id) == due, stored_due(a.id))

-- 3) 移动一天再 <CR> → due 变成下一天
open_drawer_on("带到期日的任务")
feed("C")
vim.wait(800, function()
	return buf_of("todo2duepicker") ~= nil
end)
check("picker takes focus", vim.api.nvim_get_current_win() == win_of("todo2duepicker"))
feed("l")
vim.wait(200, function()
	return false
end)
feed("<CR>")
vim.wait(500, function()
	return buf_of("todo2duepicker") == nil
end)
check("moving then CR writes the next day", stored_due(a.id) == due_utils.add_days(due, 1), stored_due(a.id))

-- 4) x 清除 due
open_drawer_on("带到期日的任务")
feed("C")
vim.wait(800, function()
	return buf_of("todo2duepicker") ~= nil
end)
feed("x")
vim.wait(500, function()
	return buf_of("todo2duepicker") == nil
end)
check("x clears the due date", stored_due(a.id) == nil, stored_due(a.id))

-- 5) 没有 due 的任务 → 落在今天所在月
check("drawer open on plain task", open_drawer_on("没有到期日的任务"))
feed("C")
vim.wait(800, function()
	return buf_of("todo2duepicker") ~= nil
end)
check("no due starts on today's month", text_of(buf_of("todo2duepicker")):find(today_label, 1, true) ~= nil)
feed("<CR>")
vim.wait(500, function()
	return buf_of("todo2duepicker") == nil
end)
check("CR on today sets today", stored_due(b.id) == today, stored_due(b.id))

-- 6) 文件头（不是任务行）→ 不开面板，也不报错
close_drawer()
drawer.toggle()
vim.wait(300, function()
	return false
end)
vim.api.nvim_win_set_cursor(win_of("todo2drawer"), { 1, 0 })
feed("C")
vim.wait(400, function()
	return false
end)
check("file header does nothing", buf_of("todo2duepicker") == nil)

-- 7) u 的三格面板贴在抽屉底部（relative = win，锚在抽屉窗口）
vim.api.nvim_win_set_cursor(win_of("todo2drawer"), { line_of("没有到期日的任务") or 2, 0 })
feed("u")
vim.wait(500, function()
	return buf_of("todo2due_panel_field") ~= nil or win_of("todo2due_panel_field") ~= nil
end)
local drawer_win = win_of("todo2drawer")
local panel_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
	local cfg = vim.api.nvim_win_get_config(win)
	if cfg.relative == "win" and drawer_win and cfg.win == drawer_win then
		panel_win = win
	end
end
check("u panel is anchored to the drawer window", panel_win ~= nil)
if panel_win then
	local cfg = vim.api.nvim_win_get_config(panel_win)
	local drawer_height = vim.api.nvim_win_get_height(drawer_win)
	check("u panel sits at the drawer bottom", cfg.row >= drawer_height - 9, cfg.row)
end
feed("<Esc>")
feed("<Esc>")

local panel = require("todo2.ui.due_panel")
panel.close()
drawer.toggle()
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-drawer-cal-proj"), "rf")
vim.fn.delete(projdir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
