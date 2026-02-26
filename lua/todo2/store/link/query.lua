-- lua/todo2/store/link/query.lua
-- 链接查询功能

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core")

---------------------------------------------------------------------
-- 获取所有链接
---------------------------------------------------------------------
function M.get_all_todo()
	local prefix = "todo.links.todo."
	local ids = store.get_namespace_keys(prefix:sub(1, -2)) or {}
	local result = {}
	for _, id in ipairs(ids) do
		local link = core.get_todo(id, { verify_line = false })
		if link and link.active ~= false then
			result[id] = link
		end
	end
	return result
end

function M.get_all_code()
	local prefix = "todo.links.code."
	local ids = store.get_namespace_keys(prefix:sub(1, -2)) or {}
	local result = {}
	for _, id in ipairs(ids) do
		local link = core.get_code(id, { verify_line = false })
		if link and link.active ~= false then
			result[id] = link
		end
	end
	return result
end

---------------------------------------------------------------------
-- 归档链接查询
---------------------------------------------------------------------
function M.get_archived_links(days)
	local cutoff_time = days and (os.time() - days * 86400) or 0
	local result = {}
	local all_todo = M.get_all_todo()

	for id, link in pairs(all_todo) do
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].todo = link
			end
		end
	end

	local all_code = M.get_all_code()
	for id, link in pairs(all_code) do
		if link.status == types.STATUS.ARCHIVED and link.active ~= false then
			if cutoff_time == 0 or (link.archived_at and link.archived_at >= cutoff_time) then
				result[id] = result[id] or {}
				result[id].code = link
			end
		end
	end

	return result
end

---------------------------------------------------------------------
-- 任务组进度
---------------------------------------------------------------------
local function collect_task_group(root_id, all_todo, result)
	result = result or {}

	if not result[root_id] then
		result[root_id] = all_todo[root_id]
	end

	for id, todo in pairs(all_todo) do
		if id:match("^" .. root_id:gsub("%.", "%%.") .. "%.") then
			if not result[id] then
				result[id] = todo
				collect_task_group(id, all_todo, result)
			end
		end
	end

	return result
end

function M.get_group_progress(root_id)
	local all_todo = M.get_all_todo()
	if not all_todo or vim.tbl_isempty(all_todo) then
		return nil
	end

	local group = collect_task_group(root_id, all_todo, {})

	if vim.tbl_count(group) <= 1 then
		return nil
	end

	local completed = 0
	local total = 0

	for _, task in pairs(group) do
		total = total + 1
		if task and types.is_completed_status(task.status) then
			completed = completed + 1
		end
	end

	return {
		done = completed,
		total = total,
		percent = math.floor(completed / total * 100),
		group_size = total,
	}
end

function M.get_task_group(root_id)
	local all_todo = M.get_all_todo()
	if not all_todo then
		return {}
	end

	local group = collect_task_group(root_id, all_todo, {})
	return vim.tbl_values(group)
end

return M
