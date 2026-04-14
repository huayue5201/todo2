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

--- 从当前行提取任务 ID（复用 id_utils，统一格式 TAG:ref:ID）
---@return string|nil
local function get_task_id_at_cursor()
	local line = vim.fn.getline(".")
	return id_utils.extract_id(line)
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
		-- 代码文件：使用 id_utils 定位注释结束位置
		local id = id_utils.extract_id(line_content)
		if id then
			local _, e = id_utils.find_id_position(line_content, id)
			if e then
				return e
			end
		end
		return #line_content
	else
		-- TODO 文件：跳到 checkbox 之后（任务内容开始）
		-- 格式: "- [ ] TODO:ref:xxx 任务内容"
		local checkbox_end = line_content:find("%]")
		if checkbox_end then
			-- 找到 checkbox 后的第一个空格位置
			local after_checkbox = checkbox_end + 1
			-- 跳过可能存在的空格
			while after_checkbox <= #line_content and line_content:sub(after_checkbox, after_checkbox) == " " do
				after_checkbox = after_checkbox + 1
			end
			return after_checkbox - 1 -- 返回 0-indexed 列号
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

	-- 获取目标行内容
	local lines = vim.api.nvim_buf_get_lines(buf, target_line - 1, target_line, false)
	local content = lines and lines[1] or ""

	-- 计算目标列
	local target_col = get_target_column(content, is_code)
	target_col = math.max(0, target_col)

	-- 执行跳转
	pcall(vim.api.nvim_win_set_cursor, win, { target_line, target_col })

	return true
end

--- 打开文件并跳转
---@param path string
---@param line number
---@param is_code boolean
local function open_file_and_jump(path, line, is_code)
	-- 检查文件是否已打开
	local bufnr = vim.fn.bufnr(path)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
	end

	-- 切换到文件
	vim.api.nvim_set_current_buf(bufnr)

	-- 等待缓冲区加载完成后跳转
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

---------------------------------------------------------------------
-- 跳转逻辑
---------------------------------------------------------------------

--- 跳转到 TODO 文件
function M.jump_to_todo()
	local id = get_task_id_at_cursor()
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

	-- 复用已有 split
	if FIXED_CONFIG.reuse_existing then
		local win = find_existing_todo_split_window(todo_path)
		if win then
			vim.api.nvim_set_current_win(win)
			safe_jump_to_line(win, todo_line, false)
			return
		end
	end

	-- 打开浮窗
	ui.open_todo_file(todo_path, "float", todo_line, { enter_insert = false })

	vim.schedule(function()
		local win = vim.api.nvim_get_current_win()
		safe_jump_to_line(win, todo_line, false)
	end)
end

--- 跳转到代码文件
function M.jump_to_code()
	local id = get_task_id_at_cursor()
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

	-- 如果当前是浮窗 TODO，则关闭浮窗
	local current_win = vim.api.nvim_get_current_win()
	local is_float = is_todo_floating_window(current_win)

	if is_float then
		vim.api.nvim_win_close(current_win, false)
		vim.schedule(function()
			open_file_and_jump(code_path, code_line, true)
		end)
		return
	end

	-- 直接跳转
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

--- 跳转到指定任务（供外部调用）
---@param task_id string
---@param target "todo"|"code"|"auto"
function M.jump_to_task(task_id, target)
	local task = core.get_task(task_id)
	if not task then
		vim.notify("任务不存在: " .. task_id, vim.log.levels.ERROR)
		return
	end

	if target == "todo" or (target == "auto" and task.locations.todo) then
		if not task.locations.todo then
			vim.notify("任务没有 TODO 位置: " .. task_id, vim.log.levels.WARN)
			return
		end
		open_file_and_jump(task.locations.todo.path, task.locations.todo.line, false)
	elseif target == "code" or (target == "auto" and task.locations.code) then
		if not task.locations.code then
			vim.notify("任务没有代码位置: " .. task_id, vim.log.levels.WARN)
			return
		end
		open_file_and_jump(task.locations.code.path, task.locations.code.line, true)
	else
		vim.notify("无法确定跳转目标", vim.log.levels.WARN)
	end
end

return M
