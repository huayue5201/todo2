-- lua/todo2/task/jumper.lua
-- 跳转模块：使用存储中已验证的位置进行跳转

local M = {}

local core = require("todo2.store.link.core")
local ui = require("todo2.ui")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 跳转配置
---------------------------------------------------------------------

local FIXED_CONFIG = {
	reuse_existing = true,
	jump_position = "auto",
}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

--- 从当前行提取任务 ID（仅 TODO 文件）
---@return string|nil
local function get_task_id_at_cursor()
	local line = vim.fn.getline(".")
	return id_utils.extract_id_from_line(line)
end

--- 查找已有 TODO split 窗口
---@param todo_path string
---@return number|nil win, number|nil bufnr
local function find_existing_todo_split_window(todo_path)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) then
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buf_path = vim.api.nvim_buf_get_name(bufnr)
			if vim.fn.fnamemodify(buf_path, ":p") == todo_path then
				local cfg = vim.api.nvim_win_get_config(win)
				if cfg.relative == "" then
					return win, bufnr
				end
			end
		end
	end
	return nil, nil
end

--- 计算跳转列
---@param line_content string
---@param is_code boolean 目标文件是否为代码文件
---@return number
local function get_target_column(line_content, is_code)
	if FIXED_CONFIG.jump_position == "line_start" then
		return 0
	elseif FIXED_CONFIG.jump_position == "line_end" then
		return #line_content
	end

	-- auto 模式
	if is_code then
		-- 代码文件：跳转到行首（无标记行）
		return 0
	else
		-- TODO 文件：跳到 checkbox 之后（任务内容开始）
		-- 格式: "- [ ] TODO:ref:xxx 任务内容"
		local checkbox_end = line_content:find("%]")
		if checkbox_end then
			local after_checkbox = checkbox_end + 1
			while after_checkbox <= #line_content and line_content:sub(after_checkbox, after_checkbox) == " " do
				after_checkbox = after_checkbox + 1
			end
			return after_checkbox - 1
		end
		return #line_content
	end
end

--- 安全跳转到行
---@param win number
---@param line number
---@param is_code boolean 目标文件是否为代码文件
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

	local target_col = get_target_column(content, is_code)
	target_col = math.max(0, target_col)

	pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })

	return true
end

--- 打开文件并跳转
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
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, line, is_code)
	end)
end

--- 检查是否在 TODO 浮动窗口中
---@param win_id number|nil
---@return boolean
local function is_todo_floating_window(win_id)
	win_id = win_id or vim.api.nvim_get_current_win()

	if not vim.api.nvim_win_is_valid(win_id) then
		return false
	end

	local win_config = vim.api.nvim_win_get_config(win_id)
	local is_float = win_config.relative ~= ""

	if not is_float then
		return false
	end

	local bufnr = vim.api.nvim_win_get_buf(win_id)
	local bufname = vim.api.nvim_buf_get_name(bufnr)

	return bufname:match("%.todo%.md$") or bufname:match("%.todo$")
end

--- 判断当前文件是否为 TODO 文件
---@return boolean
local function is_current_todo_file()
	local name = vim.api.nvim_buf_get_name(0)
	return name:match("%.todo%.md$") ~= nil or name:match("%.todo$") ~= nil
end

--- 从代码光标位置获取任务 ID
---@param bufnr number
---@param line number
---@return string|nil
local function get_task_id_at_code_cursor(bufnr, line)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return nil
	end

	local index = require("todo2.store.index")
	local tasks = index.find_code_links_by_file(path)
	for _, task in ipairs(tasks) do
		if task.locations.code and task.locations.code.line == line then
			return task.id
		end
	end
	return nil
end

--- 获取当前光标所在的任务 ID（兼容 TODO 和代码文件）
---@return string|nil
local function get_current_task_id()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.fn.line(".")
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local is_todo = filename:match("%.todo%.md$") ~= nil

	if is_todo then
		return get_task_id_at_cursor()
	else
		return get_task_id_at_code_cursor(bufnr, line)
	end
end

---------------------------------------------------------------------
-- 跳转逻辑
---------------------------------------------------------------------

--- 跳转到 TODO 文件
function M.jump_to_todo()
	local id = get_current_task_id()
	if not id then
		vim.notify("当前行没有找到任务 ID", vim.log.levels.WARN)
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local todo_path = vim.fn.fnamemodify(task.locations.todo.path, ":p")
	local todo_line = task.locations.todo.line

	if FIXED_CONFIG.reuse_existing then
		local win = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, todo_line, false)
			return
		end
	end

	ui.open_todo_file(todo_path, "float", todo_line, { enter_insert = false })

	vim.schedule(function()
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, todo_line, false)
	end)
end

--- 跳转到代码文件
function M.jump_to_code()
	local id = get_current_task_id()
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
	local is_float = is_todo_floating_window(current_win)

	if is_float then
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
	if is_current_todo_file() then
		M.jump_to_code()
	else
		M.jump_to_todo()
	end
end

return M
