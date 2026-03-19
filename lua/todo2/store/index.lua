-- lua/todo2/store/index.lua
-- 索引模块：管理文件到任务的映射和文件树结构

local M = {}

local store = require("todo2.store.nvim_store")
local file = require("todo2.utils.file") -- ⭐ 引入文件工具模块

---------------------------------------------------------------------
-- 命名空间常量
---------------------------------------------------------------------

local NS = {
	TODO = "todo.index.file_to_todo.",
	CODE = "todo.index.file_to_code.",
	TREE = "todo.index.file_tree.",
}

---------------------------------------------------------------------
-- 内部工具函数（不暴露）
---------------------------------------------------------------------

---生成键名
---@param ns string
---@param filepath string
---@return string
local function key_for(ns, filepath)
	return ns .. file.normalize_path(filepath) -- ⭐ 使用文件工具模块
end

---添加ID到文件索引
---@param ns string
---@param filepath string
---@param id string
local function add_id_to_file_index(ns, filepath, id)
	local key = key_for(ns, filepath)
	local list = store.get_key(key) or {}

	for _, existing in ipairs(list) do
		if existing == id then
			return
		end
	end

	table.insert(list, id)
	store.set_key(key, list)
end

---从文件索引移除ID
---@param ns string
---@param filepath string
---@param id string
local function remove_id_from_file_index(ns, filepath, id)
	local key = key_for(ns, filepath)
	local list = store.get_key(key)
	if not list then
		return
	end

	local new_list = {}
	for _, existing in ipairs(list) do
		if existing ~= id then
			table.insert(new_list, existing)
		end
	end

	if #new_list == 0 then
		store.delete_key(key)
	else
		store.set_key(key, new_list)
	end
end

---------------------------------------------------------------------
-- 公开接口（只暴露必要的）
---------------------------------------------------------------------

---更新文件的完整任务树
---@param path string 文件路径
---@param roots table[] 根节点列表（按行号排序）
---@return boolean 是否成功
function M.update_file_tree(path, roots)
	if not path or path == "" then
		return false
	end

	local norm_path = file.normalize_path(path) -- ⭐ 使用文件工具模块
	local tree_key = NS.TREE .. norm_path
	store.set_key(tree_key, roots or {})
	return true
end

---获取文件的完整任务树
---@param path string 文件路径
---@return table[] 根节点列表（按行号排序）
function M.get_file_tree(path)
	if not path or path == "" then
		return {}
	end

	local norm_path = file.normalize_path(path) -- ⭐ 使用文件工具模块
	local tree_key = NS.TREE .. norm_path
	return store.get_key(tree_key) or {}
end

---获取文件的所有任务ID（按行号排序）
---@param path string 文件路径
---@return string[]
function M.get_file_task_ids(path)
	local tree = M.get_file_tree(path)
	local ids = {}

	local function collect(node)
		table.insert(ids, node.id)
		for _, child in ipairs(node.children or {}) do
			collect(child)
		end
	end

	for _, root in ipairs(tree) do
		collect(root)
	end

	return ids
end

---获取文件的TODO链接列表（保留原有接口）
---@param filepath string
---@return table[]
function M.find_todo_links_by_file(filepath)
	local key = key_for(NS.TODO, filepath)
	local ids = store.get_key(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local obj = store.get_key("todo.links.internal." .. id)
		if obj then
			table.insert(results, obj)
		end
	end

	table.sort(results, function(a, b)
		return (a.locations.todo and a.locations.todo.line or 0) < (b.locations.todo and b.locations.todo.line or 0)
	end)

	return results
end

---获取文件的CODE链接列表（保留原有接口）
---@param filepath string
---@return table[]
function M.find_code_links_by_file(filepath)
	local key = key_for(NS.CODE, filepath)
	local ids = store.get_key(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local obj = store.get_key("todo.links.internal." .. id)
		if obj then
			table.insert(results, obj)
		end
	end

	table.sort(results, function(a, b)
		return (a.locations.code and a.locations.code.line or 0) < (b.locations.code and b.locations.code.line or 0)
	end)

	return results
end

---供 core 模块调用的内部函数（通过特殊的内部接口）
local Internal = {}

---添加ID到TODO文件索引
---@param filepath string
---@param id string
function Internal.add_todo_id(filepath, id)
	add_id_to_file_index(NS.TODO, filepath, id)
end

---添加ID到CODE文件索引
---@param filepath string
---@param id string
function Internal.add_code_id(filepath, id)
	add_id_to_file_index(NS.CODE, filepath, id)
end

---从TODO文件索引移除ID
---@param filepath string
---@param id string
function Internal.remove_todo_id(filepath, id)
	remove_id_from_file_index(NS.TODO, filepath, id)
end

---从CODE文件索引移除ID
---@param filepath string
---@param id string
function Internal.remove_code_id(filepath, id)
	remove_id_from_file_index(NS.CODE, filepath, id)
end

M._internal = Internal

return M
