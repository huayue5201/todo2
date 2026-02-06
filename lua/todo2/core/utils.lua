-- 文件位置：lua/todo2/core/utils.lua
--- @module todo2.core.utils
--- @brief 统一的工具函数模块（精简版）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 任务ID处理（保留，有业务逻辑）
---------------------------------------------------------------------

--- 确保任务有ID
--- @param bufnr number 缓冲区句柄
--- @param lnum number 行号（1-indexed）
--- @param task table 任务对象（可选）
--- @return string|nil 任务ID
function M.ensure_task_id(bufnr, lnum, task)
	-- 如果传入了任务对象，且已有ID，直接返回
	if task and task.id then
		return task.id
	end

	-- 否则获取解析器解析当前行
	local parser = module.get("core.parser")
	if not parser then
		vim.notify("无法获取 parser 模块", vim.log.levels.ERROR)
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	local parsed_task = parser.parse_task_line(line)

	if not parsed_task then
		vim.notify("当前行不是有效的任务行", vim.log.levels.WARN)
		return nil
	end

	if parsed_task.id then
		return parsed_task.id
	end

	-- 生成新ID
	local link_module = module.get("link")
	if not link_module then
		vim.notify("无法获取 link 模块", vim.log.levels.ERROR)
		return nil
	end

	local new_id = link_module.generate_id()
	if not new_id then
		vim.notify("无法生成任务ID", vim.log.levels.ERROR)
		return nil
	end

	return new_id
end

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
	return task.is_done and "✓" or "☐", task.is_done
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
		if child.is_done ~= nil then
			total = total + 1
			if child.is_done then
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
	local parser = module.get("core.parser")
	if not parser then
		return nil
	end

	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	return parser.parse_task_line(line)
end

return M
