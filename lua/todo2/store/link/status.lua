-- lua/todo2/store/link/status.lua
-- 纯拆分版本，完全复制原 link.lua 中的代码，没有任何新增功能

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core")

local LINK_TYPE_CONFIG = {
	todo = "todo.links.todo.",
	code = "todo.links.code.",
}

---------------------------------------------------------------------
-- 内部辅助函数（完全复制原代码）
---------------------------------------------------------------------
local function check_link_pair_integrity(todo_link, code_link, operation)
	if not todo_link and not code_link then
		return false, "链接ID不存在"
	end
	if todo_link and code_link then
		if todo_link.active == false or code_link.active == false then
			return false, "链接已被删除，不能修改状态"
		end
	end
	if (todo_link and not code_link) or (not todo_link and code_link) then
		return false, string.format("数据不一致：链接对只有一端存在 (操作: %s)", operation)
	end
	return true, nil
end

---------------------------------------------------------------------
-- 公共 API（完全复制原 link.lua 中的代码）
---------------------------------------------------------------------
function M.mark_completed(id)
	local todo_link = core.get_todo(id, { verify_line = true })
	local code_link = core.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "mark_completed")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		todo_link.previous_status = todo_link.status
		todo_link.status = types.STATUS.COMPLETED
		todo_link.completed_at = os.time()
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.previous_status = code_link.status
		code_link.status = types.STATUS.COMPLETED
		code_link.completed_at = os.time()
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code -- ⭐ 原样返回，没有事件调用
end

function M.reopen_link(id)
	local todo_link = core.get_todo(id, { verify_line = true })
	local code_link = core.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "reopen_link")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		local target_status = todo_link.previous_status or types.STATUS.NORMAL

		if todo_link.status == types.STATUS.ARCHIVED then
			todo_link.archived_at = nil
			todo_link.archived_reason = nil
		end

		todo_link.status = target_status
		todo_link.completed_at = nil
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		local target_status = code_link.previous_status or types.STATUS.NORMAL

		if code_link.status == types.STATUS.ARCHIVED then
			code_link.archived_at = nil
			code_link.archived_reason = nil
		end

		code_link.status = target_status
		code_link.completed_at = nil
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

function M.update_active_status(id, new_status)
	if not types.is_active_status(new_status) then
		vim.notify("update_active_status 只能用于活跃状态: normal, urgent, waiting", vim.log.levels.ERROR)
		return nil
	end

	local todo_link = core.get_todo(id, { verify_line = true })
	local code_link = core.get_code(id, { verify_line = true })

	local ok, err = check_link_pair_integrity(todo_link, code_link, "update_active_status")
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return nil
	end

	local results = {}

	if todo_link then
		todo_link.status = new_status
		todo_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)
		results.todo = todo_link
	end

	if code_link then
		code_link.status = new_status
		code_link.updated_at = os.time()
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)
		results.code = code_link
	end

	return results.todo or results.code
end

function M.is_completed(id)
	local todo_link = core.get_todo(id, { verify_line = false })
	local code_link = core.get_code(id, { verify_line = false })
	if todo_link and code_link then
		return types.is_completed_status(todo_link.status) and types.is_completed_status(code_link.status)
	end
	return false
end

function M.is_archived(id)
	local todo_link = core.get_todo(id, { verify_line = false })
	local code_link = core.get_code(id, { verify_line = false })
	if todo_link and code_link then
		return todo_link.status == types.STATUS.ARCHIVED and code_link.status == types.STATUS.ARCHIVED
	end
	return false
end

---------------------------------------------------------------------
-- ⭐ 新增：统一软删除函数（修复1）
---------------------------------------------------------------------
--- 统一软删除函数
--- @param id string 链接ID
--- @param reason string|nil 删除原因
--- @return boolean
function M.mark_deleted(id, reason)
	local todo_link = core.get_todo(id, { verify_line = false })
	local code_link = core.get_code(id, { verify_line = false })

	local success = false

	if todo_link then
		todo_link.status = "deleted" -- 统一状态
		todo_link.deleted_at = os.time()
		todo_link.deletion_reason = reason
		todo_link.active = false
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)

		-- 更新元数据
		local meta = require("todo2.store.meta")
		meta.soft_delete("todo")
		success = true
	end

	if code_link then
		code_link.status = "deleted"
		code_link.deleted_at = os.time()
		code_link.deletion_reason = reason
		code_link.active = false
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)

		local meta = require("todo2.store.meta")
		meta.soft_delete("code")
		success = true
	end

	return success
end

---------------------------------------------------------------------
-- ⭐ 新增：统一恢复函数（修复1）
---------------------------------------------------------------------
--- 统一恢复函数
--- @param id string 链接ID
--- @return boolean
function M.restore_deleted(id)
	local todo_link = core.get_todo(id, { verify_line = false })
	local code_link = core.get_code(id, { verify_line = false })

	local success = false

	if todo_link and todo_link.status == "deleted" then
		todo_link.status = todo_link.previous_status or "normal"
		todo_link.deleted_at = nil
		todo_link.deletion_reason = nil
		todo_link.active = true
		store.set_key(LINK_TYPE_CONFIG.todo .. id, todo_link)

		local meta = require("todo2.store.meta")
		meta.soft_restore("todo")
		success = true
	end

	if code_link and code_link.status == "deleted" then
		code_link.status = code_link.previous_status or "normal"
		code_link.deleted_at = nil
		code_link.deletion_reason = nil
		code_link.active = true
		store.set_key(LINK_TYPE_CONFIG.code .. id, code_link)

		local meta = require("todo2.store.meta")
		meta.soft_restore("code")
		success = true
	end

	return success
end

-- ⭐ 导出内部函数供其他模块使用（原 link.lua 中也有）
M._check_pair_integrity = check_link_pair_integrity

return M
