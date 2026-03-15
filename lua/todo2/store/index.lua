-- lua/todo2/store/index.lua
-- 修复循环依赖：不再 require("todo2.store.link")

local M = {}

local store = require("todo2.store.nvim_store")

---------------------------------------------------------------------
-- 工具：规范化路径
---------------------------------------------------------------------
local function normalize(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

-- 保持兼容
M._normalize_path = normalize
---------------------------------------------------------------------
-- 内部：索引命名空间
---------------------------------------------------------------------
local NS = {
	TODO = "todo.index.file_to_todo.",
	CODE = "todo.index.file_to_code.",
}

local function key_for(ns, filepath)
	return ns .. normalize(filepath)
end

---------------------------------------------------------------------
-- 添加 ID 到索引（由 link.update_xxx 调用）
---------------------------------------------------------------------
function M._add_id_to_file_index(ns, filepath, id)
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

---------------------------------------------------------------------
-- 从索引移除 ID（由 link.update_xxx 调用）
---------------------------------------------------------------------
function M._remove_id_from_file_index(ns, filepath, id)
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
-- 获取某文件的 TODO 链接（只读 store，不 require link）
-- ⭐ 修改：使用新的内部格式键名 "todo.links.internal."
---------------------------------------------------------------------
function M.find_todo_links_by_file(filepath)
	local key = key_for(NS.TODO, filepath)
	local ids = store.get_key(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		-- 使用新的内部格式键名
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

---------------------------------------------------------------------
-- 获取某文件的 CODE 链接
-- ⭐ 修改：使用新的内部格式键名 "todo.links.internal."
---------------------------------------------------------------------
function M.find_code_links_by_file(filepath)
	local key = key_for(NS.CODE, filepath)
	local ids = store.get_key(key) or {}
	local results = {}

	for _, id in ipairs(ids) do
		-- 使用新的内部格式键名
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

---------------------------------------------------------------------
-- 获取某文件的所有链接
---------------------------------------------------------------------
function M.find_all_links_by_file(filepath)
	local todo = M.find_todo_links_by_file(filepath)
	local code = M.find_code_links_by_file(filepath)

	local all = {}
	for _, v in ipairs(todo) do
		table.insert(all, v)
	end
	for _, v in ipairs(code) do
		table.insert(all, v)
	end

	table.sort(all, function(a, b)
		-- 按行号排序，优先使用 TODO 行号，如果没有则使用 CODE 行号
		local line_a = (a.locations.todo and a.locations.todo.line) or (a.locations.code and a.locations.code.line) or 0
		local line_b = (b.locations.todo and b.locations.todo.line) or (b.locations.code and b.locations.code.line) or 0
		return line_a < line_b
	end)

	return all
end

---------------------------------------------------------------------
-- 新增辅助函数：检查文件是否有链接
---------------------------------------------------------------------
function M.has_links(filepath)
	local todo_key = key_for(NS.TODO, filepath)
	local code_key = key_for(NS.CODE, filepath)

	local todo_ids = store.get_key(todo_key) or {}
	local code_ids = store.get_key(code_key) or {}

	return #todo_ids > 0 or #code_ids > 0
end

---------------------------------------------------------------------
-- 新增辅助函数：获取文件中的链接数量
---------------------------------------------------------------------
function M.get_link_count(filepath)
	local todo_key = key_for(NS.TODO, filepath)
	local code_key = key_for(NS.CODE, filepath)

	local todo_ids = store.get_key(todo_key) or {}
	local code_ids = store.get_key(code_key) or {}

	return {
		todo = #todo_ids,
		code = #code_ids,
		total = #todo_ids + #code_ids,
	}
end

return M
