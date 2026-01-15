-- lua/todo2/link/viewer.lua
--- @module todo2.link.viewer
--- @brief 展示 TAG:ref:id（QF / LocList），支持任务树排序，跳转只跳代码

local M = {}

local utf8 = require("todo2.utf8")
---------------------------------------------------------------------
-- 常量：TODO 文本截断上限
---------------------------------------------------------------------
local TODO_PREVIEW_MAX_LEN = 100

---------------------------------------------------------------------
-- 懒加载 store
---------------------------------------------------------------------
local store
local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

---------------------------------------------------------------------
-- 扫描代码文件中的 TAG:ref:id（不依赖数据库）
---------------------------------------------------------------------
local function scan_code_tags_in_file(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end

	local results = {}

	for lnum, line in ipairs(lines) do
		local tag, id = line:match("([A-Z][A-Z0-9_]+):ref:(%w+)")
		if id then
			table.insert(results, {
				id = id,
				tag = tag,
				path = path,
				line = lnum,
			})
		end
	end

	return results
end

---------------------------------------------------------------------
-- 构建任务树（用于排序 + 父子关系）
---------------------------------------------------------------------
local function collect_task_tree()
	local store_mod = get_store()
	local all_todo = store_mod.get_all_todo_links()

	local tasks_by_id = {}
	local ordered_ids = {}

	local core = require("todo2.core")

	-- 按 TODO 文件分组
	local files = {}
	for id, link in pairs(all_todo) do
		files[link.path] = true
	end

	for path, _ in pairs(files) do
		local ok, lines = pcall(vim.fn.readfile, path)
		if ok then
			local tasks = core.parse_tasks(lines)
			local roots = core.get_root_tasks(tasks)

			local function visit(t, depth)
				local line = lines[t.line_num] or ""
				local id = line:match("{#(%w+)}")
				if id then
					tasks_by_id[id] = {
						depth = depth,
						todo_path = path,
						todo_line = t.line_num,
						task = t,
					}
					table.insert(ordered_ids, id)
				end
				for _, child in ipairs(t.children or {}) do
					visit(child, depth + 1)
				end
			end

			for _, root in ipairs(roots) do
				visit(root, 0)
			end
		end
	end

	return tasks_by_id, ordered_ids
end

---------------------------------------------------------------------
-- 构建展示项（父子结构 + 代码跳转）
---------------------------------------------------------------------
local function build_display_items()
	local store_mod = get_store()
	local tasks_by_id, ordered_ids = collect_task_tree()

	-- 扫描所有代码文件中的 TAG
	local code_tags = {}
	for id, link in pairs(store_mod.get_all_code_links()) do
		local tags = scan_code_tags_in_file(link.path)
		for _, t in ipairs(tags) do
			code_tags[t.id] = t
		end
	end

	local items = {}

	for _, id in ipairs(ordered_ids) do
		local code = code_tags[id]
		if code then
			local task = tasks_by_id[id]

			table.insert(items, {
				id = id,
				tag = code.tag,
				depth = task.depth,
				code_path = code.path,
				code_line = code.line,
				todo_path = task.todo_path,
				todo_line = task.todo_line,
			})
		end
	end

	return items
end

---------------------------------------------------------------------
-- LocList：展示当前 buffer 的 TAG（方法名保持不变）
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	local tags = scan_code_tags_in_file(path)
	if #tags == 0 then
		vim.notify("当前 buffer 没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	local store_mod = get_store()
	local loc = {}

	for _, item in ipairs(tags) do
		local todo = store_mod.get_todo_link(item.id, { force_relocate = true })

		local todo_text = nil
		if todo then
			local ok, lines = pcall(vim.fn.readfile, todo.path)
			if ok then
				local raw = lines[todo.line] or ""

				todo_text = raw:gsub("%[.%]", ""):gsub("{#%w+}", ""):gsub("^%s*[-*]%s*", "")
				todo_text = vim.trim(todo_text)

				if #todo_text > TODO_PREVIEW_MAX_LEN then
					todo_text = utf8.sub(todo_text, TODO_PREVIEW_MAX_LEN) .. "..."
				end
			end
		end

		if not todo_text or todo_text == "" then
			todo_text = "<无对应 TODO 项>"
		end

		table.insert(loc, {
			filename = item.path,
			lnum = item.line,
			text = string.format("[%s %s] %s", item.tag, item.id, todo_text),
		})
	end

	vim.fn.setloclist(0, loc, "r")
	vim.cmd("lopen")
end

---------------------------------------------------------------------
-- QF：展示整个项目的 TAG（方法名保持不变）
---------------------------------------------------------------------
function M.show_project_links_qf()
	local items = build_display_items()
	local qf = {}

	for _, item in ipairs(items) do
		local prefix = string.rep("  ", item.depth)
		if item.depth > 0 then
			prefix = prefix .. "↳ "
		end

		local todo_text = nil

		if item.todo_path and item.todo_line then
			local ok, todo_lines = pcall(vim.fn.readfile, item.todo_path)
			if ok then
				local raw = todo_lines[item.todo_line] or ""

				todo_text = raw:gsub("%[.%]", ""):gsub("{#%w+}", ""):gsub("^%s*[-*]%s*", "")
				todo_text = vim.trim(todo_text)

				if #todo_text > TODO_PREVIEW_MAX_LEN then
					todo_text = utf8.sub(todo_text, TODO_PREVIEW_MAX_LEN) .. "..."
				end
			end
		end

		if not todo_text or todo_text == "" then
			todo_text = "<无对应 TODO 项>"
		end

		local text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, todo_text)

		table.insert(qf, {
			filename = item.code_path,
			lnum = item.code_line,
			text = text,
		})
	end

	if #qf == 0 then
		vim.notify("项目中没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	vim.fn.setqflist(qf, "r")
	vim.cmd("copen")
end
return M
