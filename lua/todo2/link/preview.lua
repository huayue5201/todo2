-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（完整任务树，不受 context_split 影响）

local M = {}

---------------------------------------------------------------------
-- 直接依赖（明确、可靠）
---------------------------------------------------------------------
local parser = require("todo2.core.parser")
local store_link = require("todo2.store.link")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local TODO_REF_PATTERN = "(%u+):ref:(%w+)"
local CODE_ANCHOR_PATTERN = "{#(%w+)}"

---------------------------------------------------------------------
-- 获取文件类型（使用 Neovim 内置函数）
---------------------------------------------------------------------
--- 根据文件路径获取文件类型
--- @param path string 文件路径
--- @return string 文件类型
local function get_filetype(path)
	-- 创建一个临时缓冲区来检测文件类型
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, path)
	vim.bo[bufnr].filetype = vim.filetype.match({ buf = bufnr }) or vim.filetype.match({ filename = path }) or "text"
	local ft = vim.bo[bufnr].filetype
	vim.api.nvim_buf_delete(bufnr, { force = true })
	return ft
end

---------------------------------------------------------------------
-- 获取文件名（从路径中）
---------------------------------------------------------------------
--- 从文件路径中获取文件名
--- @param path string 文件路径
--- @return string 文件名
local function get_filename(path)
	return path:match("([^/]+)$") or path
end

---------------------------------------------------------------------
-- 预览 TODO（始终使用完整任务树）
---------------------------------------------------------------------
function M.preview_todo()
	local line = vim.fn.getline(".")
	local tag, id = line:match(TODO_REF_PATTERN)
	if not id then
		return
	end

	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local link = store_link.get_todo(id, { verify_line = true })
	if not link then
		vim.notify("未找到对应的 TODO 链接，ID: " .. id, vim.log.levels.WARN)
		return
	end

	local todo_path = link.path
	local ok, lines = pcall(vim.fn.readfile, todo_path)
	if not ok then
		vim.notify("无法读取文件: " .. todo_path, vim.log.levels.ERROR)
		return
	end

	-- 使用完整树解析，确保能定位任何任务（无论是否归档）
	local _, _, id_to_task = parser.parse_file(todo_path)
	local current = id_to_task and id_to_task[id]
	if not current then
		vim.notify("任务树中未找到 ID 为 " .. id .. " 的任务", vim.log.levels.WARN)
		return
	end

	-- 找到根任务（展示整个父任务子树）
	local root = current
	while root.parent do
		root = root.parent
	end

	-- 收集整个子树的所有任务
	local all = {}
	local function collect(t)
		table.insert(all, t)
		for _, c in ipairs(t.children or {}) do
			collect(c)
		end
	end
	collect(root)

	-- 计算展示范围
	local min_line = math.huge
	local max_line = -1
	for _, t in ipairs(all) do
		if t.line_num then
			min_line = math.min(min_line, t.line_num)
			max_line = math.max(max_line, t.line_num)
		end
	end

	if min_line == math.huge or max_line == -1 then
		vim.notify("无法确定任务行范围", vim.log.levels.WARN)
		return
	end

	-- 收集展示内容
	local preview_lines = {}
	for i = min_line, max_line do
		preview_lines[#preview_lines + 1] = lines[i] or ""
	end

	-- 获取文件名作为标题
	local filename = get_filename(todo_path)

	-- TODO 预览使用 markdown
	vim.lsp.util.open_floating_preview(preview_lines, "markdown", {
		border = "rounded",
		focusable = true,
		wrap_at = 80,
		title = filename,
	})
end

---------------------------------------------------------------------
-- 预览代码（使用 Neovim 内置文件类型检测）
---------------------------------------------------------------------
function M.preview_code()
	local line = vim.fn.getline(".")
	local id = line:match(CODE_ANCHOR_PATTERN)
	if not id then
		return
	end

	if not store_link then
		vim.notify("无法获取 store.link 模块", vim.log.levels.ERROR)
		return
	end

	local link = store_link.get_code(id, { verify_line = true })
	if not link then
		vim.notify("未找到对应的代码锚点，ID: " .. id, vim.log.levels.WARN)
		return
	end

	local ok, lines = pcall(vim.fn.readfile, link.path)
	if not ok then
		vim.notify("无法读取文件: " .. link.path, vim.log.levels.ERROR)
		return
	end

	local start_line = math.max(1, link.line - 3)
	local end_line = math.min(#lines, link.line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		context_lines[#context_lines + 1] = lines[i]
	end

	-- 使用 Neovim 内置的文件类型检测
	local filetype = get_filetype(link.path)

	-- 获取文件名作为标题
	local filename = get_filename(link.path)

	vim.lsp.util.open_floating_preview(context_lines, filetype, {
		border = "rounded",
		focusable = true,
		wrap_at = 80,
		title = " " .. filename .. " ",
	})
end

return M
