-- lua/todo2/utils/buffer.lua
-- 缓冲区工具模块：提供统一的缓冲区操作

local M = {}

local file = require("todo2.utils.file")

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

---------------------------------------------------------------------
-- 行缩进操作
---------------------------------------------------------------------

---------------------------------------------------------------------
-- 窗口信息
---------------------------------------------------------------------

--- 判断窗口是否为浮动窗口
---@param winid number|nil 窗口号，nil 表示当前窗口
---@return boolean
function M.is_float_window(winid)
	winid = winid or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(winid) then
		return false
	end
	local cfg = vim.api.nvim_win_get_config(winid)
	return cfg.relative ~= ""
end

--- 获取当前缓冲区/窗口信息
---@return {bufnr: number, winid: number, filename: string, is_todo_file: boolean, is_float_window: boolean}
function M.get_current_info()
	local bufnr = vim.api.nvim_get_current_buf()
	local winid = vim.api.nvim_get_current_win()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	return {
		bufnr = bufnr,
		winid = winid,
		filename = filename,
		is_todo_file = file.is_todo_file(filename),
		is_float_window = M.is_float_window(winid),
	}
end

return M
