-- lua/todo2/core/status.lua
-- 最终版：纯数据状态机，不解析文本、不做区域限制、不写 previous_status

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")
local events = require("todo2.core.events")

---------------------------------------------------------------------
-- 状态机：你可以根据需要自定义
---------------------------------------------------------------------
local NEXT_STATUS = {
	[types.STATUS.NORMAL] = types.STATUS.URGENT,
	[types.STATUS.URGENT] = types.STATUS.WAITING,
	[types.STATUS.WAITING] = types.STATUS.COMPLETED,
	[types.STATUS.COMPLETED] = types.STATUS.NORMAL,
}

---------------------------------------------------------------------
-- 获取下一个状态（用于 cycle）
---------------------------------------------------------------------
function M.get_next(current)
	return NEXT_STATUS[current] or types.STATUS.NORMAL
end

---------------------------------------------------------------------
-- 纯数据更新：不解析文本、不做区域限制、不写 previous_status
---------------------------------------------------------------------
function M.update(id, target_status, source, opts)
	opts = opts or {}
	source = source or "status_update"

	local task = core.get_task(id)
	if not task then
		return false, "找不到任务: " .. tostring(id)
	end

	-- ⭐ 限制：完成状态的任务不能切换（除非你未来允许 archived）
	if task.core.status == types.STATUS.COMPLETED then
		return false, "已完成的任务不能切换状态"
	end

	-- 直接写入存储（纯数据）
	task.core.status = target_status
	task.timestamps.updated = os.time()

	core.save_task(id, task)

	-- 触发事件（渲染层会自动刷新）
	if not opts.skip_event then
		events.on_state_changed({
			source = source,
			changed_ids = { id },
			ids = { id },
			files = {},
			timestamp = os.time() * 1000,
		})
	end

	return true, "ok"
end

---------------------------------------------------------------------
-- 循环切换状态（UI 调用）
---------------------------------------------------------------------
function M.cycle(id)
	local task = core.get_task(id)
	if not task then
		return false, "找不到任务"
	end

	local next_status = M.get_next(task.core.status)
	return M.update(id, next_status, "cycle")
end

---------------------------------------------------------------------
-- 快捷操作（可选）
---------------------------------------------------------------------
function M.mark_completed(id)
	return M.update(id, types.STATUS.COMPLETED, "mark_completed")
end

function M.reopen(id)
	return M.update(id, types.STATUS.NORMAL, "reopen")
end

function M.archive(id)
	return M.update(id, types.STATUS.ARCHIVED, "archive")
end

return M
