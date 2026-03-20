-- lua/todo2/store/index.lua
-- 索引模块：管理文件到任务的映射
---@module "todo2.store.index"

local M = {}

local store = require("todo2.store.nvim_store")
local file = require("todo2.utils.file")

---------------------------------------------------------------------
-- 命名空间常量
---------------------------------------------------------------------

local NS = {
	TODO = "todo.index.file_to_todo.",
	CODE = "todo.index.file_to_code.",
	TREE = "todo.index.file_tree.",
}

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

---@class IndexTask
---@field id string 任务ID
---@field core table 核心数据
---@field relations? table 关系数据
---@field timestamps table 时间戳
---@field verified boolean 是否已验证
---@field locations table<string, table> 位置信息

---@class FileTreeNode
---@field id string 任务ID
---@field level integer 缩进级别
---@field children FileTreeNode[] 子节点

---------------------------------------------------------------------
-- 工具函数
---------------------------------------------------------------------

---获取命名空间的键
---@param ns string 命名空间
---@param filepath string 文件路径
---@return string
local function key_for(ns, filepath)
	return ns .. file.normalize_path(filepath)
end

---从任务级存储加载任务对象
---@param id string 任务ID
---@return IndexTask|nil
local function load_task(id)
	local core = store.get_key("todo.tasks." .. id)
	if not core then
		return nil
	end

	local todo_ctx = store.get_key("todo.task_ctx." .. id .. ".todo")
	local code_ctx = store.get_key("todo.task_ctx." .. id .. ".code")

	---@type IndexTask
	local task = {
		id = id,
		core = core.core or {},
		relations = core.relations,
		timestamps = core.timestamps or {},
		verified = core.verified == true,
		locations = {
			todo = todo_ctx,
			code = code_ctx,
		},
	}

	return task
end

---------------------------------------------------------------------
-- 文件树操作
---------------------------------------------------------------------

---更新文件树
---@param path string 文件路径
---@param roots FileTreeNode[] 根节点列表
---@return boolean
function M.update_file_tree(path, roots)
	if not path or path == "" then
		return false
	end
	local norm = file.normalize_path(path)
	store.set_key(NS.TREE .. norm, roots or {})
	return true
end

---获取文件树
---@param path string 文件路径
---@return FileTreeNode[]
function M.get_file_tree(path)
	if not path or path == "" then
		return {}
	end
	local norm = file.normalize_path(path)
	return store.get_key(NS.TREE .. norm) or {}
end

---获取文件中的所有任务ID
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

---------------------------------------------------------------------
-- 查找任务链接
---------------------------------------------------------------------

---查找文件中的所有TODO任务
---@param filepath string 文件路径
---@return IndexTask[]
function M.find_todo_links_by_file(filepath)
	local key = key_for(NS.TODO, filepath)
	local ids = store.get_key(key) or {}
	local results = {}

	-- ids 可能是旧结构列表，统一处理为字符串数组
	local id_list = {}
	if type(ids) == "table" then
		for _, v in ipairs(ids) do
			if type(v) == "string" then
				table.insert(id_list, v)
			elseif type(v) == "table" and type(v.id) == "string" then
				table.insert(id_list, v.id)
			end
		end
	end

	-- 加载任务
	for _, id in ipairs(id_list) do
		local task = load_task(id)
		if task and task.locations and task.locations.todo then
			table.insert(results, task)
		end
	end

	-- 按行号排序（数据已保证line是数字）
	table.sort(results, function(a, b)
		return (a.locations.todo.line or 0) < (b.locations.todo.line or 0)
	end)

	return results
end

---查找文件中的所有代码任务
---@param filepath string 文件路径
---@return IndexTask[]
function M.find_code_links_by_file(filepath)
	local key = key_for(NS.CODE, filepath)
	local ids = store.get_key(key) or {}
	local results = {}

	-- ids 可能是旧结构列表，统一处理为字符串数组
	local id_list = {}
	if type(ids) == "table" then
		for _, v in ipairs(ids) do
			if type(v) == "string" then
				table.insert(id_list, v)
			elseif type(v) == "table" and type(v.id) == "string" then
				table.insert(id_list, v.id)
			end
		end
	end

	-- 加载任务
	for _, id in ipairs(id_list) do
		local task = load_task(id)
		if task and task.locations and task.locations.code then
			table.insert(results, task)
		end
	end

	-- 按行号排序（数据已保证line是数字）
	table.sort(results, function(a, b)
		return (a.locations.code.line or 0) < (b.locations.code.line or 0)
	end)

	return results
end

---------------------------------------------------------------------
-- 内部接口（供core模块使用）
---------------------------------------------------------------------

---@class IndexInternal
---@field add_todo_id fun(filepath:string, id:string)
---@field add_code_id fun(filepath:string, id:string)
---@field remove_todo_id fun(filepath:string, id:string)
---@field remove_code_id fun(filepath:string, id:string)

---@type IndexInternal
M._internal = {}

---添加TODO任务ID到文件索引
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.add_todo_id(filepath, id)
	local key = key_for(NS.TODO, filepath)
	local list = store.get_key(key) or {}

	-- 转换为ID列表
	local id_list = {}
	for _, v in ipairs(list) do
		if type(v) == "string" then
			table.insert(id_list, v)
		elseif type(v) == "table" and type(v.id) == "string" then
			table.insert(id_list, v.id)
		end
	end

	-- 去重
	local seen = {}
	for _, existing in ipairs(id_list) do
		seen[existing] = true
	end
	if not seen[id] then
		table.insert(id_list, id)
	end

	store.set_key(key, id_list)
end

---添加代码任务ID到文件索引
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.add_code_id(filepath, id)
	local key = key_for(NS.CODE, filepath)
	local list = store.get_key(key) or {}

	-- 转换为ID列表
	local id_list = {}
	for _, v in ipairs(list) do
		if type(v) == "string" then
			table.insert(id_list, v)
		elseif type(v) == "table" and type(v.id) == "string" then
			table.insert(id_list, v.id)
		end
	end

	-- 去重
	local seen = {}
	for _, existing in ipairs(id_list) do
		seen[existing] = true
	end
	if not seen[id] then
		table.insert(id_list, id)
	end

	store.set_key(key, id_list)
end

---从文件索引中移除TODO任务ID
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.remove_todo_id(filepath, id)
	local key = key_for(NS.TODO, filepath)
	local list = store.get_key(key) or {}

	-- 转换为ID列表并过滤
	local id_list = {}
	for _, v in ipairs(list) do
		local vid = type(v) == "string" and v or (type(v) == "table" and v.id)
		if vid and vid ~= id then
			table.insert(id_list, vid)
		end
	end

	if #id_list == 0 then
		store.delete_key(key)
	else
		store.set_key(key, id_list)
	end
end

---从文件索引中移除代码任务ID
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.remove_code_id(filepath, id)
	local key = key_for(NS.CODE, filepath)
	local list = store.get_key(key) or {}

	-- 转换为ID列表并过滤
	local id_list = {}
	for _, v in ipairs(list) do
		local vid = type(v) == "string" and v or (type(v) == "table" and v.id)
		if vid and vid ~= id then
			table.insert(id_list, vid)
		end
	end

	if #id_list == 0 then
		store.delete_key(key)
	else
		store.set_key(key, id_list)
	end
end

return M
