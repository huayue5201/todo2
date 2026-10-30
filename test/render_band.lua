-- 行尾元数据带（`● ↻10-30 · 11-02`）+ 行内 @date 隐藏的回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-band-xdg nvim --headless -u NONE -l test/render_band.lua
--
-- 要点：
--   * 文件文本不动，到期日仍然紧跟 `<status>:<id>`；
--   * 展示层把 due 挪到行尾，和「最近改动时间」并排；
--   * 行内 @date 平时隐藏；只有光标压在那几个字符上才显出原文（列级显形）。

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-band-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
local dir = vim.fn.expand("~/.todo-files/todo2-band-proj")
vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")

require("todo2").setup({})

local due_utils = require("todo2.utils.due")
local time_utils = require("todo2.utils.time")
local format = require("todo2.utils.format")
local task_virt = require("todo2.render.task_virt")
local conceal = require("todo2.render.conceal")
local constants = require("todo2.constants")
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

local function band_of(parts)
	local text = {}
	for _, p in ipairs(parts) do
		text[#text + 1] = p[1]
	end
	return table.concat(text)
end

---------------------------------------------------------------------
-- 1) 短日期格式
---------------------------------------------------------------------
local this_year = os.date("%Y")
local other_year = tostring(tonumber(this_year) + 1)

check("due short: same year → MM-DD", due_utils.format_short(this_year .. "-11-02") == "11-02", due_utils.format_short(this_year .. "-11-02"))
check("due short: other year keeps YYYY-MM-DD", due_utils.format_short(other_year .. "-11-02") == other_year .. "-11-02")
check("due short: invalid → empty", due_utils.format_short("2026-02-31") == "")
check("time short: same year → MM-DD", time_utils.format_short_date(os.time()) == os.date("%m-%d"), time_utils.format_short_date(os.time()))
check("time short: nil → empty", time_utils.format_short_date(nil) == "")

---------------------------------------------------------------------
-- 2) 行尾元数据带：due + 最近改动同组
---------------------------------------------------------------------
local function fake_task(opts)
	return {
		id = opts.id or "bd0001",
		core = {
			status = opts.status or "todo",
			due = opts.due,
			tags = {},
		},
		timestamps = {
			created = os.time({ year = 2020, month = 1, day = 1, hour = 12 }),
			updated = os.time({ year = tonumber(this_year), month = 3, day = 4, hour = 12 }),
		},
	}
end

local with_due = band_of(task_virt.build_status(fake_task({ due = this_year .. "-11-02" })))
check("band shows due", with_due:find("11-02", 1, true) ~= nil, with_due)
check("band shows updated time with ↻", with_due:find("↻03-04", 1, true) ~= nil, with_due)
check("band puts the time before the due date", with_due:find("↻03%-04 · 11%-02") ~= nil, with_due)
check("band keeps status icon", with_due ~= "" and not with_due:find("·.*·"), with_due)

local no_due = band_of(task_virt.build_status(fake_task({})))
check("no due → no separator", no_due:find("·", 1, true) == nil, no_due)
check("no due → still shows time", no_due:find("↻03-04", 1, true) ~= nil, no_due)

local done = band_of(task_virt.build_status(fake_task({ due = this_year .. "-11-02", status = "completed" })))
check("terminal state drops the ↻ prefix", done:find("↻", 1, true) == nil, done)
check("terminal state still shows due", done:find("11-02", 1, true) ~= nil, done)

---------------------------------------------------------------------
-- 3) 行内 @date 隐藏（非光标行）/ 显形（光标行）
---------------------------------------------------------------------
local ns_due = constants.ns("due_conceal")
local function due_marks(buf)
	local marks = vim.api.nvim_buf_get_extmarks(buf, ns_due, 0, -1, { details = true })
	local concealed = 0
	for _, m in ipairs(marks) do
		if m[4] and m[4].conceal == "" then
			concealed = concealed + 1
		end
	end
	return concealed
end

local path = dir .. "/main.todo.md"
vim.fn.writefile({
	"## Active",
	"- [ ] todo:bd0001 @" .. this_year .. "-11-02 有到期的任务",
	"- [ ] todo:bd0002 没有到期的任务",
	"- [ ] todo:bd0003 @" .. this_year .. "-12-01 另一条有到期的任务",
}, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.wait(2000, function()
	local ok, t = pcall(core.get_task, "bd0001")
	return ok and t ~= nil
end, 50)

local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- 光标不在任何任务行 → 两条 due 都隐藏
conceal.apply_smart_conceal(buf, { 2, 3, 4 })
check("due concealed on both rows", due_marks(buf) == 2, due_marks(buf))

-- 光标移到第一条任务的行首（不在 due 段上）：仍然隐藏
vim.api.nvim_win_set_cursor(0, { 2, 0 })
conceal.apply_line_conceal(buf, 2)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check("line-start cursor keeps the date concealed", due_marks(buf) == 2, due_marks(buf))

-- 光标水平移到 due 段上：只有这一段显形
local mk_e = select(2, format.get_mark_position(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]))
vim.api.nvim_win_set_cursor(0, { 2, mk_e })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check("cursor on the date reveals the raw date", due_marks(buf) == 1, due_marks(buf))

-- 同一行内把光标挪回正文：又隐藏
vim.api.nvim_win_set_cursor(0, { 2, #vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check("moving off the date conceals it again", due_marks(buf) == 2, due_marks(buf))

-- 光标下移到第二条：上一条已隐藏，两条都隐藏
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check("leaving the row conceals it again", due_marks(buf) == 2, due_marks(buf))

-- 关掉 conceal_due 就全部显形
-- setup() 幂等，运行期改配置走 config.set
require("todo2.config").set("conceal_due", false)
conceal.apply_smart_conceal(buf, { 2, 3, 4 })
check("conceal_due=false keeps the inline date", due_marks(buf) == 0, due_marks(buf))

-- 文件文本始终没被改动
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check("file text keeps @date after the mark", lines[2] == "- [ ] todo:bd0001 @" .. this_year .. "-11-02 有到期的任务", lines[2])

vim.fn.delete(dir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
