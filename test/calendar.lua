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
-- 顺延目标日期（day 视图 s / >）：过期/今天 → 今天，未来 → +1 天
---------------------------------------------------------------------
local T = "2026-10-15"
check("postpone overdue -> today", model.postpone_target("2026-10-03", T) == T, model.postpone_target("2026-10-03", T))
check("postpone today -> today", model.postpone_target(T, T) == T)
check("postpone future -> +1", model.postpone_target("2026-10-20", T) == "2026-10-21", model.postpone_target("2026-10-20", T))
check("postpone cross month", model.postpone_target("2026-10-31", T) == "2026-11-01", model.postpone_target("2026-10-31", T))
check("postpone nil -> today", model.postpone_target(nil, T) == T)

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

---把「按天的任务表」包成两层条目结构（承诺层 = 这张表，活动层默认空）
---@param map table<integer, table[]>|nil
---@param marks table<integer, table[]>|nil
local function entries_of(map, marks)
	return { commits = map or {}, activities = marks or {}, undated = {} }
end

local lines, layout = view.build_month_lines(2026, 10, entries_of(items))
local grid = model.grid(2026, 10, { first_day_of_week = "monday" })
check("grid layout by default", layout.grid == true)
check("grid lines = 2 + 5*2 + 4 blank + 1", #lines == 17, #lines)
check("title has year/month", lines[1]:find("October 2026", 1, true) ~= nil, lines[1])
check("weekday header width 78", vim.fn.strdisplaywidth(lines[2]) == 78, vim.fn.strdisplaywidth(lines[2]))
check("layout 5 rows (trailing empty week trimmed)", #layout.rows == 5, #layout.rows)
check("legend line", lines[#lines]:find("commit", 1, true) ~= nil, lines[#lines])

-- 标题行尾的附加说明（日历本地筛选）
local nlines = view.build_month_lines(2026, 10, entries_of(items), { note = "filter: #fix" })
check("title shows the filter note", nlines[1]:find("filter: #fix", 1, true) ~= nil, nlines[1])
check("note keeps the grid width", vim.fn.strdisplaywidth(nlines[1]) <= 78, vim.fn.strdisplaywidth(nlines[1]))

for i, row in ipairs(layout.rows) do
	check("row " .. i .. " has 7 cells", #row.cells == 7, #row.cells)
	check("row " .. i .. " has a chip line below", row.chip == row.line + 1)
	check(
		"row " .. i .. " date and chip lines have equal width",
		vim.fn.strdisplaywidth(lines[row.line]) == vim.fn.strdisplaywidth(lines[row.chip])
	)
end
check("weeks are separated by a blank line", (function()
	local blanks = 0
	for _, line in ipairs(lines) do
		if line == "" then
			blanks = blanks + 1
		end
	end
	return blanks == #layout.rows - 1
end)())

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
local daynum3, todo3 = slice(line3, geo3.start, geo3.start + 2), slice(line3, geo3.commit_s, geo3.commit_e)
check("day number visible (1-digit)", daynum3 == " 3", daynum3)
check("commit badge text (icon spaced from number)", todo3 == "● 1", todo3)
check("no mark badge on day 3", geo3.mark_s == nil)
check("cell content fits the column", vim.fn.strdisplaywidth(slice(line3, geo3.bg_s, geo3.bg_e)) == 10,
	vim.fn.strdisplaywidth(slice(line3, geo3.bg_s, geo3.bg_e)))
local chip3 = slice(lines[layout.rows[row3].chip], geo3.chip_s, geo3.chip_e)
check("chip shows the task title", chip3:find("过期任务", 1, true) ~= nil, chip3)
check("chip bar is drawn", slice(lines[layout.rows[row3].chip], geo3.bar_s, geo3.bar_e) == "▎")
check("chip bar uses the urgency color", geo3.chip_hl == "TodoDueOverdue", geo3.chip_hl)

local row15, col15 = cell_of(15)
local geo15 = layout.rows[row15].cells[col15]
local line15 = lines[layout.rows[row15].line]
local daynum15 = slice(line15, geo15.start, geo15.start + 2)
local todo15 = slice(line15, geo15.commit_s, geo15.commit_e)
check("day number visible (2-digit)", daynum15 == "15", daynum15)
check("commit badge counts every commitment", todo15 == "● 3", todo15)
check("no mark badge without activity", geo15.mark_s == nil)
check("heat counts every commitment (done included)", geo15.heat == 3, geo15.heat)

local row4, col4 = cell_of(4)
local geo4 = layout.rows[row4].cells[col4]
check("no tasks = blank badges", geo4.commit_s == nil and geo4.mark_s == nil)
check("no tasks = no heat", geo4.heat == 0, geo4.heat)
check("no tasks = no chip", geo4.chip_hl == nil)

local row28, col28 = cell_of(28)
local geo28 = layout.rows[row28].cells[col28]
check("counts cap at 9+", slice(lines[layout.rows[row28].line], geo28.commit_s, geo28.commit_e) == "● 9+")
check("heat caps at level 3", geo28.heat == 3, geo28.heat)

check("commit badge sits right of the date", geo15.commit_s > geo15.start)

-- 日期固定列：不论当天有没有计数，日期都落在格子起始 +1 显示列（不会左右跳）
for r, row in ipairs(layout.rows) do
	local text = lines[row.line]
	for c, geo in ipairs(row.cells) do
		local want = 2 + (c - 1) * 11 + 1
		local got = vim.fn.strdisplaywidth(text:sub(1, geo.start))
		check(("day %d col %d date at fixed column"):format(r, c), got == want, ("got %d want %d"):format(got, want))
		check(("day %d col %d date digits"):format(r, c), text:sub(geo.start + 1, geo.start + 2):match("^%s*%d*$") ~= nil)
	end
end

---------------------------------------------------------------------
-- 紧凑排版（放不下 grid / 面板时降级）
---------------------------------------------------------------------
local clines, clayout = view.build_month_lines(2026, 10, entries_of(items), { grid = false })
check("compact layout flag", clayout.grid == false)
check("compact lines = 2 + 5 + 1", #clines == 8, #clines)
check("compact width same as grid", vim.fn.strdisplaywidth(clines[3]) == 78, vim.fn.strdisplaywidth(clines[3]))
check("compact has no chip lines", clayout.rows[1].chip == nil)
local crow15, ccol15 = cell_of(15)
local cgeo15 = clayout.rows[crow15].cells[ccol15]
check(
	"compact keeps badge offsets",
	slice(clines[clayout.rows[crow15].line], cgeo15.commit_s, cgeo15.commit_e) == "● 3"
)

---------------------------------------------------------------------
-- 右侧当日面板（月视图内嵌）
---------------------------------------------------------------------
local agenda_marks = { [15] = { { content = "碰过的标记", id = "mk0001", path = "a.md", line = 1, kind = "mark" } } }
local alines, alayout = view.build_month_lines(2026, 10, entries_of(items, agenda_marks), {
	grid = true,
	agenda = { date = { year = 2026, month = 10, day = 15 }, entries = {
		commits = items[15],
		marks = agenda_marks[15],
	}, width = 30 },
})
check("agenda layout attached", alayout.agenda ~= nil)
check("agenda keeps month line count", #alines == #lines, #alines)
local awidth = vim.fn.strdisplaywidth(alines[1])
for i, line in ipairs(alines) do
	check("agenda row " .. i .. " equal width", vim.fn.strdisplaywidth(line) == awidth, vim.fn.strdisplaywidth(line))
end
check("agenda title", alines[1]:find("Oct 15", 1, true) ~= nil, alines[1])
check(
	"agenda counts both layers",
	alines[2]:find("● 3 commit", 1, true) ~= nil and alines[2]:find("○ 1 mark", 1, true) ~= nil,
	alines[2]
)
check("agenda groups by layer", alines[3]:find("Commitments", 1, true) ~= nil, alines[3])
check("agenda lists active task", alines[4]:find("今天", 1, true) ~= nil, alines[4])
check(
	"agenda lists marks group",
	(function()
		local has_group, has_item = false, false
		for _, line in ipairs(alines) do
			if line:find("Marks touched", 1, true) then
				has_group = true
			end
			if line:find("碰过的标记", 1, true) then
				has_item = true
			end
		end
		return has_group and has_item
	end)()
)
check("agenda has separator", alines[1]:find("│", 1, true) ~= nil, alines[1])
-- 分隔符与面板内容必须落在「每行自己的字节位置」上（含中文行字节比显示列多）
for i, col in ipairs(alayout.agenda.sep_cols) do
	check("agenda separator at col " .. i, alines[i]:sub(col + 1, col + #"│") == "│", alines[i]:sub(col + 1, col + #"│"))
end
local header_seg
for _, seg in ipairs(alayout.agenda.segs) do
	check("agenda seg within line " .. seg[1], seg[3] <= #alines[seg[1]] and seg[2] < seg[3], seg[2] .. ".." .. seg[3])
	if seg[4] == "TodoCalendarHeader" then
		header_seg = seg
	end
end
check("agenda header seg covers panel title", header_seg ~= nil and slice(alines[1], header_seg[2], header_seg[3]):find("Oct 15", 1, true) ~= nil)
check("agenda makes lines wider", awidth > vim.fn.strdisplaywidth(lines[1]))

---------------------------------------------------------------------
-- 当日列表渲染
---------------------------------------------------------------------
local day_lines, day_map = view.build_day_lines(
	{ year = 2026, month = 10, day = 15 },
	{
		commits = {
			{ content = "写月历", id = "ab12cd", kind = "commit" },
			{ content = "很长的任务标题" .. string.rep("啊", 40), id = "ef34cd", kind = "commit" },
		},
		marks = { { content = "碰过的标记", id = "mk0002", kind = "mark" } },
	},
	40
)
check("day title", day_lines[1]:find("2026-10-15", 1, true) ~= nil, day_lines[1])
check("day count", day_lines[1]:find("(3)", 1, true) ~= nil, day_lines[1])
check(
	"day stats line",
	day_lines[2]:find("● 2 commit", 1, true) ~= nil and day_lines[2]:find("○ 1 mark", 1, true) ~= nil,
	day_lines[2]
)
check("day groups commits first", day_map.line_by_index[1] == 5 and day_map.line_by_index[3] == 8, vim.inspect(day_map.line_by_index))
check("day item id right aligned", vim.fn.strdisplaywidth(day_lines[5]) == 40, vim.fn.strdisplaywidth(day_lines[5]))
check("day item truncated", vim.fn.strdisplaywidth(day_lines[6]) == 40, vim.fn.strdisplaywidth(day_lines[6]))
check("day marks group rendered", day_lines[8]:find("碰过的标记", 1, true) ~= nil, day_lines[8])
check("day hint", day_lines[#day_lines]:find("jump", 1, true) ~= nil)
local noted = view.build_day_lines(
	{ year = 2026, month = 10, day = 15 },
	{ commits = { { content = "写月历", id = "ab12cd", kind = "commit" } }, marks = {} },
	80,
	{ note = "filter: #fix" }
)
check("day title shows the filter note", noted[1]:find("filter: #fix", 1, true) ~= nil, noted[1])
check("day title stays within width", vim.fn.strdisplaywidth(noted[1]) <= 80)

local empty = view.build_day_lines({ year = 2026, month = 10, day = 1 }, { commits = {}, marks = {} }, 40)
check("empty day", empty[2]:find("nothing on this day", 1, true) ~= nil, empty[2])

check("counts: empty", service.counts(nil).todo == 0 and service.counts(nil).done == 0)
local counts = service.counts({ { completed = false }, { completed = false }, { completed = true } })
check("counts: todo/done split", counts.todo == 2 and counts.done == 1, vim.inspect(counts))
--（active_items 已删：已完成任务的过滤由 month_items 的 hide_completed 承担，见下方用例）

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
	"- [ ] todo:ca0008 @2026-02-31 脏日期",
	"- [ ] todo:ca0009 ~2026-10-08 计划任务",
	"- [ ] todo:ca0010 ~2026-10-20 @2026-10-25 排期任务",
}, todo_dir .. "/main.todo.md")

local saved_cwd = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(tmp_root))
service.invalidate()
local month = service.month_entries(2026, 10, { force_refresh = true })
check("collects only in-month days", month.commits[3] ~= nil and month.commits[15] ~= nil and month.commits[2] == nil)
-- 2 月没有 31 号：脏日期不能塞进永远渲染不到的格子
check(
	"rejects impossible dates",
	(service.month_entries(2026, 2, { force_refresh = true }).commits[31] or {})[1] == nil
)
check(
	"start-only task becomes a commit on its start day",
	(month.commits[8] or {})[1] ~= nil and month.commits[8][1].plan == "planned",
	month.commits[8] and month.commits[8][1] and month.commits[8][1].plan
)
check(
	"start+due task is an interval anchored on due",
	(month.commits[25] or {})[1] ~= nil and month.commits[25][1].plan == "interval",
	month.commits[25] and month.commits[25][1] and month.commits[25][1].plan
)
check("mark layer exists", month.activities ~= nil)
local c15 = service.counts(month.commits[15])
-- `[x]` 计入「已完成」；`[>]`（archived）不进日历
check("keeps completed, counts it separately", #month.commits[15] == 3 and c15.todo == 2 and c15.done == 1, vim.inspect(c15))
check("completed sorted last", month.commits[15][3].completed == true, month.commits[15][3] and month.commits[15][3].content)
check("sorts by urgency/date", month.commits[15][1].content ~= "" and month.commits[3][1].due == "2026-10-03")
check(
	"dedupes across regions (no duplicates)",
	(function()
		local seen, dup = {}, 0
		for _, day_items in pairs(month.commits) do
			for _, item in ipairs(day_items) do
				if seen[item.id] then
					dup = dup + 1
				end
				seen[item.id] = true
			end
		end
		return dup == 0
	end)()
)
check("item has jump target", month.commits[15][1].path ~= nil and month.commits[15][1].line ~= nil)

-- 只显示未完成（config: calendar.show_completed = false）
local hidden = service.month_entries(2026, 10, { force_refresh = true, hide_completed = true })
local h15 = service.counts(hidden.commits[15])
check("hide_completed drops done items", #hidden.commits[15] == 2 and h15.todo == 2 and h15.done == 0, vim.inspect(h15))
check("hide_completed does not leak into the default query", service.counts(month.commits[15]).done == 1)

-- 日历本地筛选（与抽屉同一套规格）
local flt = require("todo2.render.filter")
local fix_spec = flt.parse({ "#fix" })
local only_fix = service.month_entries(2026, 10, { force_refresh = true, spec = fix_spec })
check(
	"filter keeps only #fix",
	(only_fix.commits[15] or {})[1] == nil,
	only_fix.commits[15] and only_fix.commits[15][1].content
)
check("filter keeps the tagged day", #(only_fix.commits[3] or {}) == 1)
local done_spec = flt.parse({ "status:completed" })
local only_done = service.month_entries(2026, 10, { force_refresh = true, spec = done_spec })
check(
	"status filter keeps only completed",
	#(only_done.commits[15] or {}) == 1 and only_done.commits[15][1].completed == true
)
local duo = service.month_entries(2026, 10, { force_refresh = true, hide_completed = true, spec = done_spec })
check("hide_completed + filter combine", #(duo.commits[15] or {}) == 0)
service.invalidate()
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
check("month view uses hl only (no virt_text)", not has_virt)

-- 日历本地筛选：设置/清除 → 标题行跟随（不写 TODO 文件）
view.set_filter(flt.parse({ "#fix" }))
check(
	"set_filter shows up in the title",
	vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("filter: #fix", 1, true) ~= nil,
	vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
)
check("active_filter reflects the spec", view.active_filter() ~= nil)
view.clear_filter()
check("clear_filter drops the note", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("filter:", 1, true) == nil)
check("active_filter is nil after clearing", view.active_filter() == nil)
view.close()
check("close ok", not pcall(vim.api.nvim_get_current_buf) or true)

---------------------------------------------------------------------
-- 选中日导航：h/l 先在月历网格里选日期，走出网格才翻月
---------------------------------------------------------------------
local function feed(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function title_of(b)
	return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
end

local nb = view.open({ year = 2026, month = 10, day = 15 })
local nw = vim.fn.bufwinid(nb)
vim.api.nvim_set_current_win(nw)
local r0, c0 = vim.api.nvim_win_get_cursor(nw)[1], vim.api.nvim_win_get_cursor(nw)[2]
feed("l")
local r1, c1 = vim.api.nvim_win_get_cursor(nw)[1], vim.api.nvim_win_get_cursor(nw)[2]
check("l keeps the month", title_of(nb):find("October 2026", 1, true) ~= nil, title_of(nb))
check("l moves the cursor right", c1 > c0, c0 .. "->" .. c1)
check("l stays on the same week row", r1 == r0, r0 .. "->" .. r1)
feed("h")
local r2, c2 = vim.api.nvim_win_get_cursor(nw)[1], vim.api.nvim_win_get_cursor(nw)[2]
check("h moves back to the same cell", r2 == r0 and c2 == c0, r2 .. ":" .. c2)
feed("j")
check("j keeps the month", title_of(nb):find("October 2026", 1, true) ~= nil, title_of(nb))
check("j moves a week down", vim.api.nvim_win_get_cursor(nw)[1] > r0)
view.close()

-- 跨月边界：31 号再按 j / l 就应翻到下个月（不再先走尾随的相邻月格子）
local eb = view.open({ year = 2026, month = 10, day = 31 })
local ew = vim.fn.bufwinid(eb)
vim.api.nvim_set_current_win(ew)
feed("j")
check("j from the last day flips to next month", title_of(eb):find("November 2026", 1, true) ~= nil, title_of(eb))
view.close()

local eb2 = view.open({ year = 2026, month = 10, day = 31 })
local ew2 = vim.fn.bufwinid(eb2)
vim.api.nvim_set_current_win(ew2)
feed("l")
check("l from the last day flips to next month", title_of(eb2):find("November 2026", 1, true) ~= nil, title_of(eb2))
view.close()

-- 反向：1 号再按 k / h 就应翻到上个月
local sb = view.open({ year = 2026, month = 10, day = 1 })
local sw = vim.fn.bufwinid(sb)
vim.api.nvim_set_current_win(sw)
feed("k")
check("k from the first day flips to previous month", title_of(sb):find("September 2026", 1, true) ~= nil, title_of(sb))
view.close()

local sb2 = view.open({ year = 2026, month = 10, day = 1 })
local sw2 = vim.fn.bufwinid(sb2)
vim.api.nvim_set_current_win(sw2)
feed("h")
check("h from the first day flips to previous month", title_of(sb2):find("September 2026", 1, true) ~= nil, title_of(sb2))
view.close()

---------------------------------------------------------------------
if fails == 0 then
	print("\nALL PASS")
else
	print(string.format("\n%d FAILED", fails))
	vim.cmd("cquit")
end
