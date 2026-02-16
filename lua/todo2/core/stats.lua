-- lua/todo2/core/stats.lua
--- @module todo2.core.stats
--- @brief 统计模块（修复：使用存储层作为权威状态）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local types = require("todo2.store.types")
local link = require("todo2.store.link") -- ⭐ 新增：使用存储层

---------------------------------------------------------------------
-- 从存储获取权威状态
---------------------------------------------------------------------
local function get_authoritative_status(task_id)
	if not task_id then
		return nil
	end
	local todo_link = link.get_todo(task_id, { verify_line = false })
	return todo_link and todo_link.status or nil
end

---------------------------------------------------------------------
-- 统计计算（使用存储层状态）
---------------------------------------------------------------------
local function calc_stats(task, id_to_task)
	if task.stats then
		return task.stats
	end

	local stats = { total = 0, done = 0 }

	-- 获取权威状态
	local authoritative_status = nil
	if task.id then
		authoritative_status = get_authoritative_status(task.id)
	end
	local status_to_use = authoritative_status or task.status

	if #task.children == 0 then
		stats.total = 1
		stats.done = types.is_completed_status(status_to_use) and 1 or 0
	else
		-- 递归统计所有子任务
		for _, child in ipairs(task.children) do
			local s = calc_stats(child, id_to_task)
			stats.total = stats.total + s.total
			stats.done = stats.done + s.done
		end
	end

	task.stats = stats
	return stats
end

--- 计算整个任务集的统计信息
--- @param tasks table[] 任务列表
--- @param id_to_task table ID到任务的映射
function M.calculate_all_stats(tasks, id_to_task)
	for _, t in ipairs(tasks) do
		if not t.parent then
			calc_stats(t, id_to_task)
		end
	end
end

---------------------------------------------------------------------
-- 文件摘要统计（使用存储层状态）
---------------------------------------------------------------------
function M.summarize(lines, path)
	if not path or path == "" then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
		}
	end

	-- 解析文件获取任务树
	local tasks, roots, id_to_task = parser.parse_file(path)
	if not tasks or #tasks == 0 then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
		}
	end

	-- 检测归档区域，排除归档任务
	local archive_lines = {}
	local bufnr = vim.fn.bufnr(path)
	if bufnr ~= -1 and parser.detect_archive_sections then
		local file_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
		local sections = parser.detect_archive_sections(file_lines)
		for _, section in ipairs(sections) do
			for line = section.start_line, section.end_line do
				archive_lines[line] = true
			end
		end
	end

	local count = {
		todo = 0,
		done = 0,
		total_items = 0,
		completed_items = 0,
	}

	-- 遍历所有任务
	for _, task in ipairs(tasks) do
		-- 跳过归档区域的任务
		if archive_lines[task.line_num] then
			goto continue
		end

		-- 获取权威状态
		local authoritative_status = nil
		if task.id then
			authoritative_status = get_authoritative_status(task.id)
		end
		local status_to_use = authoritative_status or task.status

		-- 所有任务计数
		count.total_items = count.total_items + 1

		-- 已完成任务计数（只统计 COMPLETED）
		if status_to_use == types.STATUS.COMPLETED then
			count.completed_items = count.completed_items + 1
		end

		-- 根任务统计
		if not task.parent then
			if status_to_use == types.STATUS.COMPLETED then
				count.done = count.done + 1
			elseif types.is_active_status(status_to_use) then
				count.todo = count.todo + 1
			end
		end

		::continue::
	end

	count.total_tasks = count.todo + count.done
	return count
end

return M
