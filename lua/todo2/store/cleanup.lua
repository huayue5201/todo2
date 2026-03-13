-- lua/todo2/store/cleanup.lua
-- 重写版：统一 scheduler + id_utils + link 中心
-- 保留所有旧接口，内部逻辑完全统一

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

	-- 1. 优先检查行号
	if link_obj.line and link_obj.line >= 1 and link_obj.line <= #lines then
		if line_contains_id(lines[link_obj.line], link_obj.id) then
			return true
		end
	end

	-- 2. 全局扫描
	for _, line in ipairs(lines) do
		if line_contains_id(line, link_obj.id) then
			return true
		end
	end

	return false
end

---------------------------------------------------------------------
-- 判断是否为悬挂链接（TODO 和 CODE 都不在文件中）
---------------------------------------------------------------------
local function is_dangling_pair(id, todo_obj, code_obj)
	-- 两端都不存在 → 已经被删除
	if not todo_obj and not code_obj then
		return false, "两端都不存在"
	end

	-- 检查 TODO 端
	local todo_exists = false
	if todo_obj then
		todo_exists = link_exists_in_file(todo_obj)
	end

	-- 检查 CODE 端
	local code_exists = false
	if code_obj then
		code_exists = link_exists_in_file(code_obj)
	end

	-- 两端都不存在于文件中 → 悬挂
	if not todo_exists and not code_exists then
		return true, "两端都不在文件中"
	end

	-- 一端不存在，另一端存在 → 不算悬挂（用户手动删除）
	return false, "至少一端仍在文件中"
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

	-- 收集所有 ID
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
				-- 删除快照
				local snapshot = archive_link.get_archive_snapshot(id)
				if snapshot then
					archive_link.delete_archive_snapshot(id)
				end

				-- 删除链接对（统一走 link 中心）
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
			-- 删除快照
			local snapshot = archive_link.get_archive_snapshot(id)
			if snapshot then
				archive_link.delete_archive_snapshot(id)
			end

			-- 删除链接对
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
-- ⭐ 新增：检查指定ID列表的悬挂状态（统一 scheduler + link 中心）
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
				link.delete_link_pair(id)
			end

			report.cleaned = report.cleaned + 1
		end
	end

	return report
end

return M
