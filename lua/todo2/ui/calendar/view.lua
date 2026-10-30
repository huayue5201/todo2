-- lua/todo2/ui/calendar/view.lua
--- 月历视图：单浮窗内两态（月视图 / 当日列表）。
---
--- 月视图有两种排版，渲染端按屏幕尺寸自动选择：
---   boxed（默认）每个日期一个圆角格子，选中格的边框整体高亮：
---     ╭────────╮╭────────╮ …   每格内宽 8 = DD + " ●N" + " ○N"
---     │15 ●2 ○1││16      │ …   ●N 未完成（绿）/ ○N 已完成（灰），0 不显示
---     ╰────────╯╰────────╯ …   7 × 10 列 + 左侧 2 列缩进 = 72
---   compact（屏幕太矮/太窄时的降级）单行每格，步长 9 列，总宽 65
--- 每格的字节偏移由 build_month_lines 连同 layout 一起返回，
--- 渲染端不自行做列算术（圆点/框线都是多字节字符，字节≠显示列）
--- 行结构（boxed）：标题 / 星期 / 每周 3 行（上边框·内容·下边框）/ 图例

local M = {}

local config = require("todo2.config")
local model = require("todo2.ui.calendar.model")
local service = require("todo2.ui.calendar.service")

local NS = vim.api.nvim_create_namespace("todo2.calendar")

local PAD = "  "
local CELL_INNER = 8 -- "DD" + " ●N" + " ○N"
local BOX_W = CELL_INNER + 2 -- 左右竖线
local CAL_WIDTH_BOXED = #PAD + 7 * BOX_W -- 72
local STEP = 9 -- compact：单元格步长（"DD" + " ●N" + " ○N" + 空格）
local CAL_WIDTH_COMPACT = #PAD + 7 * STEP -- 65
local BADGE_W = 3
local MIN_DAY_WIDTH = 40
local BOX_TOP, BOX_BOTTOM, BOX_SIDE = "╭", "╰", "│"

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
	-- 未完成计数沿用「todo 状态色」（可被 status.cycle 配置改色）
	vim.api.nvim_set_hl(0, "TodoCalendarCellActive", { link = "Title", bold = true, default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarTodo", { link = "Todo2ProgressTodo", default = true })
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

---左右都补齐到固定显示宽度（用于格子对齐）
---@param text string
---@param width integer
---@return string
local function pad_center(text, width)
	local w = vim.fn.strdisplaywidth(text)
	local left = math.max(0, math.floor((width - w) / 2))
	return string.rep(" ", left) .. text .. string.rep(" ", math.max(0, width - w - left))
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
---@class CalendarCellGeo
---@field start integer 日期文本起（0 基字节列）
---@field stop integer 单元格内容止（不含）
---@field todo_s integer|nil
---@field todo_e integer|nil
---@field done_s integer|nil
---@field done_e integer|nil
---@field box_s integer|nil 内容行整格框起（0 基字节列，含左右竖线）
---@field box_e integer|nil
---@field edge_s integer|nil 上/下边框行里的整格框起（框线是多字节字符，字节跨度另算）
---@field edge_e integer|nil

---@class CalendarRow
---@field line integer 内容行（1 基）
---@field top integer|nil 上边框行（仅 boxed）
---@field bot integer|nil 下边框行（仅 boxed）
---@field cells CalendarCellGeo[]

---@class CalendarLayout
---@field boxed boolean
---@field rows CalendarRow[]

---某个格子的日期文本与两个计数徽标（徽标定宽 3 列）
---@param cell table
---@param counts { todo: integer, done: integer }
---@return string day_text
---@return string todo_badge
---@return string done_badge
---@return string|nil todo_body 只有「圆点 + 数字」的部分（上色用）
---@return string|nil done_body
local function cell_parts(cell, counts)
	local todo_icon, done_mark = mark_icon(), done_icon()
	local day_text = cell.in_month and string.format("%2d", cell.day) or "  "
	local todo_body = counts.todo > 0 and (todo_icon .. (counts.todo <= 9 and counts.todo or "9+")) or nil
	local done_body = counts.done > 0 and (done_mark .. (counts.done <= 9 and counts.done or "9+")) or nil
	return day_text, badge(todo_icon, counts.todo), badge(done_mark, counts.done), todo_body, done_body
end

---拼出一个格子的 geo：base 为日期文本在行内的 0 基字节列
---@return CalendarCellGeo
local function cell_geo(base, day_text, todo_badge, done_badge, todo_body, done_body)
	local geo = { start = base, stop = base + #day_text + #todo_badge + #done_badge }
	if todo_body then
		geo.todo_s, geo.todo_e = base + #day_text + 1, base + #day_text + 1 + #todo_body
	end
	if done_body then
		geo.done_s = base + #day_text + #todo_badge + 1
		geo.done_e = geo.done_s + #done_body
	end
	return geo
end

---构造月视图（纯函数，供测试）。屏幕放不下 boxed 排版时由调用方改用 boxed=false。
---@param year integer
---@param month integer
---@param items table<integer, table[]>
---@param opts { boxed?: boolean }|nil
---@return string[] lines
---@return CalendarLayout layout
function M.build_month_lines(year, month, items, opts)
	local boxed = not (opts and opts.boxed == false)
	local grid = model.grid(year, month, { first_day_of_week = first_day_of_week() })

	-- 去掉整周都在本月之外的尾行（5 周月比 6 周月矮 3 行）
	local nweeks = #grid
	while nweeks > 1 do
		local has_in_month = false
		for _, cell in ipairs(grid[nweeks]) do
			if cell.in_month then
				has_in_month = true
				break
			end
		end
		if has_in_month then
			break
		end
		nweeks = nweeks - 1
	end

	local width = boxed and CAL_WIDTH_BOXED or CAL_WIDTH_COMPACT
	local lines = { center(string.format("%d 年 %d 月", year, month), width) }

	local header = {}
	for _, label in ipairs(weekday_label(model.week_start(first_day_of_week()))) do
		header[#header + 1] = boxed and pad_center(label, BOX_W) or string.format("%2s       ", label)
	end
	lines[2] = PAD .. table.concat(header)

	local layout = { boxed = boxed, rows = {} }
	local rule = string.rep("─", CELL_INNER)

	for w = 1, nweeks do
		local week = grid[w]
		local row = { cells = {} }
		local content, tops, bots = { PAD }, { PAD }, { PAD }
		local offset = #PAD
		for _, cell in ipairs(week) do
			local counts = cell.in_month and service.counts(items[cell.day]) or { todo = 0, done = 0 }
			local day_text, todo_badge, done_badge, todo_body, done_body = cell_parts(cell, counts)
			local body = day_text .. todo_badge .. done_badge
			local geo
			if boxed then
				local side = #BOX_SIDE
				geo = cell_geo(offset + side, day_text, todo_badge, done_badge, todo_body, done_body)
				geo.box_s = offset
				geo.box_e = offset + side * 2 + #body
				geo.edge_s = offset
				geo.edge_e = offset + #(BOX_TOP .. rule .. "╮")
				tops[#tops + 1] = BOX_TOP .. rule .. "╮"
				bots[#bots + 1] = BOX_BOTTOM .. rule .. "╯"
				content[#content + 1] = BOX_SIDE .. body .. BOX_SIDE
				offset = geo.box_e
			else
				geo = cell_geo(offset, day_text, todo_badge, done_badge, todo_body, done_body)
				local text = body .. " "
				content[#content + 1] = text
				offset = offset + #text
			end
			row.cells[#row.cells + 1] = geo
		end

		if boxed then
			row.top = #lines + 1
			lines[#lines + 1] = table.concat(tops)
			row.line = #lines + 1
			lines[#lines + 1] = table.concat(content)
			row.bot = #lines + 1
			lines[#lines + 1] = table.concat(bots)
		else
			row.line = #lines + 1
			lines[#lines + 1] = table.concat(content)
		end
		layout.rows[#layout.rows + 1] = row
	end

	lines[#lines + 1] = PAD
		.. string.format("%s 未完成 · %s 已完成（数字为当日任务数）", mark_icon(), done_icon())
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

---@param lines string[]
---@param layout CalendarLayout
local function render_month(lines, layout)
	set_lines(lines)
	local today = model.today()

	local grid = model.grid(state.year, state.month, { first_day_of_week = first_day_of_week() })
	for r, row in ipairs(layout.rows) do
		local week = grid[r]
		for c, geo in ipairs(row.cells) do
			local cell = week[c]
			local selected = model.same_day(cell, state.day)

			-- 本月之外：整格（含框线）变暗，保留可点击/可跳转的上下文
			if not cell.in_month then
				if row.top then
					vim.api.nvim_buf_set_extmark(state.buf, NS, row.top - 1, geo.edge_s, {
						end_col = geo.edge_e,
						hl_group = "TodoCalendarDim",
					})
					vim.api.nvim_buf_set_extmark(state.buf, NS, row.bot - 1, geo.edge_s, {
						end_col = geo.edge_e,
						hl_group = "TodoCalendarDim",
					})
					vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.box_s, {
						end_col = geo.box_e,
						hl_group = "TodoCalendarDim",
						priority = 10,
					})
				else
					vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.start, {
						end_col = geo.stop + 1,
						hl_group = "TodoCalendarDim",
					})
				end
			end

			-- 今天：日期数字高亮
			if model.same_day(cell, today) then
				vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.start, {
					end_col = geo.start + 2,
					hl_group = "TodoCalendarToday",
					priority = 110,
				})
			end

			-- 选中日：框线整体高亮（boxed）/ 整格反显（compact）
			if selected and row.top then
				for _, line in ipairs({ row.top, row.bot }) do
					vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, geo.edge_s, {
						end_col = geo.edge_e,
						hl_group = "TodoCalendarCellActive",
						priority = 120,
					})
				end
				vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.start, {
					end_col = geo.start + 2,
					hl_group = "TodoCalendarSelected",
					priority = 125,
				})
			elseif selected then
				vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.start, {
					end_col = geo.stop,
					hl_group = "TodoCalendarSelected",
					priority = 120,
				})
			end

			-- 状态圆点：●N 未完成（绿）/ ○N 已完成（灰），优先级最高，保证计数可读
			if geo.todo_s then
				vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.todo_s, {
					end_col = geo.todo_e,
					hl_group = "TodoCalendarTodo",
					priority = 130,
				})
			end
			if geo.done_s then
				vim.api.nvim_buf_set_extmark(state.buf, NS, row.line - 1, geo.done_s, {
					end_col = geo.done_e,
					hl_group = "TodoCalendarDone",
					priority = 130,
				})
			end

			if selected then
				pcall(vim.api.nvim_win_set_cursor, state.win, { row.line, geo.start })
			end
		end
	end

	-- 标题行 / 星期行 / 图例
	vim.api.nvim_buf_set_extmark(state.buf, NS, 0, 0, { end_col = #lines[1], hl_group = "TodoCalendarHeader" })
	vim.api.nvim_buf_set_extmark(state.buf, NS, 1, 0, { end_col = #lines[2], hl_group = "TodoCalendarDim" })
	local legend = #lines
	vim.api.nvim_buf_set_extmark(state.buf, NS, legend - 1, 0, {
		end_col = #lines[legend],
		hl_group = "TodoCalendarHint",
	})
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

---行集能否完整放进屏幕（含浮窗边框与留白）
---@param lines string[]
---@return boolean
local function fits_screen(lines)
	return #lines + 2 <= vim.o.lines - 1 and max_width(lines) + 4 <= vim.o.columns
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
	if state.mode == "day" then
		local lines = M.build_day_lines(state.day, state.day_items, MIN_DAY_WIDTH)
		local width, height = fit_window(lines, MIN_DAY_WIDTH)
		center_window(width, height)
		render_day(width)
		return
	end

	-- 月视图：优先圆角格子排版，屏幕放不下时降级为单行紧凑排版
	local lines, layout = M.build_month_lines(state.year, state.month, state.items, { boxed = true })
	if not fits_screen(lines) then
		lines, layout = M.build_month_lines(state.year, state.month, state.items, { boxed = false })
	end
	local min_width = layout.boxed and CAL_WIDTH_BOXED or CAL_WIDTH_COMPACT
	local width, height = fit_window(lines, min_width)
	center_window(width, height)
	render_month(lines, layout)
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
	local width = math.min(CAL_WIDTH_BOXED, math.max(20, vim.o.columns - 4))
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
