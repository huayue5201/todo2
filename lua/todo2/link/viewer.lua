-- lua/todo2/link/viewer.lua
--- @module todo2.link.viewer
--- @brief 展示 TAG:ref:id（QF / LocList），基于 parser 的权威任务树

local M = {}

local utf8 = require("todo2.utf8")

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local parser
local file_manager

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

local function get_parser()
	if not parser then
		parser = require("todo2.core.parser")
	end
	return parser
end

local function get_file_manager()
	if not file_manager then
		file_manager = require("todo2.ui.file_manager")
	end
	return file_manager
end

---------------------------------------------------------------------
-- 工具：从 parser 的任务树中提取所有带 id 的任务
---------------------------------------------------------------------

local function collect_tasks_with_id(todo_path)
	local parser_mod = get_parser()
	local tasks, roots = parser_mod.parse_file(todo_path)

	local result = {}
	for _, task in ipairs(tasks) do
		if task.id then
			table.insert(result, task)
		end
	end
	return result
end

---------------------------------------------------------------------
-- 工具：构建展示项（用于 QF）
---------------------------------------------------------------------

local function build_project_items()
	local store_mod = get_store()
	local fm = get_file_manager()

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local items = {}

	for _, todo_path in ipairs(todo_files) do
		local tasks = collect_tasks_with_id(todo_path)

		for _, task in ipairs(tasks) do
			local code = store_mod.get_code_link(task.id)
			if code then
				table.insert(items, {
					id = task.id,
					tag = code.tag,
					depth = task.level,
					order = task.order,
					code_path = code.path,
					code_line = code.line,
					todo_path = todo_path,
					todo_line = task.line_num,
					todo_text = task.content,
				})
			end
		end
	end

	-- 排序：按文件 → depth → order
	table.sort(items, function(a, b)
		if a.todo_path ~= b.todo_path then
			return a.todo_path < b.todo_path
		end
		if a.depth ~= b.depth then
			return a.depth < b.depth
		end
		return (a.order or 0) < (b.order or 0)
	end)

	return items
end

---------------------------------------------------------------------
-- LocList：展示当前 buffer 的 TAG
---------------------------------------------------------------------

function M.show_buffer_links_loclist()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	local store_mod = get_store()
	local code_links = store_mod.find_code_links_by_file(path)

	if #code_links == 0 then
		vim.notify("当前 buffer 没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	local loc = {}

	for _, link in ipairs(code_links) do
		local todo = store_mod.get_todo_link(link.id)
		local todo_text = todo and todo.content or "<无对应 TODO 项>"

		table.insert(loc, {
			filename = link.path,
			lnum = link.line,
			text = string.format("[%s %s] %s", link.tag, link.id, todo_text),
		})
	end

	vim.fn.setloclist(0, loc, "r")
	vim.cmd("lopen")
end

---------------------------------------------------------------------
-- QF：展示整个项目的 TAG（父子结构）
---------------------------------------------------------------------

function M.show_project_links_qf()
	local items = build_project_items()
	if #items == 0 then
		vim.notify("项目中没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	local qf = {}

	for _, item in ipairs(items) do
		local prefix = string.rep(" ", item.depth)
		if item.depth > 0 then
			prefix = prefix .. "↳"
		end

		local text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, item.todo_text or "<无内容>")

		table.insert(qf, {
			filename = item.code_path,
			lnum = item.code_line,
			text = text,
		})
	end

	vim.fn.setqflist(qf, "r")
	vim.cmd("copen")
end

return M
