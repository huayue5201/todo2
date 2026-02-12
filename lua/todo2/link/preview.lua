-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（完整任务树，不受 context_split 影响）

local M = {}

---------------------------------------------------------------------
-- 依赖加载（直接 require，避免 module.get 间接调用）
---------------------------------------------------------------------
local parser = require("todo2.core.parser") -- ✅ 直接依赖
local module = require("todo2.module") -- 仍用于获取 store.link

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local TODO_REF_PATTERN = "(%u+):ref:(%w+)"
local CODE_ANCHOR_PATTERN = "{#(%w+)}"

---------------------------------------------------------------------
-- 预览 TODO（始终使用完整任务树）
---------------------------------------------------------------------
function M.preview_todo()
	local line = vim.fn.getline(".")
	local tag, id = line:match(TODO_REF_PATTERN)
	if not id then
		return
	end

	local store_link = module.get("store.link")
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

	vim.lsp.util.open_floating_preview(preview_lines, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

---------------------------------------------------------------------
-- 预览代码（保持原逻辑，不受 parser 影响）
---------------------------------------------------------------------
function M.preview_code()
	local line = vim.fn.getline(".")
	local id = line:match(CODE_ANCHOR_PATTERN)
	if not id then
		return
	end

	local store_link = module.get("store.link")
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

	vim.lsp.util.open_floating_preview(context_lines, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

return M
