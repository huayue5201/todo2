-- lua/todo2/ui/calendar/view.lua
--- 月历视图：单浮窗内两态（月视图 / 当日列表）。
---
--- 布局（月视图，0 基列）：
---   "  " + 7 × ("DD" + " ●N" + " ○N" + " ")  → 单元格步长 9（显示列），总宽 65
---   ●N = 未完成数（绿色），○N = 已完成数（灰色），计数为 0 时留空
---   每格的字节偏移由 build_month_lines 连同 layout 一起返回，
---   渲染端不自行做列算术（圆点是多字节字符，字节≠显示列）
--- 行结构：
---   1 标题 / 2 空 / 3 星期 / 4 空 / 5..10 六周 / 11 图例

local M = {}

local config = require("todo2.config")
local model = require("todo2.ui.calendar.model")
local service = require("todo2.ui.calendar.service")

local NS = vim.api.nvim_create_namespace("todo2.calendar")

local PAD = "  "
local ROW_FIRST_WEEK = 5
local CAL_WIDTH = 65 -- 2 + 7 × 9 = "DD" + " ●N" + " ○N" + 空格
local BADGE_W = 3
local MIN_DAY_WIDTH = 40

local WEEKDAY_LABELS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local WEEKDAY_FULL = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

local WIN_TITLE = " 📅 月历 "

---@type table 状态：{ buf, win, year, month, day, mode, items, day_items, index }
local state = nil

-- 任务变化（状态/删除/改期）后自动重算；未打开时 refresh 是空操作
local hooks_installed = false
local function install_hooks()
	if hooks_installed then
		return
	end
	hooks_installed = true
	pcall(function()
		require("todo2.core.events").on_change(function()
			M.refresh()
		end)
	end)
end

---------------------------------------------------------------------
-- 高亮
---------------------------------------------------------------------
local hl_ready = false
local function setup_highlights()
	if hl_ready then
		return
	end
	hl_ready = true
	vim.api.nvim_set_hl(0, "TodoCalendarToday", { link = "TodoDueSoon", bold = true, default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarSelected", { reverse = true, default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarDim", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarHeader", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarHint", { link = "Comment", italic = true, default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarTodo", { link = "Added", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarDone", { link = "Comment", default = true })
end

---------------------------------------------------------------------
-- 工具
---------------------------------------------------------------------
---按显示宽度居中（CJK 双宽字符按 2 列计）
---@param text string
---@param width integer
---@return string
local function center(text, width)
	local w = vim.fn.strdisplaywidth(text)
	local pad = math.max(0, width - w)
	return string.rep(" ", math.floor(pad / 2)) .. text
end

---@param text string
---@param width integer
---@return string
local function truncate(text, width)
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	local out = ""
	for _, char in ipairs(vim.fn.split(text, "\\zs")) do
		if vim.fn.strdisplaywidth(out .. char) > width - 1 then
			break
		end
		out = out .. char
	end
	return out .. "…"
end

local function first_day_of_week()
	return config.get("calendar.first_day_of_week") or "monday"
end

local function mark_icon()
	return config.get("calendar.mark_icon") or "●"
end

local function done_icon()
	return config.get("calendar.done_icon") or "○"
end

---计数徽标：" ●3" / " ○1" / 空占位（固定 3 列宽，保证网格对齐）
---@param icon string
---@param n integer
---@return string
local function badge(icon, n)
	if not n or n <= 0 then
		return string.rep(" ", BADGE_W)
	end
	local count = n <= 9 and tostring(n) or "9+"
	return " " .. icon .. count
end

local function weekday_label(week_start)
	local labels = {}
	for i = 0, 6 do
		labels[i + 1] = WEEKDAY_LABELS[((week_start - 1 + i) % 7) + 1]
	end
	return labels
end

local function weekday_full(date)
	return WEEKDAY_FULL[model.weekday(date.year, date.month, date.day)]
end

local function fmt_date(date)
	return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

---------------------------------------------------------------------
-- 月视图构建（纯函数，供测试）
---------------------------------------------------------------------
---@param year integer
---@param month integer
---@param items table<integer, table[]>
---@return string[] lines
---@return table[][] layout 每周每格 { start=, stop=, todo_s=, todo_e=, done_s=, done_e= }（0 基字节列）
function M.build_month_lines(year, month, items)
	local grid = model.grid(year, month, { first_day_of_week = first_day_of_week() })
	local todo_icon, done_mark = mark_icon(), done_icon()

	local lines = { center(string.format("%d 年 %d 月", year, month), CAL_WIDTH), "" }
	local header = {}
	for _, label in ipairs(weekday_label(model.week_start(first_day_of_week()))) do
		header[#header + 1] = string.format("%2s       ", label)
	end
	lines[3] = PAD .. table.concat(header)
	lines[4] = ""

	local layout = {}
	for _, week in ipairs(grid) do
		local parts = { PAD }
		local offset = #PAD
		local cols = {}
		for _, cell in ipairs(week) do
			local counts = cell.in_month and service.counts(items[cell.day]) or { todo = 0, done = 0 }
			local day_text = cell.in_month and string.format("%2d", cell.day) or "  "
			local todo_badge = badge(todo_icon, counts.todo)
			local done_badge = badge(done_mark, counts.done)
			local text = day_text .. todo_badge .. done_badge .. " "

			local geo = { start = offset, stop = offset + #text }
			-- 只给「圆点 + 数字」上色，跳过前导空格
			if counts.todo > 0 then
				local body = todo_icon .. (counts.todo <= 9 and tostring(counts.todo) or "9+")
				geo.todo_s, geo.todo_e = offset + #day_text + 1, offset + #day_text + 1 + #body
			end
			if counts.done > 0 then
				local body = done_mark .. (counts.done <= 9 and tostring(counts.done) or "9+")
				geo.done_s, geo.done_e = offset + #day_text + #todo_badge + 1,
					offset + #day_text + #todo_badge + 1 + #body
			end
			cols[#cols + 1] = geo
			offset = offset + #text
			parts[#parts + 1] = text
		end
		lines[#lines + 1] = table.concat(parts)
		layout[#layout + 1] = cols
	end

	lines[#lines + 1] = PAD
		.. string.format("%s 未完成 · %s 已完成（数字为当日任务数）", todo_icon, done_mark)
	return lines, layout
end

---当日列表行（纯函数，供测试）
---@param date table
---@param items table[] 已排序（未完成在前，已完成在后）
---@param width integer
---@return string[] lines
function M.build_day_lines(date, items, width)
	local counts = service.counts(items)
	local stat = string.format("  ●%d 未完成 · ○%d 已完成", counts.todo, counts.done)
	local title = string.format("%s %s  (%d)", fmt_date(date), weekday_full(date), #items)
	local lines = { truncate(title, width), truncate(stat, width), "" }

	if #items == 0 then
		lines[4] = "  (无到期任务)"
	else
		for _, item in ipairs(items) do
			local right = item.id and ("todo:" .. item.id) or ""
			local box = item.completed and "○" or "◻"
			local left = "  " .. box .. " " .. (item.content ~= "" and item.content or "(无标题)")
			local fill = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
			if fill < 1 then
				left = truncate(left, math.max(1, width - vim.fn.strdisplaywidth(right) - 1))
				fill = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
			end
			lines[#lines + 1] = left .. string.rep(" ", fill) .. right
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "  <CR> 跳转 · b/Esc 返回 · q 关闭"
	return lines
end

---------------------------------------------------------------------
-- 渲染
---------------------------------------------------------------------
local function set_lines(lines)
	vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf })
	vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
end

local function render_month()
	local lines, layout = M.build_month_lines(state.year, state.month, state.items)
	set_lines(lines)

	local today = model.today()
	local grid = model.grid(state.year, state.month, { first_day_of_week = first_day_of_week() })

	for row, week in ipairs(grid) do
		local line = ROW_FIRST_WEEK + row - 1
		local cols = layout[row]
		for col, cell in ipairs(week) do
			local geo = cols[col]
			-- 本月之外：日期变暗（保留可点击/可跳转的上下文）
			if not cell.in_month then
				vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, geo.start, {
					end_col = geo.start + 2,
					hl_group = "TodoCalendarDim",
				})
			end
			-- 今天
			if model.same_day(cell, today) then
				vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, geo.start, {
					end_col = geo.start + 2,
					hl_group = "TodoCalendarToday",
					priority = 110,
				})
			end
			-- 选中日：整格反显
			if model.same_day(cell, state.day) then
				vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, geo.start, {
					end_col = geo.stop,
					hl_group = "TodoCalendarSelected",
					priority = 120,
				})
			end
			-- 状态圆点：●N 未完成（绿）/ ○N 已完成（灰），优先于反显，保证计数可读
			if geo.todo_s then
				vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, geo.todo_s, {
					end_col = geo.todo_e,
					hl_group = "TodoCalendarTodo",
					priority = 130,
				})
			end
			if geo.done_s then
				vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, geo.done_s, {
					end_col = geo.done_e,
					hl_group = "TodoCalendarDone",
					priority = 130,
				})
			end
		end
	end

	-- 标题行 / 星期行 / 图例
	vim.api.nvim_buf_set_extmark(state.buf, NS, 0, 0, { end_col = #lines[1], hl_group = "TodoCalendarHeader" })
	vim.api.nvim_buf_set_extmark(state.buf, NS, 2, 0, { end_col = #lines[3], hl_group = "TodoCalendarDim" })
	local legend = #lines
	vim.api.nvim_buf_set_extmark(state.buf, NS, legend - 1, 0, {
		end_col = #lines[legend],
		hl_group = "TodoCalendarHint",
	})

	-- 光标落到选中日
	for row, week in ipairs(grid) do
		for col, cell in ipairs(week) do
			if model.same_day(cell, state.day) then
				pcall(vim.api.nvim_win_set_cursor, state.win, { ROW_FIRST_WEEK + row - 1, layout[row][col].start })
				return
			end
		end
	end
end

---行集的最大显示宽度
---@param lines string[]
---@return integer
local function max_width(lines)
	local w = 0
	for _, line in ipairs(lines) do
		w = math.max(w, vim.fn.strdisplaywidth(line))
	end
	return w
end

---按内容与编辑器尺寸算出浮窗的 { width, height }
---@param lines string[]
---@param min_width integer
---@return integer width
---@return integer height
local function fit_window(lines, min_width)
	local width = math.min(math.max(max_width(lines) + 2, min_width), math.max(20, vim.o.columns - 4))
	local height = math.min(math.max(#lines, 6), math.max(6, vim.o.lines - 4))
	return width, height
end

---把浮窗摆到编辑器正中
---@param width integer
---@param height integer
local function center_window(width, height)
	local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))
	pcall(vim.api.nvim_win_set_config, state.win, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
	})
end

local function render_day(width)
	local lines = M.build_day_lines(state.day, state.day_items, width)
	set_lines(lines)

	for i, item in ipairs(state.day_items) do
		local line = i + 2
		local hl = item.completed and "TodoCalendarDone" or item.hl
		if hl then
			vim.api.nvim_buf_set_extmark(state.buf, NS, line, 0, {
				end_col = #lines[line + 1],
				hl_group = hl,
			})
		end
		if i == state.index then
			vim.api.nvim_buf_set_extmark(state.buf, NS, line, 0, { line_hl_group = "CursorLine" })
		end
	end
	local hint = #lines
	vim.api.nvim_buf_set_extmark(state.buf, NS, hint - 1, 0, {
		end_col = #lines[hint],
		hl_group = "TodoCalendarHint",
	})

	local line = (#state.day_items == 0) and 4 or (3 + state.index)
	pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, line), 0 })
end

local function render()
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	local is_day = state.mode == "day"
	local min_width = is_day and MIN_DAY_WIDTH or CAL_WIDTH
	local lines = is_day and M.build_day_lines(state.day, state.day_items, min_width)
		or M.build_month_lines(state.year, state.month, state.items)

	local width, height = fit_window(lines, min_width)
	center_window(width, height)

	if is_day then
		render_day(width)
	else
		render_month()
	end
end

---------------------------------------------------------------------
-- 导航
---------------------------------------------------------------------
local function reload(opts)
	opts = opts or {}
	state.items = service.month_items(state.year, state.month, { force_refresh = opts.force_refresh })
end

local function goto_month(year, month, day)
	state.year, state.month = year, month
	reload()
	state.day = { year = year, month = month, day = day or 1 }
	local max_day = model.days_in_month(year, month)
	state.day.day = math.max(1, math.min(state.day.day, max_day))
	render()
end

local function move_days(n)
	local target = model.add_days(state.day, n)
	if target.month ~= state.month or target.year ~= state.year then
		state.items = service.month_items(target.year, target.month)
		state.year, state.month = target.year, target.month
		state.day = target
		render()
		return
	end
	state.day = target
	render()
end

local function goto_today()
	local today = model.today()
	state.year, state.month, state.day = today.year, today.month, today
	reload()
	render()
end

local function open_day()
	state.day_items = state.items[state.day.day] or {}
	state.index = 1
	state.mode = "day"
	render()
end

local function back_to_month()
	state.mode = "month"
	state.day_items = {}
	render()
end

local function jump_to_task(item)
	if not item or not item.path or not item.line then
		return
	end
	local path, line = item.path, item.line
	M.close()
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
	vim.cmd("normal! zz")
end

---------------------------------------------------------------------
-- keymap
---------------------------------------------------------------------
local function map(lhs, fn, desc)
	vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, desc = desc })
end

local function setup_keymaps()
	map("q", function()
		M.close()
	end, "关闭月历")
	map("<Esc>", function()
		if state.mode == "day" then
			back_to_month()
		else
			M.close()
		end
	end, "返回/关闭")

	map("h", function()
		if state.mode == "day" then
			return
		end
		move_days(-1)
	end, "前一天")
	map("l", function()
		if state.mode == "day" then
			return
		end
		move_days(1)
	end, "后一天")
	map("k", function()
		if state.mode == "day" then
			if state.index > 1 then
				state.index = state.index - 1
				render()
			end
			return
		end
		move_days(-7)
	end, "上一周/上一条")
	map("j", function()
		if state.mode == "day" then
			if state.index < #state.day_items then
				state.index = state.index + 1
				render()
			end
			return
		end
		move_days(7)
	end, "下一周/下一条")

	map("H", function()
		if state.mode == "day" then
			return
		end
		local y, m = state.year, state.month - 1
		if m < 1 then
			y, m = y - 1, 12
		end
		goto_month(y, m, state.day.day)
	end, "上个月")
	map("L", function()
		if state.mode == "day" then
			return
		end
		local y, m = state.year, state.month + 1
		if m > 12 then
			y, m = y + 1, 1
		end
		goto_month(y, m, state.day.day)
	end, "下个月")
	map("t", function()
		goto_today()
	end, "回到今天")

	map("<CR>", function()
		if state.mode == "day" then
			jump_to_task(state.day_items[state.index])
			return
		end
		open_day()
	end, "打开当天任务 / 跳转")
	map("b", function()
		if state.mode == "day" then
			back_to_month()
		end
	end, "返回月视图")
end

---------------------------------------------------------------------
-- 生命周期
---------------------------------------------------------------------
local function ensure_buffer()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "todo2calendar", { buf = buf })
	local width = math.min(CAL_WIDTH, math.max(20, vim.o.columns - 4))
	local height = 12
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = WIN_TITLE,
		title_pos = "center",
	})
	return buf, win
end

---打开月历（已打开时聚焦并刷新）
---@param opts? { year?: integer, month?: integer, day?: integer }
function M.open(opts)
	opts = opts or {}
	setup_highlights()

	if state and state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_set_current_win(state.win)
		reload()
		render()
		return state.buf
	end

	local today = model.today()
	local year = opts.year or today.year
	local month = opts.month or today.month
	if year < 1970 or year > 9999 or month < 1 or month > 12 then
		vim.notify(string.format("%04d-%02d 不是有效月份", year, month), vim.log.levels.WARN)
		return
	end

	local buf, win = ensure_buffer()
	state = {
		buf = buf,
		win = win,
		year = year,
		month = month,
		day = { year = year, month = month, day = math.min(opts.day or today.day, model.days_in_month(year, month)) },
		mode = "month",
		items = {},
		day_items = {},
		index = 1,
	}

	reload()
	setup_keymaps()
	render()
	install_hooks()

	vim.api.nvim_create_autocmd("VimResized", {
		callback = function()
			M.refresh()
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			state = nil
		end,
	})
	return buf
end

---关闭月历
function M.close()
	if state and state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	state = nil
end

---切换开关
function M.toggle(opts)
	if state and state.win and vim.api.nvim_win_is_valid(state.win) then
		M.close()
	else
		M.open(opts)
	end
end

---有效且处于月视图时刷新（任务变化后调用）
function M.refresh()
	if state and state.win and vim.api.nvim_win_is_valid(state.win) and state.mode == "month" then
		reload({ force_refresh = true })
		render()
	end
end

return M
