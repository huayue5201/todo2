-- lua/todo2/store/task/query.lua
-- 查询模块：按文件查询任务

local M = {}

local store = require("todo2.store.nvim_store")
local file = require("todo2.utils.file")

--- 从任务级存储加载任务对象（复用 store/task/core 的权威加载器）
--- @param id string 任务ID
--- @return table|nil
local function load_task(id)
	return require("todo2.store.task.core").get_task(id)
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

--- 解析任务的“有效代码位置”：优先自身锚点；否则沿父链向上取最近的可用锚点。
--- 供“补充任务”（在 TODO 文件里用 `ns` 建的子任务）使用——它们没有自己的锚点，
--- 上下文继承自最近的父任务：父是纯清单任务则无锚点，父有锚点则继承之。
---@param id string
---@return table|nil loc 有效代码位置
---@return boolean inherited 是否继承自祖先
function M.resolve_code_location(id)
	local core = require("todo2.store.task.core")
	local task = core.get_task(id)
	if not task then
		return nil, false
	end

	local own = task.locations and task.locations.code
	if own and not core.is_anchor_lost(task) then
		return own, false
	end

	-- get_ancestors 返回 [根 ... 父]，从近到远找最近的可用锚点
	local ancestors = require("todo2.store.task.relation").get_ancestors(id)
	for i = #ancestors, 1, -1 do
		local anc = core.get_task(ancestors[i])
		local loc = anc and anc.locations and anc.locations.code
		if loc and not core.is_anchor_lost(anc) then
			return loc, true
		end
	end

	return nil, false
end

return M
