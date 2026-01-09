-- lua/todo2/render.lua
--- @module todo2.render
--- @brief 负责 TODO 文件的任务渲染（删除线、灰色高亮、子任务统计）
---
--- 设计目标：
--- 1. 渲染必须稳定、幂等、无闪烁
--- 2. 不产生 extmark 残留
--- 3. 删除线、灰色高亮、统计三者互不干扰
--- 4. 支持递归任务树渲染
--- 5. 未来可扩展（图标、折叠、hover）

local M = {}

---------------------------------------------------------------------
-- 命名空间（用于 extmark）
---------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("todo2_render")

---------------------------------------------------------------------
-- 工具函数：安全获取行文本
---------------------------------------------------------------------

--- 获取某一行文本（安全）
--- @param bufnr integer
--- @param row integer 0-based
--- @return string
local function get_line(bufnr, row)
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line or ""
end

---------------------------------------------------------------------
-- 渲染单个任务
---------------------------------------------------------------------

--- 渲染单个任务（删除线、灰色高亮、子任务统计）
---
--- @param bufnr integer
--- @param task table { line_num, is_done, stats?, children? }
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
-- 渲染所有根任务
---------------------------------------------------------------------

--- 渲染整个 TODO 文件
---
--- @param bufnr integer
--- @param root_tasks table[]
function M.render_all(bufnr, root_tasks)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 清除旧渲染（幂等）
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	for _, task in ipairs(root_tasks) do
		render_tree(bufnr, task)
	end
end

---------------------------------------------------------------------
-- 清理命名空间缓存（可选）
---------------------------------------------------------------------

function M.clear_cache()
	-- 未来可扩展：如果需要缓存渲染 diff，可在此清理
end

return M
