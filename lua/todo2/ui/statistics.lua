-- lua/todo2/ui/statistics.lua
--- @module todo2.ui.statistics
--- @brief 统计信息格式化（使用配置模块的进度条样式）

local M = {}

-- ⭐ 引入配置模块
local config = require("todo2.config")

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
	local percent = math.floor(ratio * 100)

	-- ⭐ 获取进度条字符配置
	local chars = config.get_progress_chars()
	local length_config = config.get_progress_length()

	-- 使用配置的长度（默认20，但可以从配置获取）
	local bar_length = 20 -- 保持向后兼容，或者使用配置
	if length_config and length_config.max then
		bar_length = length_config.max
	end

	local filled = math.floor(ratio * bar_length)
	local bar = string.rep(chars.filled, filled) .. string.rep(chars.empty, bar_length - filled)

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

return M
