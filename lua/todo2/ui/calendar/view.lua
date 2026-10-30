-- lua/todo2/ui/calendar/view.lua
--- 月历视图：单浮窗内两态（月视图 / 当日列表）。
---
--- 月视图有两种排版，渲染端按屏幕尺寸自动选择：
---   grid（默认）纯背景色块分格（不用任何边框字符，字符底色的方块感就是格子）：
---       Mo        Tu        We        Th        Fr        Sa        Su
---        1         2         3 ●1      4         5         6         7
---                                       ▎过期任务
---
---     每格 9 显示列、格间 1 列空白，周与周之间隔一条空白行：格子由一块
---     底色矩形表示，不画框线。每格 2 行：第 1 行 = 日期 + 计数，第 2 行 =
---     最紧急任务标题（▎ 色条 + 截断标题）。忙碌度 = 底色深浅三档；今天 =
---     日期上的强调色块；选中日 = 更亮的整格底色。本月以外的日期不着底色。
---   compact（屏幕太矮/太窄时的降级）单行每格、步长 9 列，总宽 65
--- 每格的字节偏移由 build_month_lines 连同 layout 一起返回，渲染端不做列
--- 算术（圆点/色条都是多字节字符，字节 != 显示列）。
--- 行结构（grid）：标题 / 星期 / 每周（内容 2 行，前置一条分隔线）/ 图例

local M = {}

local config = require("todo2.config")
local model = require("todo2.ui.calendar.model")
local service = require("todo2.ui.calendar.service")

local NS = vim.api.nvim_create_namespace("todo2.calendar")

local PAD = "  "
local CELL_W = 9 -- 每格内容宽度（显示列）："15 ●2 ○1" / " 3 ●1"
local COLS = 7 -- 一周 7 天
local CELL_GAP = " " -- 格间空白（不着色，让底色方块彼此分开）
local GRID_WIDTH = #PAD + COLS * CELL_W + (COLS - 1) -- 71 显示列
local COMPACT_WIDTH = #PAD + COLS * CELL_W -- 65 显示列
local MIN_DAY_WIDTH = 40
local PANEL_MIN_COLUMNS = 116 -- 屏幕至少这么宽才在月视图右侧挂当日面板
local PANEL_WIDTH = 36 -- 面板内容宽度（不含左侧分隔符）
local PANEL_SEP = "│" -- 月历与面板之间的分隔
local CHIP_BAR = "▎" -- 任务色条（GUI 事件样式）
local HEAT_LEVELS = { [1] = 1, [2] = 2, [3] = 3 } -- 未完成数 -> 热力档位

local WEEKDAY_LABELS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local WEEKDAY_FULL = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }

local WIN_TITLE = " 📅 月历 "

---@type table 状态：{ buf, win, year, month, day, mode, items, day_items, index }
local state = nil
local lock_view ---@type fun()|nil 前向声明（keymap 里要用）

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
---取某个高亮组的前景色（用于派生半透明底色）
---@param name string
---@param fallback string
---@return string
local function fg_of(name, fallback)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	if ok and hl and hl.fg then
		return string.format("#%06x", hl.fg)
	end
	return fallback
end

---某个高亮组是否有背景色
---@param name string
---@return boolean
local function has_bg(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and hl ~= nil and hl.bg ~= nil
end

---按主题色派生「今天胶囊」与热力档位（半透明底 + blend，深浅与主题无关）
local function setup_tints()
	vim.api.nvim_set_hl(0, "TodoCalendarToday", {
		bg = fg_of("TodoDueSoon", "#ffa94d"),
		blend = 55,
		bold = true,
		default = true,
	})
	local tint = fg_of("Todo2ProgressTodo", "#51cf66")
	for level, blend in pairs({ [1] = 91, [2] = 84, [3] = 74 }) do
		vim.api.nvim_set_hl(0, "TodoCalendarHeat" .. level, { bg = tint, blend = blend, default = true })
	end
	-- 空格子（本月内但没有任务）也给一块很淡的底，格子形状才连成一片
	vim.api.nvim_set_hl(0, "TodoCalendarCell", { bg = fg_of("Comment", "#808080"), blend = 94, default = true })
end

local hl_ready = false
local function setup_highlights()
	if hl_ready then
		return
	end
	hl_ready = true
	-- 今天：日期外套一块柔和的色块（取 TodoDueSoon 的前景色做半透明底）
	-- 热力：忙碌度三档淡底，取 todo 状态色做半透明底，深浅随档位递增
	vim.api.nvim_set_hl(0, "TodoCalendarSelected", { link = "Visual", bold = true, default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarDim", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarHeader", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarHint", { link = "Comment", italic = true, default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarRule", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarTodo", { link = "Todo2ProgressTodo", default = true })
	vim.api.nvim_set_hl(0, "TodoCalendarDone", { link = "Comment", default = true })
	setup_tints()
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
---@field start integer 第 1 行日期文本起（0 基字节列）
---@field stop integer 第 1 行文本止（不含）
---@field bg_s integer 整格底色起（0 基字节列）
---@field bg_e integer 整格底色止（不含）
---@field todo_s integer|nil
---@field todo_e integer|nil
---@field done_s integer|nil
---@field done_e integer|nil
---@field chip_s integer|nil 第 2 行整格起
---@field chip_e integer|nil
---@field bar_s integer|nil 色条起
---@field bar_e integer|nil
---@field text_s integer|nil 标题起
---@field text_e integer|nil
---@field heat integer 0..3 忙碌度档位（0 = 不着色）
---@field chip_hl string|nil 色条用的高亮组（取任务紧迫度）

---@class CalendarRow
---@field line integer 第 1 行（1 基）
---@field chip integer|nil 第 2 行（1 基，仅 grid 排版）
---@field rule integer|nil 周分隔线（1 基，仅 grid 排版）
---@field cells CalendarCellGeo[]

---@class CalendarLayout
---@field grid boolean
---@field rows CalendarRow[]

---补齐到固定显示宽度（多字节字符按显示列算）
---@param text string
---@param width integer
---@return string
local function pad_end(text, width)
	local w = vim.fn.strdisplaywidth(text)
	return w >= width and text or text .. string.rep(" ", width - w)
end

---行集中最宽一行的显示宽度
---@param lines string[]
---@return integer
local function max_width(lines)
	local max = 0
	for _, line in ipairs(lines) do
		max = math.max(max, vim.fn.strdisplaywidth(line))
	end
	return max
end

local function count_text(n)
	return n <= 9 and tostring(n) or "9+"
end

---格子第 1 行：日期 + 两个计数（未完成/已完成），返回文本与各段字节偏移。
---内容在格子里居中（没有计数时日期才好看），所以额外返回左侧补的字节数。
---@return string text
---@return { todo_s?: integer, todo_e?: integer, done_s?: integer, done_e?: integer }
---@return integer lead 左侧补的字节数
local function counts_text(cell, counts)
	local todo_icon, done_mark = mark_icon(), done_icon()
	local text = cell.in_month and string.format("%2d", cell.day) or "  "
	local spans = {}
	if counts.todo > 0 then
		local body = todo_icon .. count_text(counts.todo)
		spans.todo_s, spans.todo_e = #text + 1, #text + 1 + #body
		text = text .. " " .. body
	end
	if counts.done > 0 then
		local body = done_mark .. count_text(counts.done)
		spans.done_s, spans.done_e = #text + 1, #text + 1 + #body
		text = text .. " " .. body
	end
	local lead = math.max(0, math.floor((CELL_W - vim.fn.strdisplaywidth(text)) / 2))
	-- 先补左侧再补右侧：总宽必须精确等于 CELL_W（否则格子会忽宽忽窄）
	local content = string.rep(" ", lead) .. text
	local rest = CELL_W - vim.fn.strdisplaywidth(content)
	if rest > 0 then
		content = content .. string.rep(" ", rest)
	end
	return content, spans, lead
end

---格子第 2 行：最紧急的一条未完成任务（色条 + 截断标题）
---@param items table[]|nil
---@return string text 定宽 CELL_W
---@return string|nil hl 色条颜色（任务紧迫度）
---@return integer title_bytes 标题的字节长度（0 = 无标题）
local function chip_text(items)
	for _, item in ipairs(items or {}) do
		if not item.completed then
			local title = truncate(item.content ~= "" and item.content or "(无标题)", CELL_W - 1)
			return pad_end(CHIP_BAR .. title, CELL_W), item.hl, #title
		end
	end
	return pad_end("", CELL_W), nil, 0
end

---右侧当日面板的文本行与渲染段（与月历等高，超出部分折叠为 +N）
---@param date { year: integer, month: integer, day: integer }
---@param items table[]
---@param width integer
---@param height integer
---@return string[] lines
---@return table[] segs { line, from, to, hl }
local function build_agenda_lines(date, items, width, height)
	local lines, segs = {}, {}
	local head = string.format("%d 月 %d 日 %s", date.month, date.day, weekday_full(date))
	lines[1] = pad_end(truncate(head, width), width)
	segs[#segs + 1] = { 1, 0, #lines[1], "TodoCalendarHeader" }

	local counts = service.counts(items)
	local stat = string.format("%s %d　%s %d", mark_icon(), counts.todo, done_icon(), counts.done)
	lines[2] = pad_end(truncate(stat, width), width)
	segs[#segs + 1] = { 2, 0, #lines[2], "TodoCalendarHint" }

	local row, shown = 3, 0
	for _, item in ipairs(items) do
		if row > height then
			break
		end
		local text = truncate(item.content ~= "" and item.content or "(无标题)", width - 2)
		local bar = CHIP_BAR
		local body = bar .. " " .. text
		lines[row] = pad_end(body, width)
		segs[#segs + 1] = { row, 0, #bar, item.completed and "TodoCalendarDone" or item.hl }
		if item.completed then
			segs[#segs + 1] = { row, #bar + 1, #body, "TodoCalendarDone" }
		end
		row = row + 1
		shown = shown + 1
	end

	local rest = #items - shown
	if rest > 0 and row <= height - 1 then
		lines[row] = pad_end(string.format("… 还有 %d 条", rest), width)
		segs[#segs + 1] = { row, 0, #lines[row], "TodoCalendarHint" }
	end
	-- 末行：操作提示（与月历底部图例同行）
	if height >= 3 then
		local hint = truncate("j/k 切换日期 ⏎ 当日", width)
		lines[height] = pad_end(hint, width)
		segs[#segs + 1] = { height, 0, #lines[height], "TodoCalendarHint" }
	end
	for i = 1, height do
		if not lines[i] then
			lines[i] = pad_end("", width)
		else
			lines[i] = pad_end(lines[i], width)
		end
	end
	return lines, segs
end

---@param year integer
---@param month integer
---@param items table<integer, table[]>
---@param opts { grid?: boolean, agenda?: { date: {year:integer,month:integer,day:integer}, items: table[], width: integer } }|nil grid=false 时使用单行紧凑排版
---@return string[] lines
---@return CalendarLayout layout
function M.build_month_lines(year, month, items, opts)
	local grid_mode = not (opts and opts.grid == false)
	local grid = model.grid(year, month, { first_day_of_week = first_day_of_week() })

	-- 去掉整周都在本月之外的尾行（5 周月比 6 周月矮）
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

	local width = grid_mode and GRID_WIDTH or COMPACT_WIDTH
	local lines = { center(string.format("%d 年 %d 月", year, month), width) }

	local header = {}
	for i, label in ipairs(weekday_label(model.week_start(first_day_of_week()))) do
		header[#header + 1] = pad_center(label, CELL_W) .. (i < COLS and " " or "")
	end
	lines[2] = PAD .. table.concat(header)

	local layout = { grid = grid_mode, rows = {} }

	for w = 1, nweeks do
		local week = grid[w]
		local row = { cells = {} }
		local first, chip_line = { PAD }, { PAD }
		local offset, chip_offset = #PAD, #PAD

		for c, cell in ipairs(week) do
			if c > 1 and grid_mode then
				first[#first + 1] = CELL_GAP
				chip_line[#chip_line + 1] = CELL_GAP
				offset = offset + #CELL_GAP
				chip_offset = chip_offset + #CELL_GAP
			end
			local counts = cell.in_month and service.counts(items[cell.day]) or { todo = 0, done = 0 }
			local text, spans, lead = counts_text(cell, counts)
			local base = offset + lead
			local geo = {
				start = base,
				stop = offset + #text,
				bg_s = offset,
				bg_e = offset + #text,
				heat = HEAT_LEVELS[math.min(counts.todo, 3)] or 0,
			}
			geo.todo_s, geo.todo_e = spans.todo_s and base + spans.todo_s, spans.todo_e and base + spans.todo_e
			geo.done_s, geo.done_e = spans.done_s and base + spans.done_s, spans.done_e and base + spans.done_e
			first[#first + 1] = text
			offset = offset + #text

			if grid_mode then
				local chip, hl, title_bytes = chip_text(cell.in_month and items[cell.day] or nil)
				geo.chip_s, geo.chip_e = chip_offset, chip_offset + #chip
				chip_line[#chip_line + 1] = chip
				chip_offset = chip_offset + #chip
				if hl then
					geo.chip_hl = hl
					geo.bar_s = geo.chip_s
					geo.bar_e = geo.chip_s + #CHIP_BAR
					geo.text_s = geo.bar_e
					geo.text_e = geo.bar_e + title_bytes
				end
			end
			row.cells[#row.cells + 1] = geo
		end

		if grid_mode then
			if w > 1 then
				lines[#lines + 1] = "" -- 周间空行：让上下两排底色块分开
			end
			row.line = #lines + 1
			lines[#lines + 1] = table.concat(first)
			row.chip = #lines + 1
			lines[#lines + 1] = table.concat(chip_line)
		else
			row.line = #lines + 1
			lines[#lines + 1] = table.concat(first)
		end
		layout.rows[#layout.rows + 1] = row
	end

	lines[#lines + 1] = PAD
		.. string.format("%s 未完成 · %s 已完成 · %s 当日 · q 关闭", mark_icon(), done_icon(), "⏎")

	-- 右侧当日面板：与月历逐行拼接（行数不足时补空行，保证两侧等高）
	local agenda = opts and opts.agenda
	if agenda and agenda.width and agenda.width > 0 then
		local panel, panel_segs = build_agenda_lines(agenda.date, agenda.items or {}, agenda.width, #lines)
		local month_width = max_width(lines)
		local shift = month_width + #PANEL_SEP
		for i, line in ipairs(lines) do
			lines[i] = pad_end(line, month_width) .. PANEL_SEP .. panel[i]
		end
		for _, seg in ipairs(panel_segs) do
			seg[2], seg[3] = seg[2] + shift, seg[3] + shift
		end
		layout.agenda = { width = agenda.width, sep_col = month_width, segs = panel_segs }
	end
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
			local left = "  " .. CHIP_BAR .. " " .. (item.content ~= "" and item.content or "(无标题)")
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
	local grid = model.grid(state.year, state.month, { first_day_of_week = first_day_of_week() })
	local today = model.today()

	---@param line integer 1 基
	---@param from integer 0 基字节列
	---@param to integer
	local function paint(line, from, to, group, priority)
		if to <= from then
			return
		end
		vim.api.nvim_buf_set_extmark(state.buf, NS, line - 1, from, {
			end_col = to,
			hl_group = group,
			priority = priority or 100,
		})
	end

	for r, row in ipairs(layout.rows) do
		local week = grid[r]
		if row.rule then
			local rule_line = lines[row.rule]
			paint(row.rule, #PAD, #rule_line, "TodoCalendarRule")
		end
		for c, geo in ipairs(row.cells) do
			local cell = week[c]
			local selected = model.same_day(cell, state.day)
			local lines_of_cell = { { row.line, geo.bg_s, geo.bg_e } }
			if row.chip then
				lines_of_cell[#lines_of_cell + 1] = { row.chip, geo.chip_s, geo.chip_e }
			end

			-- 格子 = 一块底色矩形：本月内一定有底（没任务用最淡的），越忙越深
			if cell.in_month then
				local bg = geo.heat > 0 and ("TodoCalendarHeat" .. geo.heat) or "TodoCalendarCell"
				for _, seg in ipairs(lines_of_cell) do
					paint(seg[1], seg[2], seg[3], bg, 90)
				end
			else
				-- 本月之外：不上底色，文字压暗
				for _, seg in ipairs(lines_of_cell) do
					paint(seg[1], seg[2], seg[3], "TodoCalendarDim", 95)
				end
			end
			-- 选中日：整格淡底（Visual），盖过热力
			if selected then
				for _, seg in ipairs(lines_of_cell) do
					paint(seg[1], seg[2], seg[3], "TodoCalendarSelected", 120)
				end
			end
			-- 今天：日期外套胶囊（优先级最高，压过选中底色）
			if model.same_day(cell, today) then
				paint(row.line, geo.start, geo.start + 2, "TodoCalendarToday", 130)
			end
			-- 计数：●N 未完成（绿）/ ○N 已完成（灰）
			if geo.todo_s then
				paint(row.line, geo.todo_s, geo.todo_e, "TodoCalendarTodo", 140)
			end
			if geo.done_s then
				paint(row.line, geo.done_s, geo.done_e, "TodoCalendarDone", 140)
			end
			-- 事件色条（GUI 事件样式）：色条用紧迫度色，标题淡化避免抢眼
			if geo.chip_hl then
				paint(row.chip, geo.bar_s, geo.bar_e, geo.chip_hl, 140)
				paint(row.chip, geo.text_s, geo.text_e, "TodoCalendarDim", 110)
			end

			if selected then
				pcall(vim.api.nvim_win_set_cursor, state.win, { row.line, geo.start })
			end
		end
	end

	-- 右侧当日面板：分隔线 + 标题/统计/色条
	if layout.agenda then
		local sep_col = layout.agenda.sep_col
		for i = 1, #lines do
			paint(i, sep_col, sep_col + #PANEL_SEP, "TodoCalendarRule")
		end
		for _, seg in ipairs(layout.agenda.segs) do
			paint(seg[1], seg[2], seg[3], seg[4])
		end
	end

	-- 标题行 / 星期行 / 图例
	paint(1, 0, #lines[1], "TodoCalendarHeader")
	paint(2, 0, #lines[2], "TodoCalendarDim")
	local legend = #lines
	paint(legend, 0, #lines[legend], "TodoCalendarHint")
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

	-- 月视图：优先细线分栏版式，屏幕放不下时降级为单行紧凑排版
	local agenda_opts
	if vim.o.columns >= PANEL_MIN_COLUMNS then
		agenda_opts = {
			date = state.day,
			items = service.day_items(state.year, state.month, state.day.day),
			width = PANEL_WIDTH,
		}
	end
	local lines, layout = M.build_month_lines(state.year, state.month, state.items, {
		grid = true,
		agenda = agenda_opts,
	})
	if not fits_screen(lines) then
		lines, layout = M.build_month_lines(state.year, state.month, state.items, { grid = false })
	end
	if layout.agenda and layout.grid then
		-- 面板让布局变宽：再确认一次放得下，放不下就丢掉面板
		if not fits_screen(lines) then
			lines, layout = M.build_month_lines(state.year, state.month, state.items, { grid = true })
		end
	end
	local min_width = layout.grid and GRID_WIDTH or COMPACT_WIDTH
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
	-- 视口锁死：滚轮/翻页/居中一律无效，内容永远从第 1 行开始画
	for _, key in ipairs({
		"<C-e>",
		"<C-y>",
		"<C-d>",
		"<C-u>",
		"<C-f>",
		"<C-b>",
		"<C-o>",
		"<C-i>",
		"zz",
		"zt",
		"zb",
		"H",
		"M",
		"L",
		"<ScrollWheelUp>",
		"<ScrollWheelDown>",
		"<ScrollWheelLeft>",
		"<ScrollWheelRight>",
	}) do
		vim.keymap.set("n", key, function()
			if lock_view then
				lock_view()
			end
		end, { buffer = state.buf, nowait = true, silent = true, desc = "月历：锁定视口" })
	end

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
---浮窗选项：固定视口（不换行、无 scrolloff、不可横向滚动），不透明
---@param win integer
local function configure_window(win)
	local function set(name, value)
		pcall(vim.api.nvim_set_option_value, name, value, { win = win })
	end
	set("wrap", false)
	set("scrolloff", 0)
	set("sidescrolloff", 0)
	set("virtualedit", "")
	set("winfixheight", true)
	set("winfixwidth", true)
	set("list", false)
	set("number", false)
	-- 半透明由配置决定；默认 0 = 完全不透明，避免下层代码透进来
	local blend = config.get("calendar.winblend")
	set("winblend", type(blend) == "number" and blend >= 0 and blend or 0)
	-- 兜底：主题没给 NormalFloat 背景时借用 Normal，防止「透明」透着看到代码
	if not has_bg("NormalFloat") then
		pcall(vim.api.nvim_set_option_value, "winhighlight", "Normal:Normal,NormalNC:Normal", { win = win })
	end
end

---把视口钉在左上角（任何滚动都撤销），避免内容被滚出窗口
function lock_view()
	if not (state and state.win and vim.api.nvim_win_is_valid(state.win)) then
		return
	end
	pcall(vim.api.nvim_win_call, state.win, function()
		local info = vim.fn.getwininfo(state.win)[1]
		if info and (info.topline ~= 1 or info.leftcol ~= 0) then
			vim.fn.winrestview({ topline = 1, leftcol = 0 })
		end
	end)
end

local function ensure_buffer()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "todo2calendar", { buf = buf })
	local width = math.min(GRID_WIDTH, math.max(20, vim.o.columns - 4))
	local height = 12 -- 立即被 center_window 按内容改写
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
	configure_window(win)
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

	-- 滚动（<C-e>/鼠标/zz）后立刻把视口拉回左上角，文字不会被滚出窗口
	vim.api.nvim_create_autocmd({ "WinScrolled", "WinEnter", "CursorMoved" }, {
		buffer = buf,
		callback = function()
			if lock_view then
				lock_view()
			end
		end,
	})

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
