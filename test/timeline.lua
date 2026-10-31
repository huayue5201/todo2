-- 时间线视图（ui/timeline.lua）：纯排版逻辑 + 打开/关闭行为。
-- 运行：XDG_DATA_HOME=/tmp/todo2-timeline-xdg nvim --headless -u NONE -l test/timeline.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-timeline-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-timeline-proj"), "rf")

require("todo2").setup({})
vim.cmd("runtime! plugin/todo2.lua")

local actions = require("todo2.ai.actions")
local timeline = require("todo2.ui.timeline")
local model = require("todo2.ui.calendar.model")
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

local function has(lines, pattern)
	for _, l in ipairs(lines) do
		if l:find(pattern) then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------
-- 1) 纯排版：一段区间画成条，点画成一个标记
---------------------------------------------------------------------
local monday = { year = 2026, month = 10, day = 26 } -- 周一
check("monday fixture", model.weekday(monday.year, monday.month, monday.day) == 2) -- 周日=1

-- 第 11 个「字符」（不是字节）：左侧 "  ● 10-27 " 是 10 个显示字符
local function bar_of(line)
	return vim.fn.strcharpart(line, 10, 7)
end

local commits = {
	{
		item = { id = "tl0001", content = "区间任务", tags = { "backend" } },
		from = "2026-10-27",
		to = "2026-10-29",
		title = "区间任务",
		hl = "TodoTime",
	},
	{
		item = { id = "tl0002", content = "单日任务" },
		from = "2026-10-28",
		to = "2026-10-28",
		title = "单日任务",
		hl = "TodoDueSoon",
	},
}
local points = { { item = { id = "tl0003", content = "被碰过的标记" }, day = "2026-10-30", title = "被碰过的标记" } }

local lines, rows = timeline.build_lines("week", monday, commits, points, 100)

check("title has range", has(lines, "Timeline · week · 2026%-10%-26 → 2026%-11%-01"))
check("header counts", has(lines, "2 commitments · 1 marks touched"))
check("interval row exists", has(lines, "区间任务"))
check("interval bar is 3 cells", (function()
	for i, l in ipairs(lines) do
		if l:find("区间任务") then
			-- 条从第 2 天（10-27）到第 4 天（10-29）
			local bar = bar_of(l)
			return bar == "░███░░░", bar
		end
	end
	return false
end)())
check("single day bar is 1 cell", (function()
	for _, l in ipairs(lines) do
		if l:find("单日任务") then
			local bar = bar_of(l)
			return bar == "░░█░░░░", bar
		end
	end
	return false
end)())
check("point row has marker", (function()
	for _, l in ipairs(lines) do
		if l:find("被碰过的标记") then
			-- 点用空格铺底（不是 ░，避免看起来像一条区间条）
			return bar_of(l) == "    ▪  ", bar_of(l)
		end
	end
	return false
end)())
check("rows map back to items", (function()
	for i, l in ipairs(lines) do
		if l:find("区间任务") then
			return rows[i] and rows[i].id == "tl0001"
		end
	end
	return false
end)())
check("no overflow", (function()
	for _, l in ipairs(lines) do
		if text.width(l) > 100 then
			return false, text.width(l)
		end
	end
	return true
end)())
check("hint line", has(lines, "%] next · %[ prev"))

---------------------------------------------------------------------
-- 2) 月视图：整月天数
---------------------------------------------------------------------
local month_lines = timeline.build_lines("month", { year = 2026, month = 2, day = 1 }, {}, {}, 120)
check("month title", has(month_lines, "Timeline · month · 2026%-02%-01 → 2026%-02%-28"))
check("empty period message", has(month_lines, "nothing scheduled or touched"))

---------------------------------------------------------------------
-- 3) 打开/关闭 + 真实数据落行
---------------------------------------------------------------------
local f = actions.create_todo_file("timeline")
local a = actions.create_task({ content = "跨天区间任务", path = f.path })
local b = actions.create_task({ content = "只有开始日", path = f.path })
check("create tasks", a and a.id and b and b.id)
require("todo2.handlers.datefield").set_by_id("start", a.id, "2026-10-27")
require("todo2.handlers.datefield").set_by_id("due", a.id, "2026-10-29")
require("todo2.handlers.datefield").set_by_id("start", b.id, "2026-10-28")

timeline.open({ range = "week", date = monday })
local buf = timeline._state.buf
check("timeline opened", buf ~= nil and vim.api.nvim_buf_is_valid(buf))
check("buffer filetype", vim.bo[buf].filetype == "todo2timeline")
local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check("real interval drawn", has(content, "跨天区间任务"))
check("real planned drawn", has(content, "只有开始日"))
check("span glyph present", has(content, "█"))

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(100)
check("q closes", timeline.is_open() == false)

print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
if fails > 0 then
	vim.cmd("cquit 1")
end
vim.cmd("qa!")
