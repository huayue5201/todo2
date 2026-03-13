-- lua/todo2/store/cleanup.lua
-- 重写版：统一 scheduler + id_utils + link 中心
-- TODO 为权威来源：TODO 删除后，整对链接应被清理

local M = {}

local link = require("todo2.store.link")
local index = require("todo2.store.index")
local id_utils = require("todo2.utils.id")
local archive_link = require("todo2.store.link.archive")
local scheduler = require("todo2.render.scheduler")

---------------------------------------------------------------------
-- 工具：统一读取文件行（scheduler 是唯一真相源）
---------------------------------------------------------------------
local function read_lines(filepath)
	if not filepath or filepath == "" then
		return {}
	end
	return scheduler.get_file_lines(filepath, false) or {}
end

---------------------------------------------------------------------
-- 工具：统一判断某行是否包含 ID
---------------------------------------------------------------------
local function line_contains_id(line, id)
	if not line or not id then
		return false
	end
	if id_utils.contains_todo_anchor(line) and id_utils.extract_id_from_todo_anchor(line) == id then
		return true
	end
	if id_utils.contains_code_mark(line) and id_utils.extract_id_from_code_mark(line) == id then
		return true
	end
	return false
end

---------------------------------------------------------------------
-- 判断链接是否仍存在于文件中（统一 scheduler + id_utils）
---------------------------------------------------------------------
local function link_exists_in_file(link_obj)
	if not link_obj or not link_obj.path or not link_obj.id then
		return false
	end

	local lines = read_lines(link_obj.path)
	if #lines == 0 then
		return false
	end

	if link_obj.line and link_obj.line >= 1 and link_obj.line <= #lines then
		if line_contains_id(lines[link_obj.line], link_obj.id) then
			return true
		end
	end

	for _, line in ipairs(lines) do
		if line_contains_id(line, link_obj.id) then
			return true
		end
	end

	return false
end

---------------------------------------------------------------------
-- 判断是否为悬挂链接（TODO 为权威来源）
-- 规则：
-- 1. 如果 TODO 不存在或不在文件中 → 整对链接视为悬挂
-- 2. 否则，如果 CODE 存在但不在文件中 → 视为悬挂
-- 3. 否则不算悬挂
---------------------------------------------------------------------
local function is_dangling_pair(id, todo_obj, code_obj)
	-- ⭐ 情况 1：TODO link 本身不存在 → 必须删除整个 link pair
	if not todo_obj then
		return true, "TODO 链接不存在"
	end

	-- ⭐ 情况 2：TODO link 存在，但文件中找不到 → 必须删除整个 link pair
	local todo_exists = link_exists_in_file(todo_obj)
	if not todo_exists then
		return true, "TODO 不在文件中"
	end

	-- ⭐ 情况 3：TODO 存在，但 CODE link 存在且文件中找不到 → 删除整个 link pair
	if code_obj then
		local code_exists = link_exists_in_file(code_obj)
		if not code_exists then
			return true, "CODE 不在文件中"
		end
	end

	-- ⭐ 情况 4：TODO 存在且 CODE 存在 → 不删除
	return false, "TODO 仍在文件中"
end

---------------------------------------------------------------------
-- 清理悬挂链接（彻底删除，统一走 link.delete_link_pair）
---------------------------------------------------------------------
function M.cleanup_dangling_links(opts)
	opts = opts or {}
	local dry_run = opts.dry_run or false
	local verbose = opts.verbose or false

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local ids = {}
	for id, _ in pairs(all_todo) do
		table.insert(ids, id)
	end
	for id, _ in pairs(all_code) do
		if not all_todo[id] then
			table.insert(ids, id)
		end
	end

	local report = {
		checked = #ids,
		cleaned = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local todo_obj = all_todo[id]
		local code_obj = all_code[id]

		local is_dangling, reason = is_dangling_pair(id, todo_obj, code_obj)

		if is_dangling then
			if verbose then
				vim.notify(string.format("清理悬挂链接 %s: %s", id, reason), vim.log.levels.DEBUG)
			end

			table.insert(report.details, {
				id = id,
				action = "delete",
				reason = reason,
			})

			if not dry_run then
				local snapshot = archive_link.get_archive_snapshot(id)
				if snapshot then
					archive_link.delete_archive_snapshot(id)
				end
				link.delete_link_pair(id)
			end

			report.cleaned = report.cleaned + 1
		end
	end

	return report
end

---------------------------------------------------------------------
-- 清理过期归档（30 天前）
---------------------------------------------------------------------
function M.cleanup_expired_archives()
	local cutoff = os.time() - 30 * 86400
	local archived = link.get_archived_links()
	local cleaned = 0

	for id, data in pairs(archived) do
		local archive_time = nil
		if data.todo and data.todo.archived_at then
			archive_time = data.todo.archived_at
		elseif data.code and data.code.archived_at then
			archive_time = data.code.archived_at
		end

		if archive_time and archive_time < cutoff then
			local snapshot = archive_link.get_archive_snapshot(id)
			if snapshot then
				archive_link.delete_archive_snapshot(id)
			end
			link.delete_link_pair(id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

---------------------------------------------------------------------
-- 综合清理（悬挂 + 过期归档）
---------------------------------------------------------------------
function M.cleanup_all(opts)
	local dangling = M.cleanup_dangling_links(opts)
	local expired = M.cleanup_expired_archives()

	return {
		dangling_cleaned = dangling.cleaned,
		expired_archives = expired,
		summary = string.format("清理完成：%d 个悬挂链接，%d 个过期归档", dangling.cleaned, expired),
	}
end

---------------------------------------------------------------------
-- 检查指定ID列表的悬挂状态（统一 scheduler + link 中心）
---------------------------------------------------------------------
function M.check_dangling_by_ids(ids, opts)
	opts = opts or {}
	local dry_run = opts.dry_run or false
	local verbose = opts.verbose or false

	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local report = {
		checked = #ids,
		cleaned = 0,
		details = {},
	}

	for _, id in ipairs(ids) do
		local todo_obj = all_todo[id]
		local code_obj = all_code[id]

		local is_dangling, reason = is_dangling_pair(id, todo_obj, code_obj)

		if is_dangling then
			if verbose then
				vim.notify(string.format("清理悬挂链接 %s: %s", id, reason), vim.log.levels.DEBUG)
			end

			table.insert(report.details, {
				id = id,
				action = "delete",
				reason = reason,
			})

			if not dry_run then
				local snapshot = archive_link.get_archive_snapshot(id)
				if snapshot then
					archive_link.delete_archive_snapshot(id)
				end
				link.delete_link_pair(id)
			end

			report.cleaned = report.cleaned + 1
		end
	end

	return report
end

return M
