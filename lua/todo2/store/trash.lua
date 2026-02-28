-- lua/todo2/store/trash.lua
-- 软删除和回收站管理（最终版 - 适配统一软删除规则）
local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local index = require("todo2.store.index")
local verification = require("todo2.store.verification") -- 引入统一验证模块

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	RETENTION_DAYS = 30,
	AUTO_CLEANUP = true,
}

---------------------------------------------------------------------
-- 内部辅助函数（全部 local）
---------------------------------------------------------------------
local function log_permanent_deletion(id, link_type)
	local log_key = "todo.log.trash.permanent_deletions"
	local log = store.get_key(log_key) or {}
	table.insert(log, {
		id = id,
		type = link_type,
		timestamp = os.time(),
	})
	if #log > 100 then
		table.remove(log, 1)
	end
	store.set_key(log_key, log)
end

---------------------------------------------------------------------
-- 公共 API（仅保留被调用的函数 + 适配统一软删除）
---------------------------------------------------------------------
--- 清空回收站（永久删除所有软删除的链接）
--- @param days number|nil
--- @return table
function M.empty_trash(days)
	local function get_trash(days)
		local cutoff_time = days and (os.time() - days * 86400) or 0
		local result = { todo = {}, code = {}, pairs = {} }

		local all_todo = link.get_all_todo()
		for id, todo_link in pairs(all_todo) do
			-- 统一软删除判定：优先基于deleted_at
			if todo_link.deleted_at and todo_link.deleted_at > 0 then
				if cutoff_time == 0 or todo_link.deleted_at >= cutoff_time then
					-- 校准active字段（兼容旧数据）
					if todo_link.active ~= false then
						todo_link.active = false
						store.set_key("todo.links.todo." .. id, todo_link)
					end
					result.todo[id] = todo_link
					local code_link = link.get_code(id)
					if code_link and code_link.deleted_at and code_link.deleted_at > 0 then
						result.pairs[id] = {
							todo = todo_link,
							code = code_link,
							deleted_at = todo_link.deleted_at or code_link.deleted_at,
						}
					end
				end
			end
		end

		local all_code = link.get_all_code()
		for id, code_link in pairs(all_code) do
			-- 统一软删除判定：优先基于deleted_at
			if code_link.deleted_at and code_link.deleted_at > 0 then
				if cutoff_time == 0 or code_link.deleted_at >= cutoff_time then
					-- 校准active字段（兼容旧数据）
					if code_link.active ~= false then
						code_link.active = false
						store.set_key("todo.links.code." .. id, code_link)
					end
					result.code[id] = code_link
					if not result.pairs[id] then
						local todo_link = link.get_todo(id)
						if todo_link and todo_link.deleted_at and todo_link.deleted_at > 0 then
							result.pairs[id] = {
								todo = todo_link,
								code = code_link,
								deleted_at = code_link.deleted_at or todo_link.deleted_at,
							}
						end
					end
				end
			end
		end
		return result
	end

	local function permanent_delete(id)
		local deleted = false
		local todo_key = "todo.links.todo." .. id
		local todo_link = store.get_key(todo_key)
		if todo_link and todo_link.deleted_at and todo_link.deleted_at > 0 then
			store.delete_key(todo_key)
			index._remove_id_from_file_index("todo.index.file_to_todo", todo_link.path, id)
			deleted = true
			log_permanent_deletion(id, "todo")
		end

		local code_key = "todo.links.code." .. id
		local code_link = store.get_key(code_key)
		if code_link and code_link.deleted_at and code_link.deleted_at > 0 then
			store.delete_key(code_key)
			index._remove_id_from_file_index("todo.index.file_to_code", code_link.path, id)
			deleted = true
			log_permanent_deletion(id, "code")
		end
		return deleted
	end

	local trash = get_trash(days)
	local report = {
		total_todo = 0,
		total_code = 0,
		total_pairs = 0,
		deleted_todo = 0,
		deleted_code = 0,
		deleted_pairs = 0,
	}

	for id, _ in pairs(trash.todo) do
		report.total_todo = report.total_todo + 1
	end
	for id, _ in pairs(trash.code) do
		report.total_code = report.total_code + 1
	end
	for id, _ in pairs(trash.pairs) do
		report.total_pairs = report.total_pairs + 1
	end

	for id, _ in pairs(trash.pairs) do
		if permanent_delete(id) then
			report.deleted_pairs = report.deleted_pairs + 1
		end
	end
	for id, _ in pairs(trash.todo) do
		if not trash.pairs[id] and permanent_delete(id) then
			report.deleted_todo = report.deleted_todo + 1
		end
	end
	for id, _ in pairs(trash.code) do
		if not trash.pairs[id] and permanent_delete(id) then
			report.deleted_code = report.deleted_code + 1
		end
	end

	-- 清理后刷新元数据
	verification.refresh_metadata_stats()

	report.summary = string.format(
		"回收站清理完成: 删除了 %d 对链接, %d 个孤立TODO, %d 个孤立代码链接",
		report.deleted_pairs,
		report.deleted_todo,
		report.deleted_code
	)
	return report
end

--- 恢复已删除的链接（统一调用verification模块）
--- @param link_id string 链接ID
--- @param link_type string "todo" | "code"
--- @return boolean
function M.restore_link(link_id, link_type)
	return verification.restore_link_deleted(link_id, link_type)
end

--- 自动清理过期的软删除链接
--- @return table
function M.auto_cleanup()
	return M.empty_trash(CONFIG.RETENTION_DAYS)
end

return M
