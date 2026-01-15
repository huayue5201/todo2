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
	local line = vim.fn.getline(".")
	local tag, id = line:match("(%u+):ref:(%w+)")
	if not id then
		return
	end

	local link = get_store().get_todo_link(id)
	if not link then
		return
	end

	-- 读取文件
	local ok, lines = pcall(vim.fn.readfile, link.path)
	if not ok then
		return
	end

	----------------------------------------------------------------------
	-- ⭐ 使用 parser.lua 解析任务树
	----------------------------------------------------------------------

	local tasks = parser.parse_tasks(lines)

	-- 找到当前任务
	local current
	for _, t in ipairs(tasks) do
		if t.line_num == link.line then
			current = t
			break
		end
	end

	if not current then
		return
	end

	----------------------------------------------------------------------
	-- ⭐ 根据父子关系决定展示范围
	----------------------------------------------------------------------

	local root = current.parent or current
	local start_line = root.line_num
	local end_line = root.line_num

	if root.children and #root.children > 0 then
		local last_child = root.children[#root.children]
		end_line = last_child.line_num
	end

	----------------------------------------------------------------------
	-- ⭐ 收集展示内容
	----------------------------------------------------------------------

	local preview_lines = {}
	for i = start_line, end_line do
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
