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
}

---------------------------------------------------------------------
-- 类型定义
---------------------------------------------------------------------

---@class IndexTask
---@field id string 任务ID
---@field core table 核心数据
---@field timestamps table 时间戳
---@field locations table<string, table> 位置信息

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
	-- 复用 store/task/core 的权威加载器（含位置校验与字段清洗）
	return require("todo2.store.task.core").get_task(id)
end

---------------------------------------------------------------------
-- 文件任务查询
---------------------------------------------------------------------

---获取文件中的所有任务ID
---唯一真源是 file_to_todo 倒排索引（原 file_tree 派生缓存会造成两份真源，已移除）
---@param path string 文件路径
---@return string[]
function M.get_file_task_ids(path)
	if not path or path == "" then
		return {}
	end
	return store.get_key(key_for(NS.TODO, path)) or {}
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

	-- 加载任务（索引为纯字符串 ID 数组）
	for _, id in ipairs(ids) do
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

	-- 加载任务（索引为纯字符串 ID 数组）
	for _, id in ipairs(ids) do
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

---查找代码文件中指定行的任务
---@param filepath string 文件路径
---@param line number 行号
---@return IndexTask|nil
function M.find_code_task_at_line(filepath, line)
	if not filepath or filepath == "" or not line then
		return nil
	end
	local tasks = M.find_code_links_by_file(filepath)
	for _, task in ipairs(tasks) do
		if task.locations and task.locations.code and task.locations.code.line == line then
			return task
		end
	end
	return nil
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

	-- 去重后追加
	if not vim.tbl_contains(list, id) then
		table.insert(list, id)
	end

	store.set_key(key, list)
end

---添加代码任务ID到文件索引
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.add_code_id(filepath, id)
	local key = key_for(NS.CODE, filepath)
	local list = store.get_key(key) or {}

	-- 去重后追加
	if not vim.tbl_contains(list, id) then
		table.insert(list, id)
	end

	store.set_key(key, list)
end

---从文件索引中移除TODO任务ID
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.remove_todo_id(filepath, id)
	local key = key_for(NS.TODO, filepath)
	local list = store.get_key(key) or {}

	local new_list = {}
	for _, v in ipairs(list) do
		if v ~= id then
			table.insert(new_list, v)
		end
	end

	if #new_list == 0 then
		store.delete_key(key)
	else
		store.set_key(key, new_list)
	end
end

---从文件索引中移除代码任务ID
---@param filepath string 文件路径
---@param id string 任务ID
function M._internal.remove_code_id(filepath, id)
	local key = key_for(NS.CODE, filepath)
	local list = store.get_key(key) or {}

	local new_list = {}
	for _, v in ipairs(list) do
		if v ~= id then
			table.insert(new_list, v)
		end
	end

	if #new_list == 0 then
		store.delete_key(key)
	else
		store.set_key(key, new_list)
	end
end

return M
