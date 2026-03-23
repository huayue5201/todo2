-- lua/todo2/task/jumper.lua
-- 跳转模块：使用存储中已验证的位置进行跳转

local M = {}

local core = require("todo2.store.link.core")
local ui = require("todo2.ui")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 跳转配置
---------------------------------------------------------------------

---@class JumpConfig
---@field reuse_existing boolean 是否复用已有 TODO split
---@field jump_position "auto"|"line_start"|"line_end"|"link_end"

local FIXED_CONFIG = {
	reuse_existing = true,
	jump_position = "auto",
}

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

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
---@param strategy string
---@return number
local function get_target_column(line_content, strategy)
	if strategy == "line_start" then
		return 0
	elseif strategy == "line_end" then
		return #line_content
	elseif strategy == "link_end" then
		if id_utils.contains_code_mark(line_content) then
			local tag = id_utils.extract_tag_from_code_mark(line_content)
			local id = id_utils.extract_id_from_code_mark(line_content)
			if tag and id then
				local pattern = id_utils.format_mark(tag, id)
				local _, e = line_content:find(pattern, 1, true)
				if e then
					return e + 1
				end
			end
		end
		return #line_content
	else
		if id_utils.contains_code_mark(line_content) then
			return get_target_column(line_content, "link_end")
		end
		return #line_content
	end
end

--- 安全跳转到行
---@param win number
---@param line number
---@param col number?
---@return boolean
local function safe_jump_to_line(win, line, col)
	col = col or -1
	local auto = col == -1

	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(line, line_count))
	local target_col = col

	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	if lines and #lines > 0 then
		local content = lines[1]
		if auto then
			target_col = get_target_column(content, FIXED_CONFIG.jump_position)
		else
			target_col = math.min(target_col, #content)
		end
	else
		target_col = 0
	end

	target_col = math.max(0, target_col)
	pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })

	return true
end

--- LSP 风格打开文件
---@param path string
---@param line number
local function open_file_like_lsp(path, line)
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	vim.api.nvim_set_current_buf(bufnr)

	local win = vim.api.nvim_get_current_win()
	safe_jump_to_line(win, line, -1)
end

-- 检查是否在 TODO 浮动窗口中
---@param win_id? number 窗口ID，默认当前窗口
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

	-- 检查buffer是否是TODO文件
	local bufnr = vim.api.nvim_win_get_buf(win_id)
	local bufname = vim.api.nvim_buf_get_name(bufnr)

	return bufname:match("%.todo%.md$") or bufname:match("todo")
end
---------------------------------------------------------------------
-- 跳转逻辑（直接使用存储数据）
---------------------------------------------------------------------

--- 跳转到 TODO 文件
function M.jump_to_todo()
	local line = vim.fn.getline(".")
	if not id_utils.contains_code_mark(line) then
		vim.notify("当前行没有链接标记", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_code_mark(line)
	if not id then
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.todo then
		vim.notify("未找到 TODO 链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local todo_path = vim.fn.fnamemodify(task.locations.todo.path, ":p")
	local todo_line = task.locations.todo.line

	-- 复用已有 split
	if FIXED_CONFIG.reuse_existing then
		local win = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, todo_line, -1)
			return
		end
	end

	-- 打开浮窗
	ui.open_todo_file(todo_path, "float", todo_line, { enter_insert = false })

	vim.schedule(function()
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, todo_line, -1)
	end)
end

--- 跳转到代码文件
function M.jump_to_code()
	local line = vim.fn.getline(".")
	if not id_utils.contains_code_mark(line) then
		vim.notify("当前行没有代码链接", vim.log.levels.WARN)
		return
	end

	local id = id_utils.extract_id_from_code_mark(line)
	if not id then
		return
	end

	local task = core.get_task(id)
	if not task or not task.locations.code then
		vim.notify("未找到代码链接记录: " .. id, vim.log.levels.ERROR)
		return
	end

	local code_path = vim.fn.fnamemodify(task.locations.code.path, ":p")
	local code_line = task.locations.code.line

	-- 如果当前是浮窗 TODO，则关闭浮窗
	local current_win = vim.api.nvim_get_current_win()
	local is_float = is_todo_floating_window(current_win)

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			open_file_like_lsp(code_path, code_line)
		end)
		return
	end

	-- 直接跳转
	open_file_like_lsp(code_path, code_line)
end

--- 动态跳转
function M.jump_dynamic()
	local name = vim.api.nvim_buf_get_name(0)
	local is_todo = name:match("%.todo%.md$") ~= nil
	if is_todo then
		M.jump_to_code()
	else
		M.jump_to_todo()
	end
end

return M
