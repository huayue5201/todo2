-- lua/todo2/store/link/query.lua
-- 查询模块：提供各种查询功能，直接操作存储
-- 注意：此模块是查询的推荐入口，core中的查询函数已废弃

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")

local INTERNAL_PREFIX = "todo.links.internal."

---@alias TaskID string 任务ID，格式如 "20240321.abc123"
---@alias Task table 内部格式任务对象

---------------------------------------------------------------------
-- 获取所有任务（返回内部格式数组）
---------------------------------------------------------------------

---获取所有任务
---@return table<TaskID, Task> 任务ID到任务对象的映射表
function M.get_all_tasks()
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

---------------------------------------------------------------------
-- 获取所有有TODO位置的任务
---------------------------------------------------------------------

---获取所有有TODO位置的任务
---@return table<TaskID, Task> 任务ID到任务对象的映射表
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

---------------------------------------------------------------------
-- 获取所有有代码位置的任务
---------------------------------------------------------------------

---获取所有有代码位置的任务
---@return table<TaskID, Task> 任务ID到任务对象的映射表
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

---------------------------------------------------------------------
-- 获取归档任务
---------------------------------------------------------------------

---获取归档任务
---@param days? number 可选，只返回指定天数内的归档任务
---@return table<TaskID, Task> 任务ID到任务对象的映射表
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

---------------------------------------------------------------------
-- 按文件路径查询任务
---------------------------------------------------------------------

---按文件路径查询任务
---@param path string 文件路径
---@return { todo: table<TaskID, Task>, code: table<TaskID, Task> } TODO位置和代码位置的任务
function M.find_by_file(path)
	path = require("todo2.store.index")._normalize_path(path)
	local result = {
		todo = {},
		code = {},
	}

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

---------------------------------------------------------------------
-- 按标签查询
---------------------------------------------------------------------

---按标签查询任务
---@param tag string 标签名（不含括号）
---@return table<TaskID, Task> 任务ID到任务对象的映射表
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

---------------------------------------------------------------------
-- 按状态查询
---------------------------------------------------------------------

---按状态查询任务
---@param status string 状态值，参考 types.STATUS
---@return table<TaskID, Task> 任务ID到任务对象的映射表
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
-- 获取任务组（按ID前缀）
---------------------------------------------------------------------

---递归收集任务组
---@param root_id TaskID 根任务ID
---@param all_tasks table<TaskID, Task> 所有任务
---@param result? table<TaskID, Task> 结果收集表
---@return table<TaskID, Task> 任务组
local function collect_task_group(root_id, all_tasks, result)
	result = result or {}

	if not result[root_id] then
		result[root_id] = all_tasks[root_id]
	end

	for id, task in pairs(all_tasks) do
		if id:match("^" .. root_id:gsub("%.", "%%.") .. "%.") then
			if not result[id] then
				result[id] = task
				collect_task_group(id, all_tasks, result)
			end
		end
	end

	return result
end

---获取任务组（包含所有子任务）
---@param root_id TaskID 根任务ID
---@param opts? { include_archived?: boolean } 选项
---@return Task[] 任务对象数组
function M.get_task_group(root_id, opts)
	opts = opts or {}
	local include_archived = opts.include_archived == true

	local all_tasks = M.get_all_tasks()
	if not all_tasks then
		return {}
	end

	-- 过滤归档
	if not include_archived then
		local filtered = {}
		for id, task in pairs(all_tasks) do
			if task.core.status ~= types.STATUS.ARCHIVED then
				filtered[id] = task
			end
		end
		all_tasks = filtered
	end

	local group = collect_task_group(root_id, all_tasks, {})
	return vim.tbl_values(group)
end

---------------------------------------------------------------------
-- 任务组进度
---------------------------------------------------------------------

---获取任务组进度
---@param root_id TaskID 根任务ID
---@return { done: number, total: number, percent: number, group_size: number }? 进度信息
function M.get_group_progress(root_id)
	local all_tasks = M.get_all_tasks()
	if not all_tasks or vim.tbl_isempty(all_tasks) then
		return nil
	end

	local group = collect_task_group(root_id, all_tasks, {})
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

return M
