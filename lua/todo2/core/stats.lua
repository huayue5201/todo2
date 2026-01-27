-- lua/todo2/core/stats.lua
--- @module todo2.core.stats

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 统计（递归）
---------------------------------------------------------------------
local function calc_stats(task)
	if task.stats then
		return task.stats
	end

	local stats = { total = 0, done = 0 }

	if #task.children == 0 then
		stats.total = 1
		stats.done = task.is_done and 1 or 0
	else
		for _, child in ipairs(task.children) do
			local s = calc_stats(child)
			stats.total = stats.total + s.total
			stats.done = stats.done + s.done
		end
	end

	task.stats = stats
	return stats
end

function M.calculate_all_stats(tasks)
	for _, t in ipairs(tasks) do
		if not t.parent then
			calc_stats(t)
		end
	end
end

---------------------------------------------------------------------
-- ⭐ 新版 summarize：基于 parser.parse_file(path)
---------------------------------------------------------------------
function M.summarize(lines, path)
	-- 如果没有传 path，则无法使用 parse_file
	if not path or path == "" then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
		}
	end

	-- 使用 parser.parse_file(path) 获取任务树
	local parser_mod = module.get("core.parser")
	local tasks, roots = parser_mod.parse_file(path)

	local count = {
		todo = 0,
		done = 0,
		total_items = 0,
		completed_items = 0,
	}

	for _, t in ipairs(tasks) do
		if not t.parent then
			if t.is_done then
				count.done = count.done + 1
			else
				count.todo = count.todo + 1
			end
		end

		count.total_items = count.total_items + 1
		if t.is_done then
			count.completed_items = count.completed_items + 1
		end
	end

	count.total_tasks = count.todo + count.done
	return count
end

return M
