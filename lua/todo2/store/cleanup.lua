-- lua/todo2/store/cleanup.lua
--- @module todo2.store.cleanup

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local link = require("todo2.store.link")
local index = require("todo2.store.index")
local types = require("todo2.store.types")

--- 清理过期链接
--- @param days number
--- @return number
function M.cleanup(days)
	local now = os.time()
	local threshold = now - days * 86400
	local cleaned = 0

	-- 清理代码链接
	for id, link_obj in pairs(link.get_all_code()) do
		if (link_obj.created_at or 0) < threshold then
			link.delete_code(id)
			cleaned = cleaned + 1
		end
	end

	-- 清理TODO链接
	for id, link_obj in pairs(link.get_all_todo()) do
		if (link_obj.created_at or 0) < threshold then
			link.delete_todo(id)
			cleaned = cleaned + 1
		end
	end

	return cleaned
end

--- 清理已完成的链接
--- @param days number|nil
--- @return number
function M.cleanup_completed(days)
	local now = os.time()
	local threshold = days and (now - days * 86400) or 0
	local cleaned = 0

	-- 清理已完成的代码链接
	for id, link_obj in pairs(link.get_all_code()) do
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
				link.delete_code(id)
				cleaned = cleaned + 1
			end
		end
	end

	-- 清理已完成的TODO链接
	for id, link_obj in pairs(link.get_all_todo()) do
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
				link.delete_todo(id)
				cleaned = cleaned + 1
			end
		end
	end

	return cleaned
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

	-- 检查代码链接
	for id, link_obj in pairs(all_code) do
		summary.total_code = summary.total_code + 1

		-- 检查文件是否存在
		local norm_path = index._normalize_path(link_obj.path)
		if vim.fn.filereadable(norm_path) == 0 then
			summary.missing_files = summary.missing_files + 1
			summary.broken_links = summary.broken_links + 1

			if verbose then
				vim.notify("缺失代码文件: " .. (link_obj.path or "<?>"), vim.log.levels.DEBUG)
			end
		end

		-- 检查对应的TODO链接
		if not all_todo[id] then
			summary.orphan_code = summary.orphan_code + 1
			summary.broken_links = summary.broken_links + 1

			if verbose then
				vim.notify("孤立代码标记: " .. id, vim.log.levels.DEBUG)
			end
		end
	end

	-- 检查TODO链接
	for id, link_obj in pairs(all_todo) do
		summary.total_todo = summary.total_todo + 1

		-- 检查文件是否存在
		local norm_path = index._normalize_path(link_obj.path)
		if vim.fn.filereadable(norm_path) == 0 then
			summary.missing_files = summary.missing_files + 1
			summary.broken_links = summary.broken_links + 1

			if verbose then
				vim.notify("缺失 TODO 文件: " .. (link_obj.path or "<?>"), vim.log.levels.DEBUG)
			end
		end

		-- 检查对应的代码链接
		if not all_code[id] then
			summary.orphan_todo = summary.orphan_todo + 1
			summary.broken_links = summary.broken_links + 1

			if verbose then
				vim.notify("孤立 TODO 标记: " .. id, vim.log.levels.DEBUG)
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

	local report = {
		relocated = 0,
		deleted_orphans = 0,
		errors = 0,
	}

	-- 尝试重定位文件
	for id, link_obj in pairs(all_code) do
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

	for id, link_obj in pairs(all_todo) do
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

	-- 删除孤儿链接（仅当dry_run为false时）
	if not dry_run then
		for id, link_obj in pairs(all_code) do
			if not all_todo[id] then
				link.delete_code(id)
				report.deleted_orphans = report.deleted_orphans + 1
			end
		end

		for id, link_obj in pairs(all_todo) do
			if not all_code[id] then
				link.delete_todo(id)
				report.deleted_orphans = report.deleted_orphans + 1
			end
		end
	end

	return report
end

return M
