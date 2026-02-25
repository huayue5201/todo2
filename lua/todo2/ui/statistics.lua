-- lua/todo2/ui/statistics.lua
--- @module todo2.ui.statistics
--- @brief 统计信息格式化（修复：正确显示进度条和比例）

local M = {}

--- 格式化统计摘要
--- @param stat table 统计信息（来自 core.stats.summarize）
--- @return string 格式化后的文本
function M.format_summary(stat)
	if not stat then
		return "暂无数据"
	end

	if stat.total_items == 0 then
		return "暂无任务"
	end

	-- 计算整体完成比例（基于所有任务）
	local ratio = stat.completed_items / stat.total_items
	local filled = math.floor(ratio * 20) -- 20格进度条
	-- TODO:ref:41d806
	local bar = string.rep("▰", filled) .. string.rep("▱", 20 - filled)
	local percent = math.floor(ratio * 100)

	-- 根据是否有根任务来显示不同的格式
	if stat.total_tasks == stat.total_items then
		-- 所有行都是任务（没有非任务行）
		return string.format("%s %d%%｜完成: %d/%d", bar, percent, stat.completed_items, stat.total_items)
	else
		-- 混合内容（有非任务行）
		return string.format(
			"%s %d%%｜主任务: %d/%d｜总计: %d/%d",
			bar,
			percent,
			stat.done,
			stat.total_tasks,
			stat.completed_items,
			stat.total_items
		)
	end
end

--- 获取简洁的统计摘要（用于状态栏）
--- @param stat table 统计信息
--- @return string 简洁格式
function M.format_compact(stat)
	if not stat or stat.total_items == 0 then
		return "📋 0"
	end

	local ratio = stat.completed_items / stat.total_items
	local percent = math.floor(ratio * 100)

	if stat.total_tasks == stat.total_items then
		return string.format("📋 %d/%d %d%%", stat.completed_items, stat.total_items, percent)
	else
		return string.format(
			"📋 %d/%d %d%% | %d/%d",
			stat.completed_items,
			stat.total_items,
			percent,
			stat.done,
			stat.total_tasks
		)
	end
end

return M
