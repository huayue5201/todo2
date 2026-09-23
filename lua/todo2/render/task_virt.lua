-- lua/todo2/render/task_virt.lua
-- 任务行虚拟文本共享构建器：供 todo_render / code_render 复用，
-- 统一「状态图标 + 时间」和「子任务进度条」的渲染逻辑。

local M = {}

local types = require("todo2.store.types")
local status = require("todo2.ui.status")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local progress_render = require("todo2.render.progress")

--- 追加状态图标 + 时间显示到虚拟文本数组。
---@param task table 任务对象
---@param parts table[] 虚拟文本数组（原地追加）
---@return table[]
function M.build_status(task, parts)
	parts = parts or {}

	local link_obj = {
		id = task.id,
		status = task.core.status,
		previous_status = task.core.previous_status,
		created_at = task.timestamps.created,
		updated_at = task.timestamps.updated,
		completed_at = task.timestamps.completed,
		archived_at = task.timestamps.archived,
	}

	local components = status.get_display_components(link_obj)
	if not components then
		return parts
	end

	if components.icon and components.icon ~= "" then
		table.insert(parts, { "  ", "Normal" })
		table.insert(parts, { components.icon, components.icon_highlight or "Normal" })
	end

	if components.time and components.time ~= "" then
		table.insert(parts, { " ", "Normal" })
		table.insert(parts, { components.time, components.time_highlight or "Normal" })
	end

	return parts
end

--- 追加子任务进度条到虚拟文本数组。
---@param task_id string 任务ID
---@param parts table[] 虚拟文本数组（原地追加）
---@return table[]
function M.build_progress(task_id, parts)
	parts = parts or {}

	local child_ids = relation.get_child_ids(task_id)
	if #child_ids == 0 then
		return parts
	end

	local all_ids = { task_id }
	local descendants = relation.get_descendants(task_id)
	vim.list_extend(all_ids, descendants)

	local done = 0
	for _, id in ipairs(all_ids) do
		local t = core.get_task(id)
		if t and types.is_completed_status(t.core.status) then
			done = done + 1
		end
	end

	local progress = {
		done = done,
		total = #all_ids,
		percent = #all_ids > 0 and math.floor(done / #all_ids * 100) or 0,
	}

	if progress.total <= 1 then
		return parts
	end

	local virt = progress_render.build(progress)
	if virt and #virt > 0 then
		vim.list_extend(parts, virt)
	end

	return parts
end

return M
