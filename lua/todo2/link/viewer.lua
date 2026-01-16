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
-- 统一 TODO 文本解析（使用 relocate + UTF8 安全截断）
---------------------------------------------------------------------
local function get_todo_text(id, max_len)
	local store_mod = get_store()
	local link = store_mod.get_todo_link(id, { force_relocate = true })
	if not link then
		return nil
	end

	-- 直接读取 TODO 文件（轻量、稳定）
	local ok, lines = pcall(vim.fn.readfile, link.path)
	if not ok then
		return nil
	end

	local raw = lines[link.line]
	if not raw then
		return nil
	end

	-- 去掉状态图标
	local text = raw:gsub("%[.%]", "")
	-- 去掉 {#id}
	text = text:gsub("{#%w+}", "")
	-- 去掉 markdown 前缀
	text = text:gsub("^%s*[-*]%s*", "")
	text = vim.trim(text)

	max_len = max_len or TODO_PREVIEW_MAX_LEN
	if #text > max_len then
		text = utf8.sub(text, max_len) .. "..."
	end

	return text
end
---------------------------------------------------------------------
-- 使用 store 的结构树构建任务树（不重复解析）
---------------------------------------------------------------------
local function collect_task_tree()
	local store_mod = get_store()
	local all = store_mod.get_all_todo_links()

	local tasks_by_id = {}
	local ordered_ids = {}

	for id, link in pairs(all) do
		local struct = store_mod.get_task_structure(id)
		if struct then
			tasks_by_id[id] = {
				depth = struct.depth or 0,
				todo_path = link.path,
				todo_line = link.line,
			}
			table.insert(ordered_ids, id)
		end
	end

	-- 按深度排序（父任务在前）
	table.sort(ordered_ids, function(a, b)
		return (tasks_by_id[a].depth or 0) < (tasks_by_id[b].depth or 0)
	end)

	return tasks_by_id, ordered_ids
end

---------------------------------------------------------------------
-- 构建展示项（父子结构 + 代码跳转）
---------------------------------------------------------------------
local function build_display_items()
	local store_mod = get_store()
	local tasks_by_id, ordered_ids = collect_task_tree()

	local items = {}

	for _, id in ipairs(ordered_ids) do
		local code = store_mod.get_code_link(id)
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
				todo_text = get_todo_text(id, TODO_PREVIEW_MAX_LEN),
			})
		end
	end

	return items
end

---------------------------------------------------------------------
-- LocList：展示当前 buffer 的 TAG
---------------------------------------------------------------------
function M.show_buffer_links_loclist()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p")

	local store_mod = get_store()
	local tags = {}

	-- 使用 store 的 code_link，而不是重新扫描文件
	for id, link in pairs(store_mod.get_all_code_links()) do
		if link.path == path then
			table.insert(tags, {
				id = id,
				tag = link.tag,
				path = link.path,
				line = link.line,
			})
		end
	end

	if #tags == 0 then
		vim.notify("当前 buffer 没有 TAG 标记", vim.log.levels.INFO)
		return
	end

	local loc = {}

	for _, item in ipairs(tags) do
		local todo_text = get_todo_text(item.id, TODO_PREVIEW_MAX_LEN)
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
-- QF：展示整个项目的 TAG（父子结构）
---------------------------------------------------------------------
function M.show_project_links_qf()
	local items = build_display_items()
	local qf = {}

	for _, item in ipairs(items) do
		local prefix = string.rep(" ", item.depth)
		if item.depth > 0 then
			prefix = prefix .. "↳"
		end

		local text = string.format("%s[%s %s] %s", prefix, item.tag, item.id, item.todo_text or "<无对应 TODO 项>")

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
