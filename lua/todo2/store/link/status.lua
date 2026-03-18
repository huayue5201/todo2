-- lua/todo2/store/link/status.lua
-- 状态管理：专门处理任务的状态变更

local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 状态常量（方便使用）
---------------------------------------------------------------------
M.STATUS = types.STATUS

---------------------------------------------------------------------
-- 标记完成
---------------------------------------------------------------------

---标记任务为完成
---@param id string 任务ID
---@return table? 更新后的任务
function M.complete(id)
	local task = core.get_task(id)
	if not task then
		vim.notify("任务不存在", vim.log.levels.ERROR)
		return nil
	end

	local now = os.time()
	task.core.previous_status = task.core.status
	task.core.status = types.STATUS.COMPLETED
	task.timestamps.completed = now
	task.timestamps.updated = now

	core.save_task(id, task)
	return task
end

---------------------------------------------------------------------
-- 重新打开任务
---------------------------------------------------------------------

---重新打开已完成/归档的任务
---@param id string 任务ID
---@return table? 更新后的任务
function M.reopen(id)
	local task = core.get_task(id)
	if not task then
		vim.notify("任务不存在", vim.log.levels.ERROR)
		return nil
	end

	local now = os.time()
	task.core.status = task.core.previous_status or types.STATUS.NORMAL
	task.core.previous_status = nil
	task.timestamps.completed = nil
	task.timestamps.archived = nil
	task.timestamps.archived_reason = nil
	task.timestamps.updated = now

	core.save_task(id, task)
	return task
end

---------------------------------------------------------------------
-- 设置状态
---------------------------------------------------------------------

---设置任务状态（通用接口）
---@param id string 任务ID
---@param new_status string 新状态
---@return table? 更新后的任务
function M.set_status(id, new_status)
	if not types.is_valid_status(new_status) then
		vim.notify("无效的状态: " .. tostring(new_status), vim.log.levels.ERROR)
		return nil
	end

	local task = core.get_task(id)
	if not task then
		vim.notify("任务不存在", vim.log.levels.ERROR)
		return nil
	end

	local now = os.time()
	task.core.previous_status = task.core.status
	task.core.status = new_status

	if new_status == types.STATUS.COMPLETED then
		task.timestamps.completed = now
	elseif new_status == types.STATUS.ARCHIVED then
		-- 注意：归档应该使用 archive.archive_task()，这里只改状态
		vim.notify("建议使用 archive.archive_task() 进行归档", vim.log.levels.WARN)
		task.timestamps.archived = now
	end

	task.timestamps.updated = now

	core.save_task(id, task)
	return task
end

---------------------------------------------------------------------
-- 状态判断
---------------------------------------------------------------------

---判断任务是否已完成
---@param id string 任务ID
---@return boolean
function M.is_completed(id)
	local task = core.get_task(id)
	return task and types.is_completed_status(task.core.status) or false
end

---判断任务是否已归档
---@param id string 任务ID
---@return boolean
function M.is_archived(id)
	local task = core.get_task(id)
	return task and task.core.status == types.STATUS.ARCHIVED or false
end

---判断任务是否活跃（未完成且未归档）
---@param id string 任务ID
---@return boolean
function M.is_active(id)
	local task = core.get_task(id)
	return task and types.is_active_status(task.core.status) or false
end

---------------------------------------------------------------------
-- 批量操作
---------------------------------------------------------------------

---批量标记完成
---@param ids string[] 任务ID列表
---@return table<string, table?> 结果映射表
function M.complete_many(ids)
	local results = {}
	for _, id in ipairs(ids) do
		results[id] = M.complete(id)
	end
	return results
end

---批量重新打开
---@param ids string[] 任务ID列表
---@return table<string, table?> 结果映射表
function M.reopen_many(ids)
	local results = {}
	for _, id in ipairs(ids) do
		results[id] = M.reopen(id)
	end
	return results
end

return M
