-- lua/todo2/store/index.lua
--- @module todo2.store.index

local M = {}

---------------------------------------------------------------------
-- 依赖模块
---------------------------------------------------------------------
local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")

---------------------------------------------------------------------
-- 内部配置常量（新增：消除魔法字符串）
---------------------------------------------------------------------
local LINK_CONFIG = {
	todo = {
		index_ns = "todo.index.file_to_todo",
		link_ns = "todo.links.todo",
	},
	code = {
		index_ns = "todo.index.file_to_code",
		link_ns = "todo.links.code",
	},
}

--- 规范化文件路径
--- @param path string
--- @return string
function M._normalize_path(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

--- 添加ID到文件索引
--- @param index_ns string
--- @param filepath string
--- @param id string
local function add_id_to_file_index(index_ns, filepath, id)
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
	local list = store.get_key(key) or {}

	for _, existing in ipairs(list) do
		if existing == id then
			return
		end
	end

	table.insert(list, id)
	store.set_key(key, list)
end

--- 从文件索引移除ID
--- @param index_ns string
--- @param filepath string
--- @param id string
local function remove_id_from_file_index(index_ns, filepath, id)
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
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
-- 通用查找函数（新增：抽象重复逻辑）
---------------------------------------------------------------------
local function _find_links_by_file(filepath, link_type)
	local cfg = LINK_CONFIG[link_type]
	local norm = M._normalize_path(filepath)
	local ids = store.get_key(cfg.index_ns .. "." .. norm) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = store.get_key(cfg.link_ns .. "." .. id)
		if link then
			table.insert(results, link)
		end
	end

	return results
end

--- 查找TODO链接的文件索引
--- @param filepath string
--- @return table[]
function M.find_todo_links_by_file(filepath)
	return _find_links_by_file(filepath, "todo")
end

--- 查找代码链接的文件索引
--- @param filepath string
--- @return table[]
function M.find_code_links_by_file(filepath)
	return _find_links_by_file(filepath, "code")
end

--- 重建索引（用于修复）
--- @param link_type string
function M.rebuild_index(link_type)
	local prefix = link_type == types.LINK_TYPES.TODO_TO_CODE and "todo.links.todo" or "todo.links.code"
	local index_ns = link_type == types.LINK_TYPES.TODO_TO_CODE and "todo.index.file_to_todo"
		or "todo.index.file_to_code"

	-- 清除现有索引
	local keys = store.get_namespace_keys(index_ns)
	for _, key in ipairs(keys) do
		store.delete_key(key)
	end

	-- 重新构建索引
	local ids = store.get_namespace_keys(prefix)
	for _, id in ipairs(ids) do
		local link = store.get_key(prefix .. "." .. id)
		if link and link.path then
			add_id_to_file_index(index_ns, link.path, id)
		end
	end

	return true
end

M._add_id_to_file_index = add_id_to_file_index
M._remove_id_from_file_index = remove_id_from_file_index

return M
