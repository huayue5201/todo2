-- lua/todo2/utils/buffer.lua
-- 缓冲区工具模块：提供统一的缓冲区操作

local M = {}

---------------------------------------------------------------------
-- 缓冲区基础操作
---------------------------------------------------------------------

--- 检查缓冲区是否有效
---@param bufnr number 缓冲区号
---@return boolean
function M.is_valid(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

--- 获取缓冲区文件路径
---@param bufnr number 缓冲区号
---@return string 文件路径，无效返回空字符串
function M.get_path(bufnr)
	if not M.is_valid(bufnr) then
		return ""
	end
	return vim.api.nvim_buf_get_name(bufnr)
end

--- 获取缓冲区行数
---@param bufnr number 缓冲区号
---@return number
function M.line_count(bufnr)
	if not M.is_valid(bufnr) then
		return 0
	end
	return vim.api.nvim_buf_line_count(bufnr)
end

---------------------------------------------------------------------
-- 行号验证
---------------------------------------------------------------------

--- 验证行号是否有效
---@param bufnr number 缓冲区号
---@param line number 行号（1-indexed）
---@return boolean
function M.is_valid_line(bufnr, line)
	if not M.is_valid(bufnr) then
		return false
	end
	local line_num = tonumber(line)
	if not line_num then
		return false
	end
	return line_num >= 1 and line_num <= M.line_count(bufnr)
end

---------------------------------------------------------------------
-- 获取行内容
---------------------------------------------------------------------

--- 获取指定行内容
---@param bufnr number 缓冲区号
---@param line number 行号（1-indexed）
---@return string|nil 行内容，无效返回 nil
function M.get_line(bufnr, line)
	if not M.is_valid_line(bufnr, line) then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)
	return lines[1]
end

--- 获取缓冲区所有行
---@param bufnr number 缓冲区号
---@return string[] 行列表，无效返回空表
function M.get_lines(bufnr)
	if not M.is_valid(bufnr) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- 获取指定行范围内容
---@param bufnr number 缓冲区号
---@param start_line number 起始行（1-indexed）
---@param end_line number 结束行（1-indexed）
---@return string[] 行列表
function M.get_lines_range(bufnr, start_line, end_line)
	if not M.is_valid(bufnr) then
		return {}
	end
	local start_idx = math.max(0, start_line - 1)
	local end_idx = math.min(M.line_count(bufnr), end_line)
	return vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
end

---------------------------------------------------------------------
-- 行缩进操作
---------------------------------------------------------------------

--- 获取行缩进
---@param bufnr number 缓冲区号
---@param line number 行号
---@return string 缩进字符串（空格或制表符）
function M.get_line_indent(bufnr, line)
	local content = M.get_line(bufnr, line)
	if not content then
		return ""
	end
	return content:match("^(%s*)") or ""
end

--- 获取行缩进级别（按4空格为单位）
---@param bufnr number 缓冲区号
---@param line number 行号
---@param tab_width number 制表符宽度（默认4）
---@return number 缩进级别
function M.get_line_indent_level(bufnr, line, tab_width)
	tab_width = tab_width or 4
	local indent = M.get_line_indent(bufnr, line)
	local spaces = 0
	for i = 1, #indent do
		local c = indent:sub(i, i)
		if c == " " then
			spaces = spaces + 1
		elseif c == "\t" then
			spaces = spaces + tab_width
		end
	end
	return math.floor(spaces / tab_width)
end

---------------------------------------------------------------------
-- 光标操作
---------------------------------------------------------------------

--- 获取光标所在行号
---@param winid number|nil 窗口号，nil 表示当前窗口
---@return number|nil 行号
function M.get_cursor_line(winid)
	winid = winid or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(winid) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(winid)
	return cursor and cursor[1] or nil
end

--- 获取光标所在列号
---@param winid number|nil 窗口号，nil 表示当前窗口
---@return number|nil 列号（0-indexed）
function M.get_cursor_col(winid)
	winid = winid or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(winid) then
		return nil
	end
	local cursor = vim.api.nvim_win_get_cursor(winid)
	return cursor and cursor[2] or nil
end

--- 设置光标位置
---@param winid number|nil 窗口号
---@param line number 行号（1-indexed）
---@param col number|nil 列号（0-indexed），nil 表示行首
---@return boolean 是否成功
function M.set_cursor(winid, line, col)
	winid = winid or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(winid) then
		return false
	end
	local bufnr = vim.api.nvim_win_get_buf(winid)
	if not M.is_valid_line(bufnr, line) then
		return false
	end
	col = col or 0
	pcall(vim.api.nvim_win_set_cursor, winid, { line, col })
	return true
end

---------------------------------------------------------------------
-- 行内容操作
---------------------------------------------------------------------

--- 替换指定行内容
---@param bufnr number 缓冲区号
---@param line number 行号
---@param new_content string 新内容
---@return boolean 是否成功
function M.set_line(bufnr, line, new_content)
	if not M.is_valid_line(bufnr, line) then
		return false
	end
	pcall(vim.api.nvim_buf_set_lines, bufnr, line - 1, line, false, { new_content })
	return true
end

--- 在指定行后插入新行
---@param bufnr number 缓冲区号
---@param after_line number 在哪个行后插入（0 表示在第一行前）
---@param content string 新行内容
---@return number|nil 新插入的行号
function M.insert_line_after(bufnr, after_line, content)
	if not M.is_valid(bufnr) then
		return nil
	end
	local insert_pos = after_line
	pcall(vim.api.nvim_buf_set_lines, bufnr, insert_pos, insert_pos, false, { content })
	return after_line + 1
end

--- 在指定行前插入新行
---@param bufnr number 缓冲区号
---@param before_line number 在哪个行前插入
---@param content string 新行内容
---@return number|nil 新插入的行号
function M.insert_line_before(bufnr, before_line, content)
	if not M.is_valid_line(bufnr, before_line) then
		return nil
	end
	local insert_pos = before_line - 1
	pcall(vim.api.nvim_buf_set_lines, bufnr, insert_pos, insert_pos, false, { content })
	return before_line
end

--- 删除指定行
---@param bufnr number 缓冲区号
---@param line number 行号
---@return boolean 是否成功
function M.delete_line(bufnr, line)
	if not M.is_valid_line(bufnr, line) then
		return false
	end
	pcall(vim.api.nvim_buf_set_lines, bufnr, line - 1, line, false, {})
	return true
end

return M
