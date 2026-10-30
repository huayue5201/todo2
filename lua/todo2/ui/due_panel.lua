-- lua/todo2/ui/due_panel.lua
-- 到期日输入面板：三个定长输入框排成一行（年 / 月 / 日），带防呆与实时预览。
--
-- 与 lua/dap-extensions/ui/popup.lua 的关系：沿用「父浮窗 + 每字段一个子窗口 +
-- 活动格边框高亮」的结构，但这里字段数量与宽度都是固定的，所以没有 resize /
-- relayout，也没有逐字段历史记录（日期几乎用不到，改用 t/m/w/x 快捷）。
--
-- 防呆三层：
--   1. 输入层：非数字不进 buffer，年 4 位 / 月日 2 位，填满自动跳下一格
--   2. 语义层：越界值提交时归一化（2 月 31 日 → 2 月 28 日），底部实时预览结果
--   3. 兜底层：三格全空 = 清除到期日；Esc 取消不改动；表达式走 `e` 退回旧输入框

local M = {}

local due_utils = require("todo2.utils.due")
local calendar_model = require("todo2.ui.calendar.model")
local text = require("todo2.utils.text")

---@class Todo2DueField
---@field key "year"|"month"|"day"
---@field title string
---@field width number 输入框内部宽度
---@field maxlen number 最多接受的数字位数

---@type Todo2DueField[]
local FIELDS = {
	{ key = "year", title = "年", width = 4, maxlen = 4 },
	{ key = "month", title = "月", width = 2, maxlen = 2 },
	{ key = "day", title = "日", width = 2, maxlen = 2 },
}

local YEAR_MIN, YEAR_MAX = 1970, 2999

local HINT_KEYS = "  t 今天   m 明天   w +1周   x 清除   e 表达式"
local HINT_KEYS_W = "  Tab 下一格 · Enter 确认 · Esc 退出输入 · q 取消"

vim.api.nvim_set_hl(0, "Todo2DuePanelActive", { default = true, link = "DiagnosticInfo" })
vim.api.nvim_set_hl(0, "Todo2DuePanelIdle", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "Todo2DuePanelPreview", { default = true, link = "Title" })

---@class Todo2DuePanelState
---@field parent number|nil
---@field pbuf number|nil
---@field windows {buf: number, win: number}[]
---@field closing boolean
---@field focus number
---@field advancing boolean
---@field sanitizing boolean
---@field id string|nil
---@field on_done fun()|nil
local state = {
	parent = nil,
	pbuf = nil,
	windows = {},
	closing = false,
	width = 0,
	focus = 1,
	advancing = false,
	sanitizing = false,
	ns = nil,
	id = nil,
	on_done = nil,
}

local function win_valid(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- 取某个输入框里的原始文本
---@param index number
---@return string
local function field_text(index)
	local w = state.windows[index]
	if not w or not buf_valid(w.buf) then
		return ""
	end
	return (vim.api.nvim_buf_get_lines(w.buf, 0, -1, false)[1] or "")
end

local function digits_only(s)
	return (tostring(s or ""):gsub("%D", ""))
end

--- 三格内容 → 日期；返回 date|nil, err|nil, clear|boolean
---@return string|nil, string|nil, boolean|nil
local function resolve()
	local y = digits_only(field_text(1))
	local m = digits_only(field_text(2))
	local d = digits_only(field_text(3))
	local today = due_utils.today()
	local ty, tm, td = today:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")

	if y == "" and m == "" and d == "" then
		return nil, nil, true
	end

	local year
	if y == "" then
		year = tonumber(ty)
	elseif #y <= 2 then
		-- 只输 2 位按 20xx 补全
		year = 2000 + tonumber(y)
	elseif #y == 4 then
		year = tonumber(y)
	else
		return nil, "年份请输 2 位或 4 位数字"
	end
	year = math.max(YEAR_MIN, math.min(YEAR_MAX, year))

	local month = m == "" and tonumber(tm) or tonumber(m)
	if not month then
		return nil, "月份无效"
	end
	month = math.max(1, math.min(12, month))

	local day = d == "" and tonumber(td) or tonumber(d)
	if not day then
		return nil, "日期无效"
	end
	local max_day = calendar_model.days_in_month(year, month)
	day = math.max(1, math.min(max_day, day))

	return string.format("%04d-%02d-%02d", year, month, day)
end

local function weekday_label(date)
	local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
	return os.date("%a", t)
end

local update_preview
local center_field

--- 关闭全部浮窗
local function close_all()
	if state.closing then
		return
	end
	state.closing = true
	for _, w in ipairs(state.windows) do
		if win_valid(w.win) then
			pcall(vim.api.nvim_win_close, w.win, true)
		end
		if buf_valid(w.buf) then
			pcall(vim.api.nvim_buf_delete, w.buf, { force = true })
		end
	end
	if win_valid(state.parent) then
		pcall(vim.api.nvim_win_close, state.parent, true)
	end
	if buf_valid(state.pbuf) then
		pcall(vim.api.nvim_buf_delete, state.pbuf, { force = true })
	end
	state.parent, state.pbuf, state.windows = nil, nil, {}
	state.closing = false
	state.id, state.on_done = nil, nil
	state.ns = nil
end

function M.close()
	close_all()
end

function M.is_open()
	return state.parent ~= nil and win_valid(state.parent)
end

--- 读当前三格 → 提交（写回 store + TODO 行）
local function submit()
	local date, err = resolve()
	if err then
		vim.notify("[todo2] " .. err, vim.log.levels.WARN)
		return
	end
	local id, on_done = state.id, state.on_done
	close_all()
	local ok = require("todo2.handlers.due").set_due_for_id(id, date or "")
	if not ok then
		return
	end
	vim.notify(date and ("Due: " .. date) or "Due cleared", vim.log.levels.INFO)
	if on_done then
		on_done()
	end
end

local function cancel()
	close_all()
end

--- 切换焦点到第 i 格
---@param index number
---@param enter_insert? boolean 切换后是否进入插入模式
local function focus(index, enter_insert)
	if state.closing then
		return
	end
	index = ((index - 1) % #FIELDS) + 1
	state.focus = index
	for i, w in ipairs(state.windows) do
		if win_valid(w.win) then
			local hl = (i == index) and "Todo2DuePanelActive" or "Todo2DuePanelIdle"
			pcall(vim.api.nvim_win_set_config, w.win, {
				border = {
					{ "╭", hl },
					{ "─", hl },
					{ "╮", hl },
					{ "│", hl },
					{ "╯", hl },
					{ "─", hl },
					{ "╰", hl },
					{ "│", hl },
				},
			})
		end
	end
	local target = state.windows[index]
	if target and win_valid(target.win) then
		pcall(vim.api.nvim_set_current_win, target.win)
		if enter_insert then
			pcall(vim.cmd, "startinsert!")
		end
	end
end

--- 把某格内容清空并写回
local function set_field(index, value)
	local w = state.windows[index]
	if not w or not buf_valid(w.buf) then
		return
	end
	state.sanitizing = true
	vim.api.nvim_buf_set_lines(w.buf, 0, -1, false, { value })
	state.sanitizing = false
	if win_valid(w.win) then
		pcall(vim.api.nvim_win_set_cursor, w.win, { 1, #value })
	end
	center_field(index)
end

--- 把某一格的内容视觉居中：用 overlay 虚拟文本补空格，buffer 里仍只存纯数字
---@param index number
center_field = function(index)
	local w = state.windows[index]
	local field = FIELDS[index]
	if not w or not buf_valid(w.buf) or not w.ns then
		return
	end
	pcall(vim.api.nvim_buf_clear_namespace, w.buf, w.ns, 0, -1)
	local raw = field_text(index)
	if #raw >= field.width then
		return
	end
	local left = math.floor((field.width - #raw) / 2)
	local padded = string.rep(" ", left) .. raw .. string.rep(" ", field.width - #raw - left)
	pcall(vim.api.nvim_buf_set_extmark, w.buf, w.ns, 0, 0, {
		virt_text = { { padded, "Normal" } },
		virt_text_pos = "overlay",
	})
end

--- 快捷值：t 今天 / m 明天 / w +1 周 / x 清除
---@param key "t"|"m"|"w"|"x"
local function apply_shortcut(key)
	local today = due_utils.today()
	local date
	if key == "t" then
		date = today
	elseif key == "m" then
		date = due_utils.add_days(today, 1)
	elseif key == "w" then
		date = due_utils.add_days(today, 7)
	end

	if key == "x" then
		set_field(1, "")
		set_field(2, "")
		set_field(3, "")
	else
		local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
		set_field(1, y)
		set_field(2, m)
		set_field(3, d)
	end
	update_preview()
	focus(state.focus, true)
end

--- 输入层过滤：只留数字、限长，顺便自动跳下一格
local function sanitize(index)
	if state.sanitizing or state.closing then
		return
	end
	local w = state.windows[index]
	local field = FIELDS[index]
	if not w or not buf_valid(w.buf) then
		return
	end

	local raw = field_text(index)
	local clean = digits_only(raw):sub(1, field.maxlen)
	if clean ~= raw then
		set_field(index, clean)
	else
		if win_valid(w.win) then
			local cursor = vim.api.nvim_win_get_cursor(w.win)
			if cursor[2] > #clean then
				pcall(vim.api.nvim_win_set_cursor, w.win, { 1, #clean })
			end
		end
	end

	center_field(index)
	update_preview()

	-- 填满自动跳格（最后一格不动）
	if #clean >= field.maxlen and index < #FIELDS and not state.advancing then
		state.advancing = true
		focus(index + 1, true)
		state.advancing = false
	end
end

--- 实时预览行：把三格解析成最终会写入的日期
update_preview = function()
	if state.closing or not buf_valid(state.pbuf) then
		return
	end
	local date, err = resolve()
	local line
	if err then
		line = "→ ⚠ " .. err
	elseif not date then
		line = "→ (清除到期日)"
	else
		line = ("→ %s  %s"):format(date, weekday_label(date))
	end
	line = text.center(line, state.width)
	pcall(function()
		vim.bo[state.pbuf].modifiable = true
		vim.api.nvim_buf_set_lines(state.pbuf, 2, 3, false, { line })
		vim.bo[state.pbuf].modifiable = false
		if state.ns then
			vim.api.nvim_buf_clear_namespace(state.pbuf, state.ns, 2, 3)
			vim.api.nvim_buf_set_extmark(state.pbuf, state.ns, 2, 0, {
				end_col = #line,
				hl_group = "Todo2DuePanelPreview",
			})
		end
	end)
end

--- 表达式模式：退回原来的一行输入框（支持 today / +7d / 2026-11-02）
local function expression_mode()
	local id, on_done = state.id, state.on_done
	close_all()
	require("todo2.handlers.due").prompt_expression(id, on_done)
end

--- 打开面板
---@param opts {id: string, due?: string|nil, on_done?: fun()|nil}
function M.open(opts)
	opts = opts or {}
	if not opts.id then
		return
	end
	M.close()

	state.closing = false
	state.focus = 1
	state.id = opts.id
	state.on_done = opts.on_done
	state.windows = {}

	-- 预填当前到期日（无则全空 = 提交即清除）
	local y, m, d = "", "", ""
	local seed = opts.due
	if seed and seed:match("^%d%d%d%d%-%d%d%-%d%d$") then
		y, m, d = seed:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	end
	local values = { y, m, d }

	-- 父浮窗：只放预览与提示行，字段行由子窗口覆盖
	local field_row_width = 2
	for i, field in ipairs(FIELDS) do
		field_row_width = field_row_width + field.width + 2
		if i < #FIELDS then
			field_row_width = field_row_width + 1
		end
	end
	local width = math.max(field_row_width, text.width(HINT_KEYS), text.width(HINT_KEYS_W))

	local pbuf = vim.api.nvim_create_buf(false, true)
	local parent = vim.api.nvim_open_win(pbuf, false, {
		relative = "cursor",
		row = 1,
		col = 1,
		width = width,
		height = 6,
		style = "minimal",
		border = "rounded",
		title = " due date ",
		title_pos = "center",
	})
	state.width = width
	vim.bo[pbuf].bufhidden = "wipe"
	vim.bo[pbuf].modifiable = true
	vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, {
		"",
		"",
		text.center("→", width),
		"",
		text.center(HINT_KEYS:gsub("^%s+", ""), width),
		text.center(HINT_KEYS_W:gsub("^%s+", ""), width),
	})
	vim.bo[pbuf].modifiable = false
	vim.wo[parent].cursorline = false

	state.pbuf, state.parent = pbuf, parent

	local ns = vim.api.nvim_create_namespace("todo2_due_panel_" .. pbuf)
	state.ns = ns

	-- 三个输入框横向排列，整排水平居中
	local row_width = 0
	for i, field in ipairs(FIELDS) do
		row_width = row_width + field.width + 2
		if i < #FIELDS then
			row_width = row_width + 1
		end
	end
	local col = math.max(0, math.floor((width - row_width) / 2))
	for i, field in ipairs(FIELDS) do
		local buf = vim.api.nvim_create_buf(false, true)
		local win = vim.api.nvim_open_win(buf, false, {
			relative = "win",
			win = parent,
			row = 1,
			col = col,
			width = field.width,
			height = 1,
			style = "minimal",
			border = "rounded",
			title = " " .. field.title .. " ",
			title_pos = "center",
		})
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { values[i] or "" })
		state.windows[i] = {
			buf = buf,
			win = win,
			ns = vim.api.nvim_create_namespace("todo2_due_panel_field_" .. buf),
		}
		center_field(i)
		col = col + field.width + 2 + 1
	end

	-- 每个输入框的键位与自动过滤
	for i, w in ipairs(state.windows) do
		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = w.buf,
			callback = function()
				sanitize(i)
			end,
		})

		vim.keymap.set({ "n", "i" }, "<Tab>", function()
			focus(i + 1, true)
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
			focus(i - 1, true)
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set({ "n", "i" }, "<C-m>", function()
			submit()
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("n", "<CR>", function()
			submit()
		end, { buffer = w.buf, silent = true, nowait = true })
		-- 插入模式 Esc 只退出输入：继续按 Esc / q 才是取消，方便走到 e（表达式输入）
		vim.keymap.set("i", "<Esc>", function()
			pcall(vim.cmd, "stopinsert")
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("i", "<C-e>", expression_mode, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("n", "<Esc>", cancel, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("n", "q", cancel, { buffer = w.buf, silent = true, nowait = true })

		-- 正常模式：i/a 回到插入，t/m/w/x 是快捷值，h/l 切格
		vim.keymap.set("n", "i", function()
			focus(i, true)
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("n", "a", function()
			focus(i, true)
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("n", "h", function()
			focus(i - 1, false)
		end, { buffer = w.buf, silent = true, nowait = true })
		vim.keymap.set("n", "l", function()
			focus(i + 1, false)
		end, { buffer = w.buf, silent = true, nowait = true })
		for _, key in ipairs({ "t", "m", "w", "x" }) do
			vim.keymap.set("n", key, function()
				apply_shortcut(key)
			end, { buffer = w.buf, silent = true, nowait = true })
		end
		vim.keymap.set("n", "e", expression_mode, { buffer = w.buf, silent = true, nowait = true })
	end

	update_preview()
	focus(1, true)
end

--- 对当前缓冲区里光标所在任务的到期日打开面板
---@param id string
---@param on_done? fun()
function M.open_for(id, on_done)
	local task = require("todo2.store.task.core").get_task(id)
	if not task then
		vim.notify("[todo2] task does not exist: " .. tostring(id), vim.log.levels.WARN)
		return
	end
	M.open({ id = id, due = task.core.due, on_done = on_done })
end

return M
