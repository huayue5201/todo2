-- lua/todo2/link/preview.lua
local M = {}

local parser = require("todo2.core.parser")

-- ✅ 新写法（lazy require）
local store

local function get_store()
	if not store then
		store = require("todo2.store")
	end
	return store
end

function M.preview_todo()
	-- 当前行：TAG:ref:ID
	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return
	end

	-- 获取 TODO 链接
	local link = store.get_todo_link(id)
	if not link then
		return
	end

	-- 读取 TODO 文件
	local ok, lines = pcall(vim.fn.readfile, link.path)
	if not ok then
		return
	end

	----------------------------------------------------------------------
	-- ⭐ 使用持久结构决定展示范围
	----------------------------------------------------------------------

	local struct = store.get_task_structure(id)
	if not struct then
		return
	end

	-- 如果是子任务 → 展示父任务的整个子树
	local root_id = struct.parent_id or id
	local root_link = store.get_todo_link(root_id)
	if not root_link then
		return
	end

	-- 获取根任务的结构
	local root_struct = store.get_task_structure(root_id)
	if not root_struct then
		return
	end

	-- 收集所有子任务（包括自己）
	local all_ids = {}
	local function collect(id)
		table.insert(all_ids, id)
		local s = store.get_task_structure(id)
		if s and s.children then
			for _, cid in ipairs(s.children) do
				collect(cid)
			end
		end
	end
	collect(root_id)

	-- 找到这些任务的最小行号和最大行号
	local min_line = math.huge
	local max_line = -1

	for _, tid in ipairs(all_ids) do
		local tlink = store.get_todo_link(tid)
		if tlink then
			min_line = math.min(min_line, tlink.line)
			max_line = math.max(max_line, tlink.line)
		end
	end

	if min_line == math.huge or max_line == -1 then
		return
	end

	----------------------------------------------------------------------
	-- ⭐ 收集展示内容
	----------------------------------------------------------------------

	local preview_lines = {}
	for i = min_line, max_line do
		table.insert(preview_lines, lines[i])
	end

	local content = table.concat(preview_lines, "\n")

	----------------------------------------------------------------------
	-- ⭐ 打开浮窗
	----------------------------------------------------------------------

	vim.lsp.util.open_floating_preview({ content }, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

function M.preview_code()
	local line = vim.fn.getline(".")
	local id = line:match("{#(%w+)}")

	if not id then
		return
	end

	local link = get_store().get_code_link(id)
	if not link then
		return
	end

	local ok, lines = pcall(vim.fn.readfile, link.path)
	if not ok then
		return
	end

	local start_line = math.max(1, link.line - 3)
	local end_line = math.min(#lines, link.line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		table.insert(context_lines, lines[i])
	end

	local content = table.concat(context_lines, "\n")

	vim.lsp.util.open_floating_preview({ content }, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

return M
