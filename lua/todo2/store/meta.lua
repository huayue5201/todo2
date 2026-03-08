-- lua/todo2/store/meta.lua
-- 极简版：所有统计通过一次扫描获得

local M = {}

local store = require("todo2.store.nvim_store")
local types = require("todo2.store.types")
local link = require("todo2.store.link")

---------------------------------------------------------------------
-- 扫描所有链接并返回统计
---------------------------------------------------------------------
function M.get_stats()
	local all_todo = link.get_all_todo()
	local all_code = link.get_all_code()

	local stats = {
		total_links = 0,
		todo_links = 0,
		code_links = 0,
		archived_todo_links = 0,
		archived_code_links = 0,
	}

	for _, todo in pairs(all_todo) do
		stats.todo_links = stats.todo_links + 1
		if types.is_archived_status(todo.status) then
			stats.archived_todo_links = stats.archived_todo_links + 1
		end
	end

	for _, code in pairs(all_code) do
		stats.code_links = stats.code_links + 1
		if types.is_archived_status(code.status) then
			stats.archived_code_links = stats.archived_code_links + 1
		end
	end

	stats.total_links = stats.todo_links + stats.code_links
	return stats
end

---------------------------------------------------------------------
-- 初始化（可重算）
---------------------------------------------------------------------
function M.init()
	return M.get_stats()
end

return M
