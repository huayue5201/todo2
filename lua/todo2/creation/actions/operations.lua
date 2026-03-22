-- lua/todo2/ui/operations.lua
-- UI 层，只处理用户交互

local M = {}

local state_manager = require("todo2.core.state_manager")
local service = require("todo2.creation.service")

---------------------------------------------------------------------
-- 批量切换任务状态（可视模式）
function M.toggle_selected_tasks(bufnr)
	local start_line = vim.fn.line("v")
	local end_line = vim.fn.line(".")

	-- 修复：传入 opts 参数（可以为空表）
	local results = state_manager.toggle_range(bufnr, start_line, end_line, {})

	-- 退出可视模式
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

	return results.success
end

---------------------------------------------------------------------
-- 切换当前行任务（单行）
---------------------------------------------------------------------
function M.toggle_current_line()
	local bufnr = vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	return state_manager.toggle_line(bufnr, lnum)
end

---------------------------------------------------------------------
-- 插入任务（保持不变）
---------------------------------------------------------------------
function M.insert_task(text, indent_extra, bufnr)
	local target_buf = bufnr or vim.api.nvim_get_current_buf()
	local lnum = vim.fn.line(".")

	local result = service.insert_task_line(target_buf, lnum, {
		indent = indent_extra and string.rep(" ", indent_extra) or "",
		content = text or "新任务",
	})

	if result and result.line_num then
		M.place_cursor_at_line_end(0, result.line_num)
		M.start_insert_at_line_end()
	end
end

---------------------------------------------------------------------
-- 光标工具函数
---------------------------------------------------------------------
function M.place_cursor_at_line_end(win, lnum)
	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_get_current_win()
	end

	local bufnr = vim.api.nvim_win_get_buf(win)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
	vim.api.nvim_win_set_cursor(win, { lnum, #line })
end

function M.start_insert_at_line_end()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "n", true)
end

---------------------------------------------------------------------
-- 创建子任务
---------------------------------------------------------------------
function M.create_child_task(parent_bufnr, parent_task, child_id, content)
	return service.create_child_task(parent_bufnr, parent_task, child_id, content)
end

return M
