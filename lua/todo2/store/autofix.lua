-- lua/todo2/store/autofix.lua
-- 极简修复系统：只做三件事 + 白名单保护
-- 1) 行号修复（基于 locator）
-- 2) 悬挂数据删除（TODO 和 CODE 都不存在）
-- 3) TODO 删除 → 删除 CODE + 存储
-- 不扫描 CODE 文件，不创建 ID，不修改内容

local M = {}

local link = require("todo2.store.link")
local index = require("todo2.store.index")
local locator = require("todo2.store.locator")
local archive = require("todo2.store.link.archive")
local config = require("todo2.config")

---------------------------------------------------------------------
-- 白名单（如归档任务、特殊任务）
---------------------------------------------------------------------
local WHITELIST = {}

function M.add_whitelist(id)
	WHITELIST[id] = true
end

function M.remove_whitelist(id)
	WHITELIST[id] = nil
end

local function is_whitelisted(id)
	return WHITELIST[id] == true
end

---------------------------------------------------------------------
-- 1) 行号修复：使用 locator 精准定位
---------------------------------------------------------------------
local function fix_line_number(id, link_obj)
	if not link_obj or is_whitelisted(id) then
		return false
	end

	local located = locator.locate_task_sync(link_obj)
	if not located or not located.line then
		return false
	end

	if located.line ~= link_obj.line then
		link_obj.line = located.line
		link_obj.line_verified = true
		link_obj.updated_at = os.time()

		if link_obj.type == "todo" then
			link.update_todo(id, link_obj)
		else
			link.update_code(id, link_obj)
		end

		return true
	end

	return false
end

---------------------------------------------------------------------
-- 2) 悬挂删除：TODO 和 CODE 都不存在 → 删除存储
---------------------------------------------------------------------
local function delete_dangling(id)
	if is_whitelisted(id) then
		return false
	end

	local todo = link.get_todo(id)
	local code = link.get_code(id)

	if todo or code then
		return false
	end

	-- 删除 archive snapshot
	local snapshot = archive.get_archive_snapshot(id)
	if snapshot then
		archive.delete_archive_snapshot(id)
	end

	-- 删除 link pair（todo + code）
	link.delete_link_pair(id)

	-- 删除 index
	index.remove_from_all_indices(id)

	return true
end

---------------------------------------------------------------------
-- 3) TODO 删除 → 删除 CODE + 存储
---------------------------------------------------------------------
local function delete_if_todo_missing(id)
	if is_whitelisted(id) then
		return false
	end

	local todo = link.get_todo(id)
	local code = link.get_code(id)

	-- TODO 不存在，但 CODE 还在 → 删除 CODE + 存储
	if not todo and code then
		local snapshot = archive.get_archive_snapshot(id)
		if snapshot then
			archive.delete_archive_snapshot(id)
		end

		link.delete_link_pair(id)
		index.remove_from_all_indices(id)
		return true
	end

	return false
end

---------------------------------------------------------------------
-- 主修复入口：对所有 ID 执行三类修复
---------------------------------------------------------------------
function M.run_full_repair()
	local all_ids = index.get_all_ids()
	local report = {
		line_fixed = 0,
		dangling_deleted = 0,
		todo_deleted_cleanup = 0,
	}

	for _, id in ipairs(all_ids) do
		if not is_whitelisted(id) then
			-- 行号修复
			local todo = link.get_todo(id)
			local code = link.get_code(id)

			if todo and fix_line_number(id, todo) then
				report.line_fixed = report.line_fixed + 1
			end

			if code and fix_line_number(id, code) then
				report.line_fixed = report.line_fixed + 1
			end

			-- 悬挂删除
			if delete_dangling(id) then
				report.dangling_deleted = report.dangling_deleted + 1
			end

			-- TODO 删除 → 删除 CODE
			if delete_if_todo_missing(id) then
				report.todo_deleted_cleanup = report.todo_deleted_cleanup + 1
			end
		end
	end

	return report
end

---------------------------------------------------------------------
-- 定期修复（例如每 10 分钟）
---------------------------------------------------------------------
function M.setup_periodic_repair()
	local timer = vim.loop.new_timer()
	timer:start(0, 10 * 60 * 1000, function()
		vim.schedule(function()
			M.run_full_repair()
		end)
	end)
end

return M
