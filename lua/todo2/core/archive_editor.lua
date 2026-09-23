-- lua/todo2/core/archive_editor.lua
-- 归档相关的缓冲区行编辑：负责 TODO 文件行的读取、归档区定位与行移动。

local M = {}

local archive_utils = require("todo2.core.archive_utils")

---获取缓冲区行（优先从缓冲区读取）
---@param bufnr number 缓冲区号
---@return string[]|nil
function M.get_buffer_lines(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---查找或创建归档区域
---@param bufnr number 缓冲区号
---@param lines string[] 文件行
---@return number, string[]
function M.find_or_create_archive_section(bufnr, lines)
	local title = archive_utils.build_archive_title()

	for i, line in ipairs(lines) do
		if archive_utils.is_archive_section_line(line) then
			local insert_point = i + 1
			while insert_point <= #lines and lines[insert_point]:match("^%s*$") do
				insert_point = insert_point + 1
			end
			return insert_point, lines
		end
	end

	table.insert(lines, "")
	table.insert(lines, title)

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return #lines + 1, lines
end

---移动行到归档区域
---@param bufnr number 缓冲区号
---@param tasks_to_move table[] 要移动的任务行
---@param archive_start number 归档区域起始行
---@param lines string[] 文件行
---@return table[]
function M.move_tasks_to_archive(bufnr, tasks_to_move, archive_start, lines)
	-- 从原位置删除（从后往前删，避免索引变化）
	table.sort(tasks_to_move, function(a, b)
		return a.original_line > b.original_line
	end)

	for _, item in ipairs(tasks_to_move) do
		if lines[item.original_line] then
			table.remove(lines, item.original_line)
		end
	end

	-- 重新按原顺序插入归档区域
	table.sort(tasks_to_move, function(a, b)
		return a.original_line < b.original_line
	end)

	local insert_pos = archive_start
	for _, item in ipairs(tasks_to_move) do
		if item.original_line < archive_start then
			insert_pos = insert_pos - 1
		end
	end

	for i, item in ipairs(tasks_to_move) do
		local pos = insert_pos + i - 1
		table.insert(lines, pos, item.line)
		item.new_line_num = pos
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	return tasks_to_move
end

return M
