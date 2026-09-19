-- lua/todo2/task/jumper.lua
-- 跳转模块：使用存储中已验证的位置进行跳转

local M = {}

local core = require("todo2.store.link.core")
local window = require("todo2.ui.window")
local file = require("todo2.utils.file")
local buffer = require("todo2.utils.buffer")
local cursor = require("todo2.task.cursor")

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
			if vim.fn.fnamemodify(buf_path, ":p") == todo_path then
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
	vim.schedule(function()
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
	vim.schedule(function()
		safe_jump_to_line(vim.api.nvim_get_current_win(), line, false)
	end)
end

--- 跳转到 TODO 文件
function M.jump_to_todo()
	local id = cursor.get_id()
	if not id then
		vim.notify("当前行没有找到任务 ID", vim.log.levels.WARN)
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	open_todo_and_jump(vim.fn.fnamemodify(task.locations.todo.path, ":p"), task.locations.todo.line)
end

--- 跳转到代码文件
function M.jump_to_code()
	local id = cursor.get_id()
	if not id then
		vim.notify("当前行没有找到任务 ID", vim.log.levels.WARN)
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.code then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local code_path = vim.fn.fnamemodify(task.locations.code.path, ":p")
	local code_line = task.locations.code.line

	local current_win = vim.api.nvim_get_current_win()
	if is_todo_floating_window(current_win) then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			open_file_and_jump(code_path, code_line, true)
		end)
		return
	end

	open_file_and_jump(code_path, code_line, true)
end

--- 动态跳转（根据当前文件类型自动选择方向）
function M.jump_dynamic()
	local bufname = vim.api.nvim_buf_get_name(0)

	if file.is_todo_file(bufname) then
		M.jump_to_code()
	else
		M.jump_to_todo()
	end
end

--- 按任务 ID 跳转到指定位置（供热力图等外部调用）
---@param id string 任务ID
---@param target string|nil 目标位置："code" | "todo" | nil（自动：优先 code）
function M.jump_to_task(id, target)
	if not id then
		vim.notify("未找到任务 ID", vim.log.levels.WARN)
		return
	end

	local task = core.get_task(id)
	if not task then
		vim.notify("任务不存在: " .. id, vim.log.levels.ERROR)
		return
	end

	if target == "todo" and task.locations.todo then
		open_todo_and_jump(vim.fn.fnamemodify(task.locations.todo.path, ":p"), task.locations.todo.line)
	elseif target == "code" and task.locations.code then
		open_file_and_jump(vim.fn.fnamemodify(task.locations.code.path, ":p"), task.locations.code.line, true)
	elseif task.locations.code then
		open_file_and_jump(vim.fn.fnamemodify(task.locations.code.path, ":p"), task.locations.code.line, true)
	elseif task.locations.todo then
		open_todo_and_jump(vim.fn.fnamemodify(task.locations.todo.path, ":p"), task.locations.todo.line)
	else
		vim.notify(string.format("任务 %s 没有关联位置", id), vim.log.levels.WARN)
	end
end

return M
