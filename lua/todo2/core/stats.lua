-- lua/todo2/core/stats.lua
--- @module todo2.core.stats
--- @brief 统计模块（修复：使用存储层作为权威状态，并区分区域）

local M = {}

---------------------------------------------------------------------
-- 直接依赖
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local types = require("todo2.store.types")
local link = require("todo2.store.link")
local config = require("todo2.config")

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
-- ⭐ 新增：判断任务是否在归档区域
---------------------------------------------------------------------
local function is_task_in_archive(task, archive_trees)
	if not task or not archive_trees then
		return false
	end

	for _, tree in pairs(archive_trees) do
		if task.line_num >= tree.start_line and task.line_num <= tree.end_line then
			return true
		end
	end
	return false
end

---------------------------------------------------------------------
-- 任务组进度统计（核心双轨实现）
---------------------------------------------------------------------

--- 递归统计任务组（供渲染层复用）
--- @param root_task table 根任务（解析树节点）
--- @param exclude_archive boolean 是否排除归档区域的任务
--- @return table { done = number, total = number, percent = number, group_size = number }
function M.calc_group_progress(root_task, exclude_archive)
	if not root_task then
		return { done = 0, total = 0, percent = 0, group_size = 0 }
	end

	local stats = { total = 0, done = 0 }

	-- ⭐ 递归统计内部函数
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
-- ⭐ 修复版：文件摘要统计（区分活跃区域和归档区域）
---------------------------------------------------------------------
function M.summarize(lines, path)
	if not path or path == "" then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
			archived = {
				tasks = 0,
				items = 0,
				completed = 0,
				done = 0,
			},
		}
	end

	-- 解析文件获取任务树和归档区域
	local tasks, roots, id_to_task = parser.parse_file(path)
	local archive_trees = parser.parse_archive_trees(path, false)

	if not tasks or #tasks == 0 then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
			archived = {
				tasks = 0,
				items = 0,
				completed = 0,
				done = 0,
			},
		}
	end

	-- ⭐ 分离活跃区域和归档区域的统计
	local active = {
		todo = 0,
		done = 0,
		total_items = 0,
		completed_items = 0,
		total_tasks = 0,
	}

	local archived = {
		tasks = 0,
		items = 0,
		completed = 0,
		done = 0,
	}

	-- ⭐ 递归统计函数（带区域判断）
	local function count_node(node, is_in_archive)
		if not node then
			return
		end

		-- 获取权威状态
		local status = get_authoritative_status(node)

		if is_in_archive then
			-- 归档区域统计
			archived.items = archived.items + 1
			if status == types.STATUS.COMPLETED then
				archived.completed = archived.completed + 1
			end
			if not node.parent then
				archived.tasks = archived.tasks + 1
				if status == types.STATUS.COMPLETED then
					archived.done = archived.done + 1
				end
			end
		else
			-- 活跃区域统计
			active.total_items = active.total_items + 1
			if status == types.STATUS.COMPLETED then
				active.completed_items = active.completed_items + 1
			end
			if not node.parent then
				active.total_tasks = active.total_tasks + 1
				if status == types.STATUS.COMPLETED then
					active.done = active.done + 1
				elseif types.is_active_status(status) then
					active.todo = active.todo + 1
				end
			end
		end

		-- 递归子任务
		for _, child in ipairs(node.children or {}) do
			count_node(child, is_in_archive)
		end
	end

	-- ⭐ 从根任务开始统计
	for _, root in ipairs(roots) do
		local in_archive = is_task_in_archive(root, archive_trees)
		count_node(root, in_archive)
	end

	return {
		-- 活跃区域
		todo = active.todo,
		done = active.done,
		total_items = active.total_items,
		completed_items = active.completed_items,
		total_tasks = active.total_tasks,
		-- 归档区域
		archived = archived,
	}
end

return M
