-- lua/todo2/render/task_virt.lua
-- 任务行虚拟文本共享构建器：供 todo_render / code_render 复用，
-- 统一「状态图标 + 时间」和「子任务进度条」的渲染逻辑。

local M = {}

local types = require("todo2.store.types")
local status = require("todo2.ui.status")
local core = require("todo2.store.task.core")
local relation = require("todo2.store.task.relation")
local progress_render = require("todo2.render.progress")
local due_utils = require("todo2.utils.due")

--- 追加状态图标 + 行尾元数据带（到期日 · 最近改动时间）到虚拟文本数组。
---
--- 布局：`  <状态图标> <🔄时间> · <start→due>`
---   - 时间字段：同行时 `MM-DD`，跳年 `YYYY-MM-DD`；有排期时写成 `10-20→11-02`，
---     按 due 的紧迫度上色（只有 start 时按 start 着色，终态转灰）
---   - 时间：完成/归档取对应时间，其余取最后修改时间
---   - 两段之间用灰色 `·` 分隔；缺段时不留空位
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

	local st = task.core.status
	local cfg = status.get(st)
	if not cfg then
		return parts
	end

	if cfg.icon and cfg.icon ~= "" then
		table.insert(parts, { "  ", "Normal" })
		table.insert(parts, { cfg.icon, cfg.hl_group or "Normal" })
	end

	-- 时间字段：有 due 取 due 着色（承诺的紧迫度），只有 start 时按 start 着色
	local span_text = due_utils.format_span_short(task.core.start, task.core.due)
	local span_hl = due_utils.hl(task.core.due or task.core.start, st) or "TodoTime"
	local time_text = status.get_time_display(link_obj, "short")
	-- 终态的图标已说明时间语义（✓ 完成 / ❚ 归档），不再重复前缀符号
	local terminal = types.is_completed_status(st)

	-- 顺序：状态图标 → 建立/修改时间 → 到期日。时间在前更符合阅读直觉
	--（先看这条任务什么时候动过，再看它什么时候到期）。
	if time_text ~= "" then
		table.insert(parts, { " ", "Normal" })
		table.insert(parts, { (terminal and "" or "↻") .. time_text, "TodoTime" })
	end

	if span_text ~= "" and time_text ~= "" then
		table.insert(parts, { " ·", "Comment" })
	end

	if span_text ~= "" then
		table.insert(parts, { " ", "Normal" })
		table.insert(parts, { span_text, span_hl })
	end

	return parts
end

--- 追加子任务进度条到虚拟文本数组。
---@param task_id string 任务ID
---@param parts table[] 虚拟文本数组（原地追加）
---@return table[]
function M.build_progress(task_id, parts)
	parts = parts or {}

	local all_ids = { task_id }
	local descendants = relation.get_descendants(task_id)
	if #descendants == 0 then
		return parts
	end
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
