-- lua/todo2/store/verification.lua
-- 极简验证层：统一走 locator + link 中心，不重复读文件/判断 ID/更新存储

local M = {}

local locator = require("todo2.store.locator")
local types = require("todo2.store.types")
local index = require("todo2.store.index")

---------------------------------------------------------------------
-- 单个链接验证（同步）
-- 旧接口：verify_single_link(link_obj)
-- 新逻辑：直接调用 locator.locate_task_sync（不写回存储）
---------------------------------------------------------------------
function M.verify_single_link(link_obj)
	if not link_obj or not link_obj.path then
		return nil
	end

	-- 归档任务不需要验证位置
	if types.is_archived_status(link_obj.status) then
		local updated = vim.deepcopy(link_obj)
		updated.line_verified = true
		updated.last_verified_at = os.time()
		return updated
	end

	local verified = locator.locate_task_sync(link_obj)
	if verified then
		verified.last_verified_at = os.time()
	end
	return verified
end

---------------------------------------------------------------------
-- 单个链接验证（异步）
-- 旧接口：verify_single_link_async(link_obj, callback)
-- 新逻辑：调用 locator.locate_task（内部已写回 link 中心）
---------------------------------------------------------------------
function M.verify_single_link_async(link_obj, callback)
	if not link_obj then
		if callback then
			callback(nil)
		end
		return
	end

	-- 归档任务不需要验证位置
	if types.is_archived_status(link_obj.status) then
		local updated = vim.deepcopy(link_obj)
		updated.line_verified = true
		updated.last_verified_at = os.time()
		if callback then
			callback(updated)
		end
		return
	end

	locator.locate_task(link_obj, function(verified)
		if verified then
			verified.last_verified_at = os.time()
		end
		if callback then
			callback(verified)
		end
	end)
end

---------------------------------------------------------------------
-- 验证某个文件中的所有链接
-- 旧接口：verify_file_links(filepath, callback)
-- 新逻辑：遍历所有链接 → 调用 verify_single_link_async
-- 注意：定位写回由 locator 完成，这里不再重复 update_*。
---------------------------------------------------------------------
function M.verify_file_links(filepath, callback)
	local todo_links = index.find_todo_links_by_file(filepath)
	local code_links = index.find_code_links_by_file(filepath)

	local total = #todo_links + #code_links
	local processed = 0

	if total == 0 then
		if callback then
			callback({ total = 0, verified = 0, failed = 0 })
		end
		return
	end

	local result = { total = total, verified = 0, failed = 0 }

	local function done_one(ok)
		if ok then
			result.verified = result.verified + 1
		else
			result.failed = result.failed + 1
		end
		processed = processed + 1
		if processed >= total and callback then
			callback(result)
		end
	end

	for _, todo_link in ipairs(todo_links) do
		M.verify_single_link_async(todo_link, function(verified)
			if verified and verified.line_verified then
				done_one(true)
			else
				done_one(false)
			end
		end)
	end

	for _, code_link in ipairs(code_links) do
		M.verify_single_link_async(code_link, function(verified)
			if verified and verified.line_verified then
				done_one(true)
			else
				done_one(false)
			end
		end)
	end
end

---------------------------------------------------------------------
-- 兼容接口：update_expired_context（旧版本使用）
-- 新逻辑：保持接口，但只更新 context_updated_at，避免报错
---------------------------------------------------------------------
function M.update_expired_context(link_obj, days)
	if not link_obj or not link_obj.context then
		return false
	end

	local now = os.time()
	local threshold = (days or 7) * 86400

	if not link_obj.context_updated_at or (now - link_obj.context_updated_at) > threshold then
		link_obj.context_updated_at = now
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 兼容接口：refresh_metadata_stats（旧版本使用）
-- 新逻辑：空实现，避免报错
---------------------------------------------------------------------
function M.refresh_metadata_stats()
	return true
end

return M
