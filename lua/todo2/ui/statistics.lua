-- lua/todo2/ui/statistics.lua
--- @module todo2.ui.statistics
--- @brief 统计信息格式化（使用配置模块的进度条样式）

local M = {}

local config = require("todo2.config")

--- 格式化统计摘要
--- @param stat table 统计信息（来自 core.stats.summarize）
--- @return string 格式化后的文本
function M.format_summary(stat)
	if not stat then
		return "暂无数据"
	end

	local total = stat.total_items or 0
	local completed = stat.completed_items or 0
	local tasks = stat.total_tasks or 0
	local done = stat.done or 0

	local archived_tasks = stat.archived and stat.archived.tasks or 0
	local archived_items = stat.archived and stat.archived.items or 0

	if total == 0 and archived_items == 0 then
		return "暂无任务"
	end

	local parts = {}

	---------------------------------------------------------------------
	-- ⭐ 使用 progress_bar 配置（不再调用不存在的 API）
	---------------------------------------------------------------------
	local bar_cfg = config.get("progress_bar") or {}
	local chars = bar_cfg.chars or { filled = "█", empty = "░" }
	local length_cfg = bar_cfg.length or {}
	local bar_length = length_cfg.max or 20

	---------------------------------------------------------------------
	-- 活跃区域进度
	---------------------------------------------------------------------
	if total > 0 then
		local ratio = completed / total
		local percent = math.floor(ratio * 100)

		local filled = math.floor(ratio * bar_length)
		local bar = string.rep(chars.filled, filled) .. string.rep(chars.empty, bar_length - filled)

		if tasks == total then
			table.insert(parts, string.format("%s %d%%｜完成: %d/%d", bar, percent, completed, total))
		else
			table.insert(
				parts,
				string.format("%s %d%%｜主任务: %d/%d｜总计: %d/%d", bar, percent, done, tasks, completed, total)
			)
		end
	end

	---------------------------------------------------------------------
	-- 归档区域信息
	---------------------------------------------------------------------
	if archived_items > 0 then
		table.insert(parts, string.format("📦 归档: %d个任务", archived_tasks))
	end

	return table.concat(parts, " ｜ ")
end

return M
