-- lua/todo2/ui/attributes.lua
-- 任务属性面板：把 status / tags / start / due 四个字段收在一个浮窗里编辑。
--
-- 只是 UI 聚合：字段仍各自独立写入（store + TODO 行），文件格式与命令都不变。
-- 入口：`:TodoSet`、抽屉 `i`。

local win_util = require("todo2.utils.win")
local M = {}

local core = require("todo2.store.task.core")
local events = require("todo2.core.events")
local due_utils = require("todo2.utils.due")
local text = require("todo2.utils.text")
local status_ui = require("todo2.ui.status")

local LABEL_W = 8
local FIELDS = { "status", "tags", "start", "due" }
local FIELD_TITLES = { status = "Status", tags = "Tags", start = "Start", due = "Due" }

---@class Todo2AttributesState
---@field buf number|nil
---@field win number|nil
---@field id string|nil
local state = { buf = nil, win = nil, id = nil }

local function valid()
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win) and state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

--- 当前任务的三个字段展示值
---@param task table
---@return {value: string, hl: string}[]
local function field_values(task)
	local data = task.core or {}
	local def = status_ui.get(data.status)
	local tags = data.tags or {}
	local start = data.start
	local due = data.due

	local start_text = "(none)"
	local start_hl = "Comment"
	if start then
		start_text = due_utils.format_short(start, due_utils.today())
		start_hl = "TodoTime"
	end

	local due_text = "(none)"
	local due_hl = "Comment"
	if due then
		local urgency = due_utils.urgency(due, data.status)
		due_text = due_utils.format_short(due, due_utils.today()) .. (urgency and ("  · " .. urgency) or "")
		due_hl = due_utils.hl(due, data.status) or "TodoTime"
	end

	return {
		{ value = vim.trim(def.icon or "") .. " " .. def.label, hl = def.hl_group },
		{ value = #tags > 0 and table.concat(tags, " ") or "(none)", hl = #tags > 0 and "TodoTag" or "Comment" },
		{ value = start_text, hl = start_hl },
		{ value = due_text, hl = due_hl },
	}
end

---@param task table
---@return string[] lines, {row: number, col: number, end_col: number, hl: string}[]
local function build_lines(task)
	local values = field_values(task)
	local lines, marks = {}, {}

	for i, key in ipairs(FIELDS) do
		local label = text.pad_end(FIELD_TITLES[key], LABEL_W)
		local prefix = "  " .. label .. "  "
		lines[#lines + 1] = prefix .. values[i].value
		marks[#marks + 1] = { row = i - 1, col = #prefix, end_col = #prefix + #values[i].value, hl = values[i].hl }
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "  <CR> edit this field · s status · t tags · S start · D due · q close"
	return lines, marks
end

--- 把当前任务重新画进面板
---@param id string|nil
---面板几何：打开与刷新共用一份，刷新时窗口不会跳位置。
---@param lines string[]
---@param title string
---@return table config
local function geometry(lines, title)
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, text.width(line))
	end
	local win_width = math.min(math.max(width + 2, 40), math.max(vim.o.columns - 4, 20))
	return {
		relative = "editor",
		width = win_width,
		height = #lines,
		row = math.max(math.floor((vim.o.lines - #lines) / 3), 1),
		col = math.max(math.floor((vim.o.columns - win_width) / 2), 1),
		title = " " .. text.truncate(title, 32) .. " ",
		title_pos = "center",
	}
end

local function render(id)
	if not valid() then
		return
	end
	local task = id and core.get_task(id)
	if not task then
		M.close()
		return
	end

	state.id = id
	local lines, marks = build_lines(task)
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false

	local ns = vim.api.nvim_create_namespace("todo2_attrs_" .. state.buf)
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
	for _, mark in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(state.buf, ns, mark.row, mark.col, {
			end_col = mark.end_col,
			hl_group = mark.hl,
		})
	end

	pcall(vim.api.nvim_win_set_config, state.win, geometry(lines, task.core.content or ""))
end

local function refresh()
	if not valid() then
		return
	end
	render(state.id)
end

--- 编辑某个字段（写回后由 store 事件自动重画，面板保持打开）
---@param field "status"|"tags"|"start"|"due"
local function edit(field)
	local id = state.id
	if not id then
		return
	end
	if field == "status" then
		status_ui.show_status_menu(id)
	elseif field == "tags" then
		require("todo2.handlers.tags").tag_for_id(id)
	elseif field == "start" then
		require("todo2.handlers.start").start_for_id(id)
	elseif field == "due" then
		require("todo2.handlers.due").due_for_id(id)
	end
end

--- 光标所在行对应的字段
---@return string|nil
local function field_at_cursor()
	if not valid() then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(state.win)[1]
	return FIELDS[row]
end

function M.close()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		win_util.close(state.win)
	end
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
	end
	state.win, state.buf, state.id = nil, nil, nil
end

function M.is_open()
	return valid()
end

--- 打开属性面板
---@param id string|nil
function M.open(id)
	if not id then
		return
	end
	M.close()
	local task = core.get_task(id)
	if not task then
		vim.notify("[todo2] task does not exist: " .. tostring(id), vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "todo2attrs"

	local lines, marks = build_lines(task)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	local cfg = geometry(lines, task.core.content or "")
	cfg.style = "minimal"
	cfg.border = "rounded"
	local win = vim.api.nvim_open_win(buf, true, cfg)

	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true

	state.buf, state.win, state.id = buf, win, id

	local ns = vim.api.nvim_create_namespace("todo2_attrs_" .. buf)
	for _, mark in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(buf, ns, mark.row, mark.col, {
			end_col = mark.end_col,
			hl_group = mark.hl,
		})
	end

	local opts = { buffer = buf, silent = true, nowait = true }
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, vim.tbl_extend("force", opts, { desc = "Attributes: " .. desc }))
	end
	map("<CR>", function()
		local field = field_at_cursor()
		if field then
			edit(field)
		end
	end, "edit field under cursor")
	map("s", function()
		edit("status")
	end, "set status")
	map("t", function()
		edit("tags")
	end, "set tags")
	map("S", function()
		edit("start")
	end, "set start date")
	map("D", function()
		edit("due")
	end, "set due date")
	map("q", M.close, "close")
	map("<Esc>", M.close, "close")

end

--- `:TodoSet`：对光标处的任务打开面板
function M.open_for_cursor()
	require("todo2.task.picker").pick({ none_msg = "[todo2] No task at cursor" }, function(task)
		M.open(task.id)
	end)
end

-- 面板开着时跟着 store 变化重画（标签/日期由各自 handler 写回），与抽屉同一机制。
events.on_change(function()
	if valid() then
		refresh()
	end
end)

return M
