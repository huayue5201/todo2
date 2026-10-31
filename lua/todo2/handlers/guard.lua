-- lua/todo2/handlers/guard.lua
-- 任务可写性守卫：把"哪些状态下允许写入"收成一条规则。
--
-- 归档（`core.status = archived`）是**冻结态**：可以阅读、跳转、反归档，
-- 其余写入（改日期、改标签、删除、改标题）一律拒绝，并告诉用户下一步怎么做。
-- 之前同一条规则散落在抽屉 / deleter / datefield / tags 里，导致"能不能改"
-- 取决于从哪个入口进来。
local M = {}

local types = require("todo2.store.types")
local core = require("todo2.store.task.core")

---任务是否被冻结（当前只有归档）。
---@param task table|nil
---@return boolean
function M.is_frozen(task)
	return task ~= nil and task.core ~= nil and task.core.status == types.STATUS.ARCHIVED
end

---写入前守卫。返回 false 时 err 已经是给人看的一句话。
---@param id string
---@param action string 人类可读动作，如 "change the due date"
---@return boolean ok
---@return string|nil err
function M.check(id, action)
	local task = core.get_task(id)
	if not task then
		return false, "Task does not exist: " .. tostring(id)
	end
	if M.is_frozen(task) then
		return false, ("cannot %s: task is archived (unarchive it first with :TodoUnarchive)"):format(action)
	end
	return true, nil
end

return M
