-- lua/todo2/store/verification.lua
-- 极简版验证系统（单文件版本）
-- 只保留：verify_single_link / verify_file_links

local M = {}

local store = require("todo2.store.nvim_store")
local link = require("todo2.store.link")
local locator = require("todo2.store.locator")
local types = require("todo2.store.types")
local index = require("todo2.store.index")
local id_utils = require("todo2.utils.id")

---------------------------------------------------------------------
-- 单个链接验证（同步）
---------------------------------------------------------------------
function M.verify_single_link(link_obj)
	if not link_obj or not link_obj.path then
		return nil
	end

	-- 归档任务不需要验证位置
	if types.is_archived_status(link_obj.status) then
		link_obj.line_verified = true
		link_obj.last_verified_at = os.time()
		return link_obj
	end

	-- 调用定位器
	local verified = locator.locate_task_sync(link_obj)

	if verified and verified.line_verified then
		verified.last_verified_at = os.time()
	end

	return verified
end

---------------------------------------------------------------------
-- 单个链接验证（异步）
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
		link_obj.line_verified = true
		link_obj.last_verified_at = os.time()
		if callback then
			callback(link_obj)
		end
		return
	end

	locator.locate_task(link_obj, function(verified)
		if verified and verified.line_verified then
			verified.last_verified_at = os.time()
		end
		if callback then
			callback(verified)
		end
	end)
end

---------------------------------------------------------------------
-- 验证某个文件中的所有链接
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
				store.set_key("todo.links.todo." .. todo_link.id, verified)
				done_one(true)
			else
				done_one(false)
			end
		end)
	end

	for _, code_link in ipairs(code_links) do
		M.verify_single_link_async(code_link, function(verified)
			if verified and verified.line_verified then
				store.set_key("todo.links.code." .. code_link.id, verified)
				done_one(true)
			else
				done_one(false)
			end
		end)
	end
end

return M
