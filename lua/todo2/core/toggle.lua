-- lua/todo2/core/toggle.lua
local M = {}

local function replace_status(bufnr, lnum, from, to)
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line then
		return false
	end

	local start_col, end_col = line:find(from)
	if not start_col then
		return false
	end

	vim.api.nvim_buf_set_text(bufnr, lnum - 1, start_col - 1, lnum - 1, end_col, { to })
	return true
end

local function toggle_task_and_children(task, bufnr, new_status)
	if new_status == nil then
		new_status = not task.is_done
	end

	local success
	if new_status then
		success = replace_status(bufnr, task.line_num, "%[ %]", "[x]")
	else
		success = replace_status(bufnr, task.line_num, "%[[xX]%]", "[ ]")
	end

	if success then
		task.is_done = new_status
	end

	for _, child in ipairs(task.children) do
		toggle_task_and_children(child, bufnr, new_status)
	end
end

---------------------------------------------------------------------
-- ⭐ 纯逻辑切换（不写盘、不刷新 UI、不触发 sync）
-- 写盘由 autosave.request_save() 负责
-- UI 刷新由 autosave 写盘后自动触发
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum)
	local parser = require("todo2.core.parser")
	local core = require("todo2.core")

	-- 1. 解析任务树
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local tasks = parser.parse_tasks(lines)

	-- 2. 找到当前任务
	local current_task
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		return false, "不是任务行"
	end

	-- 3. 切换当前任务 + 子任务
	toggle_task_and_children(current_task, bufnr, nil)

	-- 4. 重新计算统计
	core.calculate_all_stats(tasks)

	-- 5. 父子联动（纯逻辑，不写盘）
	core.sync_parent_child_state(tasks, bufnr)

	return true, current_task.is_done
end

return M
