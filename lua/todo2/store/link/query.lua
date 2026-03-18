-- lua/todo2/store/link/query.lua
-- 查询模块：提供各种查询功能，直接操作存储

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local core = require("todo2.store.link.core")

local INTERNAL_PREFIX = "todo.links.internal."

-- 警告记录
local warned = {}

local function warn_deprecated(old_name, new_name)
	if not warned[old_name] then
		vim.notify(
			string.format("[todo2] %s is deprecated, use %s for tree operations", old_name, new_name),
			vim.log.levels.WARN
		)
		warned[old_name] = true
	end
end

---------------------------------------------------------------------
-- 内部辅助函数（保留原有的ID前缀方式）
---------------------------------------------------------------------

local function get_all_tasks_raw()
	local keys = store.get_namespace_keys(INTERNAL_PREFIX:sub(1, -2)) or {}
	local result = {}
	for _, key in ipairs(keys) do
		local id = key:match("todo%.links%.internal%.(.*)$")
		if id then
			local task = store.get_key(key)
			if task then
				result[id] = task
			end
		end
	end
	return result
end

local function collect_task_group_by_prefix(root_id, all_tasks, result)
	result = result or {}
	if not result[root_id] then
		result[root_id] = all_tasks[root_id]
	end
	for id, task in pairs(all_tasks) do
		if id:match("^" .. root_id:gsub("%.", "%%.") .. "%.") then
			if not result[id] then
				result[id] = task
				collect_task_group_by_prefix(id, all_tasks, result)
			end
		end
	end
	return result
end

---------------------------------------------------------------------
-- 原有API保持不变
---------------------------------------------------------------------

---获取所有任务
---@return table<string, table>
function M.get_all_tasks()
	return get_all_tasks_raw()
end

---获取所有有TODO位置的任务
---@return table<string, table>
function M.get_todo_tasks()
	local all = M.get_all_tasks()
	local result = {}
	for id, task in pairs(all) do
		if task.locations.todo then
			result[id] = task
		end
	end
	return result
end

---获取所有有代码位置的任务
---@return table<string, table>
function M.get_code_tasks()
	local all = M.get_all_tasks()
	local result = {}
	for id, task in pairs(all) do
		if task.locations.code then
			result[id] = task
		end
	end
	return result
end

---获取归档任务
---@param days? number
---@return table<string, table>
function M.get_archived_tasks(days)
	local cutoff = days and (os.time() - days * 86400) or 0
	local all = M.get_all_tasks()
	local result = {}
	for id, task in pairs(all) do
		if task.core.status == types.STATUS.ARCHIVED then
			if cutoff == 0 or (task.timestamps.archived and task.timestamps.archived >= cutoff) then
				result[id] = task
			end
		end
	end
	return result
end

---按文件路径查询任务
---@param path string
---@return { todo: table<string, table>, code: table<string, table> }
function M.find_by_file(path)
	path = require("todo2.store.index")._normalize_path(path)
	local result = { todo = {}, code = {} }
	local all = M.get_all_tasks()
	for id, task in pairs(all) do
		if task.locations.todo and task.locations.todo.path == path then
			result.todo[id] = task
		end
		if task.locations.code and task.locations.code.path == path then
			result.code[id] = task
		end
	end
	return result
end

---按标签查询
---@param tag string
---@return table<string, table>
function M.find_by_tag(tag)
	local result = {}
	local all = M.get_all_tasks()
	for id, task in pairs(all) do
		for _, t in ipairs(task.core.tags) do
			if t == tag then
				result[id] = task
				break
			end
		end
	end
	return result
end

---按状态查询
---@param status string
---@return table<string, table>
function M.find_by_status(status)
	local result = {}
	local all = M.get_all_tasks()
	for id, task in pairs(all) do
		if task.core.status == status then
			result[id] = task
		end
	end
	return result
end

---------------------------------------------------------------------
-- ⚠️ get_task_group 转发到新实现（带警告）
---------------------------------------------------------------------

---获取任务组（包含所有子任务）
---@param root_id string
---@param opts? { include_archived?: boolean }
---@return table[]
function M.get_task_group(root_id, opts)
	warn_deprecated("query.get_task_group", "relation.get_task_tree")

	-- 尝试用新模块
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if ok then
		local tree = relation.get_task_tree(root_id)
		if tree then
			-- 转换为旧的数组格式
			local result = {}
			local function collect(node)
				table.insert(result, core.get_task(node.id))
				for _, child in ipairs(node.children) do
					collect(child)
				end
			end
			collect(tree)

			-- 过滤归档
			if opts and not opts.include_archived then
				local filtered = {}
				for _, task in ipairs(result) do
					if task and task.core.status ~= types.STATUS.ARCHIVED then
						table.insert(filtered, task)
					end
				end
				return filtered
			end
			return result
		end
	end

	-- 后备：原有的ID前缀方式
	opts = opts or {}
	local all_tasks = M.get_all_tasks()
	if not opts.include_archived then
		local filtered = {}
		for id, task in pairs(all_tasks) do
			if task.core.status ~= types.STATUS.ARCHIVED then
				filtered[id] = task
			end
		end
		all_tasks = filtered
	end
	local group = collect_task_group_by_prefix(root_id, all_tasks, {})
	return vim.tbl_values(group)
end

---获取任务组进度
---@param root_id string
---@return { done: number, total: number, percent: number, group_size: number }?
function M.get_group_progress(root_id)
	warn_deprecated("query.get_group_progress", "relation based progress")

	local ok, relation = pcall(require, "todo2.store.link.relation")
	if ok then
		local descendants = relation.get_descendants(root_id)
		if #descendants > 0 then
			local all_ids = { root_id }
			vim.list_extend(all_ids, descendants)

			local done = 0
			local total = 0
			for _, id in ipairs(all_ids) do
				local task = core.get_task(id)
				if task then
					total = total + 1
					if types.is_completed_status(task.core.status) then
						done = done + 1
					end
				end
			end
			return {
				done = done,
				total = total,
				percent = total > 0 and math.floor(done / total * 100) or 0,
				group_size = total,
			}
		end
	end

	-- 后备：原有的ID前缀方式
	local all_tasks = M.get_all_tasks()
	local group = collect_task_group_by_prefix(root_id, all_tasks, {})
	if vim.tbl_count(group) <= 1 then
		return nil
	end
	local done = 0
	local total = 0
	for _, task in pairs(group) do
		total = total + 1
		if types.is_completed_status(task.core.status) then
			done = done + 1
		end
	end
	return {
		done = done,
		total = total,
		percent = total > 0 and math.floor(done / total * 100) or 0,
		group_size = total,
	}
end

---------------------------------------------------------------------
-- ⭐ 新API：基于关系的高级查询
---------------------------------------------------------------------

--- 获取任务树
---@param root_id string
---@return table?
function M.get_task_tree(root_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		vim.notify("[todo2] relation module not loaded", vim.log.levels.WARN)
		return nil
	end
	return relation.get_task_tree(root_id)
end

--- 获取所有子任务
---@param parent_id string
---@return table[]
function M.get_children(parent_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local child_ids = relation.get_child_ids(parent_id)
	local result = {}
	for _, id in ipairs(child_ids) do
		local task = core.get_task(id)
		if task then
			table.insert(result, task)
		end
	end
	return result
end

--- 获取父任务
---@param child_id string
---@return table?
function M.get_parent(child_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return nil
	end

	local parent_id = relation.get_parent_id(child_id)
	if parent_id then
		return core.get_task(parent_id)
	end
	return nil
end

--- 获取兄弟任务
---@param task_id string
---@return table[]
function M.get_siblings(task_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local parent_id = relation.get_parent_id(task_id)
	if not parent_id then
		return {}
	end

	local siblings = {}
	local child_ids = relation.get_child_ids(parent_id)
	for _, id in ipairs(child_ids) do
		if id ~= task_id then
			local task = core.get_task(id)
			if task then
				table.insert(siblings, task)
			end
		end
	end
	return siblings
end

--- 获取所有后代
---@param root_id string
---@return table[]
function M.get_descendants(root_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local descendant_ids = relation.get_descendants(root_id)
	local result = {}
	for _, id in ipairs(descendant_ids) do
		local task = core.get_task(id)
		if task then
			table.insert(result, task)
		end
	end
	return result
end

--- 获取祖先路径
---@param task_id string
---@return table[]
function M.get_ancestors(task_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local ancestor_ids = relation.get_ancestors(task_id)
	local result = {}
	for _, id in ipairs(ancestor_ids) do
		local task = core.get_task(id)
		if task then
			table.insert(result, task)
		end
	end
	return result
end

return M
