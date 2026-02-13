-- lua/todo2/core/utils.lua
local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser")

---------------------------------------------------------------------
-- 获取任务状态（保留）
---------------------------------------------------------------------

--- 获取任务状态
--- @param task table 任务对象
--- @return string, boolean 状态图标, 是否完成
function M.get_task_status(task)
	if not task then
		return nil
	end
	return task.completed and "✓" or "☐", task.completed -- 使用 completed 字段
end

---------------------------------------------------------------------
-- 获取任务文本（带截断）（保留）
---------------------------------------------------------------------

--- 获取任务文本
--- @param task table 任务对象
--- @param max_len number 最大长度（可选）
--- @return string|nil 任务文本
function M.get_task_text(task, max_len)
	if not task then
		return nil
	end

	local text = task.content or ""
	max_len = max_len or 40

	-- 去除首尾空白
	text = text:gsub("^%s+", ""):gsub("%s+$", "")

	-- 计算 UTF-8 字符长度
	local char_len = vim.str_utfindex(text)

	-- 如果长度在限制内，直接返回
	if char_len <= max_len then
		return text
	end

	-- 计算截断位置（留出3个字符给省略号）
	local byte_index = vim.str_byteindex(text, max_len - 3, true)

	-- 安全截断并添加省略号
	return text:sub(1, byte_index or #text) .. "..."
end

---------------------------------------------------------------------
-- 获取任务进度（保留）
---------------------------------------------------------------------

--- 获取任务进度
--- @param task table 任务对象
--- @return table|nil 进度信息
function M.get_task_progress(task)
	if not task or not task.children or #task.children == 0 then
		return nil
	end

	local done, total = 0, 0

	for _, child in ipairs(task.children) do
		if child.completed ~= nil then -- 使用 completed 字段
			total = total + 1
			if child.completed then
				done = done + 1
			end
		end
	end

	if total == 0 then
		return nil
	end

	return {
		done = done,
		total = total,
		percent = math.floor(done / total * 100),
	}
end

---------------------------------------------------------------------
-- 通用工具函数（精简）
---------------------------------------------------------------------

--- 获取行缩进
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @return string 缩进字符串
function M.get_line_indent(bufnr, lnum)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return line:match("^(%s*)") or ""
end

--- 获取当前行的任务信息
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @return table|nil 任务信息
function M.get_task_at_line(bufnr, lnum)
	if not parser then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return parser.parse_task_line(line)
end

return M
