-- lua/todo2/core/stats.lua
--- @module todo2.core.stats
--- @brief 统计模块（修复：使用存储层作为权威状态）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local types = require("todo2.store.types")
local link = require("todo2.store.link")

---------------------------------------------------------------------
-- 核心：双轨状态获取
---------------------------------------------------------------------

--- 获取任务的权威状态（双轨制）
--- @param task table 解析树中的任务
--- @return string|nil status, boolean is_from_store
local function get_authoritative_status(task)
	if not task then
		return nil, false
	end

	-- 双链任务：从存储层获取（第一正确数据源）
	if task.id then
		local todo_link = link.get_todo(task.id, { verify_line = false })
		if todo_link then
			return todo_link.status, true
		end
	end

	-- 普通任务：从解析树获取
	return task.status, false
end

---------------------------------------------------------------------
-- 任务组进度统计（核心双轨实现）
---------------------------------------------------------------------

--- 递归统计任务组（供渲染层复用）
--- @param root_task table 根任务（解析树节点）
--- @return table { done = number, total = number, percent = number, group_size = number }
function M.calc_group_progress(root_task)
	if not root_task then
		return { done = 0, total = 0, percent = 0, group_size = 0 }
	end

	local stats = { total = 0, done = 0 }

	-- 递归统计内部函数
	local function count_node(node)
		-- 统计当前节点
		stats.total = stats.total + 1

		-- 获取双轨状态
		local status = get_authoritative_status(node)
		if status and types.is_completed_status(status) then
			stats.done = stats.done + 1
		end

		-- 递归统计子节点
		for _, child in ipairs(node.children or {}) do
			count_node(child)
		end
	end

	count_node(root_task)

	-- 计算百分比
	local percent = stats.total > 0 and math.floor(stats.done / stats.total * 100) or 0

	return {
		done = stats.done,
		total = stats.total,
		percent = percent,
		group_size = stats.total,
	}
end

--- 计算整个任务集的统计信息
--- @param tasks table[] 任务列表
--- @param id_to_task table ID到任务的映射
function M.calculate_all_stats(tasks, id_to_task)
	for _, t in ipairs(tasks) do
		if not t.parent then
			t.stats = M.calc_group_progress(t)
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

		-- 获取权威状态（复用双轨逻辑）
		local status = get_authoritative_status(task)

		-- 所有任务计数
		count.total_items = count.total_items + 1

		-- 已完成任务计数（只统计 COMPLETED）
		if status == types.STATUS.COMPLETED then
			count.completed_items = count.completed_items + 1
		end

		-- 根任务统计
		if not task.parent then
			if status == types.STATUS.COMPLETED then
				count.done = count.done + 1
			elseif types.is_active_status(status) then
				count.todo = count.todo + 1
			end
		end

		::continue::
	end

	count.total_tasks = count.todo + count.done
	return count
end

return M
