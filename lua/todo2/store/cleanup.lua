-- lua/todo2/store/cleanup.lua
--- @module todo2.store.cleanup

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local link = require("todo2.store.link")
local index = require("todo2.store.index")
local types = require("todo2.store.types")

----------------------------------------------------------------------
-- 通用清理函数（新增：抽象重复逻辑）
----------------------------------------------------------------------

-- 通用清理过期链接
local function _cleanup_expired_links(link_type, days)
	local now = os.time()
	local threshold = now - days * 86400
	local cleaned = 0
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local delete_fun = link_type == "todo" and link.delete_todo or link.delete_code

	for id, link_obj in pairs(get_all_fun()) do
		if (link_obj.created_at or 0) < threshold then
			delete_fun(id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

-- 通用清理已完成链接
local function _cleanup_completed_links(link_type, days)
	local now = os.time()
	local threshold = days and (now - days * 86400) or 0
	local cleaned = 0
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local delete_fun = link_type == "todo" and link.delete_todo or link.delete_code

	for id, link_obj in pairs(get_all_fun()) do
		local status = link_obj.status or types.STATUS.NORMAL
		if status == types.STATUS.COMPLETED then
			-- 检查时间条件
			local should_clean = false
			if threshold == 0 then
				should_clean = true
			elseif link_obj.completed_at then
				should_clean = link_obj.completed_at < threshold
			else
				should_clean = (link_obj.created_at or 0) < threshold
			end

			if should_clean then
				delete_fun(id)
				cleaned = cleaned + 1
			end
		end
	end

	return cleaned
end

-- 通用验证链接
local function _validate_links(link_type, all_todo, all_code, summary, verbose)
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local opposite_links = link_type == "todo" and all_code or all_todo
	local index_ns = link_type == "todo" and "todo.index.file_to_todo" or "todo.index.file_to_code"

	for id, link_obj in pairs(get_all_fun()) do
		summary["total_" .. link_type] = summary["total_" .. link_type] + 1

		-- 检查文件是否存在
		local norm_path = index._normalize_path(link_obj.path)
		if vim.fn.filereadable(norm_path) == 0 then
			summary.missing_files = summary.missing_files + 1
			summary.broken_links = summary.broken_links + 1

			if verbose then
				vim.notify(
					"缺失" .. (link_type == "todo" and "TODO" or "代码") .. "文件: " .. (link_obj.path or "<?>"),
					vim.log.levels.DEBUG
				)
			end
		end

		-- 检查对应的链接
		if not opposite_links[id] then
			summary["orphan_" .. link_type] = summary["orphan_" .. link_type] + 1
			summary.broken_links = summary.broken_links + 1

			if verbose then
				vim.notify(
					"孤立" .. (link_type == "todo" and "TODO" or "代码") .. "标记: " .. id,
					vim.log.levels.DEBUG
				)
			end
		end
	end
end

----------------------------------------------------------------------
-- 对外API（复用通用函数）
----------------------------------------------------------------------

--- 清理过期链接
--- @param days number
--- @return number
function M.cleanup(days)
	local cleaned_todo = _cleanup_expired_links("todo", days)
	local cleaned_code = _cleanup_expired_links("code", days)
	return cleaned_todo + cleaned_code
end

--- 清理已完成的链接
--- @param days number|nil
--- @return number
function M.cleanup_completed(days)
	local cleaned_todo = _cleanup_completed_links("todo", days)
	local cleaned_code = _cleanup_completed_links("code", days)
	return cleaned_todo + cleaned_code
end

--- 验证所有链接
--- @param opts table|nil
--- @return table
function M.validate_all(opts)
	opts = opts or {}
	local verbose = opts.verbose or false

	local all_code = link.get_all_code()
	local all_todo = link.get_all_todo()

	local summary = {
		total_code = 0,
		total_todo = 0,
		orphan_code = 0,
		orphan_todo = 0,
		missing_files = 0,
		broken_links = 0,
	}

	-- 验证代码链接
	_validate_links("code", all_todo, all_code, summary, verbose)

	-- 验证TODO链接
	_validate_links("todo", all_todo, all_code, summary, verbose)

	summary.summary = string.format(
		"代码标记: %d, TODO 标记: %d, 孤立代码: %d, 孤立 TODO: %d, 缺失文件: %d, 损坏链接: %d",
		summary.total_code,
		summary.total_todo,
		summary.orphan_code,
		summary.orphan_todo,
		summary.missing_files,
		summary.broken_links
	)

	return summary
end

--- 尝试修复损坏的链接
--- @param opts table|nil
--- @return table
function M.repair_links(opts)
	opts = opts or {}
	local verbose = opts.verbose or false
	local dry_run = opts.dry_run or false

	local all_code = link.get_all_code()
	local all_todo = link.get_all_todo()

	local report = {
		relocated = 0,
		deleted_orphans = 0,
		errors = 0,
	}

	-- 通用重定位函数
	local function _relocate_link(link_obj, link_type)
		local norm_path = index._normalize_path(link_obj.path)
		if vim.fn.filereadable(norm_path) == 0 then
			local relocated = link._relocate_link_if_needed(link_obj, { verbose = verbose })
			if relocated.path ~= link_obj.path then
				report.relocated = report.relocated + 1
				if verbose then
					vim.notify(string.format("重定位: %s -> %s", link_obj.path, relocated.path), vim.log.levels.INFO)
				end
			end
		end
	end

	-- 尝试重定位文件
	for _, link_obj in pairs(all_code) do
		_relocate_link(link_obj, "code")
	end

	for _, link_obj in pairs(all_todo) do
		_relocate_link(link_obj, "todo")
	end

	-- 删除孤儿链接（仅当dry_run为false时）
	if not dry_run then
		for id in pairs(all_code) do
			if not all_todo[id] then
				link.delete_code(id)
				report.deleted_orphans = report.deleted_orphans + 1
			end
		end

		for id in pairs(all_todo) do
			if not all_code[id] then
				link.delete_todo(id)
				report.deleted_orphans = report.deleted_orphans + 1
			end
		end
	end

	return report
end

--- 清理过期归档链接（30天前）
--- @return number 清理的数量
function M.cleanup_expired_archives()
	local store = module.get("store")
	local link_mod = module.get("store.link")

	if not store or not link_mod then
		return 0
	end

	local cutoff_time = os.time() - 30 * 86400 -- 30天
	local cleaned = 0

	-- 清理TODO链接
	local all_todo = store.get_all_todo_links() or {}
	for id, link in pairs(all_todo) do
		if link.archived_at and link.archived_at < cutoff_time then
			store.delete_todo_link(id)
			cleaned = cleaned + 1
		end
	end

	-- 清理代码链接
	local all_code = store.get_all_code_links() or {}
	for id, link in pairs(all_code) do
		if link.archived_at and link.archived_at < cutoff_time then
			store.delete_code_link(id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

return M
