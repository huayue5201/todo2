-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（基于 parser 权威任务树）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 懒加载依赖
---------------------------------------------------------------------

local store
local function get_store()
	if not store then
		store = module.get("store")
	end
	return store
end

local function get_parser()
	return module.get("core.parser")
end

---------------------------------------------------------------------
-- ⭐ 预览 TODO（基于 parser 权威任务树）
---------------------------------------------------------------------
function M.preview_todo()
	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return
	end

	local link = get_store().get_todo_link(id)
	if not link then
		return
	end

	local todo_path = link.path
	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		return
	end

	-----------------------------------------------------------------
	-- 1. 使用 parser.parse_file 获取任务树
	-----------------------------------------------------------------
	local parser = get_parser()
	local tasks, roots = parser.parse_file(todo_path)

	-- 找到当前任务
	local current = nil
	for _, t in ipairs(tasks) do
		if t.id == id then
			current = t
			break
		end
	end
	if not current then
		return
	end

	-----------------------------------------------------------------
	-- 2. 找到根任务（如果有父任务，则展示整个父任务子树）
	-----------------------------------------------------------------
	local root = current
	while root.parent do
		root = root.parent
	end

	-----------------------------------------------------------------
	-- 3. 收集整个子树的所有任务 ID
	-----------------------------------------------------------------
	local all = {}
	local function collect(t)
		table.insert(all, t)
		for _, c in ipairs(t.children or {}) do
			collect(c)
		end
	end
	collect(root)

	-----------------------------------------------------------------
	-- 4. 计算展示范围（最小行号 → 最大行号）
	-----------------------------------------------------------------
	local min_line = math.huge
	local max_line = -1

	for _, t in ipairs(all) do
		if t.line_num then
			min_line = math.min(min_line, t.line_num)
			max_line = math.max(max_line, t.line_num)
		end
	end

	if min_line == math.huge or max_line == -1 then
		return
	end

	-----------------------------------------------------------------
	-- 5. 收集展示内容
	-----------------------------------------------------------------
	local preview_lines = {}
	for i = min_line, max_line do
		table.insert(preview_lines, lines[i])
	end

	local content = table.concat(preview_lines, "\n")

	-----------------------------------------------------------------
	-- 6. 打开浮窗
	-----------------------------------------------------------------
	vim.lsp.util.open_floating_preview({ content }, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

---------------------------------------------------------------------
-- ⭐ 预览代码（保持原逻辑）
---------------------------------------------------------------------
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
