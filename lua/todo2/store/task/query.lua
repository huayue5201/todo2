-- lua/todo2/store/task/query.lua
-- 查询模块：按文件查询任务

local M = {}

local store = require("todo2.store.nvim_store")
local file = require("todo2.utils.file")

--- 从任务级存储加载任务对象
--- @param id string 任务ID
--- @return table|nil
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
		verification = core_data.verification,
		locations = {
			todo = todo_ctx,
			code = code_ctx,
		},
	}
end

--- 按文件路径查询任务
--- @param path string 文件路径
--- @return { todo: table<string, table>, code: table<string, table> }
function M.find_by_file(path)
	path = file.normalize_path(path)

	local todo_ids = store.get_key("todo.index.file_to_todo." .. path) or {}
	local code_ids = store.get_key("todo.index.file_to_code." .. path) or {}

	local result = { todo = {}, code = {} }

	for _, id in ipairs(todo_ids) do
		local task = load_task(id)
		if task and task.locations and task.locations.todo then
			result.todo[id] = task
		end
	end

	for _, id in ipairs(code_ids) do
		local task = load_task(id)
		if task and task.locations and task.locations.code then
			result.code[id] = task
		end
	end

	return result
end

return M
