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

	-- ⭐ 活跃区域统计
	local total = stat.total_items or 0
	local completed = stat.completed_items or 0
	local tasks = stat.total_tasks or 0
	local done = stat.done or 0

	-- ⭐ 归档区域统计（如果有）
	local archived_tasks = stat.archived and stat.archived.tasks or 0
	local archived_items = stat.archived and stat.archived.items or 0

	if total == 0 and archived_items == 0 then
		return "暂无任务"
	end

	-- 构建显示字符串
	local parts = {}

	-- 活跃区域进度
	if total > 0 then
		local ratio = completed / total
		local percent = math.floor(ratio * 100)

		-- 获取进度条字符配置
		local chars = config.get_progress_chars()
		local length_config = config.get_progress_length()

		-- 使用配置的长度
		local bar_length = 20
		if length_config and length_config.max then
			bar_length = length_config.max
		end

		local filled = math.floor(ratio * bar_length)
		local bar = string.rep(chars.filled, filled) .. string.rep(chars.empty, bar_length - filled)

		if tasks == total then
			-- 所有行都是任务（没有非任务行）
			table.insert(parts, string.format("%s %d%%｜完成: %d/%d", bar, percent, completed, total))
		else
			-- 混合内容（有非任务行）
			table.insert(
				parts,
				string.format("%s %d%%｜主任务: %d/%d｜总计: %d/%d", bar, percent, done, tasks, completed, total)
			)
		end
	end

	-- 归档区域信息
	if archived_items > 0 then
		table.insert(parts, string.format("📦 归档: %d个任务", archived_tasks))
	end

	return table.concat(parts, " ｜ ")
end

return M
