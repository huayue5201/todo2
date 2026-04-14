-- lua/todo2/core/stats.lua
-- 完全重构版：100% 基于 store，不依赖 scheduler

local M = {}

local types = require("todo2.store.types")
local index = require("todo2.store.index")

---------------------------------------------------------------------
-- 获取任务状态（权威来源：store）
---------------------------------------------------------------------
local function get_status(task)
	if not task or not task.core then
		return nil
	end
	return task.core.status
end

---------------------------------------------------------------------
-- 判断是否为根任务（无 parent_id）
---------------------------------------------------------------------
local function is_root(task)
	return not (task.relations and task.relations.parent_id)
end

---------------------------------------------------------------------
-- 主函数：文件摘要统计
---------------------------------------------------------------------
function M.summarize(_, path)
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

	-- 直接从 store 获取任务（不解析文件）
	local todo_tasks = index.find_todo_links_by_file(path)

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

	for _, task in ipairs(todo_tasks) do
		local status = get_status(task)
		local is_archived = (status == types.STATUS.ARCHIVED)

		-- 每个任务都是一个 item
		if is_archived then
			archived.items = archived.items + 1
		else
			active.total_items = active.total_items + 1
		end

		-- 完成状态
		if status == types.STATUS.COMPLETED then
			if is_archived then
				archived.completed = archived.completed + 1
			else
				active.completed_items = active.completed_items + 1
			end
		end

		-- 根任务统计
		if is_root(task) then
			if is_archived then
				archived.tasks = archived.tasks + 1
				if status == types.STATUS.COMPLETED then
					archived.done = archived.done + 1
				end
			else
				active.total_tasks = active.total_tasks + 1
				if status == types.STATUS.COMPLETED then
					active.done = active.done + 1
				elseif types.is_active_status(status) then
					active.todo = active.todo + 1
				end
			end
		end
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
