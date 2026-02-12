-- lua/todo2/store/cleanup.lua
-- 数据清理与维护

local M = {}

local link = require("todo2.store.link")
local index = require("todo2.store.index")

----------------------------------------------------------------------
-- 通用清理函数（全部 local）
----------------------------------------------------------------------
local function cleanup_expired_links(link_type, days)
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

local function cleanup_completed_links(link_type, days)
	local now = os.time()
	local threshold = days and (now - days * 86400) or 0
	local cleaned = 0
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local delete_fun = link_type == "todo" and link.delete_todo or link.delete_code

	for id, link_obj in pairs(get_all_fun()) do
		if link_obj.status == "completed" then
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

local function validate_links(link_type, all_todo, all_code, summary, verbose)
	local get_all_fun = link_type == "todo" and link.get_all_todo or link.get_all_code
	local opposite_links = link_type == "todo" and all_code or all_todo

	for id, link_obj in pairs(get_all_fun()) do
		summary["total_" .. link_type] = summary["total_" .. link_type] + 1

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

local function relocate_link(link_obj, verbose)
	local norm_path = index._normalize_path(link_obj.path)
	if vim.fn.filereadable(norm_path) == 0 then
		if verbose then
			vim.notify(string.format("文件不存在，无法重定位: %s", link_obj.path), vim.log.levels.WARN)
		end
		return link_obj
	else
		local locator = require("todo2.store.locator")
		local relocated = locator.locate_task(link_obj)
		if relocated.path ~= link_obj.path or relocated.line ~= link_obj.line then
			if verbose then
				vim.notify(
					string.format("重新定位链接: %s:%d", relocated.path, relocated.line),
					vim.log.levels.INFO
				)
			end
			return relocated
		end
		return link_obj
	end
end

----------------------------------------------------------------------
-- 公共 API（仅保留被调用的函数）
----------------------------------------------------------------------
--- 清理过期链接
--- @param days number
--- @return table
function M.cleanup(days)
	local cleaned_todo = cleanup_expired_links("todo", days)
	local cleaned_code = cleanup_expired_links("code", days)

	local config = require("todo2.store.config")
	local trash_report = {}
	if config.get("trash.enabled") and config.get("trash.auto_cleanup") then
		local trash = require("todo2.store.trash")
		trash_report = trash.auto_cleanup()
	end

	return {
		expired_todo = cleaned_todo,
		expired_code = cleaned_code,
		expired_total = cleaned_todo + cleaned_code,
		trash_cleaned = (trash_report.deleted_pairs or 0)
			+ (trash_report.deleted_todo or 0)
			+ (trash_report.deleted_code or 0),
		summary = string.format(
			"清理完成: %d 个过期TODO, %d 个过期代码链接, %d 个软删除链接",
			cleaned_todo,
			cleaned_code,
			(trash_report.deleted_pairs or 0) + (trash_report.deleted_todo or 0) + (trash_report.deleted_code or 0)
		),
	}
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

	validate_links("code", all_todo, all_code, summary, verbose)
	validate_links("todo", all_todo, all_code, summary, verbose)

	if opts.check_verification then
		summary.unverified_todo = 0
		summary.unverified_code = 0
		for _, link_obj in pairs(all_todo) do
			if not link_obj.line_verified then
				summary.unverified_todo = summary.unverified_todo + 1
			end
		end
		for _, link_obj in pairs(all_code) do
			if not link_obj.line_verified then
				summary.unverified_code = summary.unverified_code + 1
			end
		end
	end

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
	local store = require("todo2.store.nvim_store")

	local report = {
		relocated = 0,
		deleted_orphans = 0,
		errors = 0,
		unverified_fixed = 0,
	}

	for _, link_obj in pairs(all_code) do
		local relocated = relocate_link(link_obj, verbose)
		if relocated.path ~= link_obj.path or relocated.line ~= link_obj.line then
			if not dry_run then
				store.set_key("todo.links.code." .. link_obj.id, relocated)
			end
			report.relocated = report.relocated + 1
		end
		if not link_obj.line_verified and relocated.line_verified then
			report.unverified_fixed = report.unverified_fixed + 1
		end
	end

	for _, link_obj in pairs(all_todo) do
		local relocated = relocate_link(link_obj, verbose)
		if relocated.path ~= link_obj.path or relocated.line ~= link_obj.line then
			if not dry_run then
				store.set_key("todo.links.todo." .. link_obj.id, relocated)
			end
			report.relocated = report.relocated + 1
		end
		if not link_obj.line_verified and relocated.line_verified then
			report.unverified_fixed = report.unverified_fixed + 1
		end
	end

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

--- 清理过期归档链接
--- @return number
function M.cleanup_expired_archives()
	local cutoff_time = os.time() - 30 * 86400
	local cleaned = 0
	local archived = link.get_archived_links()
	for id, data in pairs(archived) do
		local archive_time = nil
		if data.todo and data.todo.archived_at then
			archive_time = data.todo.archived_at
		elseif data.code and data.code.archived_at then
			archive_time = data.code.archived_at
		end
		if archive_time and archive_time < cutoff_time then
			if data.todo then
				link.delete_todo(id)
			end
			if data.code then
				link.delete_code(id)
			end
			cleaned = cleaned + 1
		end
	end
	return cleaned
end

--- 清理孤立的归档链接
--- @return table
function M.cleanup_orphan_archives()
	local archived = link.get_archived_links()
	local report = { cleaned = 0, orphan_todo = 0, orphan_code = 0 }
	for id, data in pairs(archived) do
		local has_todo = data.todo ~= nil
		local has_code = data.code ~= nil
		if has_todo and not has_code then
			link.delete_todo(id)
			report.orphan_todo = report.orphan_todo + 1
			report.cleaned = report.cleaned + 1
		elseif has_code and not has_todo then
			link.delete_code(id)
			report.orphan_code = report.orphan_code + 1
			report.cleaned = report.cleaned + 1
		end
	end
	return report
end

--- 清理已完成的链接
--- @param days number|nil
--- @return number
function M.cleanup_completed(days)
	local cleaned_todo = cleanup_completed_links("todo", days)
	local cleaned_code = cleanup_completed_links("code", days)
	return cleaned_todo + cleaned_code
end

return M
