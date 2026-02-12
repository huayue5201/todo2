-- lua/todo2/core/stats.lua
--- @module todo2.core.stats
--- @brief 统计模块（适配 status 字段，始终使用完整任务树）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser") -- ✅ 直接依赖
local types = require("todo2.store.types") -- ✅ 状态判断工具

---------------------------------------------------------------------
-- 统计计算（递归，基于 status）
---------------------------------------------------------------------
local function calc_stats(task)
	if task.stats then
		return task.stats
	end

	local stats = { total = 0, done = 0 }

	if #task.children == 0 then
		stats.total = 1
		-- ✅ 使用统一的状态判断函数
		stats.done = types.is_completed_status(task.status) and 1 or 0
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

--- 计算整个任务集的统计信息（修改任务对象，缓存 stats）
--- @param tasks table[] 任务列表（通常来自 parser）
function M.calculate_all_stats(tasks)
	for _, t in ipairs(tasks) do
		if not t.parent then
			calc_stats(t)
		end
	end
end

---------------------------------------------------------------------
-- 文件摘要统计（始终使用完整任务树）
---------------------------------------------------------------------
--- 获取文件的整体统计摘要
--- @param lines table 文件行（已不再使用，保留参数向后兼容）
--- @param path string 文件路径
--- @return table 统计结果
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

	-- 始终使用完整树，不受 context_split 影响
	local tasks, roots = parser.parse_file(path)
	if not tasks then
		return {
			todo = 0,
			done = 0,
			total_items = 0,
			completed_items = 0,
			total_tasks = 0,
		}
	end

	local count = {
		todo = 0,
		done = 0,
		total_items = 0,
		completed_items = 0,
	}

	for _, t in ipairs(tasks) do
		-- 根任务计数（todo/done）
		if not t.parent then
			if types.is_completed_status(t.status) then
				count.done = count.done + 1
			else
				count.todo = count.todo + 1
			end
		end

		-- 所有任务计数
		count.total_items = count.total_items + 1
		if types.is_completed_status(t.status) then
			count.completed_items = count.completed_items + 1
		end
	end

	count.total_tasks = count.todo + count.done
	return count
end

return M
