-- lua/todo2/store/index.lua
--- @module todo2.store.index
--- 文件索引管理

local M = {}

local store = require("todo2.store.nvim_store")

--- 规范化文件路径
function M._normalize_path(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

--- 添加ID到文件索引
function M._add_id_to_file_index(index_ns, filepath, id)
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
	local list = store.get_key(key) or {}

	-- 避免重复
	for _, existing in ipairs(list) do
		if existing == id then
			return
		end
	end

	table.insert(list, id)
	store.set_key(key, list)
end

--- 从文件索引移除ID
function M._remove_id_from_file_index(index_ns, filepath, id)
	local norm = M._normalize_path(filepath)
	local key = string.format("%s.%s", index_ns, norm)
	local list = store.get_key(key)

	if not list then
		return
	end

	-- 过滤掉要删除的ID
	local new_list = {}
	for _, existing in ipairs(list) do
		if existing ~= id then
			table.insert(new_list, existing)
		end
	end

	-- 保存或删除
	if #new_list == 0 then
		store.delete_key(key)
	else
		store.set_key(key, new_list)
	end
end

--- 查找TODO链接的文件索引
function M.find_todo_links_by_file(filepath)
	local norm = M._normalize_path(filepath)
	local key = "todo.index.file_to_todo." .. norm
	local ids = store.get_key(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = store.get_key("todo.links.todo." .. id)
		if link then
			table.insert(results, link)
		end
	end

	-- 按行号排序
	table.sort(results, function(a, b)
		return (a.line or 0) < (b.line or 0)
	end)

	return results
end

--- 查找代码链接的文件索引
function M.find_code_links_by_file(filepath)
	local norm = M._normalize_path(filepath)
	local key = "todo.index.file_to_code." .. norm
	local ids = store.get_key(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		local link = store.get_key("todo.links.code." .. id)
		if link then
			table.insert(results, link)
		end
	end

	-- 按行号排序
	table.sort(results, function(a, b)
		return (a.line or 0) < (b.line or 0)
	end)

	return results
end

return M
