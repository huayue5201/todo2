-- lua/todo2/store/link/query.lua
-- 新版查询模块：完全适配任务级存储结构（tasks / task_ctx）
-- 严格 LuaDoc 版本

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local file = require("todo2.utils.file")

---------------------------------------------------------------------
-- 类型定义（严格 LuaDoc）
---------------------------------------------------------------------

--- @class todo2.TaskLocation
--- @field path string 文件路径
--- @field line integer 行号
--- @field context table|nil 代码上下文
--- @field context_updated_at integer|nil

--- @class todo2.TaskObject
--- @field id string
--- @field core table
--- @field relations table|nil
--- @field timestamps table
--- @field verified boolean|nil
--- @field locations { todo: todo2.TaskLocation|nil, code: todo2.TaskLocation|nil }

---------------------------------------------------------------------
-- 内部工具：从任务级存储加载任务
---------------------------------------------------------------------

--- 从任务级存储加载任务对象
--- @param id string 任务ID
--- @return todo2.TaskObject|nil
local function load_task(id)
	local core_data = store.get_key("todo.tasks." .. id)
	if not core_data then
		return nil
	end

	local todo_ctx = store.get_key("todo.task_ctx." .. id .. ".todo")
	local code_ctx = store.get_key("todo.task_ctx." .. id .. ".code")

	return {
		id = id,
		core = core_data.core or {},
		relations = core_data.relations,
		timestamps = core_data.timestamps or {},
		verified = core_data.verified,
		locations = {
			todo = todo_ctx,
			code = code_ctx,
		},
	}
end

---------------------------------------------------------------------
-- 获取所有任务
---------------------------------------------------------------------

--- 获取所有任务（扫描 todo.tasks.*）
--- @return table<string, todo2.TaskObject>
function M.get_all_tasks()
	local keys = store.get_namespace_keys("todo.tasks") or {}
	local result = {}

	for _, key in ipairs(keys) do
		local id = key:match("^todo%.tasks%.(.+)$")
		if id then
			local task = load_task(id)
			if task then
				result[id] = task
			end
		end
	end

	return result
end

---------------------------------------------------------------------
-- TODO / CODE 查询
---------------------------------------------------------------------

--- 获取所有有 TODO 位置的任务
--- @return table<string, todo2.TaskObject>
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

--- 获取所有有 CODE 位置的任务
--- @return table<string, todo2.TaskObject>
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
-- 按文件查询
---------------------------------------------------------------------

--- 按文件路径查询任务
--- @param path string 文件路径
--- @return { todo: table<string, todo2.TaskObject>, code: table<string, todo2.TaskObject> }
function M.find_by_file(path)
	path = file.normalize_path(path)

	local todo_ids = store.get_key("todo.index.file_to_todo." .. path) or {}
	local code_ids = store.get_key("todo.index.file_to_code." .. path) or {}

	local result = { todo = {}, code = {} }

	-- 加载TODO任务
	for _, id in ipairs(todo_ids) do
		local task = load_task(id)
		if task and task.locations and task.locations.todo then
			result.todo[id] = task
		end
	end

	-- 加载代码任务
	for _, id in ipairs(code_ids) do
		local task = load_task(id)
		if task and task.locations and task.locations.code then
			result.code[id] = task
		end
	end

	return result
end

---------------------------------------------------------------------
-- 标签 / 状态 / 归档 查询
---------------------------------------------------------------------

--- 按标签查询
--- @param tag string 标签名
--- @return table<string, todo2.TaskObject>
function M.find_by_tag(tag)
	local all = M.get_all_tasks()
	local result = {}

	for id, task in pairs(all) do
		local tags = task.core.tags or {}
		for _, t in ipairs(tags) do
			if t == tag then
				result[id] = task
				break
			end
		end
	end

	return result
end

--- 按状态查询
--- @param status string 状态值
--- @return table<string, todo2.TaskObject>
function M.find_by_status(status)
	local all = M.get_all_tasks()
	local result = {}

	for id, task in pairs(all) do
		if task.core.status == status then
			result[id] = task
		end
	end

	return result
end

--- 获取归档任务
--- @param days? number 最近天数，nil表示所有归档任务
--- @return table<string, todo2.TaskObject>
function M.get_archived_tasks(days)
	local cutoff = days and (os.time() - days * 86400) or 0
	local all = M.get_all_tasks()
	local result = {}

	for id, task in pairs(all) do
		if task.core.status == types.STATUS.ARCHIVED then
			if cutoff == 0 then
				result[id] = task
			else
				local archived_at = task.timestamps.archived
				if archived_at and archived_at >= cutoff then
					result[id] = task
				end
			end
		end
	end

	return result
end

---------------------------------------------------------------------
-- 任务树 / 关系查询
---------------------------------------------------------------------

--- 获取任务树
--- @param root_id string 根任务ID
--- @return table|nil
function M.get_task_tree(root_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return nil
	end
	return relation.get_task_tree(root_id)
end

--- 获取所有子任务
--- @param parent_id string 父任务ID
--- @return todo2.TaskObject[]
function M.get_children(parent_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local ids = relation.get_child_ids(parent_id)
	local result = {}

	for _, id in ipairs(ids) do
		local task = load_task(id)
		if task then
			table.insert(result, task)
		end
	end

	return result
end

--- 获取父任务
--- @param child_id string 子任务ID
--- @return todo2.TaskObject|nil
function M.get_parent(child_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return nil
	end

	local parent_id = relation.get_parent_id(child_id)
	if parent_id then
		return load_task(parent_id)
	end

	return nil
end

--- 获取兄弟任务
--- @param task_id string 任务ID
--- @return todo2.TaskObject[]
function M.get_siblings(task_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local parent_id = relation.get_parent_id(task_id)
	if not parent_id then
		return {}
	end

	local result = {}
	local ids = relation.get_child_ids(parent_id)

	for _, id in ipairs(ids) do
		if id ~= task_id then
			local task = load_task(id)
			if task then
				table.insert(result, task)
			end
		end
	end

	return result
end

--- 获取所有后代
--- @param root_id string 根任务ID
--- @return todo2.TaskObject[]
function M.get_descendants(root_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local ids = relation.get_descendants(root_id)
	local result = {}

	for _, id in ipairs(ids) do
		local task = load_task(id)
		if task then
			table.insert(result, task)
		end
	end

	return result
end

--- 获取祖先路径
--- @param task_id string 任务ID
--- @return todo2.TaskObject[]
function M.get_ancestors(task_id)
	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return {}
	end

	local ids = relation.get_ancestors(task_id)
	local result = {}

	for _, id in ipairs(ids) do
		local task = load_task(id)
		if task then
			table.insert(result, task)
		end
	end

	return result
end

---------------------------------------------------------------------
-- 任务组进度
---------------------------------------------------------------------

--- 获取任务组进度
--- @param root_id string 根任务ID
--- @return { done: integer, total: integer, percent: integer, group_size: integer }|nil
function M.get_group_progress(root_id)
	local tree = M.get_task_tree(root_id)
	if not tree then
		return nil
	end

	local ok, relation = pcall(require, "todo2.store.link.relation")
	if not ok then
		return nil
	end

	local ids = { root_id }
	vim.list_extend(ids, relation.get_descendants(root_id))

	local done = 0
	local total = 0

	for _, id in ipairs(ids) do
		local task = load_task(id)
		if task then
			total = total + 1
			if task.core.status == types.STATUS.COMPLETED then
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

return M
