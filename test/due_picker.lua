-- 月历点选浮窗（ui/date_picker.lua）的纯逻辑与键位行为。
-- 运行：XDG_DATA_HOME=/tmp/todo2-due-picker-xdg nvim --headless -u NONE -l test/due_picker.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-due-picker-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-due-picker-proj"), "rf")

require("todo2").setup({})
vim.cmd("runtime! plugin/todo2.lua")

local actions = require("todo2.ai.actions")
local picker = require("todo2.ui.date_picker")
local core = require("todo2.store.task.core")
local text = require("todo2.utils.text")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

local f = actions.create_todo_file("picker")
local t = actions.create_task({ content = "picker 任务", path = f.path })
check("create task", t and t.id)
check("set due", (actions.set_due(t.id, "2026-03-31")) ~= nil)

local function buf()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "todo2datepicker" then
			return b
		end
	end
	return nil
end

local function lines()
	local b = buf()
	return b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or {}
end

local function preview()
	for _, l in ipairs(lines()) do
		if l:find("→", 1, true) then
			return vim.trim(l)
		end
	end
	return ""
end

local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function stored_due()
	local task = core.get_task(t.id)
	return task and task.core and task.core.due or nil
end

-- 纯函数：末尾整周都在下个月的行要被裁掉
do
	-- 行数 = 标题 + 星期 + 周行 + 预览 + 折行后的提示
	local function rows(date, width)
		return #picker.build_lines(date, width) - (2 + 1 + #picker.hint_lines(width))
	end
	-- 2026-03：3/30-31 落在第 6 行，仍有本月日子 → 6 行都保留
	check("march keeps six rows", rows({ year = 2026, month = 3, day = 31 }, 40) == 6)
	-- 2027-02：2/1 是周一，正好 4 整周，第 5 行全是 3 月 → 裁掉
	check("february drops the all-out trailing week", rows({ year = 2027, month = 2, day = 1 }, 40) == 4,
		rows({ year = 2027, month = 2, day = 1 }, 40))

	-- 窄窗口：提示必须折行，任何一行都不能超出内容宽度（否则文字被顶出边框）
	for _, width in ipairs({ 20, 26, 40, 60 }) do
		local too_wide = nil
		for _, line in ipairs(picker.build_lines({ year = 2026, month = 3, day = 31 }, width)) do
			if text.width(line) > width then
				too_wide = line
				break
			end
		end
		check("lines never overflow at width " .. width, too_wide == nil, too_wide)
	end
	check("narrow width wraps hints onto more lines", #picker.hint_lines(20) > #picker.hint_lines(80),
		#picker.hint_lines(20) .. " vs " .. #picker.hint_lines(80))
end

-- 打开：预填 due、预览写的是同一天
picker.open_for(t.id)
vim.wait(200, function()
	return false
end)
check("picker opens", buf() ~= nil)
check("title is the due month", lines()[1]:find("March 2026", 1, true) ~= nil, lines()[1])
check("preview shows the due date", preview():find("2026-03-31", 1, true) ~= nil, preview())

-- L 翻到下个月：3-31 → 4-30（日被夹住）
feed("L")
vim.wait(200, function()
	return false
end)
check("L goes to next month", lines()[1]:find("April 2026", 1, true) ~= nil, lines()[1])
check("day is clamped to the month length", preview():find("2026-04-30", 1, true) ~= nil, preview())

-- h 退一天
feed("h")
vim.wait(150, function()
	return false
end)
check("h moves one day back", preview():find("2026-04-29", 1, true) ~= nil, preview())

-- j 前进一周
feed("j")
vim.wait(150, function()
	return false
end)
check("j moves one week forward", preview():find("2026-05-06", 1, true) ~= nil, preview())

-- H 翻回上个月
feed("H")
vim.wait(150, function()
	return false
end)
check("H goes to previous month", lines()[1]:find("April 2026", 1, true) ~= nil, lines()[1])

-- <Esc> 取消：store 不变
feed("<Esc>")
vim.wait(300, function()
	return buf() == nil
end)
check("Esc closes", buf() == nil)
check("Esc leaves the task untouched", stored_due() == "2026-03-31", stored_due())

-- t 跳到今天再 <CR> 写入
picker.open_for(t.id)
vim.wait(200, function()
	return false
end)
-- 与 <leader>mvc 月历同一套隔离：窗口无任何装饰栏，buffer 关掉各插件的开关
do
	local b = buf()
	local w = vim.fn.bufwinid(b)
	local function wopt(name)
		return vim.api.nvim_get_option_value(name, { win = w })
	end
	check("picker: no number column", wopt("number") == false)
	check("picker: no signcolumn", wopt("signcolumn") == "no")
	check("picker: no statuscolumn", wopt("statuscolumn") == "")
	check("picker: no winbar", wopt("winbar") == "")
	check("picker: no cursorline", wopt("cursorline") == false)
	check("picker: no wrap", wopt("wrap") == false)
	check("picker: buf completion off", vim.b[b].completion == false)
	check("picker: indent guides off", vim.b[b].miniindentscope_disable == true)
	check("picker: treesitter-context off", vim.b[b].treesitter_context_disable == true)
	check("picker: marked as plugin float", vim.b[b].todo2_float == true)
end
feed("t")
vim.wait(150, function()
	return false
end)
local today = require("todo2.utils.due").today()
check("t jumps to today", preview():find(today, 1, true) ~= nil, preview())
feed("<CR>")
vim.wait(300, function()
	return buf() == nil
end)
check("CR writes today", stored_due() == today, stored_due())

vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-due-picker-proj"), "rf")
vim.fn.delete(projdir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
