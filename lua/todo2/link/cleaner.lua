-- lua/todo2/link/cleaner.lua
local M = {}

local store

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

---------------------------------------------------------------------
-- 工具函数：文件是否存在
---------------------------------------------------------------------
local function file_exists(path)
	return vim.fn.filereadable(path) == 1
end

---------------------------------------------------------------------
-- 工具函数：行号是否越界
---------------------------------------------------------------------
local function line_valid(path, line)
	if not file_exists(path) then
		return false
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return false
	end
	return line >= 1 and line <= #lines
end

---------------------------------------------------------------------
-- ⭐ 自动清理所有无效链接
---------------------------------------------------------------------
function M.cleanup_all_links()
	local store_mod = get_store()

	local all_code = store_mod.get_all_code_links()
	local all_todo = store_mod.get_all_todo_links()

	-----------------------------------------------------------------
	-- 1. 删除无头 TODO（没有 code link）
	-----------------------------------------------------------------
	for id, todo in pairs(all_todo) do
		if not all_code[id] then
			store_mod.delete_todo_link(id)
		end
	end

	-----------------------------------------------------------------
	-- 2. 删除无头 CODE（没有 todo link）
	-----------------------------------------------------------------
	for id, code in pairs(all_code) do
		if not all_todo[id] then
			store_mod.delete_code_link(id)
		end
	end

	-----------------------------------------------------------------
	-- 3. 删除不存在文件的链接
	-----------------------------------------------------------------
	for id, code in pairs(store_mod.get_all_code_links()) do
		if not file_exists(code.path) then
			store_mod.delete_code_link(id)
		end
	end

	for id, todo in pairs(store_mod.get_all_todo_links()) do
		if not file_exists(todo.path) then
			store_mod.delete_todo_link(id)
		end
	end

	-----------------------------------------------------------------
	-- 4. 删除越界行号的链接
	-----------------------------------------------------------------
	for id, code in pairs(store_mod.get_all_code_links()) do
		if not line_valid(code.path, code.line) then
			store_mod.delete_code_link(id)
		end
	end

	for id, todo in pairs(store_mod.get_all_todo_links()) do
		if not line_valid(todo.path, todo.line) then
			store_mod.delete_todo_link(id)
		end
	end
end

return M
