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
---     底色矩形表示，不画框线。每格 2 行：第 1 行 = 日期（固定左对齐）+
---     计数（右对齐），第 2 行 = 最紧急任务标题（▎ 色条 + 截断标题）。
---     忙碌度 = 底色深浅三档；今天 = 日期上的强调色块；选中日 = 更亮的整格
---     底色。本月以外的日期不着底色。
---   屏幕够宽（>= PANEL_MIN_COLUMNS）时在右侧拼一栏当日面板，与月历等高。
---   compact（屏幕太矮/太窄或放下 panel 时的降级）单行每格、步长 9 列，总宽 65
--- 每格的字节偏移由 build_month_lines 连同 layout 一起返回，渲染端不做列
--- 算术（圆点/色条都是多字节字符，字节 != 显示列）。
--- 行结构（grid）：标题 / 星期 / 每周（内容 2 行，周间一条空行）/ 图例
--- 偏移约定：layout 里所有列号都是 **0 基字节列**（给 extmark 用）；凡是跟
--- 宽度有关的计算一律走 strdisplaywidth（CJK/圆点是双宽或多字节）。

local M = {}

local config = require("todo2.config")
local model = require("todo2.ui.calendar.model")
local service = require("todo2.ui.calendar.service")

local NS = vim.api.nvim_create_namespace("todo2.calendar")

local PAD = "  "
local CELL_W = 10 -- 每格内容宽度（显示列）："15 ● 2 ○ 1"；图标与数字之间始终留空格
local COLS = 7 -- 一周 7 天
local CELL_GAP = " " -- 格间空白（不着色，让底色方块彼此分开）
local GRID_WIDTH = #PAD + COLS * CELL_W + (COLS - 1) -- 78 显示列（compact 同宽，只是每周 1 行）
local MIN_DAY_WIDTH = 40
local PANEL_MIN_COLUMNS = 116 -- 屏幕至少这么宽才在月视图右侧挂当日面板
local PANEL_WIDTH = 36 -- 面板内容宽度（不含左侧分隔符）
local PANEL_SEP = "│" -- 月历与面板之间的分隔
local CHIP_BAR = "▎" -- 任务色条（GUI 事件样式）

local WEEKDAY_LABELS = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
local WEEKDAY_FULL = {
	"Sunday",
	"Monday",
	"Tuesday",
	"Wednesday",
	"Thursday",
	"Friday",
	"Saturday",
}
local MONTHS = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}
local MONTHS_SHORT = {
	"Jan",
	"Feb",
	"Mar",
	"Apr",
	"May",
	"Jun",
	"Jul",
	"Aug",
	"Sep",
	"Oct",
	"Nov",
	"Dec",
}

local WIN_TITLE = " 📅 Calendar "

---@type table 状态：{ buf, win, year, month, day, mode, items, day_items, index }
local state = nil
local lock_view ---@type fun()|nil 前向声明（keymap 里要用）

-- 任务变化（状态/删除/改期）后自动重算；未打开时 refresh 是空操作
local hooks_installed = false
local function install_hooks()
	if hooks_installed then
		return
	end
	-- 订阅成功后才置位：events 模块暂不可用时会重试，而不是永久放弃
	local ok = pcall(function()
		require("todo2.core.events").on_change(function()
			M.refresh()
		end)
	end)
	hooks_installed = ok
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

---按主题色派生「今天日期色块」与热力档位（半透明底 + blend，深浅与主题无关）
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
local color_hook = false
local function setup_highlights()
	if hl_ready then
		return
	end
	hl_ready = true
	-- 主题色是从当前 colorscheme 采样成字面值的，换主题后要重新采样
	if not color_hook then
		color_hook = true
		vim.api.nvim_create_autocmd("ColorScheme", {
			callback = function()
				hl_ready = false
				if state and vim.api.nvim_win_is_valid(state.win) then
					setup_highlights()
				end
			end,
		})
	end
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
---@field cells CalendarCellGeo[]

---@class CalendarLayout
---@field grid boolean
---@field width integer 内容区显示宽度（最宽一行）
---@field rows CalendarRow[]
---@field weeks integer[][][]|nil model.grid 的结果（渲染端复用，避免重算）
---@field agenda { sep_cols: integer[], segs: table[] }|nil 右侧面板（逐行字节偏移）

---补齐到固定显示宽度（多字节字符按显示列算）
---@param text string
---@param width integer
---@return string
local function pad_end(text, width)
	local w = vim.fn.strdisplaywidth(text)
	return w >= width and text or text .. string.rep(" ", width - w)
end

---行集中最宽一行的显示宽度（**显示列**，不是字节数）
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

---格子第 1 行：日期在固定列（左对齐），计数右对齐——日期位置不随计数多少跳动
---@return string text 定宽 CELL_W
---@return { todo_s?: integer, todo_e?: integer, done_s?: integer, done_e?: integer }
local function counts_text(cell, counts, icons)
	-- 不变量：这里所有「宽度」都用 strdisplaywidth（显示列），所有 extmark 偏移
	-- 都是 #s（字节列）；两者只在纯 ASCII 时相等，混用就会错位。
	local todo_icon, done_mark = icons.todo, icons.done
	local date = cell.in_month and string.format("%2d", cell.day) or "  "
	local head = " " .. date -- 日期占 3 列（1 空格 + 2 位数字），所有格子对齐

	local badges = {}
	if counts.todo > 0 then
		badges[#badges + 1] = { key = "todo", icon = todo_icon, num = count_text(counts.todo) }
	end
	if counts.done > 0 then
		badges[#badges + 1] = { key = "done", icon = done_mark, num = count_text(counts.done) }
	end

	-- 图标与数字之间留空格：● 属于「宽度不定」字符，某些字体按 2 列渲染，
	-- 紧贴数字会视觉重叠（月格与当日列表都会）。宽度不够时逐级收紧
	-- （留空格 -> 紧贴 -> 去掉分隔符）。
	local avail = CELL_W - #head
	local function body_of(b, spaced)
		return spaced and (b.icon .. " " .. b.num) or (b.icon .. b.num)
	end
	local function compose(spaced, sep)
		local parts = {}
		for _, b in ipairs(badges) do
			parts[#parts + 1] = body_of(b, spaced)
		end
		return table.concat(parts, sep)
	end
	-- 三级降级：图标+空格+数字（最清楚）→ 图标紧贴数字但两个计数分开 → 全紧贴；
	-- 并且始终给日期与计数之间留至少 1 列空白
	local candidates = { { true, " " }, { false, " " }, { false, "" } }
	local spaced, sep = false, ""
	local badge_str = ""
	for i, cand in ipairs(candidates) do
		local str = compose(cand[1], cand[2])
		local room = (i == #candidates) and avail or (avail - 1)
		if vim.fn.strdisplaywidth(str) <= math.max(room, 0) then
			spaced, sep, badge_str = cand[1], cand[2], str
			break
		end
	end
	if badge_str == "" then
		spaced, sep = false, ""
		badge_str = compose(false, "")
	end
	local gap = math.max(0, avail - vim.fn.strdisplaywidth(badge_str))
	local text = head .. string.rep(" ", gap) .. badge_str

	-- 计数段偏移（相对本行，1 基字节下标）：按顺序逐个定位，避免重复计数时找错
	local spans = {}
	local cursor = #head + gap + 1
	for _, b in ipairs(badges) do
		local body = body_of(b, spaced)
		local s_at, e_at = text:find(body, cursor, true)
		if s_at then
			-- 统一成 [s, e) 半开区间（find 给的是闭区间，末尾 +1）
			spans[b.key .. "_s"], spans[b.key .. "_e"] = s_at, e_at + 1
			cursor = e_at + 1
		end
	end
	return text, spans
end

---格子第 2 行：最紧急的一条未完成任务（色条 + 截断标题）
---@param items table[]|nil
---@return string text 定宽 CELL_W
---@return string|nil hl 色条颜色（任务紧迫度）
---@return integer title_bytes 标题的字节长度（0 = 无标题）
local function chip_text(items)
	for _, item in ipairs(items or {}) do
		if not item.completed then
			local title = truncate(item.content ~= "" and item.content or "(untitled)", CELL_W - 1)
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
	local head = string.format("%s %d · %s", MONTHS_SHORT[date.month], date.day, weekday_full(date))
	lines[1] = pad_end(truncate(head, width), width)
	segs[#segs + 1] = { 1, 0, #lines[1], "TodoCalendarHeader" }

	local counts = service.counts(items)
	local stat = string.format("%s %d open · %s %d done", mark_icon(), counts.todo, done_icon(), counts.done)
	lines[2] = pad_end(truncate(stat, width), width)
	segs[#segs + 1] = { 2, 0, #lines[2], "TodoCalendarHint" }

	local row, shown = 3, 0
	for _, item in ipairs(items) do
		if row > height then
			break
		end
		local text = truncate(item.content ~= "" and item.content or "(untitled)", width - 2)
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
		lines[row] = pad_end(string.format("… %d more", rest), width)
		segs[#segs + 1] = { row, 0, #lines[row], "TodoCalendarHint" }
	end
	-- 末行：操作提示（与月历底部图例同行）
	if height >= 3 then
		local hint = truncate("j/k change day · ⏎ open", width)
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
	local icons = { todo = mark_icon(), done = done_icon() }
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

	local width = GRID_WIDTH
	local lines = { center(string.format("%s %d", MONTHS[month], year), width) }

	local header = {}
	for i, label in ipairs(weekday_label(model.week_start(first_day_of_week()))) do
		header[#header + 1] = " " .. pad_end(label, CELL_W - 1) .. (i < COLS and " " or "")
	end
	lines[2] = PAD .. table.concat(header)

	local layout = { grid = grid_mode, rows = {}, weeks = grid }

	for w = 1, nweeks do
		local week = grid[w]
		local row = { cells = {} }
		local first, chip_line = { PAD }, { PAD }
		local offset, chip_offset = #PAD, #PAD

		for c, cell in ipairs(week) do
			if c > 1 then
				first[#first + 1] = CELL_GAP
				chip_line[#chip_line + 1] = CELL_GAP
				offset = offset + #CELL_GAP
				chip_offset = chip_offset + #CELL_GAP
			end
			local counts = cell.in_month and service.counts(items[cell.day]) or { todo = 0, done = 0 }
			local text, spans = counts_text(cell, counts, icons)
			local base = offset
			local geo = {
				start = base + 1,
				bg_s = offset,
				bg_e = offset + #text,
				heat = math.min(counts.todo, 3),
			}
			-- spans 是 1 基下标，geo 用 0 基字节列：都要减 1
			geo.todo_s = spans.todo_s and (base + spans.todo_s - 1) or nil
			geo.todo_e = spans.todo_e and (base + spans.todo_e - 1) or nil
			geo.done_s = spans.done_s and (base + spans.done_s - 1) or nil
			geo.done_e = spans.done_e and (base + spans.done_e - 1) or nil
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
		.. string.format("%s open · %s done · ⏎ day view · q close", icons.todo, icons.done)

	-- 右侧当日面板：与月历逐行拼接（行数不足时补空行，保证两侧等高）
	local agenda = opts and opts.agenda
	local month_width = max_width(lines)
	if agenda and agenda.width and agenda.width > 0 then
		local panel, panel_segs = build_agenda_lines(agenda.date, agenda.items or {}, agenda.width, #lines)
		local sep_cols = {}
		for i, line in ipairs(lines) do
			local padded = pad_end(line, month_width)
			-- 分隔符与面板内容都按「该行自己的字节长度」定位：含中文/圆点的行
			-- 字节数比显示列多，用统一的显示宽度会整体左移
			sep_cols[i] = #padded
			lines[i] = padded .. PANEL_SEP .. panel[i]
		end
		for _, seg in ipairs(panel_segs) do
			local shift = sep_cols[seg[1]] + #PANEL_SEP
			seg[2], seg[3] = seg[2] + shift, seg[3] + shift
		end
		layout.agenda = { sep_cols = sep_cols, segs = panel_segs }
		month_width = max_width(lines)
	end
	layout.width = month_width
	return lines, layout
end

---当日列表行（纯函数，供测试）
---@param date table
---@param items table[] 已排序（未完成在前，已完成在后）
---@param width integer
---@return string[] lines
function M.build_day_lines(date, items, width)
	local counts = service.counts(items)
	local stat = string.format("  %s %d open · %s %d done", mark_icon(), counts.todo, done_icon(), counts.done)
	local title = string.format("%s · %s  (%d)", fmt_date(date), weekday_full(date), #items)
	local lines = { truncate(title, width), truncate(stat, width), "" }

	if #items == 0 then
		lines[4] = "  (nothing due)"
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
	lines[#lines + 1] = "  <CR> jump · b/Esc back · q close"
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

---给某行的一段字节区间上高亮（0 基字节列）
---@param line integer 1 基行号
---@param from integer 0 基字节列
---@param to integer 0 基字节列（不含）
---@param group string
---@param priority integer|nil
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

---@param lines string[]
---@param layout CalendarLayout
local function render_month(lines, layout)
	set_lines(lines)
	local today = model.today()

	for r, row in ipairs(layout.rows) do
		local week = layout.weeks[r]
		for c, geo in ipairs(row.cells) do
			local cell = week[c]
			local selected = model.same_day(cell, state.day)
			local spans_of_cell = { { row.line, geo.bg_s, geo.bg_e } }
			if row.chip then
				spans_of_cell[#spans_of_cell + 1] = { row.chip, geo.chip_s, geo.chip_e }
			end

			-- 格子 = 一块底色矩形：本月内一定有底（没任务用最淡的），越忙越深
			if cell.in_month then
				local bg = geo.heat > 0 and ("TodoCalendarHeat" .. geo.heat) or "TodoCalendarCell"
				for _, seg in ipairs(spans_of_cell) do
					paint(seg[1], seg[2], seg[3], bg, 90)
				end
			else
				-- 本月之外：不上底色，文字压暗
				for _, seg in ipairs(spans_of_cell) do
					paint(seg[1], seg[2], seg[3], "TodoCalendarDim", 95)
				end
			end
			-- 选中日：整格淡底（Visual），盖过热力
			if selected then
				for _, seg in ipairs(spans_of_cell) do
					paint(seg[1], seg[2], seg[3], "TodoCalendarSelected", 120)
				end
			end
			-- 今天：日期上的色块（优先级最高，压过选中底色）
			if model.same_day(cell, today) then
				paint(row.line, geo.start, geo.start + 2, "TodoCalendarToday", 130)
			end
			-- 计数：●N 未完成 / ○N 已完成
			if geo.todo_s then
				paint(row.line, geo.todo_s, geo.todo_e, "TodoCalendarTodo", 140)
			end
			if geo.done_s then
				paint(row.line, geo.done_s, geo.done_e, "TodoCalendarDone", 140)
			end
			-- 事件色条：色条用紧迫度色，标题淡化避免抢眼
			if geo.chip_hl then
				paint(row.chip, geo.bar_s, geo.bar_e, geo.chip_hl, 140)
				paint(row.chip, geo.text_s, geo.text_e, "TodoCalendarDim", 110)
			end

			if selected then
				pcall(vim.api.nvim_win_set_cursor, state.win, { row.line, geo.start })
			end
		end
	end

	-- 右侧当日面板：分隔线 + 标题/统计/色条（每行各自的字节位置）
	if layout.agenda then
		for i, col in ipairs(layout.agenda.sep_cols) do
			paint(i, col, col + #PANEL_SEP, "TodoCalendarRule")
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
---@param width integer 内容显示宽度
---@return boolean
local function fits_screen(lines, width)
	-- 宽度只留浮窗边框（2 列）：78 列的网格在 80 列终端上仍要能用
	return #lines + 2 <= vim.o.lines - 1 and width + 2 <= vim.o.columns
end

---按内容宽度与编辑器尺寸算出浮窗的 { width, height }
---@param lines string[]
---@param content_width integer 内容区显示宽度
---@return integer width
---@return integer height
local function fit_window(lines, content_width)
	local width = math.min(content_width + 2, math.max(20, vim.o.columns - 4))
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

local ensure_row_visible ---@type fun(line: integer)|nil
---渲染当日列表（lines 由调用方构建，尺寸也由调用方决定）
---@param lines string[]
local function render_day(lines)
	set_lines(lines)

	for i, item in ipairs(state.day_items) do
		local line = i + 2
		local hl = item.completed and "TodoCalendarDone" or item.hl
		if hl then
			paint(line, 0, #lines[line], hl) -- 行内容长度取本行，别取下一行
		end
		if i == state.index then
			vim.api.nvim_buf_set_extmark(state.buf, NS, line, 0, { line_hl_group = "CursorLine" })
		end
	end
	paint(#lines, 0, #lines[#lines], "TodoCalendarHint")

	local line = (#state.day_items == 0) and 4 or (3 + state.index)
	pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, line), 0 })
	if ensure_row_visible then
		ensure_row_visible(line)
	end
end

---内容比窗口高时，把选中行滚进可视区（当日列表可能超出窗口）
---@param line integer 1 基行号
ensure_row_visible = function(line)
	local ok, info = pcall(vim.api.nvim_win_get_info, state.win)
	if not ok or not info then
		return
	end
	local height = info.height or 0
	if height <= 0 then
		return
	end
	local topline = vim.api.nvim_win_call(state.win, function()
		return vim.fn.line("w0")
	end)
	if line < topline then
		pcall(vim.api.nvim_win_call, state.win, function()
			vim.fn.winrestview({ topline = line })
		end)
	elseif line > topline + height - 1 then
		pcall(vim.api.nvim_win_call, state.win, function()
			vim.fn.winrestview({ topline = line - height + 1 })
		end)
	end
end

local function render()
	if not state or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	if state.mode == "day" then
		local content_width = math.max(MIN_DAY_WIDTH, math.min(vim.o.columns - 6, 72))
		local lines = M.build_day_lines(state.day, state.day_items, content_width)
		local w, h = fit_window(lines, max_width(lines))
		center_window(w, h)
		render_day(lines)
		return
	end

	-- 月视图：优先 grid（够宽就挂右侧面板），放不下退 compact
	local agenda_opts
	if vim.o.columns >= PANEL_MIN_COLUMNS then
		agenda_opts = {
			date = state.day,
			items = state.items[state.day.day] or {},
			width = PANEL_WIDTH,
		}
	end
	local lines, layout = M.build_month_lines(state.year, state.month, state.items, {
		grid = true,
		agenda = agenda_opts,
	})
	if not fits_screen(lines, layout.width) then
		lines, layout = M.build_month_lines(state.year, state.month, state.items, { grid = false })
	end
	if layout.agenda and not fits_screen(lines, layout.width) then
		lines, layout = M.build_month_lines(state.year, state.month, state.items, { grid = true })
	end
	local width, height = fit_window(lines, layout.width)
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
		"M",
		"<ScrollWheelUp>",
		"<ScrollWheelDown>",
		"<ScrollWheelLeft>",
		"<ScrollWheelRight>",
	}) do
		vim.keymap.set("n", key, lock_view, { buffer = state.buf, nowait = true, silent = true, desc = "Calendar: lock viewport" })
	end

	map("q", function()
		M.close()
	end, "Close calendar")
	map("<Esc>", function()
		if state.mode == "day" then
			back_to_month()
		else
			M.close()
		end
	end, "Back / close")

	map("h", function()
		if state.mode == "day" then
			return
		end
		move_days(-1)
	end, "Previous day")
	map("l", function()
		if state.mode == "day" then
			return
		end
		move_days(1)
	end, "Next day")
	map("k", function()
		if state.mode == "day" then
			if state.index > 1 then
				state.index = state.index - 1
				render()
			end
			return
		end
		move_days(-7)
	end, "Previous week / previous item")
	map("j", function()
		if state.mode == "day" then
			if state.index < #state.day_items then
				state.index = state.index + 1
				render()
			end
			return
		end
		move_days(7)
	end, "Next week / next item")

	map("H", function()
		if state.mode == "day" then
			return
		end
		local y, m = state.year, state.month - 1
		if m < 1 then
			y, m = y - 1, 12
		end
		goto_month(y, m, state.day.day)
	end, "Previous month")
	map("L", function()
		if state.mode == "day" then
			return
		end
		local y, m = state.year, state.month + 1
		if m > 12 then
			y, m = y + 1, 1
		end
		goto_month(y, m, state.day.day)
	end, "Next month")
	map("t", function()
		goto_today()
	end, "Today")

	map("<CR>", function()
		if state.mode == "day" then
			jump_to_task(state.day_items[state.index])
			return
		end
		open_day()
	end, "Open day / jump to task")
	map("b", function()
		if state.mode == "day" then
			back_to_month()
		end
	end, "Back to month")
end

---------------------------------------------------------------------
-- 生命周期
---------------------------------------------------------------------
---浮窗选项：固定视口（不换行、无 scrolloff、不可横向滚动），不透明，
---并关掉所有装饰，避免其它插件（缩进线/状态列/fold 列/treesitter-context）在
---月历上作画
---@param win integer
local function configure_window(win)
	local function set(name, value)
		pcall(vim.api.nvim_set_option_value, name, value, { win = win })
	end
	-- 视口：不换行、不可滚、固定大小
	set("wrap", false)
	set("linebreak", false)
	set("breakindent", false)
	set("showbreak", "")
	set("list", false)
	set("scrolloff", 0)
	set("sidescrolloff", 0)
	set("virtualedit", "")
	set("winfixheight", true)
	set("winfixwidth", true)
	-- 装饰：栏位/行号/折叠/光标行/列高亮/拼写/Conceal 全部关掉，
	-- 免得其它插件（缩进线、状态列、treesitter-context 之类）在上头作画
	set("number", false)
	set("relativenumber", false)
	set("signcolumn", "no")
	set("foldcolumn", "0")
	set("foldenable", false)
	set("foldmethod", "manual")
	set("statuscolumn", "")
	set("colorcolumn", "")
	set("cursorline", false)
	set("cursorcolumn", false)
	set("spell", false)
	set("conceallevel", 0)
	set("concealcursor", "")
	set("textwidth", 0)
	set("winbar", "")
	-- 半透明由配置决定；默认 0 = 完全不透明，避免下层代码透进来
	local blend = config.get("calendar.winblend")
	set("winblend", type(blend) == "number" and blend >= 0 and blend or 0)
	-- 兜底：主题没给 NormalFloat 背景时借用 Normal，防止「透明」透着看到代码
	if not has_bg("NormalFloat") then
		pcall(vim.api.nvim_set_option_value, "winhighlight", "Normal:Normal,NormalNC:Normal", { win = win })
	end
end

---把视口钉在左上角（任何滚动都撤销），避免内容被滚出窗口。
---只在月视图生效：当日列表可能比窗口高，需要能滚（选中项由 render_day 滚进视野）。
function lock_view()
	if not (state and state.win and vim.api.nvim_win_is_valid(state.win)) then
		return
	end
	if state.mode ~= "month" then
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
	-- 明确要求各 UI 插件别在这个 buffer 上作画（每个插件自己的 buffer 局部开关）
	vim.b[buf].todo2_float = true
	vim.b[buf].miniindentscope_disable = true -- mini.indentscope：缩进线
	vim.b[buf].minicursorword_disable = true -- mini.cursorword：同名词高亮
	vim.b[buf].minitrailspace_disable = true -- mini.trailspace：行尾空格
	vim.b[buf].ibl_enabled = false -- indent-blankline
	vim.b[buf].treesitter_context_disable = true -- nvim-treesitter-context
	-- 占位尺寸：真实尺寸与位置由 render() -> fit_window/center_window 决定
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = 0,
		col = 0,
		width = math.min(GRID_WIDTH, math.max(20, vim.o.columns - 4)),
		height = 6,
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
		vim.notify(string.format("todo2 calendar: %04d-%02d is not a valid month", year, month), vim.log.levels.WARN)
		return
	end

	local buf, win = ensure_buffer()
	state = {
		buf = buf,
		win = win,
		year = year,
		month = month,
		day = {
			year = year,
			month = month,
			day = math.max(1, math.min(opts.day or today.day, model.days_in_month(year, month))),
		},
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
	vim.api.nvim_create_autocmd({ "WinScrolled", "WinEnter" }, {
		buffer = buf,
		callback = lock_view,
	})

	-- buffer 局部：随 buffer wipe 一并释放，不会每开一次就多一条全局 autocmd
	vim.api.nvim_create_autocmd("VimResized", {
		buffer = buf,
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

---窗口有效时重算数据并重绘（任务变化 / 屏幕尺寸变化后调用）
function M.refresh()
	if not (state and state.win and vim.api.nvim_win_is_valid(state.win)) then
		return
	end
	reload({ force_refresh = true })
	if state.mode == "day" then
		state.day_items = state.items[state.day.day] or {}
		state.index = math.max(1, math.min(state.index, math.max(#state.day_items, 1)))
	end
	render()
end

return M
