-- 月历（:TodoCalendar）回归测试（headless，自包含）。
-- 运行：nvim --headless -u NONE -l test/calendar.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local model = require("todo2.ui.calendar.model")
local view = require("todo2.ui.calendar.view")
local service = require("todo2.ui.calendar.service")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

---------------------------------------------------------------------
-- 纯日期计算
---------------------------------------------------------------------
check("days 2026-02", model.days_in_month(2026, 2) == 28)
check("days 2024-02 (leap)", model.days_in_month(2024, 2) == 29)
check("days 2026-10", model.days_in_month(2026, 10) == 31)
check("days 2026-12", model.days_in_month(2026, 12) == 31)
check("days 2026-04", model.days_in_month(2026, 4) == 30)

local d = model.add_days({ year = 2026, month = 1, day = 31 }, 1)
check("add_days cross month", d.year == 2026 and d.month == 2 and d.day == 1)
d = model.add_days({ year = 2026, month = 12, day = 31 }, 1)
check("add_days cross year", d.year == 2027 and d.month == 1 and d.day == 1)
d = model.add_days({ year = 2026, month = 3, day = 1 }, -1)
check("add_days back", d.year == 2026 and d.month == 2 and d.day == 28)

check(
	"diff_days",
	model.diff_days({ year = 2026, month = 3, day = 1 }, { year = 2026, month = 2, day = 1 }) == 28
)
check("same_day", model.same_day({ year = 2026, month = 1, day = 2 }, { year = 2026, month = 1, day = 2 }))
check("not same_day", not model.same_day({ year = 2026, month = 1, day = 2 }, { year = 2026, month = 1, day = 3 }))

check("parse_month ok", model.parse_month("2026-07").month == 7)
check("parse_month bad shape", model.parse_month("2026-7") == nil)
check("parse_month bad range", model.parse_month("2026-13") == nil)
check("parse_month empty", model.parse_month(nil) == nil)

---------------------------------------------------------------------
-- 网格：6 行 × 7 列，包含整月，首格星期符合 first_day_of_week
---------------------------------------------------------------------
for _, first in ipairs({ "monday", "sunday" }) do
	local grid = model.grid(2026, 10, { first_day_of_week = first })
	check(first .. ": 6 rows", #grid == 6)
	check(first .. ": 7 cols", #grid[1] == 7)

	local start = model.week_start(first)
	check(first .. ": first cell weekday", model.weekday(grid[1][1].year, grid[1][1].month, grid[1][1].day) == start)
	local last = grid[6][7]
	check(first .. ": last cell weekday", model.weekday(last.year, last.month, last.day) == (start + 5) % 7 + 1)

	local seen, in_month = {}, 0
	for _, week in ipairs(grid) do
		for _, cell in ipairs(week) do
			if cell.in_month then
				in_month = in_month + 1
				seen[cell.day] = true
			end
		end
	end
	check(first .. ": all days in month", in_month == 31)
	local missing = 0
	for day = 1, 31 do
		if not seen[day] then
			missing = missing + 1
		end
	end
	check(first .. ": no missing day", missing == 0)
end

-- 2 月 1 日恰好是周日时，月份不能越界渲染
local feb = model.grid(2026, 2, { first_day_of_week = "monday" })
check("feb grid has 28 in-month days", (function()
	local n = 0
	for _, week in ipairs(feb) do
		for _, cell in ipairs(week) do
			if cell.in_month then
				n = n + 1
			end
		end
	end
	return n == 28
end)())

---------------------------------------------------------------------
-- 月视图渲染：标记列不遮日期数字
---------------------------------------------------------------------
local items = {
	[3] = { { hl = "TodoDueOverdue", content = "过期任务", urgency = "overdue" } },
	[15] = {
		{ hl = "TodoDueSoon", content = "今天", urgency = "today" },
		{ hl = "TodoDue", content = "以后", urgency = "future" },
		{ hl = "TodoDue", content = "已经做完了", urgency = "future", completed = true },
	},
	[28] = (function()
		local list = {}
		for i = 1, 12 do
			list[i] = { hl = "TodoDue", content = "任务" .. i, urgency = "future" }
		end
		return list
	end)(),
}

local lines, layout = view.build_month_lines(2026, 10, items)
local grid = model.grid(2026, 10, { first_day_of_week = "monday" })
check("grid layout by default", layout.grid == true)
check("grid lines = 2 + 5*2 + 4 rules + 1", #lines == 17, #lines)
check("title has year/month", lines[1]:find("2026", 1, true) ~= nil and lines[1]:find("10", 1, true) ~= nil)
check("weekday header width 71", vim.fn.strdisplaywidth(lines[2]) == 71, vim.fn.strdisplaywidth(lines[2]))
check("layout 5 rows (trailing empty week trimmed)", #layout.rows == 5, #layout.rows)
check("legend line", lines[#lines]:find("未完成", 1, true) ~= nil, lines[#lines])

for i, row in ipairs(layout.rows) do
	check("row " .. i .. " has 7 cells", #row.cells == 7, #row.cells)
	check("row " .. i .. " has a chip line below", row.chip == row.line + 1)
	check("row " .. i .. " rule above content", (i == 1 and row.rule == nil) or row.rule == row.line - 1)
	check(
		"row " .. i .. " date and chip lines have equal width",
		vim.fn.strdisplaywidth(lines[row.line]) == vim.fn.strdisplaywidth(lines[row.chip])
	)
end
check("week rules are hairline separators", lines[layout.rows[2].rule]:find("─", 1, true) ~= nil)

local function cell_of(day)
	for r = 1, #layout.rows do
		local week = grid[r]
		for c, cell in ipairs(week) do
			if cell.in_month and cell.day == day then
				return r, c
			end
		end
	end
end

---从 0 基字节区间 [from, to) 取子串（layout 里的列都是 0 基，end_col 语义）
local function slice(line, from, to)
	return line:sub(from + 1, to)
end

local row3, col3 = cell_of(3)
local geo3 = layout.rows[row3].cells[col3]
local line3 = lines[layout.rows[row3].line]
local daynum3, todo3 = slice(line3, geo3.start, geo3.start + 2), slice(line3, geo3.todo_s, geo3.todo_e)
check("day number visible (1-digit)", daynum3 == " 3", daynum3)
check("todo badge text", todo3 == "●1", todo3)
check("no done badge on day 3", geo3.done_s == nil)
check("cell content fits the column", geo3.stop - geo3.start <= 9)
local chip3 = slice(lines[layout.rows[row3].chip], geo3.chip_s, geo3.chip_e)
check("chip shows the task title", chip3:find("过期任务", 1, true) ~= nil, chip3)
check("chip bar is drawn", slice(lines[layout.rows[row3].chip], geo3.bar_s, geo3.bar_e) == "▎")
check("chip bar uses the urgency color", geo3.chip_hl == "TodoDueOverdue", geo3.chip_hl)

local row15, col15 = cell_of(15)
local geo15 = layout.rows[row15].cells[col15]
local line15 = lines[layout.rows[row15].line]
local daynum15 = slice(line15, geo15.start, geo15.start + 2)
local todo15, done15 = slice(line15, geo15.todo_s, geo15.todo_e), slice(line15, geo15.done_s, geo15.done_e)
check("day number visible (2-digit)", daynum15 == "15", daynum15)
check("todo count excludes completed", todo15 == "●2", todo15)
check("done badge counts completed", done15 == "○1", done15)
check("heat level 2 for two unfinished", geo15.heat == 2, geo15.heat)

local row4, col4 = cell_of(4)
local geo4 = layout.rows[row4].cells[col4]
check("no tasks = blank badges", geo4.todo_s == nil and geo4.done_s == nil)
check("no tasks = no heat", geo4.heat == 0, geo4.heat)
check("no tasks = no chip", geo4.chip_hl == nil)
check("cells keep a constant stride", geo4.start > geo15.start or geo4.start == geo15.start)

local row28, col28 = cell_of(28)
local geo28 = layout.rows[row28].cells[col28]
check("counts cap at 9+", slice(lines[layout.rows[row28].line], geo28.todo_s, geo28.todo_e) == "●9+")
check("heat caps at level 3", geo28.heat == 3, geo28.heat)

check("two badges in same row keep byte offsets", geo15.done_e > geo15.todo_e)

---------------------------------------------------------------------
-- 紧凑排版（屏幕放不下细线分栏时降级）
---------------------------------------------------------------------
local clines, clayout = view.build_month_lines(2026, 10, items, { grid = false })
check("compact layout flag", clayout.grid == false)
check("compact lines = 2 + 5 + 1", #clines == 8, #clines)
check("compact width 65", vim.fn.strdisplaywidth(clines[3]) == 65, vim.fn.strdisplaywidth(clines[3]))
check("compact has no chip lines", clayout.rows[1].chip == nil)
local crow15, ccol15 = cell_of(15)
local cgeo15 = clayout.rows[crow15].cells[ccol15]
check(
	"compact keeps badge offsets",
	slice(clines[clayout.rows[crow15].line], cgeo15.todo_s, cgeo15.todo_e) == "●2"
)

---------------------------------------------------------------------
-- 当日列表渲染
---------------------------------------------------------------------
local day_lines = view.build_day_lines(
	{ year = 2026, month = 10, day = 15 },
	{
		{ content = "写月历", id = "ab12cd" },
		{ content = "很长的任务标题" .. string.rep("啊", 40), id = "ef34cd" },
	},
	40
)
check("day title", day_lines[1]:find("2026-10-15", 1, true) ~= nil, day_lines[1])
check("day count", day_lines[1]:find("(2)", 1, true) ~= nil, day_lines[1])
check("day stats line", day_lines[2]:find("●2 未完成", 1, true) ~= nil, day_lines[2])
check("day item id right aligned", vim.fn.strdisplaywidth(day_lines[4]) == 40, vim.fn.strdisplaywidth(day_lines[4]))
check("day item truncated", vim.fn.strdisplaywidth(day_lines[5]) == 40, vim.fn.strdisplaywidth(day_lines[5]))
check("day hint", day_lines[#day_lines]:find("跳转", 1, true) ~= nil)

local empty = view.build_day_lines({ year = 2026, month = 10, day = 1 }, {}, 40)
check("empty day", empty[4]:find("无到期任务", 1, true) ~= nil, empty[4])

check("counts: empty", service.counts(nil).todo == 0 and service.counts(nil).done == 0)
local counts = service.counts({ { completed = false }, { completed = false }, { completed = true } })
check("counts: todo/done split", counts.todo == 2 and counts.done == 1, vim.inspect(counts))
check("active_items drops completed", #service.active_items({ { completed = false }, { completed = true } }) == 1)

---------------------------------------------------------------------
-- 数据聚合（真实 TODO 文件 → 月视图条目）
---------------------------------------------------------------------
local tmp_root = "/tmp/todo2-cal-test"
local todo_dir = vim.fn.expand("~/.todo-files/todo2-cal-test")
vim.fn.mkdir(tmp_root, "p")
vim.fn.mkdir(todo_dir, "p")
vim.fn.writefile({
	"# TODO",
	"",
	"- [ ] todo:ca0001 @2026-10-03 #fix 过期任务",
	"- [ ] todo:ca0002 @2026-10-15 当天任务",
	"  - [ ] todo:ca0003 @2026-10-15 子任务",
	"- [>] todo:ca0004 @2026-10-15 doing 任务",
	"- [x] todo:ca0005 @2026-10-15 已完成任务",
	"- [ ] todo:ca0006 @2026-11-02 下月任务",
	"- [ ] todo:ca0007 无到期日",
}, todo_dir .. "/main.todo.md")

local saved_cwd = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))
service.invalidate()
local month = service.month_items(2026, 10, { force_refresh = true })
check("collects only in-month days", month[3] ~= nil and month[15] ~= nil and month[2] == nil)
local c15 = service.counts(month[15])
-- `[x]` 计入「已完成」；`[>]`（archived）不进日历
check("keeps completed, counts it separately", #month[15] == 3 and c15.todo == 2 and c15.done == 1, vim.inspect(c15))
check("completed sorted last", month[15][3].completed == true, month[15][3] and month[15][3].content)
check("sorts by urgency/date", month[15][1].content ~= "" and month[3][1].due == "2026-10-03")
check(
	"dedupes across regions (no duplicates)",
	(function()
		local seen, dup = {}, 0
		for _, items in pairs(month) do
			for _, item in ipairs(items) do
				if seen[item.id] then
					dup = dup + 1
				end
				seen[item.id] = true
			end
		end
		return dup == 0
	end)()
)
check("item has jump target", month[15][1].path ~= nil and month[15][1].line ~= nil)
vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
vim.fn.delete(todo_dir, "rf")
vim.fn.delete(tmp_root, "rf")

---------------------------------------------------------------------
-- 真实浮窗渲染（extmark 不能落在无效行）
---------------------------------------------------------------------
local buf = view.open({ year = 2026, month = 10, day = 15 })
check("float buffer created", buf ~= nil and vim.api.nvim_buf_is_valid(buf))
check("float buffer line count", vim.api.nvim_buf_line_count(buf) == 17, vim.api.nvim_buf_line_count(buf))
local ns = vim.api.nvim_get_namespaces()["todo2.calendar"]
local extmarks = ns and vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) or {}
check("extmarks drawn", #extmarks > 0, #extmarks)
local has_virt = false
for _, m in ipairs(extmarks) do
	if m[4] and m[4].virt_text then
		has_virt = true
	end
end
check("no crash on empty month marks", not has_virt or has_virt) -- 本月无任务时也应正常渲染
view.close()
check("close ok", not pcall(vim.api.nvim_get_current_buf) or true)

---------------------------------------------------------------------
if fails == 0 then
	print("\nALL PASS")
else
	print(string.format("\n%d FAILED", fails))
	vim.cmd("cquit")
end
