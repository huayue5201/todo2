-- lua/todo2/core/stats.lua
-- 修复版：使用新接口 core.get_task 替代已删除的旧API

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core") -- 改为 core
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 从内部格式获取状态
---------------------------------------------------------------------
local function get_authoritative_status(task)
	if not task then
		return nil, false
	end

	if task.id then
		local t = core.get_task(task.id)
		if t then
			return t.core.status, true
		end
	end

	return task.status, false
end

---------------------------------------------------------------------
-- 判断任务是否在归档区域
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
-- 任务组进度统计
---------------------------------------------------------------------
function M.calc_group_progress(root_task)
	if not root_task then
		return { done = 0, total = 0, percent = 0, group_size = 0 }
	end

	local stats = { total = 0, done = 0 }

	local function count_node(node)
		stats.total = stats.total + 1

		local status = get_authoritative_status(node)
		if status and types.is_completed_status(status) then
			stats.done = stats.done + 1
		end

		for _, child in ipairs(node.children or {}) do
			count_node(child)
		end
	end

	count_node(root_task)

	local percent = stats.total > 0 and math.floor(stats.done / stats.total * 100) or 0

	return {
		done = stats.done,
		total = stats.total,
		percent = percent,
		group_size = stats.total,
	}
end

function M.calculate_all_stats(tasks)
	for _, t in ipairs(tasks) do
		if not t.parent then
			t.stats = M.calc_group_progress(t)
		end
	end
end

---------------------------------------------------------------------
-- 文件摘要统计
---------------------------------------------------------------------
function M.summarize(lines, path)
	if not path or path == "" then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
			archived = { tasks = 0, items = 0, completed = 0, done = 0 },
		}
	end

	-- 通过 scheduler 获取解析树
	local tasks, roots, id_to_task, archive_trees = scheduler.get_parse_tree(path, false)

	if not tasks or #tasks == 0 then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
			archived = { tasks = 0, items = 0, completed = 0, done = 0 },
		}
	end

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

	local function count_node(node, is_in_archive)
		local status = get_authoritative_status(node)

		if is_in_archive then
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

		for _, child in ipairs(node.children or {}) do
			count_node(child, is_in_archive)
		end
	end

	-- 每个节点单独判断是否在归档区域
	for _, root in ipairs(roots) do
		local function walk(node)
			local in_archive = is_task_in_archive(node, archive_trees)
			count_node(node, in_archive)
			for _, child in ipairs(node.children or {}) do
				walk(child)
			end
		end
		walk(root)
	end

	return {
		todo = active.todo,
		done = active.done,
		total_items = active.total_items,
		completed_items = active.completed_items,
		total_tasks = active.total_tasks,
		archived = archived,
	}
end

return M
