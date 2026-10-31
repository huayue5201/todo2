-- lua/todo2/ui/date_picker.lua
-- 截止日「点日期」浮窗：一个月历网格，移动到某天按 <CR> 直接写回任务。
-- 与 ui/due_panel.lua（三格手打 + 归一化）互补：这里靠指，那里靠敲。

local M = {}

local api = vim.api

local config = require("todo2.config")
local model = require("todo2.ui.calendar.model")
local text = require("todo2.utils.text")
local window = require("todo2.ui.window")

local CELL_W = 3 -- 两位日 + 一格间隔
local GRID_W = 7 * CELL_W - 1
local WEEK_DAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
local WEEK_DAYS_SUN = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }
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
local HINTS = "h/l/j/k move · H/L month · Tab due/start · t today · x clear · Enter set"

local HL = {
	sel = "Todo2DatePickerSel",
	dim = "Todo2DatePickerDim",
	today = "Todo2DatePickerToday",
	due = "Todo2DatePickerDue",
	preview = "Todo2DatePickerPreview",
}

---@class Todo2DatePickerState
---@field win integer|nil
---@field buf integer|nil
---@field id string|nil
---@field on_done function|nil
---@field sel table { year, month, day }
---@field field "due"|"start"
---@field value string|nil 当前字段的日期（高亮用）
---@field width integer
---@field ns integer|nil
---@field closing boolean
local state = {
	closing = false,
	sel = nil,
	field = "due",
	value = nil,
	width = GRID_W,
}

local function setup_highlights()
	vim.cmd("highlight default link " .. HL.sel .. " Visual")
	vim.cmd("highlight default link " .. HL.dim .. " Comment")
	vim.cmd("highlight default link " .. HL.today .. " DiagnosticInfo")
	vim.cmd("highlight default link " .. HL.due .. " TodoDueSoon")
	vim.cmd("highlight default link " .. HL.preview .. " Title")
end

local function win_valid()
	return state.win ~= nil and api.nvim_win_is_valid(state.win)
end

---@param date table { year, month, day }
---@return string
local function fmt(date)
	return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

---@param date table
---@return string
local function weekday_label(date)
	return os.date("%a", os.time({ year = date.year, month = date.month, day = date.day, hour = 12 }))
end

local function week_start()
	return config.get("calendar.first_day_of_week")
end

--- 月历网格：末尾整周都在下个月的行没有意义（选不到、也不好看），直接裁掉
---@param date table { year, month, day }
---@return table[][] weeks
local function grid_of(date)
	local weeks = model.grid(date.year, date.month, { first_day_of_week = week_start() })
	while #weeks > 1 do
		local all_out = true
		for _, cell in ipairs(weeks[#weeks]) do
			if cell.in_month then
				all_out = false
				break
			end
		end
		if not all_out then
			break
		end
		weeks[#weeks] = nil
	end
	return weeks
end

--- 网格里某天的位置（row 1 = 第一个周行）
---@return integer|nil row, integer|nil col
local function cell_of(date)
	for r, week in ipairs(grid_of(date)) do
		for c, cell in ipairs(week) do
			if cell.year == date.year and cell.month == date.month and cell.day == date.day then
				return r, c
			end
		end
	end
	return nil, nil
end

--- 网格第一列的显示列偏移（网格整体在浮窗里居中）
---@param width integer
---@return integer
local function grid_lead(width)
	local pad = width - GRID_W
	if pad < 0 then
		return 0
	end
	return math.floor(pad / 2)
end

--- 构造显示行（纯函数，供测试）
---@param date table { year, month, day }
---@param width integer
---@return string[] lines
function M.build_lines(date, width)
	width = width or state.width
	local labels = (week_start() == "sunday") and WEEK_DAYS_SUN or WEEK_DAYS
	local pad = string.rep(" ", grid_lead(width))
	local lines = {}

	lines[#lines + 1] = text.pad_end(text.center(("‹  %s %d  ›"):format(MONTHS[date.month], date.year), width), width)
	lines[#lines + 1] = text.pad_end(pad .. table.concat(labels, " "), width)
	for _, week in ipairs(grid_of(date)) do
		local cells = {}
		for c, cell in ipairs(week) do
			cells[c] = string.format("%2d", cell.day)
		end
		lines[#lines + 1] = text.pad_end(pad .. table.concat(cells, " "), width)
	end
	lines[#lines + 1] = text.pad_end(
		text.center(("→  %s  %s"):format(fmt(date), weekday_label(date)), width),
		width
	)
	lines[#lines + 1] = text.pad_end(text.center(HINTS, width), width)
	return lines
end

--- 显示列 → 该行字节偏移
---@param line string
---@param display_col integer
---@param count integer 取几个字符的字节长度
---@return integer start_col, integer end_col
local function byte_range(line, display_col, count)
	local bytes, cells = 0, 0
	for _, char in ipairs(vim.fn.split(line, "\\zs")) do
		if cells >= display_col then
			break
		end
		bytes = bytes + #char
		cells = cells + 1
	end
	local end_bytes, taken = bytes, 0
	for _, char in ipairs(vim.fn.split(line:sub(bytes + 1), "\\zs")) do
		if taken >= count then
			break
		end
		end_bytes = end_bytes + #char
		taken = taken + 1
	end
	return bytes, end_bytes
end

local function paint(line_index, display_col, count, hl)
	local line = api.nvim_buf_get_lines(state.buf, line_index, line_index + 1, false)[1] or ""
	local start_col, end_col = byte_range(line, display_col, count)
	pcall(api.nvim_buf_set_extmark, state.buf, state.ns, line_index, start_col, {
		end_col = end_col,
		hl_group = hl,
	})
end

local lock_view ---@type fun()|nil 前向声明（render 里要用）

local function render()
	if not win_valid() then
		return
	end
	local lines = M.build_lines(state.sel, state.width)
	api.nvim_set_option_value("modifiable", true, { buf = state.buf })
	api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	api.nvim_set_option_value("modifiable", false, { buf = state.buf })
	api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)

	local lead = grid_lead(state.width)
	local weeks = grid_of(state.sel)

	-- 本月之外的补位日变暗
	for r, week in ipairs(weeks) do
		for c, cell in ipairs(week) do
			if not cell.in_month then
				paint(1 + r, lead + (c - 1) * CELL_W, 2, HL.dim)
			end
		end
	end
	-- 已有截止日
	if state.value and state.value ~= fmt(state.sel) then
		local y, m, d = state.value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
		if y then
			local r, c = cell_of({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
			if r then
				paint(1 + r, lead + (c - 1) * CELL_W, 2, HL.due)
			end
		end
	end
	-- 今天
	local today = model.today()
	local tr, tc = cell_of(today)
	if tr and today.year == state.sel.year and today.month == state.sel.month then
		paint(1 + tr, lead + (tc - 1) * CELL_W, 2, HL.today)
	end
	-- 选中日
	local sr, sc = cell_of(state.sel)
	if sr then
		paint(1 + sr, lead + (sc - 1) * CELL_W, 2, HL.sel)
	end

	lock_view()
end

---把视口钉在左上角（任何滚动都撤销），内容永远不跟着光标跑
function lock_view()
	if not win_valid() then
		return
	end
	pcall(api.nvim_win_call, state.win, function()
		local info = vim.fn.getwininfo(state.win)[1]
		if info and (info.topline ~= 1 or info.leftcol ~= 0) then
			vim.fn.winrestview({ topline = 1, leftcol = 0 })
		end
	end)
end

local function close_all()
	if state.closing then
		return
	end
	state.closing = true
	if win_valid() then
		pcall(api.nvim_win_close, state.win, true)
	end
	if state.buf and api.nvim_buf_is_valid(state.buf) then
		pcall(api.nvim_buf_delete, state.buf, { force = true })
	end
	state.win, state.buf, state.ns = nil, nil, nil
	state.id, state.on_done, state.value = nil, nil, nil
	state.closing = false
end

function M.close()
	close_all()
end

---@return boolean
function M.is_open()
	return win_valid()
end

---@param date string|nil 传 nil 表示清除
local function commit(date)
	local id = state.id
	if not id then
		return
	end
	local label = (state.field == "start") and "start" or "due"
	local ok = require("todo2.handlers.datefield").set_by_id(state.field, id, date or "")
	if not ok then
		return
	end
	vim.notify(date and ("todo2: " .. label .. " " .. date) or ("todo2: " .. label .. " date cleared"), vim.log.levels.INFO)
	close_all()
end

local function move(delta)
	local target = model.add_days(state.sel, delta)
	state.sel = target
	render()
end

local function move_month(delta)
	local month, year = state.sel.month + delta, state.sel.year
	if month < 1 then
		month, year = 12, year - 1
	elseif month > 12 then
		month, year = 1, year + 1
	end
	state.sel = { year = year, month = month, day = math.min(state.sel.day, model.days_in_month(year, month)) }
	render()
end

local function field_label()
	return (state.field == "start") and "start date" or "due date"
end

--- 浮窗标题随字段切换
local function retitle()
	if not state.win then
		return
	end
	pcall(api.nvim_win_set_config, state.win, { title = " " .. field_label() .. " ", title_pos = "center" })
end

--- 在「到期日」与「开始日」之间切换（同一任务的两个时间维度）
local function toggle_field()
	state.field = (state.field == "start") and "due" or "start"
	local task = require("todo2.store.task.core").get_task(state.id)
	state.value = task and task.core and task.core[state.field] or nil
	if state.value and not require("todo2.utils.due").is_date(state.value) then
		state.value = nil
	end
	retitle()
	render()
end

---@param opts { id: string, field?: "due"|"start", date?: string, on_done?: function }
function M.open(opts)
	setup_highlights()
	M.close()
	state.id = opts.id
	state.on_done = opts.on_done
	state.field = (opts.field == "start") and "start" or "due"
	state.value = opts.date
	local start = model.today()
	if opts.date then
		local y, m, d = tostring(opts.date):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
		if y then
			start = { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
		end
	end
	state.sel = { year = start.year, month = start.month, day = start.day }
	state.width = math.max(GRID_W, text.width(HINTS)) + 2

	local height = 2 + #grid_of(state.sel) + 2 -- 标题 + 星期 + 周行 + 预览 + 提示
	state.buf = api.nvim_create_buf(false, true)
	vim.bo[state.buf].filetype = "todo2datepicker"
	vim.bo[state.buf].bufhidden = "wipe"
	state.ns = api.nvim_create_namespace("todo2_date_picker")

	local position = window.anchor_bottom(height + 2, state.width + 2)
	local o = {
		style = "minimal",
		border = "rounded",
		title = " " .. field_label() .. " ",
		title_pos = "center",
		width = state.width,
		height = height,
		zindex = 60,
	}
	for key, value in pairs(position) do
		o[key] = value
	end
	state.win = api.nvim_open_win(state.buf, true, o)
	-- 视口固定：不换行、不滚、不要任何「跟着光标滚」的行为
	local function wset(name, value)
		pcall(api.nvim_set_option_value, name, value, { win = state.win })
	end
	wset("wrap", false)
	wset("linebreak", false)
	wset("showbreak", "")
	wset("list", false)
	wset("scrolloff", 0)
	wset("sidescrolloff", 0)
	wset("winfixheight", true)
	wset("winfixwidth", true)
	wset("cursorline", false)
	wset("cursorcolumn", false)
	wset("number", false)
	wset("relativenumber", false)
	wset("signcolumn", "no")
	wset("foldcolumn", "0")
	wset("foldenable", false)
	wset("statuscolumn", "")
	wset("spell", false)
	wset("winbar", "")

	-- 任何外部滚动（鼠标、其它插件）后立刻复位，文字不会跑出窗口
	local group = api.nvim_create_augroup("todo2_date_picker_" .. state.buf, { clear = true })
	api.nvim_create_autocmd({ "WinScrolled", "WinEnter" }, {
		group = group,
		buffer = state.buf,
		callback = lock_view,
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = state.buf,
		callback = function()
			pcall(api.nvim_del_augroup_by_id, group)
		end,
	})

	local function map(lhs, rhs)
		vim.keymap.set("n", lhs, rhs, { buffer = state.buf, silent = true, nowait = true })
	end
	map("h", function()
		move(-1)
	end)
	map("l", function()
		move(1)
	end)
	map("j", function()
		move(7)
	end)
	map("k", function()
		move(-7)
	end)
	map("<Left>", function()
		move(-1)
	end)
	map("<Right>", function()
		move(1)
	end)
	map("<Down>", function()
		move(7)
	end)
	map("<Up>", function()
		move(-7)
	end)
	map("H", function()
		move_month(-1)
	end)
	map("L", function()
		move_month(1)
	end)
	for _, lhs in ipairs({ "<C-e>", "<C-y>", "<C-d>", "<C-u>", "<C-f>", "<C-b>", "zz", "zt", "zb", "M", "<ScrollWheelUp>", "<ScrollWheelDown>" }) do
		map(lhs, lock_view)
	end
	map("t", function()
		state.sel = model.today()
		render()
	end)
	map("x", function()
		commit(nil)
	end)
	map("<Tab>", toggle_field)
	map("<CR>", function()
		commit(fmt(state.sel))
	end)
	map("q", function()
		close_all()
	end)
	map("<Esc>", function()
		close_all()
	end)

	render()
	return state.win
end

---@param id string
---@param on_done? function
---@param field? "due"|"start"
function M.open_for(id, on_done, field)
	local task = require("todo2.store.task.core").get_task(id)
	local key = (field == "start") and "start" or "due"
	local value = task and task.core and task.core[key] or nil
	if value and not require("todo2.utils.due").is_date(value) then
		value = nil
	end
	M.open({ id = id, field = key, date = value, on_done = on_done })
end

return M
