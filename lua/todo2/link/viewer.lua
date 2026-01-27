-- lua/todo2/link/viewer.lua
--- @module todo2.link.viewer
--- @brief 展示 TAG:ref:id（QF / LocList），基于 parser 的权威任务树

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具：从 parser 的任务树中提取所有带 id 的任务
---------------------------------------------------------------------
local function collect_tasks_with_id(todo_path)
	local parser_mod = module.get("core.parser")
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
-- 工具：获取任务的完整路径（从根任务到当前任务）
---------------------------------------------------------------------
local function get_task_path(task)
	local path_parts = {}
	local current = task

	while current do
		table.insert(path_parts, 1, current.content or "<无内容>")
		current = current.parent
	end

	if #path_parts > 0 then
		return table.concat(path_parts, " → ")
	end

	return task.content or "<无内容>"
end

---------------------------------------------------------------------
-- 工具：构建展示项（用于 QF 和 LocList）
---------------------------------------------------------------------
local function build_display_items(scope)
	local store_mod = module.get("store")
	local fm = module.get("ui.file_manager")

	local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
	local todo_files = fm.get_todo_files(project)

	local items = {}

	for _, todo_path in ipairs(todo_files) do
		local tasks = collect_tasks_with_id(todo_path)

		for _, task in ipairs(tasks) do
			local code = store_mod.get_code_link(task.id)

			-- 如果 scope 是 "buffer"，则只收集与当前buffer相关的项
			if code then
				if scope == "buffer" then
					-- 获取当前buffer路径
					local current_buf = vim.api.nvim_get_current_buf()
					local current_path = vim.api.nvim_buf_get_name(current_buf)

					-- 只收集与当前buffer相关的项
					if code.path == current_path then
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
							full_path = get_task_path(task),
							task = task, -- 保存任务对象，用于构建路径
						})
					end
				else
					-- 收集所有项
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
						full_path = get_task_path(task),
						task = task, -- 保存任务对象，用于构建路径
					})
				end
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
-- LocList：展示当前 buffer 的 TAG（带父子结构）
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	local store_mod = module.get("store")
	local code_links = store_mod.find_code_links_by_file(path)

	if #code_links == 0 then
		vim.notify("当前 buffer 没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	-- 获取所有带父子结构的展示项（仅限当前buffer）
	local items = build_display_items("buffer")

	if #items == 0 then
		vim.notify("当前 buffer 没有有效的 TAG 标记", vim.log.levels.INFO)
		return
	end

	local loc = {}

	for _, item in ipairs(items) do
		-- 构建缩进前缀（根据层级）
		local prefix = ""
		if item.depth > 0 then
			prefix = string.rep("  ", item.depth - 1) .. "󱞩 "
		end

		-- 构建显示文本
		local text
		if item.full_path then
			-- 显示完整的父子路径
			text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, item.full_path)
		else
			-- 回退到原始文本
			text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, item.todo_text or "<无对应 TODO 项>")
		end

		table.insert(loc, {
			filename = item.code_path,
			lnum = item.code_line,
			text = text,
		})
	end

	vim.fn.setloclist(0, loc, "r")
	vim.cmd("lopen")
end

---------------------------------------------------------------------
-- QF：展示整个项目的 TAG（父子结构）
---------------------------------------------------------------------
function M.show_project_links_qf()
	local items = build_display_items("project")
	if #items == 0 then
		vim.notify("项目中没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	local qf = {}

	for _, item in ipairs(items) do
		-- 构建缩进前缀（根据层级）
		local prefix = ""
		if item.depth > 0 then
			prefix = string.rep("  ", item.depth - 1) .. "󱞩 "
		end

		-- 构建显示文本
		local text
		if item.full_path then
			-- 显示完整的父子路径
			text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, item.full_path)
		else
			-- 回退到原始文本
			text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, item.todo_text or "<无内容>")
		end

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
