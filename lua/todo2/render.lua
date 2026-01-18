-- lua/todo2/render.lua
--- @module todo2.render
--- @brief 专业版：只负责渲染，不负责解析任务树

local M = {}

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------
local ns = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 工具函数：安全获取行文本
---------------------------------------------------------------------
local function get_line(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line or ""
end

---------------------------------------------------------------------
-- 渲染单个任务
---------------------------------------------------------------------
function M.render_task(bufnr, task)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local row = task.line_num - 1
	local line = get_line(bufnr, row)
	local line_len = #line

	-----------------------------------------------------------------
	-- 删除线（优先级高）
	-----------------------------------------------------------------
	if task.is_done then
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_row = row,
			end_col = line_len,
			hl_group = "TodoStrikethrough",
			hl_mode = "combine",
			priority = 200,
		})

		-- 灰色高亮（优先级略低）
		vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
			end_row = row,
			end_col = line_len,
			hl_group = "TodoCompleted",
			hl_mode = "combine",
			priority = 190,
		})
	end

	-----------------------------------------------------------------
	-- 子任务统计（EOL 虚拟文本）
	-----------------------------------------------------------------
	if task.children and #task.children > 0 and task.stats then
		local done = task.stats.done or 0
		local total = task.stats.total or 0

		vim.api.nvim_buf_set_extmark(bufnr, ns, row, -1, {
			virt_text = {
				{ string.format(" (%d/%d)", done, total), "Comment" },
			},
			virt_text_pos = "eol",
			hl_mode = "combine",
			right_gravity = false,
			priority = 300,
		})
	end
end

---------------------------------------------------------------------
-- 递归渲染任务树
---------------------------------------------------------------------
local function render_tree(bufnr, task)
	M.render_task(bufnr, task)
	for _, child in ipairs(task.children or {}) do
		render_tree(bufnr, child)
	end
end

---------------------------------------------------------------------
-- ⭐ 专业版：自动从 parser 缓存获取任务树
---------------------------------------------------------------------
function M.render_all(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 通过模块管理器获取 parser 模块
	local module = require("todo2.module")
	local parser = module.get("core.parser")

	-- 获取文件路径
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return
	end

	-- 使用 parser 缓存（parse_file 已在 refresh_pipeline 中调用）
	local tasks, roots = parser.parse_file(path)

	-- roots 可能为 nil（空文件 / 无任务）
	roots = roots or {}

	-- 清除旧渲染（幂等）
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	-- 渲染所有根任务
	for _, task in ipairs(roots) do
		render_tree(bufnr, task)
	end
end

---------------------------------------------------------------------
-- 清理命名空间缓存（可选）
---------------------------------------------------------------------
function M.clear_cache()
	-- 未来可扩展
end

return M
