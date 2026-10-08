-- lua/todo2/task/jumper.lua
-- 跳转模块：使用存储中已验证的位置进行跳转

local M = {}

local core = require("todo2.store.task.core")
local query = require("todo2.store.task.query")
local index = require("todo2.store.index")
local hierarchy = require("todo2.store.task.hierarchy")
local checkbox = require("todo2.render.checkbox")
local window = require("todo2.ui.window")
local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")
local cursor = require("todo2.task.cursor")
local async_util = require("todo2.utils.async")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------

local FIXED_CONFIG = {
	reuse_existing = true,
	jump_position = "auto",
}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 检查是否在 TODO 浮动窗口中
---@param win_id number|nil
---@return boolean
local function is_todo_floating_window(win_id)
	win_id = win_id or vim.api.nvim_get_current_win()
	if not buffer.is_float_window(win_id) then
		return false
	end
	local bufnr = vim.api.nvim_win_get_buf(win_id)
	return file.is_todo_file(vim.api.nvim_buf_get_name(bufnr))
end

--- 查找已有 TODO 普通窗口
---@param todo_path string
---@return number|nil win
local function find_existing_todo_window(todo_path)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buf_path = vim.api.nvim_buf_get_name(bufnr)
			if file.normalize_path(buf_path) == todo_path then
				if not buffer.is_float_window(win) then
					return win
				end
			end
		end
	end
	return nil
end

--- 计算跳转列
---@param line_content string
---@param is_code boolean
---@return number
local function get_target_column(line_content, is_code)
	if FIXED_CONFIG.jump_position == "line_start" then
		return 0
	elseif FIXED_CONFIG.jump_position == "line_end" then
		return #line_content
	end

	if is_code then
		return 0
	end

	-- TODO 文件：跳到 checkbox 之后
	local checkbox_end = line_content:find("%]")
	if checkbox_end then
		local col = checkbox_end + 1
		while col <= #line_content and line_content:sub(col, col) == " " do
			col = col + 1
		end
		return col - 1
	end
	return #line_content
end

--- 安全跳转到行
---@param win number
---@param line number
---@param is_code boolean
---@return boolean
local function safe_jump_to_line(win, line, is_code)
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(line, line_count))
	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	local content = lines and lines[1] or ""
	local target_col = math.max(0, get_target_column(content, is_code))

	pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })
	return true
end

--- 打开普通文件并跳转
---@param path string
---@param line number
---@param is_code boolean
local function open_file_and_jump(path, line, is_code)
	local bufnr = vim.fn.bufnr(path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
	end
	vim.api.nvim_set_current_buf(bufnr)
	async_util.defer(function()
		safe_jump_to_line(vim.api.nvim_get_current_win(), line, is_code)
	end)
end

--- 打开 TODO 并跳转（优先复用已有窗口，否则浮动）
---@param path string
---@param line number
local function open_todo_and_jump(path, line)
	if FIXED_CONFIG.reuse_existing then
		local win = find_existing_todo_window(path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, line, false)
			return
		end
	end

	window.open_todo_file(path, "float", line, { enter_insert = false })
	async_util.defer(function()
		safe_jump_to_line(vim.api.nvim_get_current_win(), line, false)
	end)
end

--- 跳转到某个任务的 TODO 行。
---@param task table|nil
---@return boolean handled
local function jump_task_to_todo(task)
	if not task or not task.locations or not task.locations.todo then
		vim.notify("未找到 TODO 链接记录: " .. (task and task.id or "?"), vim.log.levels.ERROR)
		return false
	end

	open_todo_and_jump(file.normalize_path(task.locations.todo.path), task.locations.todo.line)
	return true
end

--- 收集当前代码行上所有可跳转的任务（跳过锚点失联的任务，与渲染一致）。
---@param path string
---@param lnum number
---@return table[]
local function tasks_at_line(path, lnum)
	local result = {}
	for _, task in ipairs(index.find_code_links_by_file(path)) do
		local loc = task.locations and task.locations.code
		if loc and loc.line == lnum and not core.is_anchor_lost(task) then
			table.insert(result, task)
		end
	end
	return result
end

--- 选择浮窗中单个任务的显示标签（含层级缩进）。
---@param entry { task: table, depth: number }
---@return string
local function format_pick_item(entry)
	local task = entry.task
	local depth = entry.depth or 0
	local indent = string.rep("  ", depth)
	local marker = depth > 0 and "└ " or ""
	local content = task.core.content or ""
	if content == "" then
		content = task.id
	end
	local icon = checkbox.get(task.core.status)
	return string.format("%s%s%s  [%s]", indent, marker, icon .. " " .. content, task.core.status)
end

--- 跳转到 TODO 文件（代码文件 → TODO）。
--- 当前代码行有多个任务时弹选择浮窗进行二次选择，否则直接跳转。
--- @return boolean handled
function M.jump_to_todo()
	local buf = vim.api.nvim_get_current_buf()
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then
		return false
	end

	local at_line = tasks_at_line(path, vim.fn.line("."))
	if #at_line == 0 then
		return false
	elseif #at_line == 1 then
		return jump_task_to_todo(at_line[1])
	end

	local ordered = hierarchy.build(at_line)
	vim.ui.select(ordered, {
		prompt = "该行有多个任务，选择要跳转的：",
		format_item = format_pick_item,
	}, function(entry)
		if entry then
			jump_task_to_todo(entry.task)
		end
	end)
	return true
end

--- 跳转到代码文件
---@return boolean handled
function M.jump_to_code()
	local id = cursor.get_id()
	if not id then
		return false
	end

	-- 自身锚点，或继承自父任务的锚点（补充任务）
	local loc = query.resolve_code_location(id)
	if not loc then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return true
	end

	local code_path = file.normalize_path(loc.path)
	local code_line = loc.line

	local current_win = vim.api.nvim_get_current_win()
	if is_todo_floating_window(current_win) then
		vim.api.nvim_win_close(current_win, false)
		async_util.defer(function()
			open_file_and_jump(code_path, code_line, true)
		end)
		return true
	end

	open_file_and_jump(code_path, code_line, true)
	return true
end

--- 动态跳转（根据当前文件类型自动选择方向）
---@return boolean handled
function M.jump_dynamic()
	local bufname = vim.api.nvim_buf_get_name(0)

	if file.is_todo_file(bufname) then
		return M.jump_to_code()
	end
	return M.jump_to_todo()
end
return M
