-- 行尾元数据带（`● ↻10-30 · 11-02`）+ 渲染只动 checkbox 的回归测试（headless，自包含）。
-- 运行：XDG_DATA_HOME=/tmp/todo2-band-xdg nvim --headless -u NONE -l test/render_band.lua
--
-- 要点：
--   * 文件文本不动，行尾元数据块（`@id @created @due #tag`）原样可读；
--   * 展示层把 due 放进行尾元数据带，和「最近改动时间」并排；
--   * conceal 只把 checkbox 换成状态图标，终态删除线不覆盖元数据块。

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
local todo_icon = vim.trim((require("todo2.ui.status").get("todo") or {}).icon or "")
check("band has no status icon (checkbox column already shows it)", todo_icon ~= "" and not with_due:find(todo_icon, 1, true), with_due)
local with_icon = band_of(task_virt.build_status(fake_task({}), {}, { icon = true }))
check("icon only when asked for it", with_icon:find(todo_icon, 1, true) ~= nil, with_icon)

local no_due = band_of(task_virt.build_status(fake_task({})))
check("no due → no separator", no_due:find("·", 1, true) == nil, no_due)
check("no due → still shows time", no_due:find("↻03-04", 1, true) ~= nil, no_due)

local done = band_of(task_virt.build_status(fake_task({ due = this_year .. "-11-02", status = "completed" })))
check("terminal state drops the ↻ prefix", done:find("↻", 1, true) == nil, done)
check("terminal state still shows due", done:find("11-02", 1, true) ~= nil, done)

---------------------------------------------------------------------
-- 3) 渲染：checkbox → 图标，元数据块保持明文
---------------------------------------------------------------------
local ns_conceal = constants.ns("conceal")
local ns_strike = constants.ns("strike")

local path = dir .. "/main.todo.md"
local row_todo = "- [ ] 有到期的任务 @id(bd0001) @created(1700000000) @due(" .. this_year .. "-11-02)"
local row_done = "- [x] 已完成的任务 @id(bd0002) @created(1700000000) @due(" .. this_year .. "-12-01)"
vim.fn.writefile({ "## Active", row_todo, row_done }, path)
vim.cmd("edit! " .. vim.fn.fnameescape(path))
vim.wait(2000, function()
	local ok, t = pcall(core.get_task, "bd0002")
	return ok and t ~= nil
end, 50)

local buf = vim.api.nvim_get_current_buf()
conceal.apply_buffer_conceal(buf)

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check("file text keeps the metadata block", lines[2] == row_todo, lines[2])

local cm = vim.api.nvim_buf_get_extmarks(buf, ns_conceal, 0, -1, { details = true })
check("both checkboxes conceal to an icon", #cm == 2, #cm)
local concealed = {}
for _, m in ipairs(cm) do
	concealed[#concealed + 1] = tostring(m[4] and m[4].conceal)
end
check("no conceal covers the metadata block", not table.concat(concealed, "|"):find("@", 1, true), table.concat(concealed, "|"))

local sm = vim.api.nvim_buf_get_extmarks(buf, ns_strike, 0, -1, { details = true })
local strike_end = sm[1] and sm[1][4] and sm[1][4].end_col
check("strike stops before the metadata", strike_end == row_done:find(" @id(", 1, true) - 1, tostring(strike_end))
check("strikethrough covers the content", (strike_end or 0) > row_done:find("已完成的任务", 1, true), tostring(strike_end))

vim.fn.delete(dir, "rf")
print(fails == 0 and "ALL PASS" or ("FAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
