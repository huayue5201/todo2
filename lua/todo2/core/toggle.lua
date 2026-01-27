-- lua/todo2/core/toggle.lua
--- @module todo2.core.toggle

local M = {}

---------------------------------------------------------------------
-- 模块管理器
---------------------------------------------------------------------
local module = require("todo2.module")

---------------------------------------------------------------------
-- 工具：替换行内状态
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 递归切换任务 + 子任务（修改版：只向下传播一层）
---------------------------------------------------------------------
local function toggle_task_and_children(task, bufnr)
	-- 切换当前任务状态
	local success
	if task.is_done then
		success = replace_status(bufnr, task.line_num, "%[[xX]%]", "[ ]")
		task.is_done = false
	else
		success = replace_status(bufnr, task.line_num, "%[ %]", "[x]")
		task.is_done = true
	end

	-- 如果是父任务，切换所有直接子任务（不递归处理孙子任务）
	if #task.children > 0 then
		for _, child in ipairs(task.children) do
			if task.is_done then
				replace_status(bufnr, child.line_num, "%[ %]", "[x]")
				child.is_done = true
			else
				replace_status(bufnr, child.line_num, "%[[xX]%]", "[ ]")
				child.is_done = false
			end
		end
	end

	return success
end

---------------------------------------------------------------------
-- ⭐ 新版 toggle：基于 parser.parse_file(path)
---------------------------------------------------------------------
function M.toggle_line(bufnr, lnum, opts)
	opts = opts or {}

	-----------------------------------------------------------------
	-- 1. 获取文件路径（parser 需要 path）
	-----------------------------------------------------------------
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer 没有文件路径"
	end

	-----------------------------------------------------------------
	-- 2. 使用 parser.parse_file(path) 获取任务树
	-----------------------------------------------------------------
	local parser_mod = module.get("core.parser")
	local tasks, roots = parser_mod.parse_file(path)

	-----------------------------------------------------------------
	-- 3. 找到当前任务
	-----------------------------------------------------------------
	local current_task = nil
	for _, task in ipairs(tasks) do
		if task.line_num == lnum then
			current_task = task
			break
		end
	end

	if not current_task then
		return false, "不是任务行"
	end

	-----------------------------------------------------------------
	-- 4. 切换当前任务 + 子任务
	-----------------------------------------------------------------
	local success = toggle_task_and_children(current_task, bufnr)

	-----------------------------------------------------------------
	-- 5. 重新计算统计（基于 parser 的任务树）
	-----------------------------------------------------------------
	local stats_mod = module.get("core.stats")
	stats_mod.calculate_all_stats(tasks)

	-----------------------------------------------------------------
	-- 6. 父子联动（向上同步父任务状态）
	-----------------------------------------------------------------
	local sync_mod = module.get("core.sync")
	sync_mod.sync_parent_child_state(tasks, bufnr)

	-----------------------------------------------------------------
	-- 7. 如果跳过写盘，直接返回
	-----------------------------------------------------------------
	if opts.skip_write then
		return success, current_task.is_done
	end

	-----------------------------------------------------------------
	-- 8. 触发自动保存
	-----------------------------------------------------------------
	local autosave = module.get("core.autosave")
	if autosave and autosave.request_save then
		autosave.request_save(bufnr)
	end

	return success, current_task.is_done
end

return M
