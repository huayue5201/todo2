-- lua/todo2/core/status.lua
-- 状态领域逻辑：唯一的循环顺序 + 状态写入

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 循环顺序（仅活跃状态；完成/归档不参与循环）
---------------------------------------------------------------------
local CYCLE_ORDER = {
	types.STATUS.NORMAL,
	types.STATUS.URGENT,
	types.STATUS.WAITING,
}

M.CYCLE_ORDER = CYCLE_ORDER

---------------------------------------------------------------------
-- 获取下一个状态（用于 cycle）
---------------------------------------------------------------------
function M.get_next(current)
	for i, s in ipairs(CYCLE_ORDER) do
		if s == current then
			return CYCLE_ORDER[i % #CYCLE_ORDER + 1]
		end
	end
	return CYCLE_ORDER[1]
end

---------------------------------------------------------------------
-- 纯数据更新：写存储 + 触发事件
---------------------------------------------------------------------
function M.update(id, target_status, source, opts)
	opts = opts or {}
	source = source or "status_update"

	local task = core.get_task(id)
	if not task then
		return false, "找不到任务: " .. tostring(id)
	end

	-- 已完成的任务不参与状态切换（含 cycle 与菜单）
	if task.core.status == types.STATUS.COMPLETED then
		return false, "已完成的任务不能切换状态"
	end

	task.core.status = target_status
	task.timestamps.updated = os.time()

	core.save_task(id, task)

	if not opts.skip_event then
		events.emit(source, {
			changed_ids = { id },
			ids = { id },
			files = {},
		})
	end

	return true, "ok"
end

--- 进入终态（completed / archived）：记住之前的活跃状态
---@param task table
---@param target_status string COMPLETED 或 ARCHIVED
---@param now? number
function M.enter_terminal(task, target_status, now)
	now = now or os.time()
	task.core.previous_status = task.core.status
	task.core.status = target_status
	task.timestamps.updated = now
	if target_status == types.STATUS.COMPLETED then
		task.timestamps.completed = now
	elseif target_status == types.STATUS.ARCHIVED then
		task.timestamps.archived = now
	end
end

--- 退出终态：恢复为活跃状态
---@param task table
---@param restore_status? string 优先使用的恢复状态（如快照中的状态）
---@param now? number
function M.exit_terminal(task, restore_status, now)
	if not types.is_completed_status(task.core.status) then
		return
	end
	now = now or os.time()
	task.core.status = restore_status or task.core.previous_status or types.STATUS.NORMAL
	task.core.previous_status = nil
	task.timestamps.completed = nil
	task.timestamps.archived = nil
	task.timestamps.updated = now
end

---------------------------------------------------------------------
-- 循环切换状态（UI 调用）
---------------------------------------------------------------------
function M.cycle(id)
	local task = core.get_task(id)
	if not task then
		return false, "找不到任务"
	end

	if task.core.status == types.STATUS.COMPLETED then
		return false, "已完成的任务不能切换状态"
	end

	return M.update(id, M.get_next(task.core.status), "cycle")
end

return M
