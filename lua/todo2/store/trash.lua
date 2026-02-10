-- lua/todo2/store/trash.lua
--- @module todo2.store.trash
--- 软删除和回收站管理

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local types = require("todo2.store.types")
local meta = require("todo2.store.meta")
local utils = require("todo2.store.utils")
local index = require("todo2.store.index")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	RETENTION_DAYS = 30, -- 软删除保留天数
	AUTO_CLEANUP = true, -- 是否自动清理过期软删除
}

---------------------------------------------------------------------
-- 内部辅助函数
---------------------------------------------------------------------
local function mark_as_deleted(link_obj)
	if not link_obj then
		return nil
	end

	link_obj.active = false
	link_obj.deleted_at = link_obj.deleted_at or os.time()
	link_obj.updated_at = os.time()

	return link_obj
end

local function mark_as_active(link_obj)
	if not link_obj then
		return nil
	end

	link_obj.active = true
	link_obj.deleted_at = nil
	link_obj.restored_at = os.time()
	link_obj.updated_at = os.time()

	return link_obj
end

---------------------------------------------------------------------
-- 公共API
---------------------------------------------------------------------
--- 软删除TODO链接
--- @param id string 链接ID
--- @param reason string|nil 删除原因
--- @return boolean 是否成功
function M.soft_delete_todo(id, reason)
	local todo_key = "todo.links.todo." .. id
	local link_obj = store.get_key(todo_key)

	if not link_obj then
		vim.notify("找不到TODO链接: " .. id, vim.log.levels.WARN)
		return false
	end

	-- 从文件索引中移除
	index._remove_id_from_file_index("todo.index.file_to_todo", link_obj.path, id)

	-- 标记为删除
	link_obj = mark_as_deleted(link_obj)
	link_obj.deletion_reason = reason

	-- 保存
	store.set_key(todo_key, link_obj)

	-- 记录到删除日志
	M._log_deletion(id, "todo", reason)

	vim.notify("已软删除TODO链接: " .. id, vim.log.levels.INFO)
	return true
end

--- 软删除代码链接
--- @param id string 链接ID
--- @param reason string|nil 删除原因
--- @return boolean 是否成功
function M.soft_delete_code(id, reason)
	local code_key = "todo.links.code." .. id
	local link_obj = store.get_key(code_key)

	if not link_obj then
		vim.notify("找不到代码链接: " .. id, vim.log.levels.WARN)
		return false
	end

	-- 从文件索引中移除
	index._remove_id_from_file_index("todo.index.file_to_code", link_obj.path, id)

	-- 标记为删除
	link_obj = mark_as_deleted(link_obj)
	link_obj.deletion_reason = reason

	-- 保存
	store.set_key(code_key, link_obj)

	-- 记录到删除日志
	M._log_deletion(id, "code", reason)

	vim.notify("已软删除代码链接: " .. id, vim.log.levels.INFO)
	return true
end

--- 软删除链接对（TODO和代码）
--- @param id string 链接ID
--- @param reason string|nil 删除原因
--- @return boolean 是否成功
function M.soft_delete_pair(id, reason)
	local todo_success = M.soft_delete_todo(id, reason)
	local code_success = M.soft_delete_code(id, reason)

	return todo_success or code_success
end

--- 恢复软删除的链接（两端同时恢复）
--- @param id string 链接ID
--- @return boolean 是否成功
function M.restore(id)
	local restored = false

	-- 恢复TODO链接
	local todo_key = "todo.links.todo." .. id
	local todo_link = store.get_key(todo_key)

	if todo_link and not todo_link.active then
		todo_link = mark_as_active(todo_link)
		store.set_key(todo_key, todo_link)
		restored = true

		-- 重新添加到文件索引
		index._add_id_to_file_index("todo.index.file_to_todo", todo_link.path, id)

		-- 记录恢复日志
		M._log_restoration(id, "todo")
	end

	-- 恢复代码链接
	local code_key = "todo.links.code." .. id
	local code_link = store.get_key(code_key)

	if code_link and not code_link.active then
		code_link = mark_as_active(code_link)
		store.set_key(code_key, code_link)
		restored = true

		-- 重新添加到文件索引
		index._add_id_to_file_index("todo.index.file_to_code", code_link.path, id)

		-- 记录恢复日志
		M._log_restoration(id, "code")
	end

	if restored then
		vim.notify("已恢复链接: " .. id, vim.log.levels.INFO)
	end

	return restored
end

--- 永久删除链接（从回收站移除，两端同时删除）
--- @param id string 链接ID
--- @return boolean 是否成功
function M.permanent_delete(id)
	local deleted = false

	-- 删除TODO链接
	local todo_key = "todo.links.todo." .. id
	local todo_link = store.get_key(todo_key)

	if todo_link and not todo_link.active then
		store.delete_key(todo_key)

		-- 从文件索引中移除
		index._remove_id_from_file_index("todo.index.file_to_todo", todo_link.path, id)

		deleted = true
		M._log_permanent_deletion(id, "todo")
	end

	-- 删除代码链接
	local code_key = "todo.links.code." .. id
	local code_link = store.get_key(code_key)

	if code_link and not code_link.active then
		store.delete_key(code_key)

		-- 从文件索引中移除
		index._remove_id_from_file_index("todo.index.file_to_code", code_link.path, id)

		deleted = true
		M._log_permanent_deletion(id, "code")
	end

	if deleted then
		vim.notify("已永久删除链接: " .. id, vim.log.levels.WARN)
	end

	return deleted
end

--- 获取回收站中的链接
--- @param days number|nil 多少天内的删除，nil表示所有
--- @return table 回收站链接
function M.get_trash(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {
		todo = {},
		code = {},
		pairs = {},
	}

	-- 获取所有TODO链接
	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		if not todo_link.active then
			if cutoff_time == 0 or (todo_link.deleted_at and todo_link.deleted_at >= cutoff_time) then
				result.todo[id] = todo_link

				-- 检查是否有对应的代码链接
				local code_link = link.get_code(id)
				if code_link and not code_link.active then
					result.pairs[id] = {
						todo = todo_link,
						code = code_link,
						deleted_at = todo_link.deleted_at or code_link.deleted_at,
					}
				end
			end
		end
	end

	-- 获取所有代码链接
	local all_code = link.get_all_code()
	for id, code_link in pairs(all_code) do
		if not code_link.active then
			if cutoff_time == 0 or (code_link.deleted_at and code_link.deleted_at >= cutoff_time) then
				result.code[id] = code_link

				-- 如果pair中还没有这个ID，单独添加
				if not result.pairs[id] then
					local todo_link = link.get_todo(id)
					if todo_link and not todo_link.active then
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

--- 清空回收站（永久删除所有软删除的链接）
--- @param days number|nil 删除多少天前的，nil表示全部
--- @return table 清理报告
function M.empty_trash(days)
	local trash = M.get_trash(days)
	local report = {
		total_todo = 0,
		total_code = 0,
		total_pairs = 0,
		deleted_todo = 0,
		deleted_code = 0,
		deleted_pairs = 0,
	}

	-- 先统计
	for id, _ in pairs(trash.todo) do
		report.total_todo = report.total_todo + 1
	end

	for id, _ in pairs(trash.code) do
		report.total_code = report.total_code + 1
	end

	for id, _ in pairs(trash.pairs) do
		report.total_pairs = report.total_pairs + 1
	end

	-- 执行删除
	for id, _ in pairs(trash.pairs) do
		local success = M.permanent_delete(id)
		if success then
			report.deleted_pairs = report.deleted_pairs + 1
		end
	end

	-- 单独删除孤立的链接
	for id, _ in pairs(trash.todo) do
		if not trash.pairs[id] then
			local success = M.permanent_delete(id)
			if success then
				report.deleted_todo = report.deleted_todo + 1
			end
		end
	end

	for id, _ in pairs(trash.code) do
		if not trash.pairs[id] then
			local success = M.permanent_delete(id)
			if success then
				report.deleted_code = report.deleted_code + 1
			end
		end
	end

	report.summary = string.format(
		"回收站清理完成: 删除了 %d 对链接, %d 个孤立TODO, %d 个孤立代码链接",
		report.deleted_pairs,
		report.deleted_todo,
		report.deleted_code
	)

	return report
end

--- 自动清理过期的软删除链接
--- @return table 清理报告
function M.auto_cleanup()
	local cutoff_time = os.time() - CONFIG.RETENTION_DAYS * 86400
	return M.empty_trash(CONFIG.RETENTION_DAYS)
end

-- 修改 _log_deletion 函数中的时间格式化
function M._log_deletion(id, link_type, reason)
	local log_key = "todo.log.trash.deletions"
	local log = store.get_key(log_key) or {}

	table.insert(log, {
		id = id,
		type = link_type,
		reason = reason,
		timestamp = os.time(),
		formatted_time = utils.format_time(os.time()), -- 使用 utils 格式化时间
	})

	-- 只保留最近100条记录
	if #log > 100 then
		table.remove(log, 1)
	end

	store.set_key(log_key, log)
end

function M._log_restoration(id, link_type)
	local log_key = "todo.log.trash.restorations"
	local log = store.get_key(log_key) or {}

	table.insert(log, {
		id = id,
		type = link_type,
		timestamp = os.time(),
	})

	-- 只保留最近100条记录
	if #log > 100 then
		table.remove(log, 1)
	end

	store.set_key(log_key, log)
end

function M._log_permanent_deletion(id, link_type)
	local log_key = "todo.log.trash.permanent_deletions"
	local log = store.get_key(log_key) or {}

	table.insert(log, {
		id = id,
		type = link_type,
		timestamp = os.time(),
	})

	-- 只保留最近100条记录
	if #log > 100 then
		table.remove(log, 1)
	end

	store.set_key(log_key, log)
end

return M
