-- lua/todo2/ui/timeline.lua
-- 时间线：把「时间维度」画成一条连续的时间轴（横向 = 日期，纵向 = 任务）。
--
-- 与日历的分工：
--   * 日历  = 某一天的格子（点），适合「这天有什么」
--   * 时间线 = 一段时间的跨度（线），适合「接下来两周怎么排」
-- 数据来源完全一样（service.month_entries 的 commits / activities），
-- 只是投影方式不同：承诺画成区间条，被碰过的标记画成一个点。

local M = {}

local api = vim.api
local model = require("todo2.ui.calendar.model")
local service = require("todo2.ui.calendar.service")
local text = require("todo2.utils.text")
local config = require("todo2.config")
local window = require("todo2.ui.window")

local NS = api.nvim_create_namespace("todo2_timeline")
local NS_LOCK = api.nvim_create_namespace("todo2_timeline_lock")
local FILL = "░"
local SPAN = "█"
local POINT = "▪"
local LEFT_W = 10 -- "  ● 10-27 "
local RIGHT_W = 5

local RANGE_DAYS = { week = 7, month = nil } -- month 用整月天数

---@class Todo2TimelineState
---@field buf number|nil
---@field win number|nil
---@field range "week"|"month"
---@field from table 首日
---@field to table 末日
---@field rows table[] 行索引 -> item
local state = { buf = nil, win = nil, range = "week", from = nil, to = nil, rows = {} }

local function valid()
	return state.win ~= nil and api.nvim_win_is_valid(state.win) and state.buf ~= nil and api.nvim_buf_is_valid(state.buf)
end

---------------------------------------------------------------------
-- 高亮
---------------------------------------------------------------------
local function setup_highlights()
	local groups = {
		TodoTimelineTitle = { link = "Title", default = true },
		TodoTimelineRuler = { link = "Comment", default = true },
		TodoTimelineDay = { link = "Comment", default = true },
		TodoTimelineSpan = { link = "TodoTime", default = true },
		TodoTimelinePoint = { link = "TodoCalendarDim", default = true },
		TodoTimelineHint = { link = "TodoCalendarHint", default = true },
		TodoTimelineToday = { link = "TodoCalendarToday", default = true },
	}
	for name, spec in pairs(groups) do
		if vim.fn.hlexists(name) == 0 then
			api.nvim_set_hl(0, name, spec)
		end
	end
end

---------------------------------------------------------------------
-- 周期
---------------------------------------------------------------------
local function monday_of(date)
	-- model.weekday 是「周日 = 1 … 周六 = 7」，倒退到本周一
	local wd = model.weekday(date.year, date.month, date.day)
	return model.add_days(date, -((wd + 5) % 7))
end

local function period_days(range, from)
	local n
	if range == "month" then
		n = model.days_in_month(from.year, from.month)
	else
		n = RANGE_DAYS[range] or 7
	end
	local days = {}
	for i = 0, n - 1 do
		days[#days + 1] = model.add_days(from, i)
	end
	return days
end

---按当前 range 把光标所在的周期整体前/后移
local function shift_period(delta)
	if state.range == "month" then
		local d = state.from
		local m = d.month + delta
		local y = d.year + math.floor((m - 1) / 12)
		m = ((m - 1) % 12) + 1
		state.from = { year = y, month = m, day = 1 }
	else
		state.from = model.add_days(state.from, delta * 7)
	end
	local days = period_days(state.range, state.from)
	state.to = days[#days]
end

---------------------------------------------------------------------
-- 数据
---------------------------------------------------------------------
local function key_of(date)
	return model.format_date(date)
end

---收集周期内的承诺（区间）与活动（点）
---@return table commits, table points
local function collect(days)
	local start_date, end_date = key_of(days[1]), key_of(days[#days])
	local opts = { hide_completed = config.get("calendar.show_completed") == false }

	local by_id = {}
	local touched = {}
	local months = {}
	for _, d in ipairs(days) do
		local mk = string.format("%04d-%02d", d.year, d.month)
		if not months[mk] then
			months[mk] = { year = d.year, month = d.month }
		end
	end

	for _, m in pairs(months) do
		local entries = service.month_entries(m.year, m.month, opts)
		for day, items in pairs(entries.commits or {}) do
			for _, item in ipairs(items) do
				local k = string.format("%s-%02d", string.format("%04d-%02d", m.year, m.month), day)
				if not by_id[item.id] then
					by_id[item.id] = vim.tbl_extend("force", item, { from = k, to = k })
				end
			end
		end
		for day, items in pairs(entries.activities or {}) do
			local k = string.format("%s-%02d", string.format("%04d-%02d", m.year, m.month), day)
			for _, item in ipairs(items) do
				touched[item.id] = touched[item.id] or { item = item, day = k }
			end
		end
	end

	-- 承诺的真实区间来自 start/due（日历只给了落点）
	local commits = {}
	local commit_ids = {}
	for _, item in pairs(by_id) do
		commit_ids[item.id] = true
		local from = item.start or item.due
		local to = item.due or item.start
		if from and to then
			if from > to then
				from = to
			end
			-- 与周期相交才画
			if from <= end_date and to >= start_date then
				commits[#commits + 1] = {
					item = item,
					from = from,
					to = to,
					title = item.content or "",
					hl = item.hl or "TodoTime",
				}
			end
		end
	end
	table.sort(commits, function(a, b)
		if a.from ~= b.from then
			return a.from < b.from
		end
		if a.to ~= b.to then
			return a.to < b.to
		end
		return a.title < b.title
	end)

	local points = {}
	for id, t in pairs(touched) do
		if not commit_ids[id] and t.day >= start_date and t.day <= end_date then
			points[#points + 1] = { item = t.item, day = t.day, title = t.item.content or "" }
		end
	end
	table.sort(points, function(a, b)
		if a.day ~= b.day then
			return a.day < b.day
		end
		return a.title < b.title
	end)

	return commits, points
end

---------------------------------------------------------------------
-- 渲染
---------------------------------------------------------------------
---构造时间线的文本行（纯函数，供测试）
---@param range "week"|"month"
---@param from table 周期首日
---@param commits table[]
---@param points table[]
---@param width integer 内容宽度
---@return string[] lines, table[] rows rows[i] = item 或 nil
function M.build_lines(range, from, commits, points, width)
	local days = period_days(range, from)
	local n = #days
	local today = model.format_date(model.today())

	local lines, rows = {}, {}
	local function push(line, item)
		lines[#lines + 1] = text.pad_end(line, width)
		rows[#lines] = item -- 行号 -> item（nil 表示不可跳转的装饰行）
	end

	local head = (" Timeline · %s · %s → %s"):format(range, key_of(days[1]), key_of(days[n]))
	push(head, nil)
	push((" %d commitments · %d marks touched"):format(#commits, #points), nil)

	-- 标尺：每天 3 列（日号右对齐 + 一个空格），下面一行是周几首字母。
	-- 月视图 31 列太挤，只在 1 号与每 5 天处标注日号，避免糊成一片。
	local ruler = " " .. string.rep(" ", LEFT_W - 1)
	local weekday_row = ruler
	local per_day_ruler = (n <= 10)
	for _, d in ipairs(days) do
		local show = per_day_ruler or d.day == 1 or d.day % 5 == 0
		ruler = ruler .. (show and string.format("%2d ", d.day) or "   ")
		local tiny = model.WEEKDAYS_TINY[model.weekday(d.year, d.month, d.day)] or " "
		weekday_row = weekday_row .. " " .. (show and tiny or " ") .. " "
	end
	push(ruler, nil)
	push(weekday_row, nil)
	push("", nil)

	local function bar_for(from_date, to_date)
		local cells = {}
		for _, d in ipairs(days) do
			local s = key_of(d)
			if s >= from_date and s <= to_date then
				cells[#cells + 1] = (s == today) and "▮" or SPAN
			else
				cells[#cells + 1] = FILL
			end
		end
		return table.concat(cells)
	end

	for _, c in ipairs(commits) do
		local span = bar_for(c.from, c.to)
		local left = ("  ● %s "):format(c.from:sub(6))
		local right = (c.to ~= c.from) and ("  " .. c.to:sub(6) .. "  ") or ("  " .. string.rep(" ", RIGHT_W) .. " ")
		local tags = (c.item.tags and #c.item.tags > 0) and ("  " .. table.concat(c.item.tags, " ")) or ""
		push(left .. span .. right .. c.title .. tags, c.item)
	end

	for _, p in ipairs(points) do
		local cells = {}
		for _, d in ipairs(days) do
			local s = key_of(d)
			cells[#cells + 1] = (s == p.day) and POINT or " "
		end
		local left = ("  ○ %s "):format(p.day:sub(6))
		local right = "  " .. string.rep(" ", RIGHT_W) .. " "
		push(left .. table.concat(cells) .. right .. p.title, p.item)
	end

	if #commits == 0 and #points == 0 then
		push("  (nothing scheduled or touched in this period)", nil)
	end

	push("", nil)
	push("  ] next · [ prev · w week · m month · ⏎ jump · q close", nil)
	return lines, rows
end

local function paint()
	if not valid() then
		return
	end
	api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
	local width = text.width(api.nvim_buf_get_lines(state.buf, 0, -1, false)[1] or "")
	for i, item in ipairs(state.rows) do
		if item then
			local line = api.nvim_buf_get_lines(state.buf, i - 1, i, false)[1] or ""
			local start_col = LEFT_W
			local span_len = 0
			for ch in line:sub(LEFT_W + 1, width):gmatch(".") do
				if ch == SPAN or ch == "▮" then
					span_len = span_len + 1
				end
			end
			if span_len > 0 then
				pcall(api.nvim_buf_set_extmark, state.buf, NS, i - 1, start_col, {
					end_col = start_col + span_len,
					hl_group = item.hl or "TodoTimelineSpan",
					priority = 120,
				})
			end
		end
	end
end

local function render()
	if not valid() then
		return
	end
	local commits, points = collect(period_days(state.range, state.from))
	local width = math.max(40, vim.o.columns - 8)
	local lines, rows = M.build_lines(state.range, state.from, commits, points, width)
	state.rows = rows

	api.nvim_set_option_value("modifiable", true, { buf = state.buf })
	api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	api.nvim_set_option_value("modifiable", false, { buf = state.buf })
	paint()

	local height = math.min(#lines, math.max(8, vim.o.lines - 6))
	local cfg = window.anchor_bottom(height + 2, width + 2)
	cfg.width = width
	cfg.height = height
	cfg.title = " todo2 timeline "
	cfg.title_pos = "center"
	pcall(api.nvim_win_set_config, state.win, cfg)
	window.lock_viewport(state.win)
end

---------------------------------------------------------------------
-- 交互
---------------------------------------------------------------------
local function jump()
	local item = state.rows[vim.fn.line(".")]
	if not item then
		return
	end
	local id = item.id
	if require("todo2.task.jumper").jump_to_task(id) then
		M.close()
		return
	end
	if item.path and item.line then
		M.close()
		vim.cmd("edit " .. vim.fn.fnameescape(item.path))
		pcall(api.nvim_win_set_cursor, 0, { item.line, 0 })
		vim.cmd("normal! zz")
	end
end

local function setup_keymaps()
	local opts = { buffer = state.buf, silent = true, nowait = true }
	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, opts)
	end
	map("q", M.close)
	map("<Esc>", M.close)
	map("]", function()
		shift_period(1)
		render()
	end)
	map("[", function()
		shift_period(-1)
		render()
	end)
	map("w", function()
		state.range = "week"
		M.reset(state.from)
		render()
	end)
	map("m", function()
		state.range = "month"
		M.reset(state.from)
		render()
	end)
	map("R", render)
	map("<CR>", jump)
	window.lock_viewport_keys(state.buf, state.win, { desc = "Timeline: lock viewport" })
end

---把周期重置到包含 date 的那一周/月
function M.reset(date)
	date = date or model.today()
	if state.range == "month" then
		state.from = { year = date.year, month = date.month, day = 1 }
	else
		state.from = monday_of(date)
	end
	local days = period_days(state.range, state.from)
	state.to = days[#days]
end

---------------------------------------------------------------------
-- 生命周期
---------------------------------------------------------------------
function M.close()
	if not valid() then
		state = { buf = nil, win = nil, range = state.range or "week", from = nil, to = nil, rows = {} }
		return
	end
	local win, buf = state.win, state.buf
	state = { buf = nil, win = nil, range = state.range or "week", from = nil, to = nil, rows = {} }
	pcall(api.nvim_win_close, win, true)
	if buf and api.nvim_buf_is_valid(buf) then
		pcall(api.nvim_buf_delete, buf, { force = true })
	end
end

function M.is_open()
	return valid()
end

local function ensure_buffer()
	local buf = api.nvim_create_buf(false, true)
	api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	api.nvim_set_option_value("swapfile", false, { buf = buf })
	api.nvim_set_option_value("modifiable", false, { buf = buf })
	api.nvim_set_option_value("filetype", "todo2timeline", { buf = buf })
	vim.b[buf].todo2_float = true
	vim.b[buf].miniindentscope_disable = true
	vim.b[buf].minicursorword_disable = true
	vim.b[buf].minitrailspace_disable = true
	vim.b[buf].ibl_enabled = false
	vim.b[buf].treesitter_context_disable = true

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = 0,
		col = 0,
		width = math.min(100, math.max(40, vim.o.columns - 8)),
		height = 12,
		style = "minimal",
		border = "rounded",
		title = " todo2 timeline ",
		title_pos = "center",
	})
	api.nvim_set_option_value("wrap", false, { win = win })
	api.nvim_set_option_value("scrolloff", 0, { win = win })
	api.nvim_set_option_value("sidescrolloff", 0, { win = win })
	api.nvim_set_option_value("list", false, { win = win })
	api.nvim_set_option_value("cursorline", true, { win = win })
	api.nvim_set_option_value("signcolumn", "no", { win = win })
	api.nvim_set_option_value("foldcolumn", "0", { win = win })
	api.nvim_set_option_value("number", false, { win = win })
	api.nvim_set_option_value("relativenumber", false, { win = win })
	api.nvim_set_option_value("winfixheight", true, { win = win })
	api.nvim_set_option_value("winfixwidth", true, { win = win })
	api.nvim_buf_set_extmark(buf, NS_LOCK, 0, 0, {})
	return buf, win
end

---打开时间线。
---@param opts? { range?: "week"|"month", date?: table }
function M.open(opts)
	opts = opts or {}
	setup_highlights()

	if valid() then
		api.nvim_set_current_win(state.win)
		if opts.range then
			state.range = opts.range
			M.reset(opts.date or state.from)
		end
		render()
		return state.buf
	end

	state.range = opts.range or state.range or "week"
	M.reset(opts.date or model.today())

	local buf, win = ensure_buffer()
	state.buf, state.win = buf, win
	setup_keymaps()
	render()
	return buf
end

---`:TodoTimeline [week|month]`
---@param arg? string
function M.command(arg)
	local range = (arg and arg ~= "" and vim.trim(arg):lower()) or nil
	if range and range ~= "week" and range ~= "month" then
		vim.notify("todo2 timeline: range must be week or month", vim.log.levels.WARN)
		return false
	end
	M.open({ range = range })
	return true
end

M._state = state

return M
