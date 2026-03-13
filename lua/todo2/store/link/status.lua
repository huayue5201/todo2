-- lua/todo2/store/link/status.lua
-- 链接状态管理（无软删除版本）

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core")

local PREFIX = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

---------------------------------------------------------------------
-- 内部：检查链接对一致性
---------------------------------------------------------------------
local function check_pair(todo_link, code_link, op)
	if not todo_link and not code_link then
		return false, "链接ID不存在"
	end
	if todo_link and code_link then
		return true
	end
	return false, string.format("数据不一致：链接对只有一端存在 (操作: %s)", op)
end

M._check_pair_integrity = check_pair

---------------------------------------------------------------------
-- 标记完成
---------------------------------------------------------------------
function M.mark_completed(id)
	local todo = core.get_todo(id )
	local code = core.get_code(id )

	local ok, err = check_pair(todo, code, "mark_completed")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local now = os.time()
	local result = {}

	if todo then
		todo.previous_status = todo.status
		todo.status = types.STATUS.COMPLETED
		todo.completed_at = now
		todo.updated_at = now
		store.set_key(PREFIX.todo .. id, todo)
		result.todo = todo
	end

	if code then
		code.previous_status = code.status
		code.status = types.STATUS.COMPLETED
		code.completed_at = now
		code.updated_at = now
		store.set_key(PREFIX.code .. id, code)
		result.code = code
	end

	return result.todo or result.code
end

---------------------------------------------------------------------
-- 重新打开任务（从 completed 或 archived 恢复）
---------------------------------------------------------------------
function M.reopen_link(id)
	local todo = core.get_todo(id )
	local code = core.get_code(id )

	local ok, err = check_pair(todo, code, "reopen_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local now = os.time()
	local result = {}

	if todo then
		local target = todo.previous_status or types.STATUS.NORMAL
		todo.status = target
		todo.completed_at = nil
		todo.archived_at = nil
		todo.archived_reason = nil
		todo.updated_at = now
		store.set_key(PREFIX.todo .. id, todo)
		result.todo = todo
	end

	if code then
		local target = code.previous_status or types.STATUS.NORMAL
		code.status = target
		code.completed_at = nil
		code.archived_at = nil
		code.archived_reason = nil
		code.updated_at = now
		store.set_key(PREFIX.code .. id, code)
		result.code = code
	end

	return result.todo or result.code
end

---------------------------------------------------------------------
-- 更新 active 状态（normal / urgent / waiting）
---------------------------------------------------------------------
function M.update_active_status(id, new_status)
	if not types.is_active_status(new_status) then
		vim.notify("update_active_status 只能用于 normal/urgent/waiting", vim.log.levels.ERROR)
		return nil
	end

	local todo = core.get_todo(id )
	local code = core.get_code(id )

	local ok, err = check_pair(todo, code, "update_active_status")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local now = os.time()
	local result = {}

	if todo then
		todo.status = new_status
		todo.updated_at = now
		store.set_key(PREFIX.todo .. id, todo)
		result.todo = todo
	end

	if code then
		code.status = new_status
		code.updated_at = now
		store.set_key(PREFIX.code .. id, code)
		result.code = code
	end

	return result.todo or result.code
end

---------------------------------------------------------------------
-- 判断是否完成
---------------------------------------------------------------------
function M.is_completed(id)
	local todo = core.get_todo(id )
	local code = core.get_code(id )
	if todo and code then
		return types.is_completed_status(todo.status) and types.is_completed_status(code.status)
	end
	return false
end

---------------------------------------------------------------------
-- 判断是否归档
---------------------------------------------------------------------
function M.is_archived(id)
	local todo = core.get_todo(id )
	local code = core.get_code(id )
	if todo and code then
		return todo.status == types.STATUS.ARCHIVED and code.status == types.STATUS.ARCHIVED
	end
	return false
end

return M
