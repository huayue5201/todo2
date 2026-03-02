-- lua/todo2/store/trash.lua
-- 软删除和回收站管理（修复版 - 统一使用软删除函数）
local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local index = require("todo2.store.index")
local verification = require("todo2.store.verification")

---------------------------------------------------------------------
-- 配置
---------------------------------------------------------------------
local CONFIG = {
	RETENTION_DAYS = 30,
	AUTO_CLEANUP = true,
}

---------------------------------------------------------------------
-- 内部辅助函数
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

--- ⭐ 修复3：获取软删除的链接（统一判定标准）
--- @param days number|nil 天数
--- @return table { todo = {}, code = {}, pairs = {} }
local function get_trash(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = { todo = {}, code = {}, pairs = {} }

	local all_todo = link.get_all_todo()
	for id, todo_link in pairs(all_todo) do
		-- 统一软删除判定：deleted_at 存在且 > 0
		if todo_link.deleted_at and todo_link.deleted_at > 0 then
			if cutoff_time == 0 or todo_link.deleted_at >= cutoff_time then
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
		if code_link.deleted_at and code_link.deleted_at > 0 then
			if cutoff_time == 0 or code_link.deleted_at >= cutoff_time then
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

--- ⭐ 修复4：永久删除单个链接（统一处理）
--- @param id string 链接ID
--- @param link_type string "todo" | "code"
--- @return boolean
local function permanent_delete(id, link_type)
	local key = (link_type == "todo") and "todo.links.todo." .. id or "todo.links.code." .. id
	local link_obj = store.get_key(key)

	if not link_obj then
		return false
	end

	-- 只有软删除的链接才能永久删除
	if not link_obj.deleted_at or link_obj.deleted_at <= 0 then
		return false
	end

	-- 从文件索引中移除
	local index_ns = (link_type == "todo") and "todo.index.file_to_todo" or "todo.index.file_to_code"
	if link_obj.path then
		index._remove_id_from_file_index(index_ns, link_obj.path, id)
	end

	-- 从存储中删除
	store.delete_key(key)
	log_permanent_deletion(id, link_type)

	-- 更新元数据计数
	local meta = require("todo2.store.meta")
	meta.decrement_links(link_type, false) -- 软删除的链接不活跃

	return true
end

---------------------------------------------------------------------
-- 公共 API
---------------------------------------------------------------------

--- ⭐ 修复5：清空回收站（统一使用 verification 标记，但永久删除使用本模块）
--- @param days number|nil
--- @return table
function M.empty_trash(days)
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

	-- 先删除成对出现的（两端都删除）
	for id, _ in pairs(trash.pairs) do
		local deleted_todo = permanent_delete(id, "todo")
		local deleted_code = permanent_delete(id, "code")
		if deleted_todo or deleted_code then
			report.deleted_pairs = report.deleted_pairs + 1
		end
	end

	-- 删除孤立的TODO端
	for id, _ in pairs(trash.todo) do
		if not trash.pairs[id] and permanent_delete(id, "todo") then
			report.deleted_todo = report.deleted_todo + 1
		end
	end

	-- 删除孤立的代码端
	for id, _ in pairs(trash.code) do
		if not trash.pairs[id] and permanent_delete(id, "code") then
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

--- ⭐ 修复6：恢复已删除的链接（统一使用 verification 模块）
--- @param link_id string 链接ID
--- @param link_type string "todo" | "code"
--- @return boolean
function M.restore_link(link_id, link_type)
	return verification.restore_link_deleted(link_id, link_type)
end

--- ⭐ 修复7：批量恢复链接
--- @param ids string[] 链接ID列表
--- @return table
function M.restore_links(ids)
	local report = { success = 0, failed = 0 }
	for _, id in ipairs(ids) do
		if verification.restore_link_deleted(id, "todo") or verification.restore_link_deleted(id, "code") then
			report.success = report.success + 1
		else
			report.failed = report.failed + 1
		end
	end
	return report
end

--- 自动清理过期的软删除链接
--- @return table
function M.auto_cleanup()
	return M.empty_trash(CONFIG.RETENTION_DAYS)
end

--- 获取回收站统计信息
--- @return table
function M.get_stats()
	local trash = get_trash()
	return {
		todo_count = vim.tbl_count(trash.todo),
		code_count = vim.tbl_count(trash.code),
		pair_count = vim.tbl_count(trash.pairs),
		total = vim.tbl_count(trash.todo) + vim.tbl_count(trash.code),
	}
end

return M
