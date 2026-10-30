-- lua/todo2/ui/statistics.lua
--- @module todo2.ui.statistics
--- @brief 统计信息格式化（使用配置模块的进度条样式）

local M = {}

local progress_render = require("todo2.render.progress")

--- 格式化统计摘要
--- @param stat table 统计信息（来自 core.stats.summarize）
--- @return string 格式化后的文本
function M.format_summary(stat)
	if not stat then
		return "No data"
	end

	local total = stat.total_items or 0
	local completed = stat.completed_items or 0
	local tasks = stat.total_tasks or 0
	local done = stat.done or 0

	local archived_tasks = stat.archived and stat.archived.tasks or 0
	local archived_items = stat.archived and stat.archived.items or 0

	if total == 0 and archived_items == 0 then
		return "No tasks"
	end

	local parts = {}

	---进度条统一走 render/progress（字符、style、长度都跟配置走，不再维护第二套）
	---@param percent integer
	---@param total_count integer
	---@return string
	local function progress_text(percent, total_count)
		local bar = progress_render.bar_text({ percent = percent, total = total_count })
		if bar == "" then
			return string.format("%d%%", percent)
		end
		return string.format("%s %d%%", bar, percent)
	end

	---------------------------------------------------------------------
	-- 活跃区域进度
	---------------------------------------------------------------------
	if total > 0 then
		local percent = math.floor(completed / total * 100)
		local bar = progress_text(percent, total)

		if tasks == total then
			table.insert(parts, string.format("%s | done: %d/%d", bar, completed, total))
		else
			table.insert(
				parts,
				string.format("%s | top-level: %d/%d | total: %d/%d", bar, done, tasks, completed, total)
			)
		end
	end

	---------------------------------------------------------------------
	-- 归档区域信息
	---------------------------------------------------------------------
	if archived_items > 0 then
		table.insert(parts, string.format("📦 Archived: %d tasks", archived_tasks))
	end

	return table.concat(parts, " | ")
end

return M
