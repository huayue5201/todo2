-- lua/todo2/link/preview.lua
--- @module todo2.link.preview
--- @brief 预览 TODO 或代码（基于 parser 权威任务树，修复存储API调用）

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 常量定义
---------------------------------------------------------------------
local TODO_REF_PATTERN = "(%u+):ref:(%w+)" -- 匹配 TODO:ref:ID
local CODE_ANCHOR_PATTERN = "{#(%w+)}" -- 匹配 {#ID}

---------------------------------------------------------------------
-- ⭐ 预览 TODO（基于 parser 权威任务树，利用内置 ID 映射）
---------------------------------------------------------------------
function M.preview_todo()
	local line = vim.fn.getline(".")
	local tag, id = line:match(TODO_REF_PATTERN)
	if not id then
		return
	end

	-- 获取存储模块
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

	-- 使用 parser 解析任务树，直接获取 id → task 映射（O(1) 查找）
	local parser = module.get("core.parser")
	if not parser then
		vim.notify("无法获取 core.parser 模块", vim.log.levels.ERROR)
		return
	end

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

	-- 收集整个子树的所有任务 ID
	local all = {}
	local function collect(t)
		table.insert(all, t)
		for _, c in ipairs(t.children or {}) do
			collect(c)
		end
	end
	collect(root)

	-- 计算展示范围（最小行号 → 最大行号）
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

	-- 收集展示内容（按行数组，修复浮窗换行问题）
	local preview_lines = {}
	for i = min_line, max_line do
		preview_lines[#preview_lines + 1] = lines[i] or "" -- 空行保护
	end

	-- 打开浮窗
	vim.lsp.util.open_floating_preview(preview_lines, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

---------------------------------------------------------------------
-- ⭐ 预览代码（保持原逻辑，修复存储API调用及浮窗换行）
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

	-- 提取上下文（前后各3行）
	local start_line = math.max(1, link.line - 3)
	local end_line = math.min(#lines, link.line + 3)
	local context_lines = {}

	for i = start_line, end_line do
		context_lines[#context_lines + 1] = lines[i]
	end

	-- 直接传递行数组，避免换行问题
	vim.lsp.util.open_floating_preview(context_lines, "markdown", {
		border = "rounded",
		focusable = true,
	})
end

return M
